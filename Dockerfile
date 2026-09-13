# Everything that ends up in this image is pinned, base layer included. The image
# carries a database: an unpinned install plus the weekly rebuild moves the server
# version under a live datadir, which upgrades in place and does not go back.
# Bumping a version is a commit, and the published tags follow it.
FROM debian:13-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# Percona Server for MySQL 8.4 LTS. Tags are derived from this in CI.
ARG PERCONA_SERVER_VERSION=8.4.11-11-1.trixie
# XtraBackup ships in the image so backups run without a sidecar and can never
# drift from the server version. Its numbering is its own, not the server's.
ARG PERCONA_XTRABACKUP_VERSION=8.4.0-6-1.trixie
ARG PERCONA_RELEASE_VERSION=1.0-34

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y -q; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    ca-certificates \
    curl \
    gnupg \
    gpgv \
    libjemalloc2 \
    locales \
    lsb-release \
    lz4 \
    procps \
    zstd; \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8; \
    echo "SYS_UID_MAX 1001" >> /etc/login.defs; \
    echo "SYS_GID_MAX 1001" >> /etc/login.defs; \
    groupadd -g 1001 -r mysql; \
    useradd -u 1001 -r -M -g 1001 -s /sbin/nologin -c "Default Application User" mysql; \
    locale; \
    # Install Percona
    curl --fail -O "https://repo.percona.com/apt/percona-release_${PERCONA_RELEASE_VERSION}.generic_all.deb"; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    "/percona-release_${PERCONA_RELEASE_VERSION}.generic_all.deb"; \
    rm -f "/percona-release_${PERCONA_RELEASE_VERSION}.generic_all.deb"; \
    percona-release enable-only pdps-84-lts release; \
    apt-get update; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    "percona-server-server=${PERCONA_SERVER_VERSION}" \
    "percona-server-client=${PERCONA_SERVER_VERSION}" \
    "percona-xtrabackup-84=${PERCONA_XTRABACKUP_VERSION}"; \
    # A dist-upgrade must never move the database or the tool that backs it up.
    apt-mark hold percona-server-server percona-server-client percona-xtrabackup-84; \
    # Note: do NOT purge curl/gnupg/gpgv/lsb-release — percona-server-server depends on percona-release which depends on curl
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/*; \
    # Debug builds of the server and of xtrabackup plus the debug plugin tree:
    # ~220 MB that nothing in a production container ever executes.
    rm -f /usr/sbin/mysqld-debug /usr/bin/xtrabackup-debug; \
    rm -rf /usr/lib/mysql/plugin/debug; \
    # Prepare directories
    rm -rf /etc/mysql; \
    rm -rf /var/lib/mysql; \
    rm -rf /var/log/mysql; \
    rm -rf /var/run/mysqld; \
    install -d -m 0755 -o root -g root /etc/mysql; \
    install -d -m 0755 -o mysql -g mysql /var/lib/mysql; \
    install -d -m 0750 -o mysql -g mysql /var/log/mysql; \
    install -d -m 0750 -o mysql -g mysql /var/run/mysqld; \
    install -d -m 0750 -o mysql -g mysql /var/lib/mysql-files; \
    install -d -m 0750 -o mysql -g mysql /docker-entrypoint-initdb.d; \
    install -d -m 0750 -o mysql -g mysql /docker-entrypoint-always.d; \
    install -d -m 0750 -o mysql -g mysql /tmp-replica; \
    install -d -m 0750 -o mysql -g mysql /backup; \
    install -d -m 0750 -o mysql -g mysql /etc/mysql/ssl; \
    # Drop-in dir for consumers. Separate from mysql.conf.d because an
    # includedir is read in sorted order and the last assignment wins: a file
    # dropped next to the image's own 10-/20-/30- configs has to be named so it
    # sorts after them, which is a trap. conf.d is read after mysql.conf.d, so
    # any filename in it overrides the defaults.
    install -d -m 0755 -o root -g root /etc/mysql/conf.d; \
    # Rendered by the entrypoint from the MYSQL_SERVER_ID / MYSQL_REPORT_HOST /
    # MYSQL_READ_ONLY knobs; read last, so the environment wins over any cnf.
    # Owned by mysql: the entrypoint writes it unprivileged.
    install -d -m 0750 -o mysql -g mysql /etc/mysql/env.d; \
    # Make global include file
    printf '%s\n' \
    '!includedir /etc/mysql/mysql.conf.d/' \
    '!includedir /etc/mysql/conf.d/' \
    '!includedir /etc/mysql/env.d/' > /etc/my.cnf; \
    chown root:root /etc/my.cnf; \
    chmod 0644 /etc/my.cnf

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PERCONA_TELEMETRY_DISABLE=1
ENV LD_PRELOAD=libjemalloc.so.2

COPY --chown=root:root ./config/ /etc/mysql/mysql.conf.d/
COPY --chown=root:root --chmod=0755 ./docker-entrypoint.sh /docker-entrypoint.sh

VOLUME ["/var/lib/mysql"]

# Not `mysqladmin ping`: it exits 0 on ER_ACCESS_DENIED, because the server did
# answer and that is all ping asks — a container nothing can authenticate to
# reports healthy. An authenticated statement covers both. The entrypoint
# recreates the ping user on every start, so this also holds on a datadir that
# predates it (set MYSQL_HEALTHCHECK_DISABLE to opt out of both).
HEALTHCHECK --start-interval=15s --interval=10s --timeout=3s --start-period=60s --retries=3 \
    CMD MYSQL_PWD=pong mysql --host=127.0.0.1 --user=ping --connect-timeout=1 \
        --batch --skip-column-names --execute='SELECT 1' >/dev/null 2>&1

USER mysql

EXPOSE 3306
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["mysqld"]
