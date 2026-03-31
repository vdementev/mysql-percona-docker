FROM debian:13-slim

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
    curl --fail -O https://repo.percona.com/apt/percona-release_latest.generic_all.deb; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    /percona-release_latest.generic_all.deb; \
    rm -f /percona-release_latest.generic_all.deb; \
    percona-release enable-only pdps-84-lts release; \
    apt-get update; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    percona-server-server; \
    # Note: do NOT purge curl/gnupg/gpgv/lsb-release — percona-server-server depends on percona-release which depends on curl
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/*; \
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
    install -d -m 0750 -o mysql -g mysql /tmp-replica; \
    install -d -m 0750 -o mysql -g mysql /etc/mysql/ssl; \
    # Make global include file
    printf '%s\n' '!includedir /etc/mysql/mysql.conf.d/' > /etc/my.cnf; \
    chown root:root /etc/my.cnf; \
    chmod 0644 /etc/my.cnf

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PERCONA_TELEMETRY_DISABLE=1
ENV LD_PRELOAD=libjemalloc.so.2

COPY --chown=root:root ./config/ /etc/mysql/mysql.conf.d/
COPY --chown=root:root --chmod=0755 ./docker-entrypoint.sh /docker-entrypoint.sh

VOLUME ["/var/lib/mysql"]

HEALTHCHECK --start-interval=15s --interval=10s --timeout=3s --start-period=60s --retries=3 \
    CMD ["mysqladmin","--host=127.0.0.1","--user=ping","--password=pong","--connect-timeout=1","--silent","ping"]

USER mysql

EXPOSE 3306
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["mysqld"]
