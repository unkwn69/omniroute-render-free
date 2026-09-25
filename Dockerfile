FROM diegosouzapw/omniroute:3.8.50

COPY --chmod=755 entrypoint.sh /usr/local/bin/omniroute-render-entrypoint.sh
COPY --chmod=644 backup-helper.mjs /usr/local/bin/backup-helper.mjs
COPY --chmod=644 storage-helper.mjs /usr/local/bin/storage-helper.mjs

# Build-time verification: runtime entry point exists and better-sqlite3 loads
RUN test -f /app/dev/run-standalone.mjs && \
    node -e "require('better-sqlite3')(':memory:').close()"

EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/omniroute-render-entrypoint.sh"]
