#!/usr/bin/env bash
# ============================================================
# spp-database entrypoint — Linux-native MariaDB + Apache
# ============================================================

set -e

MAINFOLDER="${SPP_ROOT:-/opt/spp/server}"
LOGDIR="$MAINFOLDER/Logs"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   PraeviusCore V2 Database  (Linux)      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

mkdir -p "$LOGDIR"

extract_if_missing() {
    local check_path="$1"
    local archive="$2"
    local extract_dir="$3"
    if [ ! -e "$check_path" ]; then
        echo "[SETUP] $check_path not found — extracting $archive ..."
        7z x "$MAINFOLDER/Tools/$archive" -o"$extract_dir" -y
        echo "[SETUP] Done."
    fi
}

extract_if_missing "$MAINFOLDER/Database/SPP-Database.ini"       "Database.7z.001" "$MAINFOLDER"
extract_if_missing "$MAINFOLDER/Tools/Apache24/apache_start.bat" "Apache24.7z"     "$MAINFOLDER/Tools"
extract_if_missing "$MAINFOLDER/Tools/php7/php.ini"              "php7.7z"          "$MAINFOLDER/Tools"

# ── Apache ────────────────────────────────────────────────
mkdir -p "$MAINFOLDER/Tools/www"
echo "ServerName spp-database" >> /etc/apache2/apache2.conf
echo "[WEB]  Starting Apache2 web panel..."
service apache2 start || apachectl start || true

# ── Locate datadir ────────────────────────────────────────
echo ""
echo "[DB]   PraeviusCore V2 Database server starting..."
echo "[DB]   Wait a few seconds before starting the other servers."
echo ""
echo "       Database access:"
echo "       Port: 3310"
echo "       User: spp_user"
echo "       Pass: 123456"
echo ""

if [ -d "$MAINFOLDER/Database/data" ]; then
    DATADIR="$MAINFOLDER/Database/data"
elif [ -d "$MAINFOLDER/Database" ]; then
    DATADIR="$MAINFOLDER/Database"
else
    echo "[DB] ERROR: Cannot find database data directory."
    exit 1
fi

echo "[DB]   Using datadir: $DATADIR"
chown -R root:root "$DATADIR"

mkdir -p /run/mysqld
chown -R root:root /run/mysqld

# ── One-time remote access grant ─────────────────────────
GRANT_DONE_MARKER="$DATADIR/.remote_access_granted"

# Helper: wait for mysqld socket to be ready and accepting connections
wait_for_mysql() {
    local max_wait="${1:-120}"   # default 120 seconds — SPP DB is large
    echo "[DB]   Waiting up to ${max_wait}s for MariaDB to be ready..."
    for i in $(seq 1 "$max_wait"); do
        # Test with a real connection attempt, not just socket file presence
        if mysqladmin --socket=/run/mysqld/mysqld.sock ping --silent 2>/dev/null; then
            echo "[DB]   MariaDB is ready (took ${i}s)."
            return 0
        fi
        printf "."
        sleep 1
    done
    echo ""
    echo "[DB]   ERROR: MariaDB did not become ready within ${max_wait}s."
    return 1
}

if [ ! -f "$GRANT_DONE_MARKER" ]; then
    echo "[DB]   First run: granting remote access to database users..."

    # Start bootstrap instance in background
    mysqld \
        --defaults-file="$MAINFOLDER/Database/SPP-Database.ini" \
        --user=root \
        --datadir="$DATADIR" \
        --socket=/run/mysqld/mysqld.sock \
        --skip-networking \
        --skip-grant-tables \
        --log-warnings=0 \
        --explicit_defaults_for_timestamp \
        --sql-mode="" &
    BOOTSTRAP_PID=$!

    # Wait until it's actually accepting connections (not just socket file exists)
    if ! wait_for_mysql 120; then
        kill "$BOOTSTRAP_PID" 2>/dev/null || true
        exit 1
    fi

    # Flush privileges first to re-enable grant system while skip-grant-tables is active,
    # then run GRANT statements
    mysql --socket=/run/mysqld/mysqld.sock << 'SQL'
FLUSH PRIVILEGES;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%'            IDENTIFIED BY ''                   WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost'     IDENTIFIED BY ''                   WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_user'@'%'         IDENTIFIED BY '123456'             WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_user'@'localhost'  IDENTIFIED BY '123456'             WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_userDB'@'%'       IDENTIFIED BY 'wl0BlZ@4QB7V@Bpg'  WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_userDB'@'localhost' IDENTIFIED BY 'wl0BlZ@4QB7V@Bpg' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'trinity'@'%'          IDENTIFIED BY 'trinity'            WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'trinity'@'localhost'   IDENTIFIED BY 'trinity'            WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

    echo ""
    echo "[DB]   Grants applied. Shutting down bootstrap instance..."

    mysqladmin --socket=/run/mysqld/mysqld.sock shutdown 2>/dev/null || kill "$BOOTSTRAP_PID" 2>/dev/null || true
    wait "$BOOTSTRAP_PID" 2>/dev/null || true

    # Wait for socket to fully disappear before starting the real instance
    echo "[DB]   Waiting for bootstrap instance to stop..."
    for i in $(seq 1 30); do
        [ ! -S /run/mysqld/mysqld.sock ] && break
        sleep 1
    done

    touch "$GRANT_DONE_MARKER"
    echo "[DB]   Remote access granted. Starting normal instance..."
else
    echo "[DB]   Remote access already configured (marker found)."
fi

echo ""
echo "[DB]   Starting MariaDB for normal operation..."

# Start in background so we can run mariadb-upgrade against it first
mysqld \
    --defaults-file="$MAINFOLDER/Database/SPP-Database.ini" \
    --user=root \
    --datadir="$DATADIR" \
    --socket=/run/mysqld/mysqld.sock \
    --bind-address=0.0.0.0 \
    --log-warnings=1 \
    --explicit_defaults_for_timestamp \
    --sql-mode="" &
MYSQLD_PID=$!

# Wait for ready
echo "[DB]   Waiting for MariaDB..."
for i in $(seq 1 60); do
    mysqladmin --socket=/run/mysqld/mysqld.sock \
        --user=spp_user --password=123456 ping --silent 2>/dev/null && break
    sleep 1
done

# ── mariadb-upgrade ────────────────────────────────────────
# Fixes mysql.proc column count mismatch from old MySQL/MariaDB version.
# This makes mysqldump --routines work correctly for saves/backups.
UPGRADE_MARKER="$DATADIR/.mariadb_upgraded"
if [ ! -f "$UPGRADE_MARKER" ]; then
    echo "[DB]   Running mariadb-upgrade to fix system table schemas..."
    mariadb-upgrade \
        --socket=/run/mysqld/mysqld.sock \
        --user=spp_user --password=123456 \
        --silent 2>/dev/null || \
    mysql_upgrade \
        --socket=/run/mysqld/mysqld.sock \
        --user=spp_user --password=123456 \
        --silent 2>/dev/null || true
    touch "$UPGRADE_MARKER"
    echo "[DB]   System tables upgraded successfully."
else
    echo "[DB]   System tables already upgraded."
fi

echo "[DB]   Ready."
wait "$MYSQLD_PID"
