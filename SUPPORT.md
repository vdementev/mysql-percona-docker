# Support and lifecycle

## Tags

| Tag | Contents |
|---|---|
| `latest` | The newest build of the current series. Moves on every merge to `main` and on the weekly rebuild. |
| `8.4.11-11` | That exact Percona Server release. Republished in place (new digest, same tag) while it is current. |
| `8.4` | The newest release of the 8.4 LTS series. |

Version tags are read out of the image after it is built and tested, so a tag
can never claim a server version the image does not actually run.

Architectures: `linux/amd64`, `linux/arm64`.

## What "supported" means

This image carries a database, so the rules are stricter than for the stateless
images in the family. Everything installed is pinned — base image by digest,
server, client and XtraBackup by exact package version — and `apt-mark hold`
keeps a dist-upgrade from moving the server under a live datadir. A server
version bump is therefore always a commit you can read, never a side effect of
a rebuild.

The weekly rebuild (Monday, ~03:55 UTC) refreshes everything *around* the
server: base-layer security updates and the supporting packages. It does not
move the server version.

The 8.4 series is Percona's LTS, supported upstream until 2032. This image
follows the 8.4 LTS channel (`pdps-84-lts`) and will keep doing so; a move to a
future LTS series would be a new set of version tags, announced in the release
notes, never a silent change to `latest`.

## Upgrades

MySQL data directories upgrade in place and do not go back. Before moving to a
new server version:

1. Take a backup — XtraBackup is in the image, `tests.sh` exercises the full
   restore path.
2. Read the upstream release notes for the versions you are skipping.
3. Pull the new version tag explicitly rather than following `latest`.

Downgrading means restoring a backup taken on the old version.

## Pinning

For a database, pin the full version tag at minimum, and the digest if you want
byte-identical:

```yaml
services:
  mysql:
    image: dementev/mysql-percona:8.4.11-11@sha256:...
```

## Patch cadence

| Trigger | What happens |
|---|---|
| Merge to `main` | Full build, backup/restore test suite, Trivy gate, publish, sign |
| Weekly cron | Same pipeline, no source change — picks up base-layer updates |
| Fixable CRITICAL/HIGH CVE | The build fails and nothing is published until it is fixed or explicitly accepted in `.trivyignore` |
| Upstream server release | A version-bump commit, reviewed and merged like any other change |

## Breaking changes

The entrypoint contract — environment variables, `*_FILE` secrets, the
`ping`/`pong` healthcheck user, the init directories — is treated as a public
interface. Changes to it are called out in the pull request and the release
notes, and land with coverage in `tests.sh`.

## Getting help

Open an issue at
[github.com/vdementev/mysql-percona-docker/issues](https://github.com/vdementev/mysql-percona-docker/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
