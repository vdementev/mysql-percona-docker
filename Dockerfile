FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y -q; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    ca-certificates \
    curl \
    gnupg \
    gpgv \
    libjemalloc-dev \
    libjemalloc2 \
    locales \
    lsb-release \
    lz4 \
    mc \
    nano \
    procps \
    zstd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8; \
    echo "SYS_UID_MAX 1001" >> /etc/login.defs; \
    echo "SYS_GID_MAX 1001" >> /etc/login.defs; \
    groupadd -g 1001 -r mysql; \
    useradd -u 1001 -r -M -g 1001 -s /sbin/nologin -c "Default Application User" mysql; \
    locale

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 
ENV PERCONA_TELEMETRY_DISABLE=1

COPY --chown=root:root ./docker-entrypoint.sh /docker-entrypoint.sh

RUN set -eux; \
    locale; \
    # Install Percona
    curl -O https://repo.percona.com/apt/percona-release_latest.generic_all.deb; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    /percona-release_latest.generic_all.deb; \
    rm -f /percona-release_latest.generic_all.deb; \
    percona-release enable-only pdps-84-lts release; \
    apt-get update; \
    apt-get install -y -q --no-install-recommends --no-install-suggests \
    percona-server-server \
    percona-xtrabackup-84 \
    percona-toolkit; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # Prepare directories
    rm -rf /etc/mysql; \
    rm -rf /var/lib/mysql; \
    rm -rf /var/log/mysql; \
    rm -rf /var/run/mysqld; \
    install -d -m 0755 -o root -g root /etc/mysql; \
    install -d -m 0755 -o mysql -g mysql /var/lib/mysql; \
    install -d -m 0755 -o mysql -g mysql /var/log/mysql; \
    install -d -m 0750 -o mysql -g mysql /var/run/mysqld; \
    install -d -m 0750 -o mysql -g mysql /var/lib/mysql-files; \
    install -d -m 0750 -o mysql -g mysql /docker-entrypoint-initdb.d; \
    # Make global include file
    printf '%s\n' '!includedir /etc/mysql/mysql.conf.d/' > /etc/my.cnf; \
    chown root:root /etc/my.cnf; \
    chmod 0644 /etc/my.cnf; \
    chmod 0644 /docker-entrypoint.sh; \
    chmod +x /docker-entrypoint.sh

COPY --chown=root:root ./config/ /etc/mysql/mysql.conf.d/

RUN set -eux; \
    install -d -m 0755 -o root -g mysql /etc/mysql/ssl; \
    cd /etc/mysql/ssl; \
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout ca-key.pem -out ca.pem \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=My-CA"; \
    openssl req -nodes -newkey rsa:2048 \
    -keyout server-key.pem -out server-req.pem \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=server.example.com"; \
    openssl x509 -req -in server-req.pem -CA ca.pem -CAkey ca-key.pem -days 3650 -CAcreateserial -out server-cert.pem; \
    openssl req -nodes -newkey rsa:2048 \
    -keyout client-key.pem -out client-req.pem \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=client.example.com"; \
    openssl x509 -req -in client-req.pem -CA ca.pem -CAkey ca-key.pem -days 3650 -CAcreateserial -out client-cert.pem; \
    rm -f server-req.pem client-req.pem; \
    chown -R mysql:mysql /etc/mysql/ssl; \
    chmod 600 ca-key.pem server-key.pem client-key.pem; \
    chmod 644 ca.pem server-cert.pem client-cert.pem;

VOLUME ["/var/lib/mysql"]
WORKDIR /app
HEALTHCHECK --start-interval=15s --interval=10s --timeout=3s --start-period=60s --retries=3 \
  CMD ["mysqladmin","--host=127.0.0.1","--user=ping","--password=pong","--connect-timeout=1","--silent","ping"]

# We need to start container as root to fix configs permissions with docker-entrypoint.sh
# For mysql server user will be changed automatically to mysql.
USER root

EXPOSE 3306
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["mysqld"]