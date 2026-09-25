# OmniRoute 3.8.50 → Render Free Deployment Report

Generated: 2026-09-25T04:43:11Z

---

## EXECUTIVE SUMMARY

**Current Status:** CONFIGURED, NOT YET DEPLOYED

The migration code has been written and validated for syntax. However, deployment requires human actions that cannot be performed from this environment:

1. Testing the backup helper requires better-sqlite3 (not available here)
2. Creating the Azure snapshot requires Azure VM access
3. Uploading to Supabase requires credentials
4. Deploying to Render requires Git push and Render dashboard access

All code is complete and ready. Remaining steps are documented below.

---

## 1. IMPLEMENTED

### ✅ CONFIGURED

| Component | Status | Details |
|-----------|--------|---------|
| `Dockerfile` | ✅ Syntax valid | Uses omniroute:3.8.50, copies entrypoint and backup helper |
| `entrypoint.sh` | ✅ Syntax valid | Uses correct `omniroute serve --no-open` command |
| `backup-helper.mjs` | ✅ Syntax valid | Uses correct `await db.backup(destinationPath)` API |
| `render.yaml` | ✅ Valid YAML | Render Free configuration with all env vars |
| Startup sequence | ✅ Implemented | restore → start → health check → periodic backup |
| Backup method | ✅ Correct API | Uses better-sqlite3 `db.backup()` (WAL-safe) |
| Security | ✅ Clean | No secrets in tracked files |

### ⬜ NOT YET TESTED

The following cannot be tested without:
- better-sqlite3 package (not in this environment)
- Azure VM access
- Docker runtime

| Component | Blocker |
|-----------|---------|
| `backup-helper.mjs` execution | Requires better-sqlite3 installed |
| WAL backup consistency | Requires live WAL database to test against |
| Container build | Requires Docker |
| OmniRoute startup | Requires deployed container |

---

## 2. DEPLOYED

**Status:** ⬜ NOT YET DEPLOYED

**Reason:** Requires human actions:
1. Push code to GitHub
2. Connect Render to repository
3. Configure 9 secrets in Render dashboard
4. Trigger deployment

---

## 3. RENDER URL

**Status:** ⬜ NOT AVAILABLE

Render URL will be assigned after first deployment.

Expected format: `https://omniroute-free.onrender.com` (or similar)

---

## 4. RENDER SERVICE STATUS

**Status:** ⬜ NOT YET CREATED

Service must be created in Render dashboard after pushing code.

---

## 5. DATABASE SNAPSHOT STATUS

### Current State

| Item | Status | Details |
|------|--------|---------|
| Old snapshot (~44 MB) | ⚠️ STALE | Exists in Supabase but smaller than live DB |
| Live Azure DB (~49 MiB) | ✅ LIVE | 50,700,288 bytes, WAL mode, 135 tables, integrity ok |
| Fresh snapshot | ⬜ NOT YET CREATED | Requires running backup-helper.mjs on Azure |

### Required Action

**Run on Azure VM (do NOT stop omniroute.service):**

```bash
# 1. Copy backup helper to Azure
scp backup-helper.mjs azureuser@<azure-ip>:/tmp/

# 2. Run backup helper
cd /tmp
node backup-helper.mjs \
  /home/azureuser/.omniroute/storage.sqlite \
  /tmp/storage-render-snapshot.sqlite

# Expected output:
# [backup-helper] Source: /home/azureuser/.omniroute/storage.sqlite
# [backup-helper] Output: /tmp/storage-render-snapshot.sqlite
# [backup-helper] Opening source database...
# [backup-helper] Creating backup...
# [backup-helper] Backup completed successfully.
# [backup-helper] Integrity check: ok
# [backup-helper] Tables: 135
# [backup-helper] Size: 48.35 MB (50700288 bytes)
# [backup-helper] Done.

# 3. Compute SHA-256
sha256sum /tmp/storage-render-snapshot.sqlite

# 4. Verify integrity
sqlite3 /tmp/storage-render-snapshot.sqlite "PRAGMA integrity_check;"
# Expected: ok

# 5. Verify table count
sqlite3 /tmp/storage-render-snapshot.sqlite "SELECT COUNT(*) FROM sqlite_master WHERE type='table';"
# Expected: 135
```

