#!/bin/sh
# OmniRoute 3.8.50 — Render Free entrypoint
#
# Startup sequence:
#   1. Create /app/data.
#   2. If /app/data/storage.sqlite is absent:
#      a. Read manifest from Supabase to find current snapshot object + SHA-256.
#      b. Download the gzip snapshot using server-side API key auth (Node.js fetch).
#      c. Verify gzip integrity (gunzip -t).
#      d. Decompress to a temp path.
#      e. Verify decompressed SHA-256 matches manifest / OMNI_STATE_SHA256.
#      f. Run SQLite magic-byte check on decompressed file.
#      g. Run SQLite PRAGMA integrity_check.
#      h. Only then atomically move it to /app/data/storage.sqlite.
#   3. Start exactly ONE OmniRoute process: omniroute serve --no-open
#   4. Wait for health endpoint (max 90 s). Abort if child exits.
#   5. Enter periodic backup loop (default 30 min):
#      a. Run backup-helper.mjs → produces <stamp>.sqlite.gz + BACKUP_SHA256.
#      b. Validate backup integrity.
#      c. Upload gz to Supabase (Node.js fetch).
#      d. Upload manifest (JSON: {object, sha256}) to Supabase (Node.js fetch).
#   6. On SIGTERM/INT: attempt one final backup, then shut down.
#
# Safety rules:
#   - NEVER log SUPABASE_KEY or any credential value.
#   - Restore failure aborts startup — no empty-DB fallback.
#   - Backup failure is non-fatal (logs warning; server keeps running).
#   - Manifest is only updated AFTER snapshot upload is confirmed.
#   - Only one snapshot object is maintained (bounded storage).

set -eu

# ── Configuration ─────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
BACKUP_INTERVAL="${OMNI_STATE_BACKUP_INTERVAL_SECONDS:-1800}"
export PORT="${PORT:-10000}"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"
export OMNIROUTE_SERVER_HOST="${OMNIROUTE_SERVER_HOST:-0.0.0.0}"

# Low-RAM Render Free defaults. These are upstream-supported OmniRoute
# controls intended for constrained containers. Render Free has a hard
# 512 MiB memory limit, so the Node heap and nonessential background work
# must be bounded before the app starts. Dashboard env vars can override
# these defaults when a larger instance is used later.
export OMNIROUTE_MEMORY_MB="${OMNIROUTE_MEMORY_MB:-128}"
export PROMPT_CACHE_MAX_SIZE="${PROMPT_CACHE_MAX_SIZE:-10}"
export PROMPT_CACHE_MAX_BYTES="${PROMPT_CACHE_MAX_BYTES:-524288}"
export SEMANTIC_CACHE_MAX_SIZE="${SEMANTIC_CACHE_MAX_SIZE:-10}"
export SEMANTIC_CACHE_MAX_BYTES="${SEMANTIC_CACHE_MAX_BYTES:-1048576}"
export STREAM_HISTORY_MAX="${STREAM_HISTORY_MAX:-10}"
export OMNIROUTE_DISABLE_BACKGROUND_SERVICES="${OMNIROUTE_DISABLE_BACKGROUND_SERVICES:-true}"
export OMNIROUTE_DISABLE_CREDENTIAL_HEALTH_CHECK="${OMNIROUTE_DISABLE_CREDENTIAL_HEALTH_CHECK:-true}"
export OMNIROUTE_DISABLE_CONNECTION_RECOVERY="${OMNIROUTE_DISABLE_CONNECTION_RECOVERY:-true}"
export OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT="${OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT:-1}"
export OMNIROUTE_CHAT_ADMISSION_HEALTHY_HEADROOM="${OMNIROUTE_CHAT_ADMISSION_HEALTHY_HEADROOM:-0}"
export APP_LOG_TO_FILE="${APP_LOG_TO_FILE:-false}"
HEALTH_PORT="$PORT"

