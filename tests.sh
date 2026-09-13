#!/usr/bin/env bash
# Backup and restore coverage for dementev/mysql-percona.
#
# Every method is run the way an operator would run it against a stock
# container: no grants added by hand, no sidecar, nothing installed first.
# IMAGE=<ref> ./tests.sh   (defaults to the published image)
set -uo pipefail

IMAGE="${IMAGE:-dementev/mysql-percona:latest}"
NET=pxb-test-net
ROOT_PW=rootpw
BKP_PW=bkppw
REPL_PW=replpw

GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  ${RED}✗${NC} %s\n" "$1"; }
step() { printf "\n${BOLD}%s${NC}\n" "$1"; }

CONTAINERS="pxb-src pxb-logical pxb-full pxb-inc pxb-stream pxb-pitr pxb-clone"
VOLUMES="pxb-backup pxb-src-data pxb-logical-data pxb-full-data pxb-inc-data pxb-stream-data pxb-pitr-data pxb-clone-data"

cleanup() {
    if [ -n "${KEEP:-}" ]; then printf "\n${BOLD}KEEP set — leaving containers running${NC}\n"; return; fi
    printf "\n${BOLD}Cleaning up...${NC}\n"
    # shellcheck disable=SC2086
    docker rm -f $CONTAINERS >/dev/null 2>&1
    # shellcheck disable=SC2086
    docker volume rm -f $VOLUMES >/dev/null 2>&1
    docker network rm $NET >/dev/null 2>&1
}
trap cleanup EXIT

# start NAME [extra docker args...]
start() {
    local name="$1"; shift
    docker run -d --name "$name" --network "$NET" \
        -e MYSQL_ROOT_PASSWORD="$ROOT_PW" \
        -v "${name}-data:/var/lib/mysql" \
        -v pxb-backup:/backup \
        "$@" "$IMAGE" >/dev/null
}

wait_healthy() {
    local name="$1" i
    for i in $(seq 1 90); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = healthy ] && return 0
        sleep 2
    done
    docker logs --tail 30 "$name" 2>&1
    return 1
}

# q NAME SQL — as root, batch mode, quiet (for assertions)
q() { docker exec -e MYSQL_PWD="$ROOT_PW" "$1" mysql -uroot -N -B -e "$2" 2>/dev/null; }
# qx NAME SQL — same, but errors are shown: setup that fails silently wastes an hour
qx() { docker exec -e MYSQL_PWD="$ROOT_PW" "$1" mysql -uroot -N -B -e "$2"; }

# xb NAME ARGS... — xtrabackup inside the server container, as the account the
# image created, over the socket. This is the "out of the box" path.
xb() {
    local name="$1"; shift
    docker exec "$name" xtrabackup --user=xtrabackup --password="$BKP_PW" "$@"
}

rows() { q "$1" "SELECT GROUP_CONCAT(v ORDER BY id) FROM shop.t"; }

# wait_rows NAME EXPECTED — replication is asynchronous, so poll instead of sleeping.
wait_rows() {
    local name="$1" expect="$2" i
    for i in $(seq 1 30); do
        [ "$(rows "$name")" = "$expect" ] && return 0
        sleep 1
    done
    return 1
}

# done_with NAME — each restored server has served its purpose; drop it so a CI
# runner is never hosting six databases at once.
done_with() { docker rm -f "$1" >/dev/null 2>&1; }

# restore_and_check NAME PREPARED_DIR EXPECTED
# Boots a container on a prepared backup the way a real restore does.
restore_and_check() {
    local name="$1" src="$2" expect="$3" got
    docker volume create "${name}-data" >/dev/null
    docker run --rm -v pxb-backup:/backup -v "${name}-data:/var/lib/mysql" \
        --entrypoint sh "$IMAGE" -c "cp -a ${src}/. /var/lib/mysql/ && rm -f /var/lib/mysql/xtrabackup_* /var/lib/mysql/backup-my.cnf" >/dev/null 2>&1
    start "$name"
    if ! wait_healthy "$name"; then fail "$name: restored server did not become healthy"; return 1; fi
    got="$(rows "$name")"
    if [ "$got" = "$expect" ]; then pass "$name: restored data intact ($got)"; else fail "$name: expected '$expect', got '$got'"; fi
}

printf "${BOLD}Image:${NC} %s\n" "$IMAGE"
cleanup >/dev/null 2>&1
docker network create "$NET" >/dev/null

step "Source server"
docker volume create pxb-backup >/dev/null
start pxb-src -e MYSQL_BACKUP_PASSWORD="$BKP_PW" -e MYSQL_BACKUP_HOST='%' -e MYSQL_SERVER_ID=1
if wait_healthy pxb-src; then pass "starts and reports healthy"; else fail "did not become healthy"; exit 1; fi

q pxb-src "CREATE DATABASE shop;
CREATE TABLE shop.t (id INT PRIMARY KEY, v VARCHAR(32)) ENGINE=InnoDB;
INSERT INTO shop.t VALUES (1,'one'),(2,'two');"
[ "$(rows pxb-src)" = "one,two" ] && pass "seed data written" || fail "seed data"

