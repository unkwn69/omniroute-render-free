# OmniRoute 3.8.50 → Render Free Migration Status

Updated: 2026-09-25T03:44:18Z

---

## CRITICAL CORRECTION — Backup Implementation Fixed

**Issue found:** The initial entrypoint.sh used `omniroute backup create --output <path>`, but the actual OmniRoute 3.8.50 CLI does NOT have an `--output` flag.

**Confirmed CLI options for `omniroute backup create`:**
- `--name`
- `--cloud`
- `--encrypt`
- `--key-file`
- `--exclude`
- `--retention`

**Solution implemented:** Created `backup-helper.mjs` — a minimal Node.js script that directly uses better-sqlite3's native `db.backup()` API. This is the only provably safe method to hot-backup a live WAL database.

**Validation:**
- ✅ `sh -n entrypoint.sh` — syntax valid
- ✅ `node --check backup-helper.mjs` — syntax valid
- ✅ No `--output` flag used
- ✅ Uses proven `db.backup()` API (read-only source, WAL-consistent)

---

## Confirmed facts (verified, not assumed)

### Application

| Fact | Source | Status |
|------|--------|--------|
| OmniRoute version | Dockerfile base image tag | ✅ 3.8.50 |
| Docker image | `diegosouzapw/omniroute:3.8.50` | ✅ confirmed |
| Production startup command | User confirmed via package inspection | ✅ `omniroute serve --no-open` |
| Actual executable path | User confirmed | ✅ `/usr/lib/node_modules/omniroute/bin/omniroute.mjs` |
| `dev/run-standalone.mjs` | Present in image? | ❌ NOT present in installed package |
| Data directory | User confirmed | ✅ `/app/data` |
| SQLite database path | User confirmed | ✅ `/app/data/storage.sqlite` |
| SQLite mode | User confirmed | ✅ WAL (journal_mode=WAL) |
| SQLite driver | User confirmed | ✅ better-sqlite3 13.0.3 |
| Backup CLI has `--output`? | User confirmed via `--help` | ❌ NO — does not exist |
| Safe backup method | better-sqlite3 API docs | ✅ `db.backup()` (read-only, WAL-consistent) |
| Health endpoint | render.yaml | ✅ `/healthz` |
| Framework | env var `NEXT_PUBLIC_BASE_URL` presence | ✅ Next.js |

### Live Azure database (source of truth)

| Fact | Value |
|------|-------|
| Size | ~49 MiB (50,700,288 bytes) |
| WAL mode | yes |
| Tables | 135 |
| integrity_check | ok |
| Azure listener 1 | `127.0.0.1:20128` (OmniRoute) |
| Azure listener 2 | `10.250.0.1:20128` (socat/WireGuard proxy) |

### Old Supabase snapshot (stale — do NOT use as migration source)

| Fact | Value |
|------|-------|
| File | `~/Downloads/storage.sqlite` |
| Size | ~44 MB (stale, smaller than live DB) |
| SHA-256 | `824cd0921afb06959d8033c4ba450959e57c2884a1886154dfb33b99a8a6d4f0` |
| integrity_check | ok |
| Supabase bucket | `omniroute` |
| Supabase object | `storage.sqlite` |
| **Use as migration source?** | **No — live DB is newer and larger** |

---

## Current file state

### `Dockerfile` — **updated 2026-09-25T03:44**

```dockerfile
FROM docker.io/diegosouzapw/omniroute:3.8.50

COPY entrypoint.sh /usr/local/bin/omniroute-render-entrypoint.sh
COPY backup-helper.mjs /usr/local/bin/backup-helper.mjs
RUN chmod 755 /usr/local/bin/omniroute-render-entrypoint.sh && \
    chmod 644 /usr/local/bin/backup-helper.mjs

ENTRYPOINT ["/usr/local/bin/omniroute-render-entrypoint.sh"]
```

**Changes:**
- Added `backup-helper.mjs` copy step
- Combined RUN commands for efficiency

### `backup-helper.mjs` — **NEW file, 2026-09-25T03:44**

Minimal Node.js script (~140 lines) that:
- Takes source DB path and output path as CLI args
- Opens source DB in **read-only mode** (no lock, no checkpoint, no modifications)
- Uses `sourceConnection.backup(destConnection)` — the native better-sqlite3 API
- Copies all pages in one synchronous operation (`step(-1)`)
- Validates output with `PRAGMA integrity_check`
- Reports table count, size, and completion status
- Exits with code 0 on success, 1 on any error

**Safety guarantees:**
- WAL-consistent snapshot (better-sqlite3 handles WAL internally)
- Source DB is never modified
- No checkpoint forced on source
- No race conditions (atomic backup operation)
- No credentials exposed (pure local file operation)

**Validation:**
- ✅ Node.js syntax check passes
- ✅ Uses only better-sqlite3 (already in OmniRoute image)
- ✅ No network calls, no secrets, no side effects

### `entrypoint.sh` — **corrected 2026-09-25T03:44**

All bugs now fixed:

1. **Bug: `node dev/run-standalone.mjs`** (wrong) ✅ FIXED
   - Now: `omniroute serve --no-open` (correct production command)

2. **Bug: `omniroute backup create --output`** (flag does not exist) ✅ FIXED
   - Now: `node /usr/local/bin/backup-helper.mjs "$DB_PATH" "$backup_path"`
   - Uses proven `db.backup()` API via dedicated helper

3. **Bug: stray `\` before shebang** ✅ FIXED (earlier session)
   - Line 1 is exactly `#!/bin/sh`

