#!/usr/bin/env bash
set -eo pipefail
shopt -s nullglob

# logging functions
mysql_log() {
  local type="$1"; shift
  local text="$*"; if [ "$#" -eq 0 ]; then text="$(cat)"; fi
  local dt; dt="$(date --rfc-3339=seconds)"
  printf '%s [%s] [Entrypoint]: %s\n' "$dt" "$type" "$text"
}
mysql_note() { mysql_log Note "$@"; }
mysql_warn() { mysql_log Warn "$@" >&2; }
mysql_error(){ mysql_log ERROR "$@" >&2; exit 1; }
# Non-fatal: used by the background bootstrap, which must never take the server down.
mysql_err()  { mysql_log ERROR "$@" >&2; }

# usage: file_env VAR [DEFAULT]
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    mysql_error "Both $var and $fileVar are set (but are exclusive)"
  fi
  local val="$def"
  if   [ "${!var:-}"     ]; then val="${!var}"
  elif [ "${!fileVar:-}" ]; then val="$(< "${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}

_is_sourced() {
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

docker_process_init_files() {
  mysql=( docker_process_sql )
  echo
  local f
  for f; do
    case "$f" in
      *.sh)
        if [ -x "$f" ]; then
          mysql_note "$0: running $f"; "$f"
        else
          mysql_note "$0: sourcing $f"; . "$f"
        fi
        ;;
      *.sql)     mysql_note "$0: running $f"; docker_process_sql < "$f"; echo ;;
      *.sql.bz2) mysql_note "$0: running $f"; bunzip2 -c "$f" | docker_process_sql; echo ;;
      *.sql.gz)  mysql_note "$0: running $f"; gunzip  -c "$f" | docker_process_sql; echo ;;
      *.sql.xz)  mysql_note "$0: running $f"; xzcat        "$f" | docker_process_sql; echo ;;
      *.sql.zst) mysql_note "$0: running $f"; zstd  -dc    "$f" | docker_process_sql; echo ;;
      *)         mysql_warn "$0: ignoring $f" ;;
    esac
    echo
  done
}

_verboseHelpArgs=( --verbose --help --log-bin-index="$(mktemp -u)" )

mysql_check_config() {
  local toRun=( "$@" "${_verboseHelpArgs[@]}" ) errors
  if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
    mysql_error $'mysqld failed while attempting to check config\n\tcommand was: '"${toRun[*]}"$'\n\t'"$errors"
  fi
}

mysql_get_config() {
  local conf="$1"; shift
  "$@" "${_verboseHelpArgs[@]}" 2>/dev/null \
    | awk -v conf="$conf" '$1 == conf && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
}

mysql_socket_fix() {
  local defaultSocket
  defaultSocket="$(mysql_get_config 'socket' mysqld --no-defaults)"
  if [ "$defaultSocket" != "$SOCKET" ]; then
    ln -sfTv "$SOCKET" "$defaultSocket" || :
  fi
}

docker_temp_server_start() {
  # read-only/super-read-only off: the temp server exists to initialise this
  # datadir, and on a node started as a standby (MYSQL_SUPER_READ_ONLY=ON)
  # every statement below would otherwise be refused, root included.
  if ! "$@" --daemonize --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}" \
       --read-only=OFF --super-read-only=OFF; then
    mysql_error "Unable to start server."
  fi
}

docker_temp_server_stop() {
  if ! mysqladmin --defaults-extra-file=<( _mysql_passfile ) shutdown -uroot --socket="${SOCKET}"; then
    mysql_error "Unable to shut down server."
  fi
}

docker_verify_minimum_env() {
  if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
    mysql_error <<-'EOF'
Database is uninitialized and password option is not specified
    You need to specify one of the following as an environment variable:
    - MYSQL_ROOT_PASSWORD
    - MYSQL_ALLOW_EMPTY_PASSWORD
    - MYSQL_RANDOM_ROOT_PASSWORD
EOF
  fi
  if [ "$MYSQL_USER" = 'root' ]; then
    mysql_error <<-'EOF'
MYSQL_USER="root" is not allowed. Use MYSQL_ROOT_PASSWORD / MYSQL_ALLOW_EMPTY_PASSWORD / MYSQL_RANDOM_ROOT_PASSWORD.
EOF
  fi
  if [ -n "$MYSQL_USER" ] && [ -z "$MYSQL_PASSWORD" ]; then
    mysql_warn 'MYSQL_USER specified, but missing MYSQL_PASSWORD; MYSQL_USER will not be created'
  elif [ -z "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
    mysql_warn 'MYSQL_PASSWORD specified, but missing MYSQL_USER; MYSQL_PASSWORD will be ignored'
  fi
}

docker_create_db_directories() {
  local user; user="$(id -u)"
  local -A dirs=( ["$DATADIR"]=1 )
  local dir
  dir="$(dirname "$SOCKET")"; dirs["$dir"]=1

  local conf
  for conf in general-log-file pid-file secure-file-priv; do
    dir="$(mysql_get_config "$conf" "$@")"
    [ -z "$dir" ] || [ "$dir" = 'NULL' ] && continue
    case "$conf" in
      secure-file-priv) ;;
      *) dir="$(dirname "$dir")" ;;
    esac
    dirs["$dir"]=1
  done

  mkdir -p "${!dirs[@]}"
  if [ "$user" = "0" ]; then
    find "${!dirs[@]}" \! -user mysql -exec chown --no-dereference mysql '{}' +
  fi
}