step "Out-of-the-box backup prerequisites"
docker exec pxb-src sh -c 'command -v xtrabackup && command -v xbstream && command -v xbcloud' >/dev/null 2>&1 \
    && pass "xtrabackup, xbstream and xbcloud are in the image" || fail "backup binaries missing"
[ "$(q pxb-src "SELECT COUNT(*) FROM mysql.component WHERE component_urn='file://component_mysqlbackup'")" = 1 ] \
    && pass "component_mysqlbackup installed by the entrypoint" || fail "component_mysqlbackup missing"
[ "$(q pxb-src "SELECT COUNT(*) FROM mysql.user WHERE user='xtrabackup'")" = 3 ] \
    && pass "backup account created for socket, 127.0.0.1 and %" || fail "backup account missing"
[ "$(q pxb-src "SELECT plugin_status FROM information_schema.plugins WHERE plugin_name='clone'")" = ACTIVE ] \
    && pass "clone plugin active without INSTALL PLUGIN" || fail "clone plugin not active"
# Versions must move together, which is the reason both are pinned in the Dockerfile.
srv="$(docker exec pxb-src mysqld --version | grep -oE '8\.4\.[0-9]+')"
xbv="$(docker exec pxb-src xtrabackup --version 2>&1 | grep -oE '8\.4\.[0-9]+' | head -1)"
[ "${srv%.*}" = "${xbv%.*}" ] && pass "xtrabackup $xbv matches server $srv series" || fail "version mismatch: server $srv, xtrabackup $xbv"

step "Logical: mysqldump → mysql"
docker exec -e MYSQL_PWD="$ROOT_PW" pxb-src sh -c \
    'mysqldump -uroot --single-transaction --set-gtid-purged=OFF --databases shop > /backup/dump.sql' \
    && pass "mysqldump wrote a dump" || fail "mysqldump failed"
start pxb-logical && wait_healthy pxb-logical
docker exec -e MYSQL_PWD="$ROOT_PW" pxb-logical sh -c 'mysql -uroot < /backup/dump.sql' \
    && pass "dump restored into a fresh server" || fail "restore failed"
[ "$(rows pxb-logical)" = "one,two" ] && pass "logical restore data intact" || fail "logical restore data"
done_with pxb-logical

step "Physical: xtrabackup full → prepare → restore"
xb pxb-src --backup --target-dir=/backup/full >/dev/null 2>&1 \
    && pass "full backup completed (socket auth, entrypoint account, no extra grants)" || fail "full backup failed"
xb pxb-src --prepare --apply-log-only --target-dir=/backup/full >/dev/null 2>&1 \
    && pass "base prepared (--apply-log-only)" || fail "prepare failed"

step "Physical: page-tracking incremental → prepare chain → restore"
q pxb-src "INSERT INTO shop.t VALUES (3,'three');"
xb pxb-src --backup --page-tracking --register-redo-log-consumer \
    --incremental-basedir=/backup/full --target-dir=/backup/inc >/dev/null 2>&1 \
    && pass "incremental backup with --page-tracking completed" || fail "incremental backup failed"

# Restore the base alone first: proves a full backup stands on its own.
docker run --rm -v pxb-backup:/backup --entrypoint sh "$IMAGE" -c 'cp -a /backup/full /backup/full-only' >/dev/null 2>&1
xb pxb-src --prepare --target-dir=/backup/full-only >/dev/null 2>&1
restore_and_check pxb-full /backup/full-only "one,two"
done_with pxb-full

xb pxb-src --prepare --target-dir=/backup/full --incremental-dir=/backup/inc >/dev/null 2>&1 \
    && pass "incremental applied onto the base" || fail "incremental prepare failed"
restore_and_check pxb-inc /backup/full "one,two,three"
done_with pxb-inc

step "Streaming: xbstream + zstd → extract → restore"
docker exec pxb-src sh -c "mkdir -p /backup/streamdir && xtrabackup --backup --user=xtrabackup --password=$BKP_PW --stream=xbstream --compress=zstd --target-dir=/backup/streamtmp > /backup/stream.xbs" 2>/dev/null \
    && pass "streamed a compressed backup to xbstream" || fail "xbstream backup failed"
docker exec pxb-src sh -c 'xbstream -x --decompress -C /backup/streamdir < /backup/stream.xbs' 2>/dev/null \
    && pass "xbstream extracted and decompressed" || fail "xbstream extract failed"
xb pxb-src --prepare --target-dir=/backup/streamdir >/dev/null 2>&1 \
    && pass "streamed backup prepared" || fail "prepare of streamed backup failed"
restore_and_check pxb-stream /backup/streamdir "one,two,three"
done_with pxb-stream

