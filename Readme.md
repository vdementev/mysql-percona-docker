## Percona MySQL Server 8.4

Minimal Percona Server for MySQL 8.4 on Debian 13 (slim).

## Features
- jemalloc allocator (LD_PRELOAD)
- TLS enabled — self-signed certs generated on first start, or mount your own to `/etc/mysql/ssl/`
- GTID replication ready (gtid_mode=ON, enforce_gtid_consistency=ON), `clone` plugin loaded at startup
- Listens dual-stack (`bind-address = *`)
- Healthcheck via `ping`/`pong` user
- Docker secrets support (`*_FILE` env vars)

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

## Notes
- xtrabackup and toolkit are not included — run them from a separate container or sidecar
- No TokuDB
- The `clone` plugin is loaded from the config, so `INSTALL PLUGIN clone` is no longer needed.
  On a datadir where it was previously installed by hand, the leftover `mysql.plugin` row makes
  mysqld log `MY-013180 Function 'clone' already exists` on every start (harmless, the plugin
  still ends up ACTIVE). Clear it once with `UNINSTALL PLUGIN clone;`.
- Mounting a tmpfs over `/var/run/mysqld` needs an explicit `mode=1777`: Docker defaults a
  tmpfs with options to 0750 root:root and the server runs as uid 1001.
