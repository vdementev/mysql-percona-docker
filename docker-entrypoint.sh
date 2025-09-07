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
  if ! "$@" --daemonize --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}"; then
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

  file_env 'MYSQL_ROOT_HOST' '172.%.%.%'
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

      CREATE USER IF NOT EXISTS 'ping'@'%' IDENTIFIED BY 'pong';
      GRANT USAGE ON *.* TO 'ping'@'%';
EOSQL
    # Optional subnet-specific account: create before granting
    if [ -n "$MYSQL_ROOT_HOST" ] && [[ "$MYSQL_ROOT_HOST" == 172.* ]]; then
      ping_block+=$'\n'"CREATE USER IF NOT EXISTS 'ping'@'172.%.%.%' IDENTIFIED BY 'pong';"
      ping_block+=$'\n'"GRANT USAGE ON *.* TO 'ping'@'172.%.%.%';"
    fi
  fi

  # 4) execute in one session
  docker_process_sql --dont-use-mysql-root-password --database=mysql <<-EOSQL
    SET autocommit = 1;
    SET @@SESSION.SQL_LOG_BIN=0;

    ${root_block_local}
    ${root_block_nonlocal}
    ${ping_block}

    DROP DATABASE IF EXISTS test;
EOSQL

  # 5) optional application db & user
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

    mysql_check_config "$@"
    docker_setup_env "$@"
    docker_create_db_directories "$@"

    # If container started as root, re-exec as mysql (not expected when USER mysql)
    if [ "$(id -u)" = "0" ]; then
      mysql_note "Switching to dedicated user 'mysql'"
      exec gosu mysql "$BASH_SOURCE" "$@"
    fi

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
  fi

  exec "$@"
}

if ! _is_sourced; then
  _main "$@"
fi