step "Point in time: binlog replay onto a restored backup"
q pxb-src "INSERT INTO shop.t VALUES (4,'four');"
q pxb-src "FLUSH BINARY LOGS;"
docker exec pxb-src sh -c 'cp /var/lib/mysql/binlog.0* /backup/binlogs_tmp_dir 2>/dev/null || (mkdir -p /backup/binlogs && cp /var/lib/mysql/binlog.0* /backup/binlogs/)' >/dev/null 2>&1
docker run --rm -v pxb-backup:/backup --entrypoint sh "$IMAGE" -c 'rm -rf /backup/pitr-base && cp -a /backup/full-only /backup/pitr-base' >/dev/null 2>&1
restore_and_check pxb-pitr /backup/pitr-base "one,two"
docker exec -e MYSQL_PWD="$ROOT_PW" pxb-pitr sh -c \
    'mysqlbinlog --skip-gtids=0 /backup/binlogs/binlog.0* | mysql -uroot' >/dev/null 2>&1 \
    && pass "binlogs replayed onto the restored backup" || fail "binlog replay failed"
[ "$(rows pxb-pitr)" = "one,two,three,four" ] \
    && pass "point-in-time recovery reached the latest transaction" || fail "PITR data: $(rows pxb-pitr)"
done_with pxb-pitr

step "CLONE INSTANCE: provision a node from a running server"
# A restart policy is not optional for a clone recipient: CLONE ends by
# restarting the server, there is no supervisor inside the container, so mysqld
# exits with "Restart server failed (mysqld is not managed by supervisor
# process)" and only the policy brings the node back with the cloned data.
start pxb-clone --restart unless-stopped -e MYSQL_SERVER_ID=2
wait_healthy pxb-clone
qx pxb-clone "SET GLOBAL clone_valid_donor_list='pxb-src:3306';"
restarts_before="$(docker inspect -f '{{.RestartCount}}' pxb-clone)"
clone_out="$(docker exec -e MYSQL_PWD="$ROOT_PW" pxb-clone mysql -uroot -e \
    "CLONE INSTANCE FROM 'xtrabackup'@'pxb-src':3306 IDENTIFIED BY '$BKP_PW';" 2>&1)"
case "$clone_out" in
    ''|*"ERROR 3707"*) pass "clone ran (in a container it ends at the self-restart it cannot do)" ;;
    *) fail "clone failed: $clone_out" ;;
esac

# Wait for the restart itself, not for clone_status: the status flips to
# Completed on the instance that is about to exit, and every write made to it in
# that window is in the files the restart replaces. Configuring replication
# there silently disappears.
restarted=false
for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.RestartCount}}' pxb-clone)" -gt "$restarts_before" ] && { restarted=true; break; }
    sleep 2
done
if $restarted && wait_healthy pxb-clone; then
    pass "node came back on the cloned datadir"
    [ "$(q pxb-clone "SELECT state FROM performance_schema.clone_status")" = "Completed" ] \
        && pass "clone_status reports Completed" || fail "clone_status not Completed"
    [ "$(rows pxb-clone)" = "one,two,three,four" ] \
        && pass "cloned node carries the donor's data" || fail "clone data: $(rows pxb-clone)"
else
    fail "cloned node did not restart"
    docker logs --tail 20 pxb-clone 2>&1
fi

step "Replica backup: --safe-slave-backup"
qx pxb-src "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '$REPL_PW';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';"
# Configuring replication right after a clone does not always take: the
# statements return success and leave no channel behind, so it has to be
# verified and retried. (Citimarine's replica-init.sh carries the same retry.)
# RESET PERSIST is part of it: CLONE copies the donor's mysqld-auto.cnf, and a
# persisted server_id from the donor outranks the config file.
configured=0
for attempt in 1 2 3 4 5; do
    qx pxb-clone "RESET PERSIST;
RESET REPLICA ALL;
-- SOURCE_SSL=1 is required, not optional: accounts authenticate with
-- caching_sha2_password, which refuses to hand over credentials over a
-- plaintext connection. The image makes its certificates on first start.
CHANGE REPLICATION SOURCE TO SOURCE_HOST='pxb-src', SOURCE_PORT=3306, SOURCE_USER='repl', SOURCE_PASSWORD='$REPL_PW', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1;
START REPLICA;" >/dev/null 2>&1
    sleep 2
    if [ -n "$(q pxb-clone "SELECT service_state FROM performance_schema.replication_connection_status")" ]; then
        configured=$attempt; break
    fi
done
[ "$configured" -gt 0 ] \
    && pass "replication configured on the cloned node (attempt $configured)" \
    || fail "replication could not be configured after 5 attempts"

q pxb-src "INSERT INTO shop.t VALUES (5,'five');"
if wait_rows pxb-clone "one,two,three,four,five"; then
    pass "replication running from the cloned node"
else
    fail "replication did not catch up: $(rows pxb-clone)"
    q pxb-clone "SELECT channel_name, service_state, last_error_message FROM performance_schema.replication_connection_status;
                 SELECT service_state, last_error_message FROM performance_schema.replication_applier_status_by_worker;
                 SELECT @@server_id;"
fi
xb pxb-clone --backup --safe-slave-backup --slave-info --target-dir=/backup/replica >/dev/null 2>&1 \
    && pass "backup from the replica with --safe-slave-backup" || fail "replica backup failed"
[ "$(q pxb-clone "SELECT service_state FROM performance_schema.replication_applier_status")" = "ON" ] \
    && pass "replication still running after the backup" || fail "replication left stopped by the backup"

printf "\n${BOLD}%d passed, %d failed${NC}\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