docker_init_database_dir() {
  mysql_note "Initializing database files"
  "$@" --initialize-insecure --default-time-zone=SYSTEM --autocommit=1
  mysql_note "Database files initialized"
}

docker_setup_env() {
  declare -g DATADIR SOCKET
  DATADIR="$(mysql_get_config 'datadir' "$@")"
  SOCKET="$(mysql_get_config 'socket'  "$@")"

  # file_env 'MYSQL_ROOT_HOST' '172.%.%.%'
  file_env 'MYSQL_ROOT_HOST' '%'
  file_env 'MYSQL_DATABASE'
  file_env 'MYSQL_USER'
  file_env 'MYSQL_PASSWORD'
  file_env 'MYSQL_ROOT_PASSWORD'

  declare -g DATABASE_ALREADY_EXISTS
  if [ -d "$DATADIR/mysql" ]; then
    DATABASE_ALREADY_EXISTS='true'
  fi
}

docker_process_sql() {
  passfileArgs=()
  if [ '--dont-use-mysql-root-password' = "$1" ]; then
    passfileArgs+=( "$1" ); shift
  fi
  if [ -n "$MYSQL_DATABASE" ]; then
    set -- --database="$MYSQL_DATABASE" "$@"
  fi
  mysql --defaults-extra-file=<( _mysql_passfile "${passfileArgs[@]}" ) \
        --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --comments "$@"
}

docker_setup_db() {
  # 1) timezone tables
  if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
    mysql_tzinfo_to_sql /usr/share/zoneinfo \
      | sed 's/Local time zone must be set--see zic manual page/FCTY/' \
      | docker_process_sql --dont-use-mysql-root-password --database=mysql
  fi

  # 2) root password
  if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
    MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"; export MYSQL_ROOT_PASSWORD
    mysql_note "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
  fi

  # Compose SQL blocks with strict CREATE→GRANT order and explicit hosts
  local root_host="$MYSQL_ROOT_HOST"
  [ -z "$root_host" ] && root_host='localhost' # safety

  local root_block_nonlocal=""
  if [ -n "$MYSQL_ROOT_HOST" ] && [ "$MYSQL_ROOT_HOST" != 'localhost' ]; then
    read -r -d '' root_block_nonlocal <<-EOSQL || true
      CREATE USER IF NOT EXISTS 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
      GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION;
EOSQL
  fi

  read -r -d '' root_block_local <<-EOSQL || true
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
    GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
EOSQL

  # 3) healthcheck users
  local ping_block=""
  if [ -z "${MYSQL_HEALTHCHECK_DISABLE:-}" ]; then
    read -r -d '' ping_block <<-'EOSQL' || true
      CREATE USER IF NOT EXISTS 'ping'@'localhost' IDENTIFIED BY 'pong';
      GRANT USAGE ON *.* TO 'ping'@'localhost';
      CREATE USER IF NOT EXISTS 'ping'@'127.0.0.1' IDENTIFIED BY 'pong';
      GRANT USAGE ON *.* TO 'ping'@'127.0.0.1';
EOSQL
    if [ -n "$MYSQL_ROOT_HOST" ] && [[ "$MYSQL_ROOT_HOST" == 172.* ]]; then
      ping_block+=$'\n'"CREATE USER IF NOT EXISTS 'ping'@'172.%.%.%' IDENTIFIED BY 'pong';"
      ping_block+=$'\n'"GRANT USAGE ON *.* TO 'ping'@'172.%.%.%';"
    fi
  fi

  docker_process_sql --dont-use-mysql-root-password --database=mysql <<-EOSQL
    SET autocommit = 1;
    SET @@SESSION.SQL_LOG_BIN=0;

    ${root_block_local}
    ${root_block_nonlocal}
    ${ping_block}

    DROP DATABASE IF EXISTS test;
EOSQL

  if [ -n "$MYSQL_DATABASE" ]; then
    mysql_note "Creating database ${MYSQL_DATABASE}"
    docker_process_sql --database=mysql <<<"CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;"
  fi

  if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
    mysql_note "Creating user ${MYSQL_USER}"
    docker_process_sql --database=mysql <<<"CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';"
    if [ -n "$MYSQL_DATABASE" ]; then
      mysql_note "Granting ${MYSQL_USER} access to ${MYSQL_DATABASE}"
      docker_process_sql --database=mysql <<<"GRANT ALL ON \`${MYSQL_DATABASE//_/\\_}\`.* TO '$MYSQL_USER'@'%';"
    fi
  fi
}