# Supabase config (server-side only — never logged)
export SUPABASE_URL="${SUPABASE_URL:-}"
export SUPABASE_STORAGE_KEY="${SUPABASE_STORAGE_KEY:-}"
export SUPABASE_BUCKET="${SUPABASE_BUCKET:-omniroute}"

# Snapshot and manifest object names
SUPABASE_SNAPSHOT_OBJECT="${SUPABASE_SNAPSHOT_OBJECT:-storage-render-snapshot.sqlite.gz}"
SUPABASE_MANIFEST_OBJECT="${SUPABASE_MANIFEST_OBJECT:-snapshot-manifest.json}"

# Initial required SHA-256 of DECOMPRESSED database (from verified Azure snapshot).
# After first backup cycle, manifest takes over. Leave blank to skip initial check.
OMNI_STATE_SHA256="${OMNI_STATE_SHA256:-0d85a22546dcb117c2b81903d3a709d9d112a5dccaf8b89b5b63671642649c81}"

mkdir -p "$DATA_DIR"

BACKUP_HELPER="/usr/local/bin/backup-helper.mjs"
STORAGE_HELPER="/usr/local/bin/storage-helper.mjs"

# ── Helpers ───────────────────────────────────────────────────────────────────

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_sqlite_file() {
  # SQLite magic: "SQLite format 3\000" (16 bytes)
  # hex: 53514c69746520666f726d6174203300
  actual="$(dd if="$1" bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  case "$actual" in
    53514c69746520666f726d6174203300*) return 0 ;;
    *) return 1 ;;
  esac
}

supabase_download() {
  local obj="$1"
  local out="$2"
  node "$STORAGE_HELPER" download "$obj" "$out"
}

supabase_upload() {
  local obj="$1"
  local src="$2"
  local ct="${3:-application/octet-stream}"
  node "$STORAGE_HELPER" upload "$obj" "$src" "$ct"
}

# ── Restore ───────────────────────────────────────────────────────────────────

