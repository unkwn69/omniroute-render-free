FROM docker.io/diegosouzapw/omniroute:3.8.50

COPY entrypoint.sh /usr/local/bin/omniroute-render-entrypoint.sh
COPY backup-helper.mjs /usr/local/bin/backup-helper.mjs
RUN chmod 755 /usr/local/bin/omniroute-render-entrypoint.sh && \
    chmod 644 /usr/local/bin/backup-helper.mjs

ENTRYPOINT ["/usr/local/bin/omniroute-render-entrypoint.sh"]