**Classification:** CONFIGURED (backup-helper.mjs ready), NOT YET EXECUTED

---

## 6. SUPABASE PERSISTENCE STATUS

### Current State

| Item | Status | Details |
|------|--------|---------|
| Supabase bucket | ✅ EXISTS | Bucket: `omniroute` (private) |
| Current object | ⚠️ STALE | Object: `storage.sqlite` (~44 MB, old snapshot) |
| Fresh object upload | ⬜ NOT YET DONE | Requires fresh snapshot from step 5 |
| Signed URL | ⬜ NOT YET GENERATED | Required for SUPABASE_RESTORE_URL |

### Required Actions

**After creating the fresh snapshot:**

1. **Upload to Supabase:**
   - Via Supabase dashboard: Storage → omniroute bucket → Upload
   - Select `/tmp/storage-render-snapshot.sqlite`
   - Rename to `storage.sqlite` (replaces existing)
   - OR use REST API with `x-upsert: true` header

2. **Generate signed URL:**
   - Supabase dashboard: Storage → omniroute → storage.sqlite → Get URL
   - Choose expiry (recommend: 1 year)
   - Save this URL as `SUPABASE_RESTORE_URL` for Render

3. **Verify upload:**
   ```bash
   # Download and verify
   curl -o /tmp/verify-download.sqlite "<signed-url>"
   sha256sum /tmp/verify-download.sqlite
   # Should match the hash from step 5
   ```

**Classification:** CONFIGURED (entrypoint restore logic ready), NOT YET EXECUTED

---

## 7. HEALTH TEST

**Status:** ⬜ NOT YET TESTED

**Requires:** Deployed Render service

**Test command:**
```bash
curl -f https://omniroute-free.onrender.com/healthz
```

**Expected:** HTTP 200

**Classification:** NOT YET TESTED

---

## 8. /v1/MODELS TEST

**Status:** ⬜ NOT YET TESTED

**Requires:** 
- Deployed Render service
- Health check passing

**Test command:**
```bash
curl -H "Authorization: Bearer <api-key>" \
  https://omniroute-free.onrender.com/v1/models
```

**Expected:** JSON list of configured models/providers

**Classification:** NOT YET TESTED

---

## 9. NON-STREAMING INFERENCE TEST

**Status:** ⬜ NOT YET TESTED

**Requires:**
- Deployed Render service
- /v1/models passing

**Test command:**
```bash
curl -X POST https://omniroute-free.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Say hello"}],
    "stream": false
  }'
```

**Expected:** JSON response with completion

**Classification:** NOT YET TESTED

---

## 10. STREAMING TEST

**Status:** ⬜ NOT YET TESTED

**Requires:**
- Non-streaming test passing

**Test command:**
```bash
curl -X POST https://omniroute-free.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Count to 5"}],
    "stream": true
  }'
```

**Expected:** SSE stream with delta chunks

**Classification:** NOT YET TESTED

---

## 11. RESTART/RESTORE TEST

**Status:** ⬜ NOT YET TESTED

**Requires:**
- All above tests passing

**Procedure:**

1. Make harmless state change (e.g., create a test route rule)
2. Wait 30+ minutes for backup to run (or trigger manual restart to force backup-on-shutdown)
3. Verify backup uploaded to Supabase
4. Redeploy Render service (forces cold start)
5. Wait for restore from Supabase
6. Verify state change survived
7. Run /v1/models test again
8. Run inference test again

**Expected:** State persists across restart

**Classification:** NOT YET TESTED

---

## 12. AZURE STATUS

**Status:** ✅ UNTOUCHED

| Component | Status | Notes |
|-----------|--------|-------|
| `omniroute.service` | ✅ RUNNING | Not modified, not stopped, not restarted |
| College Noticeboard | ✅ RUNNING | Not modified |
| PostgreSQL | ✅ RUNNING | Not modified |
| WireGuard | ✅ ACTIVE | 10.250.0.1 ↔ 10.250.0.2 not modified |
| IIS access | ✅ ACTIVE | 10.24.14.231 path not modified |
| Azure database | ✅ INTACT | /home/azureuser/.omniroute/storage.sqlite not deleted/overwritten |