_mysql_passfile() {
  if [ '--dont-use-mysql-root-password' != "$1" ] && [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    cat <<-EOF
[client]
password="${MYSQL_ROOT_PASSWORD}"
EOF
  fi
}

mysql_expire_root_user() {
  if [ -n "$MYSQL_ONETIME_PASSWORD" ]; then
    docker_process_sql --database=mysql <<-EOSQL
      ALTER USER IF EXISTS 'root'@'localhost' PASSWORD EXPIRE;
      ALTER USER IF EXISTS 'root'@'${MYSQL_ROOT_HOST}' PASSWORD EXPIRE;
EOSQL
  fi
}

mysql_generate_ssl_certs() {
  local ssl_dir="/etc/mysql/ssl"
  if [ -f "$ssl_dir/server-cert.pem" ]; then
    mysql_note "SSL certificates already exist, skipping generation"
    return
  fi
  mysql_note "Generating SSL certificates"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$ssl_dir/ca-key.pem" -out "$ssl_dir/ca.pem" \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=My-CA"
  openssl req -nodes -newkey rsa:2048 \
    -keyout "$ssl_dir/server-key.pem" -out "$ssl_dir/server-req.pem" \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=server.example.com"
  openssl x509 -req -in "$ssl_dir/server-req.pem" -CA "$ssl_dir/ca.pem" -CAkey "$ssl_dir/ca-key.pem" \
    -days 3650 -CAcreateserial -out "$ssl_dir/server-cert.pem"
  openssl req -nodes -newkey rsa:2048 \
    -keyout "$ssl_dir/client-key.pem" -out "$ssl_dir/client-req.pem" \
    -subj "/C=US/ST=CA/L=MyCity/O=MyCompany/OU=MyUnit/CN=client.example.com"
  openssl x509 -req -in "$ssl_dir/client-req.pem" -CA "$ssl_dir/ca.pem" -CAkey "$ssl_dir/ca-key.pem" \
    -days 3650 -CAcreateserial -out "$ssl_dir/client-cert.pem"
  rm -f "$ssl_dir/server-req.pem" "$ssl_dir/client-req.pem"
  chmod 600 "$ssl_dir/ca-key.pem" "$ssl_dir/server-key.pem" "$ssl_dir/client-key.pem"
  chmod 644 "$ssl_dir/ca.pem" "$ssl_dir/server-cert.pem" "$ssl_dir/client-cert.pem"
  mysql_note "SSL certificates generated"
}

# ---------------------------------------------------------------------------
# Environment-driven server identity
# ---------------------------------------------------------------------------
# Rendered into /etc/mysql/env.d/, which /etc/my.cnf includes last, so these win
# over the image defaults and over anything mounted into /etc/mysql/conf.d/.
# Node identity and the standby role are then part of the container's
# environment instead of a cnf forked per node: promoting a standby is an env
# change plus a restart, not an edit to a mounted file.

ENV_CONFIG_DIR='/etc/mysql/env.d'
ENV_CONFIG_FILE="${ENV_CONFIG_DIR}/99-env.cnf"

# usage: _mysql_bool VALUE  -> ON|OFF on stdout, non-zero exit if unparseable
_mysql_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    on|1|true|yes)  echo 'ON'  ;;
    off|0|false|no) echo 'OFF' ;;
    *) return 1 ;;
  esac
}

