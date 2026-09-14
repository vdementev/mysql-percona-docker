# mysql-percona

Percona Server for MySQL 8.4 LTS on Debian 13 slim, built to be run by people
who have to operate it: XtraBackup in the image, TLS on first boot, Docker
secrets, an honest healthcheck, and an entrypoint that treats node identity as
environment rather than as a forked config file.

Published as [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona)
for `linux/amd64` and `linux/arm64`.

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

Runs as `mysql` (uid/gid 1001) with no root path and no gosu — by design. The
data directory has to be writable by 1001.

## Features
- jemalloc allocator (LD_PRELOAD)
- XtraBackup, xbstream and xbcloud in the image, version-locked to the server
- TLS enabled — self-signed certs generated on first start, or mount your own to `/etc/mysql/ssl/`
- GTID replication ready (gtid_mode=ON, enforce_gtid_consistency=ON), `clone` plugin loaded at startup
- Listens dual-stack (`bind-address = *`)
- Healthcheck via `ping`/`pong` user
- Docker secrets support (`*_FILE` env vars)

## Tags

| Tag | Moves |
|---|---|
| `8.4.11-11` | never — one server version, rebuilt for base-layer patches |
| `8.4` | with each 8.4 LTS release |
| `latest` | with every build |

Version tags are read out of the image *after* it is built and the backup and
restore suite has passed, so a tag can never claim a server version the image
does not run. Full lifecycle and upgrade rules: [SUPPORT.md](SUPPORT.md).

Pin `8.4.11-11` (or a digest) for anything holding data. Everything installed is
pinned in the Dockerfile — base image by digest, server and XtraBackup by apt
version — so a rebuild patches the base layers and nothing else. Version bumps
are a commit, and the tags follow it.

## Configuration

Drop `.cnf` files into **`/etc/mysql/conf.d/`** — that directory is included after the
image's own defaults, so any filename there wins. (`/etc/mysql/mysql.conf.d/` holds the
image's `10-`/`20-`/`30-` files; a file added there has to sort after them to take effect,
which is why `conf.d` exists.) Read order, last wins:

    /etc/mysql/mysql.conf.d/   image defaults
    /etc/mysql/conf.d/         your configs
    /etc/mysql/env.d/          rendered from the environment (see below)

### Environment-driven identity

Set on the container, rendered into `/etc/mysql/env.d/99-env.cnf` at start, so node
identity and the standby role live in the environment instead of a cnf forked per node —
promoting a standby is an environment change plus a restart. Each accepts a `_FILE`
variant. Unset variables are not written at all.

| Variable | Option | Values |
|---|---|---|
| `MYSQL_SERVER_ID` | `server_id` | positive integer |
| `MYSQL_REPORT_HOST` | `report_host` | hostname |
| `MYSQL_READ_ONLY` | `read_only` | `ON`/`OFF` (`1`/`0`, `true`/`false`) |
| `MYSQL_SUPER_READ_ONLY` | `super_read_only` | same |

A bad value fails the start, it is not ignored. Initialisation of a fresh datadir runs with
both read-only flags off, so a node can be started as a standby from the very first boot.

## Init and start-time SQL

- `/docker-entrypoint-initdb.d/` — classic: runs **once**, only when the datadir is created.
- `/docker-entrypoint-always.d/` — runs on **every start**, against the real server, in the
  background once it accepts connections. Same file types (`.sql`, `.sql.gz`, `.sql.xz`,
  `.sql.zst`, `.sql.bz2`, `.sh`).

Use `always.d` for anything a deployment depends on but that an existing datadir will never
get from `initdb.d`: monitoring and replication accounts, grants, rotated passwords. Write
it idempotently — `CREATE USER IF NOT EXISTS` **plus** an unconditional `ALTER USER`, since
`IF NOT EXISTS` alone silently keeps the old password.

- Skipped when the server is `super_read_only` (a standby gets its accounts over replication).
  `read_only` alone does not skip it — root writes through that.
- A failure logs `[ERROR]` and leaves the server running: mysqld is never taken down by a
  bootstrap file, and the failure is visible instead of silent.
- `MYSQL_ALWAYS_TIMEOUT` (default 900) caps how long it waits for the server to accept a
  root connection before giving up with an `[ERROR]`.

## Healthcheck

`mysql -uping -e 'SELECT 1'`, not `mysqladmin ping` — ping exits 0 on access-denied, so a
server nothing can authenticate to reports healthy. The `ping`/`pong` user is recreated on
every start (see above), so this also holds on a datadir older than the healthcheck.
`MYSQL_HEALTHCHECK_DISABLE=1` skips both the user and the check's reason to exist.

## Backup and restore

