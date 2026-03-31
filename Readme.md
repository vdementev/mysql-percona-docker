## Percona MySQL Server 8.4

Minimal Percona Server for MySQL 8.4 on Debian 13 (slim).

## Features
- jemalloc allocator (LD_PRELOAD)
- TLS enabled — self-signed certs generated on first start, or mount your own to `/etc/mysql/ssl/`
- GTID replication ready (gtid_mode=ON, enforce_gtid_consistency=ON)
- Healthcheck via `ping`/`pong` user
- Docker secrets support (`*_FILE` env vars)

## Configuration
Custom configs: mount or add to `/etc/mysql/mysql.conf.d/`

## Notes
- xtrabackup and toolkit are not included — run them from a separate container or sidecar
- No TokuDB
