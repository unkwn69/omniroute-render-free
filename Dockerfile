FROM diegosouzapw/omniroute:3.8.50

COPY --chmod=755 entrypoint.sh /usr/local/bin/omniroute-render-entrypoint.sh
COPY --chmod=644 backup-helper.mjs /usr/local/bin/backup-helper.mjs
COPY --chmod=644 storage-helper.mjs /usr/local/bin/storage-helper.mjs

# Build-time smoke test: verify better-sqlite3 loads and can open a memory DB
RUN node -e "require('better-sqlite3')(':memory:').close()" && \
    node -e "const db=require('better-sqlite3')(':memory:'); db.exec('CREATE TABLE t(id INTEGER);'); console.log('sqlite test ok'); db.close()"

ENTRYPOINT ["/usr/local/bin/omniroute-render-entrypoint.sh"]