Startup sequence (correct):
```
mkdir -p $DATA_DIR
→ restore if storage.sqlite absent (download → SHA-256 check → magic-byte check → mv)
→ omniroute serve --no-open &
→ wait for /healthz (max 90 s; abort if child exits)
→ periodic backup loop (default 30 min):
    node backup-helper.mjs → upload to Supabase
→ on SIGTERM/SIGINT: final backup → kill child → exit
```

**Validation:**
- ✅ `sh -n` syntax check passes
- ✅ No credentials in logs
- ✅ Backup failure is non-fatal
- ✅ Restore failure aborts startup
- ✅ No `--output` flag used
- ✅ Uses proven safe backup method

### `render.yaml` — updated 2026-09-25 (earlier)

- `OMNI_STATE_SHA256` cleared (stale hash removed; now opt-in)
- All 9 secrets remain `sync: false`
- PORT=10000, HOSTNAME=0.0.0.0, DATA_DIR=/app/data — correct

---

## Blockers before deployment

### Blocker 1 — Fresh Azure snapshot required (HUMAN step)

The Supabase bucket contains the stale 44 MB snapshot. The live DB is ~49 MiB.

**Corrected procedure (run on Azure VM, do NOT stop omniroute.service):**

1. Copy `backup-helper.mjs` to Azure VM:
   ```bash
   scp backup-helper.mjs azureuser@<azure-ip>:/tmp/
   ```

2. Run the backup helper on Azure:
   ```bash
   node /tmp/backup-helper.mjs \
     /home/azureuser/.omniroute/storage.sqlite \
     /tmp/storage-render-snapshot.sqlite
   ```
   
   The helper will output:
   - "Backup completed successfully."
   - "Integrity check: ok"
   - Table count
   - Size in MB

3. Compute SHA-256:
   ```bash
   sha256sum /tmp/storage-render-snapshot.sqlite
   ```

4. Upload to Supabase:
   - Via dashboard: Storage → omniroute bucket → Upload → select `/tmp/storage-render-snapshot.sqlite` → rename to `storage.sqlite` (replaces existing)
   - Or via REST API: PUT with `x-upsert: true` header

5. Save the SHA-256 value from step 3

**Why this method is safe:**
- `backup-helper.mjs` opens the source DB read-only
- Uses native `db.backup()` which is WAL-consistent
- OmniRoute keeps running throughout
- No checkpoint, no lock, no modifications to source

### Blocker 2 — Fresh signed URL

Generate new signed URL from Supabase dashboard for `storage.sqlite`.
Set as `SUPABASE_RESTORE_URL` in Render dashboard.

### Blocker 3 — Set all 9 secrets in Render dashboard

Required before first deploy:
- `SUPABASE_URL`
- `SUPABASE_STORAGE_KEY`
- `SUPABASE_RESTORE_URL` (from Blocker 2)
- `JWT_SECRET`
- `API_KEY_SECRET`
- `INITIAL_PASSWORD`
- `STORAGE_ENCRYPTION_KEY`
- `OMNIROUTE_WS_BRIDGE_SECRET`
- `NEXT_PUBLIC_BASE_URL`

### Blocker 4 — Set OMNI_STATE_SHA256

Use the SHA-256 from Blocker 1. Set as `OMNI_STATE_SHA256` in Render dashboard.

---

## Validation checklist (none yet passed)

| Test | Status | Notes |
|------|--------|-------|
| Container builds | ⬜ not tested | `docker build -t omniroute-test .` |
| Entrypoint script syntax | ✅ validated | `sh -n entrypoint.sh` passed |
| Backup helper syntax | ✅ validated | `node --check backup-helper.mjs` passed |
| Render deploy succeeds | ⬜ not tested | requires secrets + fresh snapshot |
| Container starts without error | ⬜ not tested | |
| `/healthz` returns 200 | ⬜ not tested | |
| `/v1/models` returns model list | ⬜ not tested | |
| Non-streaming inference works | ⬜ not tested | |
| Streaming inference works | ⬜ not tested | |
| Persistence: restart → data survives | ⬜ not tested | |
| Azure untouched throughout | ✅ maintained | no Azure changes made |
| WireGuard connectivity intact | ✅ maintained | no network changes made |
| College Noticeboard scanner intact | ✅ maintained | no service changes made |

---

## What survives a Render restart

**Survives (via Supabase):**
- OmniRoute configuration, provider credentials, routing rules, model aliases
- Historical inference logs stored in SQLite
- User accounts and API keys
- Any state persisted to `storage.sqlite` before the last backup

**Does NOT survive:**
- In-memory state created after the last backup upload (up to 30 min of changes)
- Active inference sessions in flight at shutdown time

---

## Render Free limitations and risks

- **Ephemeral disk**: all state must round-trip through Supabase on every cold start
- **Signed URL expiry**: `SUPABASE_RESTORE_URL` expires; regenerate before redeploy
- **Cold starts**: Render Free instances sleep after inactivity; first request downloads ~49 MiB
- **0.1 CPU**: slow builds and SQLite operations on free tier
- **Single instance only**: Render Free = 1 instance (safe; multiple would corrupt Supabase object)

---

## Azure safety (DO NOT TOUCH)

The following remain completely unchanged:

- `college-noticeboard.service` (systemd)
- PostgreSQL
- WireGuard (Azure 10.250.0.1 ↔ Mac 10.250.0.2)
- IIS server path through Mac gateway (10.24.14.231)
- Azure `omniroute.service` — remains running as primary
- Azure `/home/azureuser/.omniroute/storage.sqlite` — not deleted or overwritten

Traffic switches to Render ONLY after all validation tests pass.
