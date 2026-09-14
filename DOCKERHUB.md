# mysql-percona — Percona Server for MySQL 8.4 LTS

Percona Server for MySQL 8.4 LTS on Debian 13 slim, built to be run by people
who have to operate it: XtraBackup in the image, TLS on first boot, Docker
secrets, an honest healthcheck, and an entrypoint that treats node identity as
environment rather than as a config file forked per node.

## Tags

| Tag | Moves |
|---|---|
| `8.4.11-11` | never — one server version, rebuilt for base-layer patches |
| `8.4` | with each 8.4 LTS release |
| `latest` | with every build |

Version tags are read out of the image *after* it is built and the backup and
restore suite has passed, so a tag can never claim a server version the image
does not run. Pin `8.4.11-11` or a digest for anything holding data.

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM, max-mode build provenance and a
keyless Cosign signature on every published digest.

## Quick start

```yaml
services:
  db:
    image: dementev/mysql-percona:8.4
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root
      MYSQL_DATABASE: app
    secrets: [db_root]
    volumes:
      - /data/mysql:/var/lib/mysql
```

Runs as `mysql` (uid/gid 1001), with no root path and no gosu — by design. The
data directory has to be writable by 1001.

## What's inside

- **Percona Server 8.4 LTS** from the `pdps-84-lts` channel, pinned by exact apt
  version and `apt-mark hold`-ed, on a digest-pinned `debian:13-slim`.
- **XtraBackup, xbstream and xbcloud** in the image, version-locked to the
  server, so backups need no sidecar and cannot drift.
- **jemalloc** preloaded.
- **TLS** — self-signed certificates generated on first start, or mount your own
  at `/etc/mysql/ssl/`.
- **GTID replication ready** (`gtid_mode=ON`, `enforce_gtid_consistency=ON`) with
  the `clone` plugin loaded from config.
- **Docker secrets** — every credential variable accepts a `_FILE` variant.
- Debug builds of the server, of XtraBackup and the debug plugin tree are
  removed: ~220 MB nothing in production ever executes.

## Configuration

Drop `.cnf` files into **`/etc/mysql/conf.d/`** — it is included after the
image's own defaults, so any filename there wins. Read order, last wins:

    /etc/mysql/mysql.conf.d/   image defaults
    /etc/mysql/conf.d/         your configs
    /etc/mysql/env.d/          rendered from the environment

Node identity lives in the environment, rendered into `/etc/mysql/env.d/` at
start, so promoting a standby is an environment change plus a restart rather
than a forked config file. Each accepts a `_FILE` variant, and a bad value fails
the start instead of being ignored:

| Variable | Option |
|---|---|
| `MYSQL_SERVER_ID` | `server_id` |
| `MYSQL_REPORT_HOST` | `report_host` |
| `MYSQL_READ_ONLY` | `read_only` |
| `MYSQL_SUPER_READ_ONLY` | `super_read_only` |

## Init and start-time SQL

- `/docker-entrypoint-initdb.d/` — the classic one: runs **once**, only when the
  datadir is created.
- `/docker-entrypoint-always.d/` — runs on **every start**, in the background,
  once the server accepts connections.

`always.d` is for what a deployment depends on but an existing datadir will
never get from `initdb.d`: monitoring and replication accounts, grants, rotated
passwords. Write it idempotently. It is skipped on a `super_read_only` standby,
and a failure logs `[ERROR]` and leaves the server running rather than taking
mysqld down.

## Healthcheck

`mysql -uping -e 'SELECT 1'`, not `mysqladmin ping` — ping exits 0 on
access-denied, so a server nothing can authenticate to would report healthy. The
`ping`/`pong` user is recreated on every start, so this holds on datadirs older
than the healthcheck too. `MYSQL_HEALTHCHECK_DISABLE=1` opts out of both.

## Backups

Set `MYSQL_BACKUP_PASSWORD` (or `_FILE`) and the entrypoint creates the
XtraBackup account with exactly the grants a backup takes, plus the
`mysqlbackup` component that `--page-tracking` needs. Full, incremental,
streamed-and-compressed, PITR and `CLONE INSTANCE` provisioning are all
documented in the repository README, and `tests.sh` runs every one of them
against a built image before it can be published.

## Security and provenance

Every published digest is built by the shared pipeline in
[vdementev/docker-workflows](https://github.com/vdementev/docker-workflows).
Pull requests build, test and scan without publishing; `main` is
branch-protected, so nothing reaches Docker Hub without a green check behind it.
A Trivy gate fails the build on any *fixable* CRITICAL or HIGH finding, and each
published digest carries an SBOM, max-mode SLSA provenance and a keyless Cosign
signature.

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'github.com/vdementev/' \
  dementev/mysql-percona:latest
```

[SECURITY.md](https://github.com/vdementev/mysql-percona-docker/blob/main/SECURITY.md) is the reporting channel and the response
targets; [SUPPORT.md](https://github.com/vdementev/mysql-percona-docker/blob/main/SUPPORT.md) covers tag lifecycle, pinning and
patch cadence.

## Related images

One family, built by the same pipeline, meant to run together — a proxy in
front, an app runtime, a database, and a way into it.

| Image | What it does |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) — [source](https://github.com/vdementev/angie-docker) | Public-facing reverse proxy and TLS terminator — Angie, the nginx fork, with brotli, zstd and cache-purge |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) — [source](https://github.com/vdementev/nginx-docker) | Static sites and SPAs behind that proxy — brotli/zstd siblings, Prometheus stub_status |
| [`dementev/php-fpm-with-ext`](https://hub.docker.com/r/dementev/php-fpm-with-ext) — [source](https://github.com/vdementev/docker-php-fpm-with-ext) | PHP-FPM and CLI, PHP 7.0 → 8.5, with the extensions most projects reach for |
| **[`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona)** — this image | Percona Server for MySQL 8.4 LTS, XtraBackup built in, no root inside |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) — [source](https://github.com/vdementev/adminer-docker) | Adminer 6 with every driver it supports, for reaching any of the above |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). These images are not a side
project — they are the base layer under the client and product systems we run,
which is why they are gated, tested and signed rather than pushed by hand.

Issues and pull requests:
[github.com/vdementev/mysql-percona-docker](https://github.com/vdementev/mysql-percona-docker).
Need this kind of infrastructure built or maintained for your own stack?
[lotuswebagency.com](https://lotuswebagency.com).

Packaging in this repository is MIT licensed — see
[LICENSE](https://github.com/vdementev/mysql-percona-docker/blob/main/LICENSE). The software
inside the image keeps its own upstream licenses.
