FROM diegosouzapw/omniroute:3.8.50

COPY --chmod=755 entrypoint.sh /usr/local/bin/omniroute-render-entrypoint.sh
COPY --chmod=644 backup-helper.mjs /usr/local/bin/backup-helper.mjs
COPY --chmod=644 storage-helper.mjs /usr/local/bin/storage-helper.mjs

ENTRYPOINT ["/usr/local/bin/omniroute-render-entrypoint.sh"]