**Classification:** VALIDATED - no changes made to Azure environment

---

## 13. CREDENTIAL STATUS

**Status:** ✅ EXISTING CREDENTIALS PRESERVED

| Credential | Status | Notes |
|------------|--------|-------|
| Rotation performed | ❌ NO | Per instructions: reuse existing credentials |
| Secrets in code | ❌ NO | Security sweep: clean |
| Secrets in git | ❌ NO | .gitignore prevents tracking |
| Required secrets | ⬜ NOT YET SET | Must be set in Render dashboard |

### Required Render Environment Variables

The following must be set in Render dashboard before deployment:

1. `SUPABASE_URL` - Supabase project URL
2. `SUPABASE_STORAGE_KEY` - Service role key (existing)
3. `SUPABASE_RESTORE_URL` - Fresh signed URL from step 6
4. `JWT_SECRET` - Existing OmniRoute JWT secret
5. `API_KEY_SECRET` - Existing OmniRoute API key secret
6. `INITIAL_PASSWORD` - Existing OmniRoute admin password
7. `STORAGE_ENCRYPTION_KEY` - Existing OmniRoute encryption key
8. `OMNIROUTE_WS_BRIDGE_SECRET` - Existing WS bridge secret
9. `NEXT_PUBLIC_BASE_URL` - Render URL (after deployment)

Additionally, `OMNI_STATE_SHA256` should be set to the SHA-256 from step 5 (optional but recommended).

**Classification:** CONFIGURED (render.yaml has placeholders), NOT YET SET

---

## 14. REMAINING HUMAN ACTIONS

### Phase 1: Create Fresh Snapshot (Azure VM)

```bash
# On your local machine:
cd /Users/badrisatwik/Downloads/omniroute-render-free-v2
scp backup-helper.mjs azureuser@<azure-ip>:/tmp/

# SSH to Azure:
ssh azureuser@<azure-ip>

# On Azure VM:
cd /tmp
node backup-helper.mjs \
  /home/azureuser/.omniroute/storage.sqlite \
  /tmp/storage-render-snapshot.sqlite

sha256sum /tmp/storage-render-snapshot.sqlite | tee snapshot-hash.txt
sqlite3 /tmp/storage-render-snapshot.sqlite "PRAGMA integrity_check;"
sqlite3 /tmp/storage-render-snapshot.sqlite "SELECT COUNT(*) FROM sqlite_master WHERE type='table';"

# Copy snapshot back to local:
# On local machine:
scp azureuser@<azure-ip>:/tmp/storage-render-snapshot.sqlite ~/Downloads/
scp azureuser@<azure-ip>:/tmp/snapshot-hash.txt ~/Downloads/
```

### Phase 2: Upload to Supabase

```bash
# Via Supabase dashboard:
1. Go to Storage → omniroute bucket
2. Upload storage-render-snapshot.sqlite
3. Rename to storage.sqlite (replaces old snapshot)
4. Get signed URL (1 year expiry recommended)
5. Save signed URL for next step
```

### Phase 3: Deploy to Render

```bash
# On local machine:
cd /Users/badrisatwik/Downloads/omniroute-render-free-v2

# Initialize git if needed:
git init
git add .
git commit -m "OmniRoute 3.8.50 Render Free migration"

# Push to GitHub (create repo first if needed):
git remote add origin https://github.com/<your-username>/omniroute-render-free.git
git branch -M main
git push -u origin main

# In Render dashboard:
1. Create new Web Service
2. Connect to GitHub repo
3. Runtime: Docker
4. Plan: Free
5. Set all 9 environment variables (use existing values)
6. Set OMNI_STATE_SHA256 to hash from Phase 1
7. Deploy
```

### Phase 4: Validation Tests

