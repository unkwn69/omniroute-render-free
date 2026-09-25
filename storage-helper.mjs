#!/usr/bin/env node
/**
 * OmniRoute Supabase Storage & Health Helper
 *
 * Provides Node.js fetch-based download, upload, health check,
 * and SQLite integrity verification operations without requiring curl.
 *
 * Usage:
 *   node storage-helper.mjs download <object-name> <output-path>
 *   node storage-helper.mjs upload <object-name> <input-path> [content-type]
 *   node storage-helper.mjs health <port> [path]
 *   node storage-helper.mjs verify-sqlite <sqlite-path>
 */

import { createWriteStream, readFileSync, existsSync } from 'fs';
import { pipeline } from 'stream/promises';
import { Readable } from 'stream';
import { createRequire } from 'module';
import { resolve } from 'path';

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SUPABASE_KEY = process.env.SUPABASE_STORAGE_KEY || '';
const SUPABASE_BUCKET = process.env.SUPABASE_BUCKET || 'omniroute';

function sanitizeError(msg) {
  if (!SUPABASE_KEY) return msg;
  return String(msg).split(SUPABASE_KEY).join('[REDACTED]');
}

function getObjectUrl(objectName) {
  const encoded = objectName.split('/').map(encodeURIComponent).join('/');
  return `${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(SUPABASE_BUCKET)}/${encoded}`;
}

export function loadBetterSqlite3() {
  const APP_PACKAGE_JSON = '/app/package.json';
  if (!existsSync(APP_PACKAGE_JSON)) {
    throw new Error(`application package.json not found at ${APP_PACKAGE_JSON}`);
  }
  const req = createRequire(APP_PACKAGE_JSON);
  const mod = req('better-sqlite3');
  if (typeof mod !== 'function') {
    throw new Error('better-sqlite3 did not export a constructor');
  }
  return mod;
}

async function download(objectName, outputPath) {
  if (!SUPABASE_URL || !SUPABASE_KEY) {
    console.error('[storage-helper] Error: SUPABASE_URL or SUPABASE_STORAGE_KEY is missing');
    process.exit(1);
  }

  const url = getObjectUrl(objectName);
  const res = await fetch(url, {
    method: 'GET',
    headers: {
      'apikey': SUPABASE_KEY,
      'Authorization': `Bearer ${SUPABASE_KEY}`,
    },
  });

  if (!res.ok) {
    let errorText = '';
    try {
      errorText = await res.text();
    } catch {}
    console.error(`[storage-helper] Download failed (HTTP ${res.status}): ${sanitizeError(errorText || res.statusText)}`);
    process.exit(1);
  }

  if (!res.body) {
    console.error('[storage-helper] Download failed: empty response body');
    process.exit(1);
  }

  const fileStream = createWriteStream(outputPath);
  const nodeStream = Readable.fromWeb(res.body);
  await pipeline(nodeStream, fileStream);
  console.error(`[storage-helper] Downloaded ${objectName} -> ${outputPath}`);
}

async function upload(objectName, inputPath, contentType = 'application/octet-stream') {
  if (!SUPABASE_URL || !SUPABASE_KEY) {
    console.error('[storage-helper] Error: SUPABASE_URL or SUPABASE_STORAGE_KEY is missing');
    process.exit(1);
  }

  if (!existsSync(inputPath)) {
    console.error(`[storage-helper] Error: input file not found: ${inputPath}`);
    process.exit(1);
  }

  const url = getObjectUrl(objectName);
  const data = readFileSync(inputPath);

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'apikey': SUPABASE_KEY,
      'Authorization': `Bearer ${SUPABASE_KEY}`,
      'Content-Type': contentType,
      'x-upsert': 'true',
      'Cache-Control': 'no-store',
    },
    body: data,
  });

  if (!res.ok) {
    let errorText = '';
    try {
      errorText = await res.text();
    } catch {}
    console.error(`[storage-helper] Upload failed (HTTP ${res.status}): ${sanitizeError(errorText || res.statusText)}`);
    process.exit(1);
  }

  console.error(`[storage-helper] Uploaded ${inputPath} -> ${objectName}`);
}

async function checkHealth(port, path = '/healthz') {
  try {
    const url = `http://127.0.0.1:${port}${path.startsWith('/') ? path : '/' + path}`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 4000);
    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timeout);
    if (res.ok) {
      process.exit(0);
    } else {
      process.exit(1);
    }
  } catch {
    process.exit(1);
  }
}

async function verifySqlite(sqlitePath) {
  if (!existsSync(sqlitePath)) {
    console.error(`[storage-helper] SQLite verify failed: ${sqlitePath} not found`);
    process.exit(1);
  }

  let Database;
  try {
    Database = loadBetterSqlite3();
  } catch (err) {
    console.error(`[storage-helper] Cannot load better-sqlite3: ${err.message}`);
    process.exit(1);
  }

  let db;
  try {
    db = new Database(sqlitePath, { readonly: true, fileMustExist: true });
    const integrity = db.pragma('integrity_check', { simple: true });
    if (integrity === 'ok') {
      const tableCount = db.prepare("SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table'").get().c;
      console.error(`[storage-helper] PRAGMA integrity_check: ok (${tableCount} tables)`);
      process.exit(0);
    } else {
      console.error(`[storage-helper] PRAGMA integrity_check failed: ${integrity}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`[storage-helper] SQLite verify error: ${err.message}`);
    process.exit(1);
  } finally {
    if (db) {
      try { db.close(); } catch {}
    }
  }
}

async function main() {
  const [,, command, ...args] = process.argv;

  try {
    if (command === 'download') {
      const [objectName, outputPath] = args;
      if (!objectName || !outputPath) {
        console.error('Usage: storage-helper.mjs download <object-name> <output-path>');
        process.exit(1);
      }
      await download(objectName, outputPath);
    } else if (command === 'upload') {
      const [objectName, inputPath, contentType] = args;
      if (!objectName || !inputPath) {
        console.error('Usage: storage-helper.mjs upload <object-name> <input-path> [content-type]');
        process.exit(1);
      }
      await upload(objectName, inputPath, contentType);
    } else if (command === 'health') {
      const [port, path] = args;
      if (!port) {
        console.error('Usage: storage-helper.mjs health <port> [path]');
        process.exit(1);
      }
      await checkHealth(port, path);
    } else if (command === 'verify-sqlite') {
      const [sqlitePath] = args;
      if (!sqlitePath) {
        console.error('Usage: storage-helper.mjs verify-sqlite <sqlite-path>');
        process.exit(1);
      }
      await verifySqlite(sqlitePath);
    } else {
      console.error(`Unknown command: ${command}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`[storage-helper] Fatal error: ${sanitizeError(err.message)}`);
    process.exit(1);
  }
}

main();
