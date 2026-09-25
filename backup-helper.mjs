#!/usr/bin/env node
/**
 * OmniRoute SQLite Hot Backup Helper
 *
 * Uses better-sqlite3's native db.backup() API to create a WAL-consistent
 * snapshot, then gzip-compresses it and prints machine-readable results.
 *
 * Usage:
 *   node backup-helper.mjs <source-db-path> <output-gz-path>
 *
 * Output (stdout — machine-readable KEY=VALUE lines):
 *   BACKUP_GZ_PATH=<path>
 *   BACKUP_SHA256=<hex>              <- SHA-256 of the compressed .gz file
 *   BACKUP_UNCOMPRESSED_SHA256=<hex> <- SHA-256 of the decompressed SQLite
 *   BACKUP_UNCOMPRESSED_BYTES=<n>
 *   BACKUP_TABLE_COUNT=<n>
 *   BACKUP_INTEGRITY=ok
 *
 * Progress/diagnostic messages go to stderr (safe to suppress).
 *
 * Resolution strategy for better-sqlite3:
 *   This file is copied to /usr/local/bin/ inside the Docker image.
 *   Node ESM `import` walks UP from the importer's directory looking for
 *   node_modules — from /usr/local/bin/ there are none, so bare specifiers
 *   fail. We use createRequire() to load better-sqlite3 from OmniRoute's
 *   own node_modules at /usr/lib/node_modules/omniroute/, which is where
 *   the 3.8.50 package is installed. This avoids bundling a second copy.
 */

import { createRequire } from 'module';
import { existsSync, createReadStream, createWriteStream } from 'fs';
import { unlink } from 'fs/promises';
import { dirname, resolve } from 'path';
import { access, constants } from 'fs/promises';
import { createGzip } from 'zlib';
import { createHash } from 'crypto';

// ── Locate better-sqlite3 via OmniRoute's own node_modules ─────────────────
// Try the known global install location first; fall back to require() chain
// resolution so this still works if the image layout changes.
const OMNIROUTE_PKG = '/usr/lib/node_modules/omniroute';

let Database;
try {
  const requireFromOmniroute = createRequire(resolve(OMNIROUTE_PKG, 'package.json'));
  Database = requireFromOmniroute('better-sqlite3');
} catch (e) {
  // Fallback: if the path above is wrong, try createRequire from this file
  try {
    const requireFromHere = createRequire(import.meta.url);
    Database = requireFromHere('better-sqlite3');
  } catch (e2) {
    console.error(`[backup-helper] Cannot load better-sqlite3: ${e.message}`);
    console.error(`[backup-helper] Fallback also failed: ${e2.message}`);
    process.exit(1);
  }
}

// ── Helper: gzip a file and compute SHA-256 of both compressed + uncompressed
async function gzipFile(inputPath, outputGzPath) {
  const gzHash = createHash('sha256');
  const rawHash = createHash('sha256');

  // Stream: input -> tee to rawHash + gz -> tee to gzHash -> file
  await new Promise((resolve, reject) => {
    const src = createReadStream(inputPath);
    const gz = createGzip({ level: 6 });
    const dst = createWriteStream(outputGzPath);

    src.on('error', reject);
    gz.on('error', reject);
    dst.on('error', reject);
    dst.on('finish', resolve);

    src.on('data', (chunk) => rawHash.update(chunk));
    gz.on('data', (chunk) => gzHash.update(chunk));

    src.pipe(gz).pipe(dst);
  });

  return {
    gzSha256: gzHash.digest('hex'),
    uncompressedSha256: rawHash.digest('hex'),
  };
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const [,, sourceDb, outputGzPath] = process.argv;

  if (!sourceDb || !outputGzPath) {
    console.error('Usage: node backup-helper.mjs <source-db> <output-gz-path>');
    process.exit(1);
  }

  if (!existsSync(sourceDb)) {
    console.error(`[backup-helper] Error: source not found: ${sourceDb}`);
    process.exit(1);
  }

  const outputDir = dirname(outputGzPath);
  try {
    await access(outputDir, constants.W_OK);
  } catch {
    console.error(`[backup-helper] Error: output dir not writable: ${outputDir}`);
    process.exit(1);
  }

  // Temp path: uncompressed backup (removed after gz is created)
  const tmpSqlite = outputGzPath.replace(/\.gz$/, '') + '.tmp.' + process.pid;

  console.error(`[backup-helper] source: ${sourceDb}`);
  console.error(`[backup-helper] output: ${outputGzPath}`);

  let db;
  try {
    console.error('[backup-helper] opening source DB...');
    db = new Database(sourceDb, { fileMustExist: true });

    // WAL-consistent hot backup — the ONLY safe method for a live WAL database
    console.error('[backup-helper] running db.backup()...');
    await db.backup(tmpSqlite);
    console.error('[backup-helper] db.backup() complete');

    // Validate the uncompressed backup
    const destDb = new Database(tmpSqlite, { readonly: true });
    let tableCount, uncompressedBytes;
    try {
      const integrity = destDb.pragma('integrity_check', { simple: true });
      if (integrity !== 'ok') {
        console.error(`[backup-helper] integrity_check failed: ${integrity}`);
        process.exit(1);
      }
      tableCount = destDb.prepare(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table'"
      ).get().c;
      const pageCount = destDb.pragma('page_count', { simple: true });
      const pageSize  = destDb.pragma('page_size',  { simple: true });
      uncompressedBytes = pageCount * pageSize;
      console.error(`[backup-helper] integrity: ok | tables: ${tableCount} | size: ${(uncompressedBytes/1048576).toFixed(2)} MB`);
    } finally {
      destDb.close();
    }

    // Emit uncompressed stats to stdout
    process.stdout.write(`BACKUP_UNCOMPRESSED_BYTES=${uncompressedBytes}\n`);
    process.stdout.write(`BACKUP_TABLE_COUNT=${tableCount}\n`);
    process.stdout.write(`BACKUP_INTEGRITY=ok\n`);

    // Gzip + hash
    console.error('[backup-helper] compressing...');
    const { gzSha256, uncompressedSha256 } = await gzipFile(tmpSqlite, outputGzPath);
    console.error('[backup-helper] compression done');

    // Emit to stdout
    process.stdout.write(`BACKUP_GZ_PATH=${outputGzPath}\n`);
    process.stdout.write(`BACKUP_SHA256=${gzSha256}\n`);
    process.stdout.write(`BACKUP_UNCOMPRESSED_SHA256=${uncompressedSha256}\n`);

    console.error('[backup-helper] done');

  } catch (err) {
    console.error(`[backup-helper] fatal: ${err.message}`);
    process.exit(1);
  } finally {
    if (db) { try { db.close(); } catch {} }
    try { await unlink(tmpSqlite); } catch {}
  }

  process.exit(0);
}

main();