Everything below runs in the container, as the account the entrypoint creates —
no sidecar, no grants to add. `./tests.sh` exercises all of it against a built
image. Give the container somewhere to write (`-v backups:/backup`) and set
`MYSQL_BACKUP_PASSWORD` (or `_FILE`) to enable the backup account; the entrypoint
also installs the `mysqlbackup` component that `--page-tracking` needs.

| Variable | Default | Meaning |
|---|---|---|
| `MYSQL_BACKUP_USER` | `xtrabackup` | account name |
| `MYSQL_BACKUP_PASSWORD` | — | set it to create the account; unset means no account |
| `MYSQL_BACKUP_HOST` | — | extra host pattern, e.g. `%`, for backups or clones driven from another container |

The account is created for `localhost` and `127.0.0.1` and granted what a backup
actually takes: `BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT,
REPLICATION_SLAVE_ADMIN, SYSTEM_VARIABLES_ADMIN`, plus `SELECT` on
`performance_schema.log_status`, `keyring_component_status`,
`replication_group_members` and `mysql.component`. The last two are not in
Percona's documented snippet; `--page-tracking` fails without them.

```sh
# full
docker exec db xtrabackup --user=xtrabackup --password=... --backup --target-dir=/backup/full
docker exec db xtrabackup --user=xtrabackup --password=... --prepare --apply-log-only --target-dir=/backup/full

# incremental
docker exec db xtrabackup --user=xtrabackup --password=... --backup --page-tracking \
    --incremental-basedir=/backup/full --target-dir=/backup/inc
docker exec db xtrabackup --user=xtrabackup --password=... --prepare --target-dir=/backup/full --incremental-dir=/backup/inc

# compressed stream
docker exec db sh -c 'xtrabackup --user=xtrabackup --password=... --backup --stream=xbstream --compress=zstd --target-dir=/tmp/x' > full.xbs

# restore: copy the prepared directory into an empty datadir and start
docker run --rm -v backups:/backup -v newdata:/var/lib/mysql --entrypoint sh dementev/mysql-percona:8.4 \
    -c 'cp -a /backup/full/. /var/lib/mysql/ && rm -f /var/lib/mysql/xtrabackup_* /var/lib/mysql/backup-my.cnf'
```

Point-in-time recovery is the same restore followed by `mysqlbinlog … | mysql`.
Logical dumps work as usual (`mysqldump`, and `mysqlbinlog` for replay).

### Provisioning a node with CLONE

`CLONE INSTANCE` is the fast way to build a replica, and the plugin is already
loaded. Two things are specific to running it in a container:

- **The recipient needs a restart policy.** Clone finishes by restarting the
  server, there is no supervisor in the container, so mysqld exits with
  `ERROR 3707 (mysqld is not managed by supervisor process)`. That error means
  the copy succeeded; `restart: unless-stopped` is what brings the node back.
- **Wait for that restart before touching the node.** `clone_status` reads
  `Completed` on the instance that is about to exit, and anything written in
  that window is in the files the restart replaces. Configure replication after
  the node is back, verify the channel exists, and retry if it does not.

Replication between these containers needs `SOURCE_SSL=1` (or
`GET_SOURCE_PUBLIC_KEY=1`): accounts use `caching_sha2_password`, which refuses
to authenticate over a plaintext connection. Certificates are generated on first
start, so TLS needs no setup. After a clone, `RESET PERSIST` and
`RESET REPLICA ALL` on the recipient — the donor's `mysqld-auto.cnf` and
`mysql.slave_*` rows come with the copy.

## Notes
- The Percona toolkit is not included
- No TokuDB
- Debug builds (`mysqld-debug`, `xtrabackup-debug`, the debug plugin tree) are removed
- The start-time bootstrap is skipped on a `super_read_only` standby, so install
  `component_mysqlbackup` on the primary — a cloned standby inherits it with the datadir
- The `clone` plugin is loaded from the config, so `INSTALL PLUGIN clone` is no longer needed.
  On a datadir where it was previously installed by hand, the leftover `mysql.plugin` row makes
  mysqld log `MY-013180 Function 'clone' already exists` on every start (harmless, the plugin
  still ends up ACTIVE). Clear it once with `UNINSTALL PLUGIN clone;`.
- Mounting a tmpfs over `/var/run/mysqld` needs an explicit `mode=1777`: Docker defaults a
  tmpfs with options to 0750 root:root and the server runs as uid 1001.

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

[SECURITY.md](SECURITY.md) is the reporting channel and the response
targets; [SUPPORT.md](SUPPORT.md) covers tag lifecycle, pinning and
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

Packaging in this repository is MIT licensed — see [LICENSE](LICENSE). The software
inside the image keeps its own upstream licenses.