mysql_render_env_config() {
  file_env 'MYSQL_SERVER_ID'
  file_env 'MYSQL_REPORT_HOST'
  file_env 'MYSQL_READ_ONLY'
  file_env 'MYSQL_SUPER_READ_ONLY'

  local body='' value=''

  if [ -n "$MYSQL_SERVER_ID" ]; then
    case "$MYSQL_SERVER_ID" in
      *[!0-9]*|'') mysql_error "MYSQL_SERVER_ID must be a positive integer, got '$MYSQL_SERVER_ID'" ;;
    esac
    body+="server_id = ${MYSQL_SERVER_ID}"$'\n'
  fi

  if [ -n "$MYSQL_REPORT_HOST" ]; then
    # Keep it to what a hostname can hold: the value goes into a config file.
    case "$MYSQL_REPORT_HOST" in
      *[!A-Za-z0-9.:_-]*) mysql_error "MYSQL_REPORT_HOST may only contain letters, digits and .:_- , got '$MYSQL_REPORT_HOST'" ;;
    esac
    body+="report_host = ${MYSQL_REPORT_HOST}"$'\n'
  fi

  if [ -n "$MYSQL_READ_ONLY" ]; then
    value="$(_mysql_bool "$MYSQL_READ_ONLY")" || mysql_error "MYSQL_READ_ONLY must be ON or OFF, got '$MYSQL_READ_ONLY'"
    body+="read_only = ${value}"$'\n'
  fi

  if [ -n "$MYSQL_SUPER_READ_ONLY" ]; then
    value="$(_mysql_bool "$MYSQL_SUPER_READ_ONLY")" || mysql_error "MYSQL_SUPER_READ_ONLY must be ON or OFF, got '$MYSQL_SUPER_READ_ONLY'"
    body+="super_read_only = ${value}"$'\n'
  fi

  if [ -z "$body" ]; then
    # Nothing set: drop a file left over from an earlier start, so unsetting a
    # variable actually unsets the option.
    rm -f "$ENV_CONFIG_FILE" 2>/dev/null || :
    return
  fi

  if [ ! -w "$ENV_CONFIG_DIR" ]; then
    mysql_error "$ENV_CONFIG_DIR is not writable — cannot apply MYSQL_SERVER_ID/MYSQL_REPORT_HOST/MYSQL_READ_ONLY/MYSQL_SUPER_READ_ONLY"
  fi

  # 0640: mysqld silently ignores a world-writable config file.
  ( umask 0137; printf '%s\n%s' '[mysqld]' "$body" > "$ENV_CONFIG_FILE" )
  mysql_note "Rendered $ENV_CONFIG_FILE from the environment:"
  sed 's/^/    /' "$ENV_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Start-time bootstrap
# ---------------------------------------------------------------------------
# /docker-entrypoint-initdb.d runs only when the datadir is created, so on any
# server that already has data it never runs again: accounts a deploy depends on
# (a monitoring user, a rotated password) are simply absent, and nothing says
# so. This pass runs against the real server on EVERY start, after mysqld is up,
# and is meant for statements written to be idempotent — CREATE USER IF NOT
# EXISTS followed by an unconditional ALTER USER, GRANT, and so on.
#
# It runs in the background: mysqld keeps PID 1 and is never delayed by it. A
# failure here leaves the server running and logs at [ERROR] — that is the
# signal, since the alternative is the silent drift this exists to prevent.

ALWAYS_DIR='/docker-entrypoint-always.d'