restore_state() {
  if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_STORAGE_KEY" ]; then
    echo "[entrypoint] SUPABASE_URL or SUPABASE_STORAGE_KEY is not set — cannot restore." >&2
    exit 1
  fi

  local tmp_gz="$DATA_DIR/.restore.$$.sqlite.gz"
  local tmp_sql="$DATA_DIR/.restore.$$.sqlite"
  local expected_sha256="$OMNI_STATE_SHA256"

  # Try to read manifest first (preferred — overrides OMNI_STATE_SHA256 after first backup)
  local manifest_tmp="$DATA_DIR/.manifest.$$.json"
  if supabase_download "$SUPABASE_MANIFEST_OBJECT" "$manifest_tmp" 2>/dev/null; then
    local manifest_obj
    local manifest_sha
    manifest_obj="$(node -e "try{const m=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write(m.object||'')}catch(e){}" "$manifest_tmp" 2>/dev/null || true)"
    manifest_sha="$(node -e "try{const m=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write(m.sha256||'')}catch(e){}" "$manifest_tmp" 2>/dev/null || true)"
    rm -f "$manifest_tmp"
    if [ -n "$manifest_obj" ] && [ -n "$manifest_sha" ]; then
      echo "[entrypoint] manifest found: object=$manifest_obj"
      SUPABASE_SNAPSHOT_OBJECT="$manifest_obj"
      expected_sha256="$manifest_sha"
    else
      echo "[entrypoint] manifest found but could not parse — falling back to OMNI_STATE_SHA256."
    fi
  else
    echo "[entrypoint] no manifest found — using OMNI_STATE_SHA256 and default snapshot object."
    rm -f "$manifest_tmp" 2>/dev/null || true
  fi

  echo "[entrypoint] downloading snapshot: $SUPABASE_SNAPSHOT_OBJECT"
  if ! supabase_download "$SUPABASE_SNAPSHOT_OBJECT" "$tmp_gz"; then
    echo "[entrypoint] snapshot download failed." >&2
    rm -f "$tmp_gz"
    exit 1
  fi

  # Verify gzip integrity
  echo "[entrypoint] verifying gzip integrity..."
  if ! gunzip -t "$tmp_gz" 2>/dev/null; then
    echo "[entrypoint] gzip integrity check failed — rejecting snapshot." >&2
    rm -f "$tmp_gz"
    exit 1
  fi

  # Decompress
  echo "[entrypoint] decompressing..."
  if ! gunzip -c "$tmp_gz" > "$tmp_sql"; then
    echo "[entrypoint] decompression failed." >&2
    rm -f "$tmp_gz" "$tmp_sql"
    exit 1
  fi
  rm -f "$tmp_gz"

  # SHA-256 verification
  if [ -n "$expected_sha256" ]; then
    actual="$(sha256_file "$tmp_sql")"
    if [ "$actual" != "$expected_sha256" ]; then
      echo "[entrypoint] SHA-256 mismatch — rejecting snapshot." >&2
      echo "[entrypoint] expected=$expected_sha256" >&2
      echo "[entrypoint] actual=$actual" >&2
      rm -f "$tmp_sql"
      exit 1
    fi
    echo "[entrypoint] SHA-256 verified."
  else
    echo "[entrypoint] WARNING: OMNI_STATE_SHA256 is not set — skipping SHA-256 verification." >&2
  fi

  # SQLite magic-byte check
  if ! is_sqlite_file "$tmp_sql"; then
    echo "[entrypoint] decompressed file is not a SQLite database — rejecting." >&2
    rm -f "$tmp_sql"
    exit 1
  fi

  # PRAGMA integrity_check
  echo "[entrypoint] validating SQLite integrity..."
  if ! node "$STORAGE_HELPER" verify-sqlite "$tmp_sql"; then
    echo "[entrypoint] SQLite integrity check failed — rejecting." >&2
    rm -f "$tmp_sql"
    exit 1
  fi

  # Atomic move to final path
  mv "$tmp_sql" "$DB_PATH"
  echo "[entrypoint] database restored to $DB_PATH."
}

shutting_down=0

# ── Backup ────────────────────────────────────────────────────────────────────

backup_state() {
  if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_STORAGE_KEY" ]; then
    echo "[entrypoint] Supabase credentials absent — skipping backup."
    return 0
  fi

  if [ ! -f "$DB_PATH" ]; then
    echo "[entrypoint] $DB_PATH not found — skipping backup." >&2
    return 0
  fi

  if [ ! -f "$BACKUP_HELPER" ]; then
    echo "[entrypoint] backup-helper.mjs not found — skipping backup." >&2
    return 0
  fi

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local backup_gz="$DATA_DIR/.backup.$stamp.sqlite.gz"

  echo "[entrypoint] starting backup (native db.backup + gzip)..."
  local result
  if ! result="$(node "$BACKUP_HELPER" "$DB_PATH" "$backup_gz" 2>/dev/null)"; then
    echo "[entrypoint] backup helper failed — skipping upload." >&2
    rm -f "$backup_gz"
    return 0
  fi

  if [ ! -f "$backup_gz" ]; then
    echo "[entrypoint] backup produced no output file — skipping upload." >&2
    return 0
  fi

  local backup_sha256
  backup_sha256="$(printf '%s\n' "$result" | grep '^BACKUP_UNCOMPRESSED_SHA256=' | cut -d= -f2 | tr -d '[:space:]')"
  local backup_integrity
  backup_integrity="$(printf '%s\n' "$result" | grep '^BACKUP_INTEGRITY=' | cut -d= -f2 | tr -d '[:space:]')"

  if [ "$backup_integrity" != "ok" ]; then
    echo "[entrypoint] backup integrity check failed — skipping upload." >&2
    rm -f "$backup_gz"
    return 0
  fi

  if [ -z "$backup_sha256" ]; then
    echo "[entrypoint] backup helper did not produce SHA-256 — skipping upload." >&2
    rm -f "$backup_gz"
    return 0
  fi

  echo "[entrypoint] uploading backup snapshot..."
  if ! supabase_upload "$SUPABASE_SNAPSHOT_OBJECT" "$backup_gz" "application/gzip"; then
    echo "[entrypoint] snapshot upload failed (non-fatal)." >&2
    rm -f "$backup_gz"
    return 0
  fi
  echo "[entrypoint] snapshot uploaded."
  rm -f "$backup_gz"

  local manifest_tmp="$DATA_DIR/.manifest.$stamp.json"
  printf '{"object":"%s","sha256":"%s","ts":"%s"}\n' \
    "$SUPABASE_SNAPSHOT_OBJECT" "$backup_sha256" "$stamp" > "$manifest_tmp"

  if supabase_upload "$SUPABASE_MANIFEST_OBJECT" "$manifest_tmp" "application/json"; then
    echo "[entrypoint] manifest updated."
  else
    echo "[entrypoint] manifest upload failed (non-fatal — snapshot was uploaded)." >&2
  fi
  rm -f "$manifest_tmp"
}