```bash
# Wait for deployment to complete, then:

# Test 1: Health
curl -f https://omniroute-free.onrender.com/healthz

# Test 2: Models
curl -H "Authorization: Bearer <your-api-key>" \
  https://omniroute-free.onrender.com/v1/models

# Test 3: Non-streaming inference
curl -X POST https://omniroute-free.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'

# Test 4: Streaming inference
curl -X POST https://omniroute-free.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Count to 3"}],
    "stream": true
  }'

# Test 5: Verify Azure still works
curl -k https://<azure-ip>:20128/v1/models \
  -H "Authorization: Bearer <your-api-key>"
```

---

## 15. KNOWN LIMITATIONS

### Render Free Constraints

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| 0.1 CPU | Slow builds, slow inference | Expected; free tier limitation |
| 512 MB RAM | May OOM with large models/logs | Monitor memory; may fail |
| Ephemeral disk | No persistent storage | Supabase round-trip on every cold start |
| Sleep after inactivity | First request = cold start | ~49 MiB download + startup time |
| Signed URL expiry | Restore fails when expired | Regenerate URL before expiry |

### What Survives Restart

**✅ Survives (via Supabase):**
- OmniRoute configuration
- Provider credentials
- Routing rules
- Model aliases
- Historical logs
- User accounts
- API keys

**❌ Does NOT survive:**
- In-memory state after last backup (up to 30 min)
- Active streaming sessions
- Uncommitted WAL changes at crash time

### Backup Consistency

**Backup interval:** 30 minutes (configurable via `OMNI_STATE_BACKUP_INTERVAL_SECONDS`)

**Backup method:** better-sqlite3 `db.backup()` - WAL-consistent, atomic, safe

**Risk:** If Render terminates container during backup upload, Supabase object may contain partial write. The SHA-256 check on next restore will detect and reject corrupted snapshot.

### Untested Scenarios

The following cannot be validated until deployment:

1. Actual memory usage under load
2. OmniRoute 3.8.50 behavior on Render Free CPU
3. Cold start time with 49 MiB download
4. Backup performance every 30 minutes
5. Supabase upload reliability
6. Container restart behavior
7. Real inference latency
8. Streaming performance

---

## FINAL CLASSIFICATION SUMMARY

| Category | Status |
|----------|--------|
| **Code** | ✅ CONFIGURED, syntax validated |
| **Backup helper** | ✅ CONFIGURED, API correct, NOT YET TESTED (requires better-sqlite3) |
| **Fresh snapshot** | ⬜ NOT YET CREATED (requires Azure VM access) |
| **Supabase upload** | ⬜ NOT YET DONE (requires snapshot + credentials) |
| **Render deployment** | ⬜ NOT YET DEPLOYED (requires Git push + dashboard config) |
| **Health test** | ⬜ NOT YET TESTED (requires deployment) |
| **Models test** | ⬜ NOT YET TESTED (requires deployment) |
| **Inference test** | ⬜ NOT YET TESTED (requires deployment) |
| **Streaming test** | ⬜ NOT YET TESTED (requires deployment) |
| **Restart/restore test** | ⬜ NOT YET TESTED (requires deployment) |
| **Azure safety** | ✅ VALIDATED (no changes made) |
| **Credential rotation** | ✅ VALIDATED (none performed) |
| **Secret exposure** | ✅ VALIDATED (security sweep clean) |

---

## CRITICAL NOTES

1. **DO NOT claim success until real tests pass.** Configured ≠ Working.

2. **Render Free may fail due to memory.** The Azure instance uses more than 512 MB. Failure is a valid outcome to report.

3. **Backup helper is unproven.** It passes syntax checks and uses the correct API, but has not executed successfully against a real WAL database.

4. **No credentials were rotated.** Per instructions, all existing secrets are reused.

5. **Azure remains the primary.** Do not switch clients to Render until all validation tests pass.

---

## NEXT IMMEDIATE STEP

Execute Phase 1 (Create Fresh Snapshot) from section 14 above.

This requires:
- SSH access to Azure VM
- Node.js with better-sqlite3 installed on Azure
- Running omniroute.service (do not stop it)

All subsequent phases depend on completing this first.