docker_process_always_files() {
  local f
  for f in "$ALWAYS_DIR"/*; do
    case "$f" in
      *.sh)
        if [ -x "$f" ]; then
          mysql_note "$0: running $f"; "$f"
        else
          mysql_note "$0: sourcing $f"; . "$f"
        fi
        ;;
      *.sql)     mysql_note "$0: running $f"; docker_process_sql --database=mysql < "$f" ;;
      *.sql.bz2) mysql_note "$0: running $f"; bunzip2 -c "$f" | docker_process_sql --database=mysql ;;
      *.sql.gz)  mysql_note "$0: running $f"; gunzip  -c "$f" | docker_process_sql --database=mysql ;;
      *.sql.xz)  mysql_note "$0: running $f"; xzcat      "$f" | docker_process_sql --database=mysql ;;
      *.sql.zst) mysql_note "$0: running $f"; zstd  -dc  "$f" | docker_process_sql --database=mysql ;;
      *)         mysql_warn "$0: ignoring $f" ;;
    esac
  done
}

# The healthcheck authenticates as this user, so it has to exist on a datadir
# older than the healthcheck too. The unconditional ALTER is deliberate:
# CREATE USER IF NOT EXISTS on its own is a no-op that leaves whatever password
# the account already had.
mysql_ensure_healthcheck_user() {
  docker_process_sql --database=mysql <<-'EOSQL'
    SET @@SESSION.SQL_LOG_BIN=0;
    CREATE USER IF NOT EXISTS 'ping'@'localhost' IDENTIFIED BY 'pong';
    ALTER USER 'ping'@'localhost' IDENTIFIED BY 'pong';
    GRANT USAGE ON *.* TO 'ping'@'localhost';
    CREATE USER IF NOT EXISTS 'ping'@'127.0.0.1' IDENTIFIED BY 'pong';
    ALTER USER 'ping'@'127.0.0.1' IDENTIFIED BY 'pong';
    GRANT USAGE ON *.* TO 'ping'@'127.0.0.1';
EOSQL
}

mysql_query_value() {
  docker_process_sql --database=mysql --batch --skip-column-names <<<"$1"
}

mysql_bootstrap_on_start() {
  local timeout="${MYSQL_ALWAYS_TIMEOUT:-900}" waited=0 err=''

  while ! err="$(mysql_query_value 'SELECT 1' 2>&1 >/dev/null)"; do
    if [ "$waited" -ge "$timeout" ]; then
      mysql_err "start-time bootstrap: could not connect as root within ${timeout}s — ${ALWAYS_DIR} NOT applied. Last error: ${err}"
      return 1
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  # super_read_only blocks root as well, which is the point of it on a standby:
  # its accounts and grants arrive over replication (or came with the CLONE),
  # they are not applied locally. read_only alone does not block root, so it is
  # not a reason to skip.
  if [ "$(mysql_query_value 'SELECT @@global.super_read_only' 2>/dev/null || echo 0)" = '1' ]; then
    mysql_note "start-time bootstrap: server is super_read_only, skipping (writes replicate from the primary)"
    return 0
  fi

  if [ -z "${MYSQL_HEALTHCHECK_DISABLE:-}" ]; then
    if ! mysql_ensure_healthcheck_user; then
      mysql_err "start-time bootstrap: could not create the 'ping' healthcheck user"
      return 1
    fi
  fi

  if ! docker_process_always_files; then
    mysql_err "start-time bootstrap FAILED — the server is up but ${ALWAYS_DIR} was not fully applied"
    return 1
  fi

  mysql_note "start-time bootstrap complete"
}

mysql_start_bootstrap() {
  local have_files=''
  [ -n "$(ls -A "$ALWAYS_DIR" 2>/dev/null)" ] && have_files='true'
  if [ -z "$have_files" ] && [ -n "${MYSQL_HEALTHCHECK_DISABLE:-}" ]; then
    return
  fi
  mysql_bootstrap_on_start &
}

_mysql_want_help() {
  local arg
  for arg; do
    case "$arg" in
      -'?'|--help|--print-defaults|-V|--version) return 0 ;;
    esac
  done
  return 1
}

_main() {
  if [ "${1:0:1}" = '-' ]; then
    set -- mysqld "$@"
  fi

  if [ "$1" = 'mysqld' ] && ! _mysql_want_help "$@"; then
    mysql_note "Entrypoint script for MySQL Server ${MYSQL_VERSION} started."

    mysql_render_env_config
    mysql_generate_ssl_certs
    mysql_check_config "$@"
    docker_setup_env "$@"
    docker_create_db_directories "$@"

    # Note: gosu is not installed in this image.
    # The container runs as USER mysql (see Dockerfile), so this block
    # is not reached. If root execution is needed, install gosu first.
    # if [ "$(id -u)" = "0" ]; then
    #   mysql_note "Switching to dedicated user 'mysql'"
    #   exec gosu mysql "$BASH_SOURCE" "$@"
    # fi

    if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
      docker_verify_minimum_env
      ls /docker-entrypoint-initdb.d/ > /dev/null

      docker_init_database_dir "$@"

      mysql_note "Starting temporary server"
      docker_temp_server_start "$@"
      mysql_note "Temporary server started."

      mysql_socket_fix
      docker_setup_db
      docker_process_init_files /docker-entrypoint-initdb.d/*

      mysql_expire_root_user

      mysql_note "Stopping temporary server"
      docker_temp_server_stop
      mysql_note "Temporary server stopped"

      echo
      mysql_note "MySQL init process done. Ready for start up."
      echo
    else
      mysql_socket_fix
    fi

    # Backgrounded: waits for the server this exec is about to become, then
    # applies the start-time bootstrap. mysqld stays PID 1 and is not delayed.
    mysql_start_bootstrap
  fi

  exec "$@"
}

if ! _is_sourced; then
  _main "$@"
fi