# ── Main: restore if absent ───────────────────────────────────────────────────

if [ ! -f "$DB_PATH" ]; then
  restore_state
fi

# ── Start OmniRoute ───────────────────────────────────────────────────────────

OMNIROUTE_ENTRY="/app/dev/run-standalone.mjs"

if [ ! -f "$OMNIROUTE_ENTRY" ]; then
  echo "[entrypoint] ERROR: $OMNIROUTE_ENTRY not found." >&2
  exit 1
fi

echo "[entrypoint] starting OmniRoute (node $OMNIROUTE_ENTRY)..."

node "$OMNIROUTE_ENTRY" &

child_pid=$!

# ── Health-check wait ─────────────────────────────────────────────────────────

echo "[entrypoint] waiting for OmniRoute on port $HEALTH_PORT..."
startup_timeout=90
startup_elapsed=0

while [ $startup_elapsed -lt $startup_timeout ]; do
  if ! kill -0 "$child_pid" 2>/dev/null; then
    echo "[entrypoint] OmniRoute exited unexpectedly during startup." >&2
    wait "$child_pid" || true
    exit 1
  fi

  if node "$STORAGE_HELPER" health "$HEALTH_PORT" "/healthz" 2>/dev/null; then
    echo "[entrypoint] OmniRoute healthy."
    break
  fi

  sleep 3
  startup_elapsed=$((startup_elapsed + 3))
done

if [ $startup_elapsed -ge $startup_timeout ]; then
  echo "[entrypoint] OmniRoute did not become healthy within ${startup_timeout}s." >&2
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$child_pid" || true
  exit 1
fi

# ── Shutdown handler ──────────────────────────────────────────────────────────

term_handler() {
  echo "[entrypoint] shutdown signal — stopping OmniRoute and running final backup..."
  shutting_down=1
  trap '' TERM INT

  # Gracefully stop OmniRoute so final backup reads a quiesced DB
  kill -TERM "$child_pid" 2>/dev/null || true

  # Wait up to 10 s for graceful exit
  grace=0
  while [ "$grace" -lt 10 ] && kill -0 "$child_pid" 2>/dev/null; do
    sleep 1
    grace=$((grace + 1))
  done

  # Final validated backup (non-fatal)
  backup_state || true

  # Force-kill if still running
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  wait "$child_pid" 2>/dev/null || true
  exit 0
}

trap term_handler TERM INT

# ── Periodic backup loop ──────────────────────────────────────────────────────

echo "[entrypoint] backup loop started (interval=${BACKUP_INTERVAL}s)."
while kill -0 "$child_pid" 2>/dev/null; do
  sleep "$BACKUP_INTERVAL" || true
  if kill -0 "$child_pid" 2>/dev/null && [ "$shutting_down" -eq 0 ]; then
    backup_state || true
  fi
done

wait "$child_pid"
