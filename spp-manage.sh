#!/usr/bin/env bash
# ============================================================
# spp-manage.sh — SPP Podman Stack Manager
#
# Networking modes (set one):
#   Tailscale (recommended) — pod gets a stable Tailscale IP
#     ./spp-manage.sh set-ts-key tskey-auth-xxxx
#     ./spp-manage.sh start
#
#   Macvlan (LAN static IP) — pod appears as LAN device
#     ./spp-manage.sh set-ip    192.168.1.50
#     ./spp-manage.sh set-iface enp4s0
#     ./spp-manage.sh start
#
#   Neither — uses host port forwarding (host LAN IP)
#     ./spp-manage.sh start
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.spp-env"

if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

SPP_HOST_PATH="${SPP_HOST_PATH:-Change/My/Directory}"
SPP_POD_IP="${SPP_POD_IP:-}"
SPP_HOST_IFACE="${SPP_HOST_IFACE:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-spp-server}"

SPP_CONTAINER_PATH="/opt/spp/server"
TS_STATE_DIR="$SCRIPT_DIR/.tailscale-state"
POD_NAME="spp-pod"
NETWORK_NAME="spp-macvlan"

IMG_DATABASE="spp-database-img"
IMG_BNET="spp-bnet-img"
IMG_WORLD="spp-world-img"
IMG_TAILSCALE="spp-tailscale-img"

CTR_DATABASE="spp-database"
CTR_BNET="spp-bnet"
CTR_WORLD="spp-world"
CTR_TAILSCALE="spp-tailscale"

# ────────────────────────────────────────────────────────────
save_config() {
    cat > "$CONFIG_FILE" << CONF
SPP_HOST_PATH="$SPP_HOST_PATH"
SPP_POD_IP="$SPP_POD_IP"
SPP_HOST_IFACE="$SPP_HOST_IFACE"
TS_AUTHKEY="$TS_AUTHKEY"
TS_HOSTNAME="$TS_HOSTNAME"
CONF
}

get_host_ip() {
    ip addr show | grep 'inet ' | grep -v '127.0.0.1' \
        | awk '{print $2}' | cut -d/ -f1 | head -1
}

detect_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1
}

networking_mode() {
    if [ -n "$TS_AUTHKEY" ]; then
        echo "tailscale"
    elif [ -n "$SPP_POD_IP" ]; then
        echo "macvlan"
    else
        echo "hostport"
    fi
}

# ────────────────────────────────────────────────────────────
print_header() {
    local mode; mode="$(networking_mode)"
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║        SPP Podman Stack Manager           ║"
    echo "╚═══════════════════════════════════════════╝"
    echo "  SPP files path  : $SPP_HOST_PATH"
    echo "  Networking mode : $mode"
    case "$mode" in
        tailscale) echo "  TS hostname     : $TS_HOSTNAME" ;;
        macvlan)   echo "  Pod IP          : $SPP_POD_IP"
                   echo "  Host NIC        : ${SPP_HOST_IFACE:-$(detect_iface)}" ;;
        hostport)  echo "  Host LAN IP     : $(get_host_ip)" ;;
    esac
    echo ""
}

check_path() {
    if [ "$SPP_HOST_PATH" = "Change/My/Directory" ]; then
        echo "⚠️  SPP_HOST_PATH not set. Run: ./spp-manage.sh set-path /your/path"
        read -rp "Continue anyway? (y/N): " c
        [[ "$c" =~ ^[Yy]$ ]] || exit 1
    fi
    if [ ! -d "$SPP_HOST_PATH" ]; then
        echo "⚠️  '$SPP_HOST_PATH' does not exist."
        read -rp "Continue? (y/N): " c
        [[ "$c" =~ ^[Yy]$ ]] || exit 1
    fi
}

# ────────────────────────────────────────────────────────────
ensure_macvlan_network() {
    podman network exists "$NETWORK_NAME" 2>/dev/null && \
        echo "ℹ️  Macvlan network exists — reusing." && return 0

    local subnet; subnet="$(echo "$SPP_POD_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')"
    local gateway; gateway="$(echo "$SPP_POD_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
    local iface="${SPP_HOST_IFACE:-$(detect_iface)}"

    echo "🌐 Creating macvlan network ($subnet via $iface)..."
    podman network create \
        --driver macvlan \
        --opt parent="$iface" \
        --subnet "$subnet" \
        --gateway "$gateway" \
        --ip-range "${SPP_POD_IP}/32" \
        "$NETWORK_NAME"
}

# ────────────────────────────────────────────────────────────
build_images() {
    local force="${1:-}"
    local mode; mode="$(networking_mode)"

    echo "🔨 Building spp-database image..."
    podman build $force -t "$IMG_DATABASE" \
        -f "$SCRIPT_DIR/database/Containerfile" "$SCRIPT_DIR/database"
    echo ""
    echo "🔨 Building spp-bnet image..."
    podman build $force -t "$IMG_BNET" \
        -f "$SCRIPT_DIR/bnet/Containerfile" "$SCRIPT_DIR/bnet"
    echo ""
    echo "🔨 Building spp-world image..."
    podman build $force -t "$IMG_WORLD" \
        -f "$SCRIPT_DIR/world/Containerfile" "$SCRIPT_DIR/world"

    if [ "$mode" = "tailscale" ]; then
        echo ""
        echo "🔨 Building spp-tailscale image..."
        podman build $force -t "$IMG_TAILSCALE" \
            -f "$SCRIPT_DIR/tailscale/Containerfile" "$SCRIPT_DIR/tailscale"
    fi

    echo ""
    echo "✅ All images built."
}

# ────────────────────────────────────────────────────────────
create_pod() {
    local mode; mode="$(networking_mode)"

    local pod_args=(--name "$POD_NAME")

    case "$mode" in
        tailscale)
            # Tailscale userspace networking handles its own routing
            # We still expose ports via host for LAN fallback access
            pod_args+=(
                -p 3310:3310
                -p 8080:80
                -p 1119:1119
                -p 3724:3724
                -p 1120:1120
                -p 8085:8085
                -p 7878:7878
            )
            ;;
        macvlan)
            ensure_macvlan_network
            pod_args+=(--network "$NETWORK_NAME:ip=$SPP_POD_IP")
            ;;
        hostport)
            pod_args+=(
                -p 3310:3310
                -p 8080:80
                -p 1119:1119
                -p 3724:3724
                -p 1120:1120
                -p 8085:8085
                -p 7878:7878
            )
            ;;
    esac

    echo "🚀 Creating pod: $POD_NAME ($mode mode)"
    podman pod create "${pod_args[@]}"
}

# ────────────────────────────────────────────────────────────
cmd_start() {
    print_header
    check_path

    local mode; mode="$(networking_mode)"

    # Check images — include tailscale image if needed
    local need_build=false
    for img in "$IMG_DATABASE" "$IMG_BNET" "$IMG_WORLD"; do
        podman image exists "$img" 2>/dev/null || need_build=true
    done
    if [ "$mode" = "tailscale" ]; then
        podman image exists "$IMG_TAILSCALE" 2>/dev/null || need_build=true
    fi
    if [ "$need_build" = true ]; then
        echo "📦 One or more images not found — building now..."
        build_images
    fi

    if ! podman pod exists "$POD_NAME" 2>/dev/null; then
        create_pod
    else
        echo "ℹ️  Pod '$POD_NAME' already exists — reusing."
    fi

    VOL="$SPP_HOST_PATH:$SPP_CONTAINER_PATH:z"

    # ── STEP 0: Tailscale sidecar (starts first if enabled) ──
    if [ "$mode" = "tailscale" ]; then
        mkdir -p "$TS_STATE_DIR"
        if podman container exists "$CTR_TAILSCALE" 2>/dev/null; then
            printf "  [0/3] Starting Tailscale sidecar..."
            podman start "$CTR_TAILSCALE" &>/dev/null
        else
            printf "  [0/3] Starting Tailscale sidecar..."
            podman run -d \
                --pod "$POD_NAME" \
                --name "$CTR_TAILSCALE" \
                --restart unless-stopped \
                --cap-add NET_ADMIN \
                --cap-add NET_RAW \
                --device /dev/net/tun \
                -v "$TS_STATE_DIR:/var/lib/tailscale:z" \
                -e TS_AUTHKEY="$TS_AUTHKEY" \
                -e TS_HOSTNAME="$TS_HOSTNAME" \
                "$IMG_TAILSCALE" &>/dev/null
        fi

        for i in $(seq 1 60); do
            local ts_ip
            ts_ip="$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null || true)"
            if [ -n "$ts_ip" ] && [ "$ts_ip" != "pending..." ]; then
                printf " ✅\n"
                break
            fi
            printf "."; sleep 1
        done

        if [ -z "$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null || true)" ]; then
            printf " ⚠️\n"
            clear
            print_header
            echo "⚠️  Tailscale not yet connected. Check logs:"
            echo "   ./spp-manage.sh logs spp-tailscale"
            echo ""
            echo "   If this is your first run, get the auth URL from the logs"
            echo "   and open it in a browser — OR set a pre-auth key:"
            echo "   ./spp-manage.sh set-ts-key tskey-auth-xxxx"
            echo ""
            read -rp "Continue starting game servers anyway? (y/N): " c
            [[ "$c" =~ ^[Yy]$ ]] || exit 1
        fi
    fi

    # ── STEP 1: spp-database ─────────────────────────────────
    printf "  [1/3] Starting database..."
    if podman container exists "$CTR_DATABASE" 2>/dev/null; then
        podman start "$CTR_DATABASE" &>/dev/null
    else
        podman run -d \
            --pod "$POD_NAME" \
            --name "$CTR_DATABASE" \
            --restart unless-stopped \
            -v "$VOL" \
            -e SPP_ROOT="$SPP_CONTAINER_PATH" \
            "$IMG_DATABASE" &>/dev/null
    fi

    retries=0
    until podman exec "$CTR_DATABASE" \
            mysqladmin --port=3310 --user=spp_user --password=123456 ping \
            --silent 2>/dev/null; do
        retries=$((retries+1))
        if [ "$retries" -ge 60 ]; then
            printf " ⚠️\n"
            echo "⚠️  DB timeout. Check: ./spp-manage.sh logs spp-database"
            break
        fi
        printf "."; sleep 2
    done
    printf " ✅\n"

    # ── STEP 2: spp-bnet ─────────────────────────────────────
    printf "  [2/3] Starting bnetserver..."
    if podman container exists "$CTR_BNET" 2>/dev/null; then
        podman start "$CTR_BNET" &>/dev/null
    else
        podman run -d \
            --pod "$POD_NAME" \
            --name "$CTR_BNET" \
            --restart unless-stopped \
            -v "$VOL" \
            -e SPP_ROOT="$SPP_CONTAINER_PATH" \
            -e WINEDEBUG=-all \
            "$IMG_BNET" &>/dev/null
    fi
    sleep 5
    printf " ✅\n"

    # ── STEP 3: spp-world ────────────────────────────────────
    printf "  [3/3] Starting worldserver..."
    if podman container exists "$CTR_WORLD" 2>/dev/null; then
        podman start "$CTR_WORLD" &>/dev/null
    else
        podman run -d \
            --pod "$POD_NAME" \
            --name "$CTR_WORLD" \
            --restart unless-stopped \
            -v "$VOL" \
            -e SPP_ROOT="$SPP_CONTAINER_PATH" \
            -e WINEDEBUG=-all \
            "$IMG_WORLD" &>/dev/null
    fi
    printf " ✅\n"

    # ── Print connection info ────────────────────────────────
    clear
    print_header
    echo "✅ All containers started."
    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│              Connection Information                  │"
    echo "├─────────────────────────────────────────────────────┤"

    case "$mode" in
        tailscale)
            local ts_ip
            ts_ip="$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null \
                || echo 'check: ./spp-manage.sh ts-ip')"
            printf "│  🌐 Mode          : %-32s│\n" "Tailscale"
            printf "│  🎮 Connect IP    : %-32s│\n" "$ts_ip"
            printf "│  🗄️  DB host      : %-32s│\n" "$ts_ip"
            ;;
        macvlan)
            printf "│  🌐 Mode          : %-32s│\n" "Macvlan (LAN static IP)"
            printf "│  🎮 Connect IP    : %-32s│\n" "$SPP_POD_IP"
            printf "│  🗄️  DB host      : %-32s│\n" "$SPP_POD_IP"
            ;;
        hostport)
            local h_ip; h_ip="$(get_host_ip)"
            printf "│  🌐 Mode          : %-32s│\n" "Host port forwarding"
            printf "│  🎮 Connect IP    : %-32s│\n" "$h_ip"
            printf "│  🗄️  DB host      : %-32s│\n" "$h_ip"
            ;;
    esac

    printf "│  🗄️  DB port      : %-32s│\n" "3310"
    printf "│  🗄️  DB user      : %-32s│\n" "spp_user"
    printf "│  🗄️  DB pass      : %-32s│\n" "123456"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""

    cmd_status
}

# ────────────────────────────────────────────────────────────
cmd_stop() {
    print_header
    echo "■ Stopping containers..."
    for ctr in "$CTR_WORLD" "$CTR_BNET" "$CTR_DATABASE" "$CTR_TAILSCALE"; do
        if podman container exists "$ctr" 2>/dev/null; then
            echo "  Stopping $ctr..."; podman stop "$ctr" 2>/dev/null || true
            podman rm "$ctr" 2>/dev/null || true
        fi
    done
    podman pod exists "$POD_NAME" 2>/dev/null && \
        podman pod rm "$POD_NAME" 2>/dev/null || true
    echo "✅ Stopped."
}

cmd_status() {
    echo ""
    echo "Container status:"
    echo "─────────────────────────────────────────────────────────"
    podman ps -a --filter "name=spp-" \
        --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "(none)"
    echo ""
    podman pod ps --filter "name=$POD_NAME" 2>/dev/null || echo "(pod not running)"
    echo ""
    local mode; mode="$(networking_mode)"
    echo "  Networking: $mode"
    [ "$mode" = "tailscale" ] && cmd_ts_ip
}

cmd_logs() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        podman logs -f "$target"
    else
        for ctr in "$CTR_TAILSCALE" "$CTR_DATABASE" "$CTR_BNET" "$CTR_WORLD"; do
            podman container exists "$ctr" 2>/dev/null || continue
            echo "── $ctr ──────────────────────────────────────"
            podman logs --tail 20 "$ctr" 2>/dev/null
            echo ""
        done
        echo "Follow live: ./spp-manage.sh logs spp-tailscale"
    fi
}

cmd_rebuild() {
    print_header; build_images "--no-cache"
    echo "✅ Done. Run './spp-manage.sh start'."
}

# ────────────────────────────────────────────────────────────
cmd_ts_ip() {
    if ! podman container exists "$CTR_TAILSCALE" 2>/dev/null; then
        echo "  spp-tailscale is not running."
        return 1
    fi
    local ts_ip
    ts_ip="$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null || echo '')"
    if [ -n "$ts_ip" ]; then
        echo ""
        echo "  Tailscale IP : $ts_ip"
        echo ""
        echo "  WoW realmlist:  set realmlist $ts_ip"
        echo "  DB connect  :  $ts_ip : 3310"
    else
        echo ""
        echo "  Tailscale not yet connected."
        echo "  Check auth: ./spp-manage.sh logs spp-tailscale"
    fi
}

cmd_ts_login() {
    # For first-time interactive login when no authkey is set
    if ! podman container exists "$CTR_TAILSCALE" 2>/dev/null; then
        echo "❌ spp-tailscale is not running. Start the stack first."
        exit 1
    fi
    echo "Opening Tailscale login — copy the URL and open it in your browser:"
    echo ""
    podman exec "$CTR_TAILSCALE" tailscale up \
        --hostname="$TS_HOSTNAME" \
        --accept-routes \
        --accept-dns=false
}

# ────────────────────────────────────────────────────────────
cmd_set_path() {
    [ -z "$1" ] && echo "Usage: set-path <path>" && exit 1
    SPP_HOST_PATH="$1"; save_config
    echo "✅ Path saved: $1"
}

cmd_set_ts_key() {
    [ -z "$1" ] && cat << HELP
Usage: ./spp-manage.sh set-ts-key <authkey>

Get a key from: https://login.tailscale.com/admin/settings/keys
  - Click "Generate auth key"
  - Check "Reusable" so restarts don't need a new key
  - Optionally check "Ephemeral" if you don't want it in your device list permanently

Current key: ${TS_AUTHKEY:+set (hidden)}${TS_AUTHKEY:-not set}
HELP
    [ -z "$1" ] && exit 1

    TS_AUTHKEY="$1"; save_config
    echo "✅ Tailscale auth key saved."
    echo "   Networking mode is now: tailscale"
    echo "   Run './spp-manage.sh restart' to apply."
    echo ""
    echo "   To remove the key and go back to macvlan/hostport:"
    echo "   ./spp-manage.sh set-ts-key clear"
}

cmd_set_ts_hostname() {
    [ -z "$1" ] && echo "Usage: set-ts-hostname <name>" \
        && echo "Current: $TS_HOSTNAME" && exit 1
    TS_HOSTNAME="$1"; save_config
    echo "✅ Tailscale hostname saved: $1"
}

cmd_set_ip() {
    [ -z "$1" ] && echo "Usage: set-ip <IPv4>" && exit 1
    SPP_POD_IP="$1"; save_config
    podman network rm "$NETWORK_NAME" 2>/dev/null || true
    echo "✅ Macvlan IP saved: $1  (networking mode: macvlan)"
}

cmd_set_iface() {
    [ -z "$1" ] && echo "Usage: set-iface <nic>  (find with: ip link show)" && exit 1
    ip link show "$1" &>/dev/null || { echo "❌ Interface '$1' not found."; exit 1; }
    SPP_HOST_IFACE="$1"; save_config
    podman network rm "$NETWORK_NAME" 2>/dev/null || true
    echo "✅ NIC saved: $1"
}

# ────────────────────────────────────────────────────────────
# ────────────────────────────────────────────────────────────
cmd_fix_db() {
    _ensure_database || return 1
    local sql_file="${1:-$SCRIPT_DIR/database/scripts/fix-missing-tables.sql}"
    if [ ! -f "$sql_file" ]; then
        echo "❌ SQL file not found: $sql_file"
        echo "   Usage: ./spp-manage.sh fix-db [path/to/file.sql]"
        exit 1
    fi
    echo "🔧 Checking database connection..."
    if ! podman exec "$CTR_DATABASE" \
            mysqladmin --socket=/run/mysqld/mysqld.sock --user=spp_user --password=123456 ping --silent 2>/dev/null; then
        echo "❌ Cannot reach MariaDB inside spp-database."
        echo "   Check: ./spp-manage.sh logs spp-database"
        exit 1
    fi
    echo "🔧 Running $(basename "$sql_file") against legion_auth..."
    # Pipe SQL directly, explicitly targeting legion_auth database
    podman exec -i "$CTR_DATABASE" \
        mysql \
        --socket=/run/mysqld/mysqld.sock \
        --user=spp_user \
        --password=123456 \
        --database=legion_auth \
        --verbose \
        < "$sql_file"
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✅ Tables created. Verifying..."
        podman exec "$CTR_DATABASE" \
            mysql --socket=/run/mysqld/mysqld.sock --user=spp_user --password=123456 --database=legion_auth \
            -e "SELECT table_name AS 'Table', table_rows AS 'Rows' FROM information_schema.tables WHERE table_schema='legion_auth' AND table_name IN ('uptime','transferts','transferts_logs','transfer_requests','store_products','store_history') ORDER BY table_name;"
        echo ""
        echo "   podman restart spp-bnet"
    else
        echo "❌ SQL script failed with exit code $exit_code"
        echo "   Try running manually:"
        echo "   podman exec -it spp-database mysql --socket=/run/mysqld/mysqld.sock --user=spp_user --password=123456 --database=legion_auth"
    fi
}

# ============================================================
# ── PROFILE / LAUNCHER SYSTEM ───────────────────────────────
# Ported from SPP-LegionV2 Launcher.bat
# ============================================================

# SAVES_DIR is derived at runtime so SPP_HOST_PATH changes are picked up
get_saves_dir() { echo "$SPP_HOST_PATH/Saves"; }
# DB_CREDS is used unquoted intentionally so it word-splits into separate args
DB_CREDS="--socket=/run/mysqld/mysqld.sock --user=spp_user --password=123456"

# ────────────────────────────────────────────────────────────
# Helper: run mysql inside the database container
db_query() {
    podman exec "$CTR_DATABASE" \
        mysql $DB_CREDS --silent --skip-column-names \
        -e "$1" 2>/dev/null
}

db_query_db() {
    local database="$1"; shift
    podman exec "$CTR_DATABASE" \
        mysql $DB_CREDS --silent --skip-column-names \
        --database="$database" \
        -e "$1" 2>/dev/null
}

# Helper: check if a container is running
ctr_running() {
    podman ps --filter "name=^${1}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${1}$"
}

# Helper: draw a section header
section() {
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    printf "  │  %-41s│\n" "$1"
    echo "  └─────────────────────────────────────────┘"
    echo ""
}

# ────────────────────────────────────────────────────────────
# SERVER MANAGER  (bat: servers_manager)
# ────────────────────────────────────────────────────────────
cmd_server_manager() {
    while true; do
        local db_state bnet_state world_state web_state
        db_state=$(ctr_running "$CTR_DATABASE" && echo "ON " || echo "OFF")
        bnet_state=$(ctr_running "$CTR_BNET"     && echo "ON " || echo "OFF")
        world_state=$(ctr_running "$CTR_WORLD"    && echo "ON " || echo "OFF")
        web_state=$(podman exec "$CTR_DATABASE" \
            service apache2 status &>/dev/null && echo "ON " || echo "OFF")

        clear
        section "Server Manager"
        echo "   1 - Database server  = $db_state"
        echo "   2 - Bnet server      = $bnet_state"
        echo "   3 - World server     = $world_state"
        echo "   4 - Apache (website) = $web_state"
        echo ""
        echo "   5 - Manage ALL servers"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Select server: " opt
        case "$opt" in
            1) cmd_manage_single "database" ;;
            2) cmd_manage_single "bnet" ;;
            3) cmd_manage_single "world" ;;
            4) cmd_manage_single "web" ;;
            5) cmd_manage_all ;;
            0) return ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────
# Manage a single server  (bat: manage_*_server)
cmd_manage_single() {
    local srv="$1"
    local label
    case "$srv" in
        database) label="Database" ;;
        bnet)     label="Bnet"     ;;
        world)    label="World"    ;;
        web)      label="Apache / Website" ;;
    esac

    while true; do
        clear
        section "$label Server"
        echo "   1 - Start"
        echo "   2 - Stop"
        echo "   3 - Restart"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Choice: " opt
        case "$opt" in
            1) _srv_start "$srv";   read -rp "  Press Enter..." ;;
            2) _srv_stop  "$srv";   read -rp "  Press Enter..." ;;
            3) _srv_stop  "$srv"; _srv_start "$srv"; read -rp "  Press Enter..." ;;
            0) return ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────
# Manage ALL servers  (bat: manage_all_servers)
cmd_manage_all() {
    while true; do
        clear
        section "All Servers"
        echo "   1 - Start all"
        echo "   2 - Stop all"
        echo "   3 - Restart all"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Choice: " opt
        case "$opt" in
            1) cmd_start ;;
            2) cmd_stop  ;;
            3) cmd_stop; cmd_start ;;
            0) return ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────
# Low-level start/stop helpers
# ── Ensure Tailscale sidecar is running ─────────────────────
_ensure_tailscale() {
    [ -z "$TS_AUTHKEY" ] && return 0   # Tailscale not configured — skip
    if ctr_running "$CTR_TAILSCALE"; then
        return 0
    fi
    printf "  🌐 Starting Tailscale sidecar..."
    _ensure_pod
    mkdir -p "$SCRIPT_DIR/.tailscale-state"
    if podman container exists "$CTR_TAILSCALE" 2>/dev/null; then
        podman start "$CTR_TAILSCALE" &>/dev/null || true
    else
        podman run -d \
            --pod "$POD_NAME" \
            --name "$CTR_TAILSCALE" \
            --restart unless-stopped \
            --cap-add NET_ADMIN \
            --cap-add NET_RAW \
            --device /dev/net/tun \
            -v "$SCRIPT_DIR/.tailscale-state:/var/lib/tailscale:z" \
            -e TS_AUTHKEY="$TS_AUTHKEY" \
            -e TS_HOSTNAME="$TS_HOSTNAME" \
            "$IMG_TAILSCALE" &>/dev/null || true
    fi
    # Wait up to 15s for Tailscale to connect (don't block too long)
    local ts_retries=0
    while [ $ts_retries -lt 15 ]; do
        local ts_ip
        ts_ip=$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null || true)
        if [ -n "$ts_ip" ]; then
            printf " ✅\n"
            clear
            return 0
        fi
        printf "."; sleep 1
        ts_retries=$((ts_retries+1))
    done
    printf " ⚠️\n"
    clear
    echo "  ⚠️  Tailscale not yet connected — check: ./spp-manage.sh logs spp-tailscale"
}

# ── Ensure database is running, start it if not ─────────────
_ensure_database() {
    if ctr_running "$CTR_DATABASE"; then
        return 0
    fi
    printf "  ⏳ Starting database..."
    _ensure_pod
    _ensure_tailscale
    if podman container exists "$CTR_DATABASE" 2>/dev/null; then
        podman start "$CTR_DATABASE" &>/dev/null || true
    else
        podman run -d \
            --pod "$POD_NAME" \
            --name "$CTR_DATABASE" \
            --restart unless-stopped \
            -v "$SPP_HOST_PATH:$SPP_CONTAINER_PATH:z" \
            -e SPP_ROOT="$SPP_CONTAINER_PATH" \
            "$IMG_DATABASE" &>/dev/null || true
    fi
    local retries=0
    until podman exec "$CTR_DATABASE" \
            mysqladmin --socket=/run/mysqld/mysqld.sock \
            --user=spp_user --password=123456 ping --silent 2>/dev/null; do
        retries=$((retries+1))
        if [ "$retries" -ge 60 ]; then
            printf " ❌\n"
            echo "  ❌ Database did not start in time."
            return 1
        fi
        printf "."; sleep 2
    done
    printf " ✅\n"
    clear
}

# ── Ensure the pod exists before starting any container ─────
_ensure_pod() {
    if ! podman pod exists "$POD_NAME" 2>/dev/null; then
        echo "  🚀 Creating pod: $POD_NAME"
        podman pod create             --name "$POD_NAME"             -p 3310:3310             -p 8080:80               -p 1119:1119             -p 3724:3724             -p 1120:1120             -p 8085:8085             -p 7878:7878
    fi
}

_srv_start() {
    case "$1" in
        database)
            if ctr_running "$CTR_DATABASE"; then
                echo "  Database is already running."
            else
                _ensure_pod
                _ensure_tailscale
                printf "  Starting database..."
                podman start "$CTR_DATABASE" &>/dev/null || \
                    podman run -d --pod "$POD_NAME" --name "$CTR_DATABASE" \
                        --restart unless-stopped \
                        -v "$SPP_HOST_PATH:$SPP_CONTAINER_PATH:z" \
                        -e SPP_ROOT="$SPP_CONTAINER_PATH" \
                        "$IMG_DATABASE" &>/dev/null
                printf " ✅\n"
                clear
            fi ;;
        bnet)
            if ctr_running "$CTR_BNET"; then
                echo "  Bnet is already running."
            else
                # Warn if database is not running
                if ! ctr_running "$CTR_DATABASE"; then
                    echo "  ⚠️  Warning: Database is not running."
                    echo "     Bnet requires the database to connect."
                    read -rp "  Start anyway? (y/N): " c </dev/tty
                    [[ ! "$c" =~ ^[Yy]$ ]] && return
                fi
                _ensure_pod
                _ensure_tailscale
                printf "  Starting bnet..."
                podman start "$CTR_BNET" &>/dev/null || \
                    podman run -d --pod "$POD_NAME" --name "$CTR_BNET" \
                        --restart unless-stopped \
                        -v "$SPP_HOST_PATH:$SPP_CONTAINER_PATH:z" \
                        -e SPP_ROOT="$SPP_CONTAINER_PATH" \
                        -e WINEDEBUG=-all "$IMG_BNET" &>/dev/null
                printf " ✅\n"
                clear
            fi ;;
        world)
            if ctr_running "$CTR_WORLD"; then
                echo "  World is already running."
            else
                # Warn if database or bnet are not running
                local missing=""
                ctr_running "$CTR_DATABASE" || missing="database"
                ctr_running "$CTR_BNET"     || missing="$missing${missing:+, }bnet"
                if [ -n "$missing" ]; then
                    echo "  ⚠️  Warning: The following required servers are not running:"
                    echo "     $missing"
                    echo "     World requires both database and bnet to function."
                    read -rp "  Start anyway? (y/N): " c </dev/tty
                    [[ ! "$c" =~ ^[Yy]$ ]] && return
                fi
                _ensure_pod
                _ensure_tailscale
                printf "  Starting world..."
                podman start "$CTR_WORLD" &>/dev/null || \
                    podman run -d --pod "$POD_NAME" --name "$CTR_WORLD" \
                        --restart unless-stopped \
                        -v "$SPP_HOST_PATH:$SPP_CONTAINER_PATH:z" \
                        -e SPP_ROOT="$SPP_CONTAINER_PATH" \
                        -e WINEDEBUG=-all "$IMG_WORLD" &>/dev/null
                printf " ✅\n"
                clear
            fi ;;
        web)
            echo "  Starting Apache..."
            podman exec "$CTR_DATABASE" service apache2 start 2>/dev/null || true ;;
    esac
}

_srv_stop() {
    case "$1" in
        database)
            echo "  Stopping database..."
            podman stop "$CTR_DATABASE" 2>/dev/null || true
            podman rm   "$CTR_DATABASE" 2>/dev/null || true ;;
        bnet)
            echo "  Stopping bnet..."
            podman stop "$CTR_BNET" 2>/dev/null || true
            podman rm   "$CTR_BNET" 2>/dev/null || true ;;
        world)
            echo "  Stopping world (sending graceful shutdown)..."
            # Mirror the bat's Shutdown.vbs — send 'server shutdown 5' via the FIFO
            podman exec "$CTR_WORLD" \
                bash -c 'echo "server shutdown 5" > /tmp/worldserver-stdin' 2>/dev/null || true
            local attempts=0
            while ctr_running "$CTR_WORLD" && [ $attempts -lt 30 ]; do
                printf "."; sleep 3; attempts=$((attempts+1))
            done
            echo ""
            # Force kill if still running after 90s
            if ctr_running "$CTR_WORLD"; then
                echo "  Force stopping world..."
                podman stop "$CTR_WORLD" 2>/dev/null || true
            fi
            podman rm "$CTR_WORLD" 2>/dev/null || true ;;
        web)
            echo "  Stopping Apache..."
            podman exec "$CTR_DATABASE" service apache2 stop 2>/dev/null || true ;;
    esac
}

# ────────────────────────────────────────────────────────────
# SERVER SETTINGS  (bat: server_settings)
# ────────────────────────────────────────────────────────────
cmd_server_settings() {
    while true; do
        local realm_name
        realm_name=$(db_query_db "legion_auth" \
            "SELECT name FROM realmlist WHERE id=1;" 2>/dev/null || echo "unknown")

        clear
        section "Server Settings"
        echo "   Realm: $realm_name"
        echo ""
        echo "   1 - Change Realm Name"
        echo "   2 - Change Server IP"
        echo "   3 - Edit bnetserver.conf"
        echo "   4 - Edit worldserver.conf"
        echo "   5 - Database info"
        echo "   6 - Server logs"
        echo "   7 - Import custom SQL"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Choice: " opt
        case "$opt" in
            1) cmd_change_realmname ;;
            2) cmd_change_ip ;;
            3) cmd_edit_conf "bnetserver.conf" ;;
            4) cmd_edit_conf "worldserver.conf" ;;
            5) cmd_db_info ;;
            6) cmd_logs ;;
            7) cmd_sql_import ;;
            0) return ;;
        esac
    done
}

cmd_change_realmname() {
    local current
    current=$(db_query_db "legion_auth" \
        "SELECT name FROM realmlist WHERE id=1;" 2>/dev/null || echo "unknown")

    clear
    section "Change Realm Name"
    echo "   Current name: $current"
    echo ""
    read -rp "  New realm name (Enter to cancel): " newname
    [ -z "$newname" ] && return

    db_query_db "legion_auth" \
        "UPDATE realmlist SET name='$newname' WHERE id=1;"
    echo ""
    echo "  ✅ Realm name changed to: $newname"
    read -rp "  Press Enter..."
}

cmd_edit_conf() {
    local conf="$1"
    local conf_path="$SPP_HOST_PATH/Servers/$conf"
    if [ ! -f "$conf_path" ]; then
        echo "  ❌ $conf not found at: $conf_path"
        read -rp "  Press Enter..."
        return
    fi
    # Use $EDITOR, fall back to nano, then vi
    local editor="${EDITOR:-}"
    [ -z "$editor" ] && command -v nano &>/dev/null && editor="nano"
    [ -z "$editor" ] && editor="vi"
    echo "  Opening $conf with $editor..."
    "$editor" "$conf_path"
}

cmd_db_info() {
    clear
    section "Database Info"
    echo "   Host : 127.0.0.1 (inside pod)"
    echo "   Port : 3310"
    echo "   User : spp_user"
    echo "   Pass : 123456"
    echo ""
    if ctr_running "$CTR_DATABASE"; then
        echo "   Status: 🟢 Running"
        echo ""
        echo "   Databases:"
        podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS -e "SHOW DATABASES;" 2>/dev/null \
            | grep -v "^Database$" | grep -v "^information_schema$" \
            | sed 's/^/     /'
    else
        echo "   Status: 🔴 Not running"
    fi
    echo ""
    read -rp "  Press Enter..."
}

# ────────────────────────────────────────────────────────────
# ACCOUNTS  (bat: account_menu)
# ────────────────────────────────────────────────────────────
cmd_accounts() {
    while true; do
        clear
        section "Account Management"
        echo "   1 - List accounts"
        echo "   2 - Create account"
        echo "   3 - Set account password"
        echo "   4 - Set GM level"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Choice: " opt
        case "$opt" in
            1) cmd_list_accounts ;;
            2) cmd_create_account ;;
            3) cmd_set_password ;;
            4) cmd_set_gm ;;
            0) return ;;
        esac
    done
}

cmd_list_accounts() {
    _ensure_database || { read -rp "  Press Enter..."; return; }
    clear
    section "Accounts"
    #echo "   ID   Username              Email                         Last Login"
    echo "   ─────────────────────────────────────────────────────────────────"
    podman exec "$CTR_DATABASE" \
        mysql $DB_CREDS --database=legion_auth \
        --table \
        -e "SELECT id, username, email, last_login FROM account ORDER BY id LIMIT 50;" \
        2>/dev/null | sed 's/^/   /'
    echo ""
    read -rp "  Press Enter..."
}

cmd_create_account() {
    _ensure_database || { read -rp "  Press Enter..."; return; }
    clear
    section "Create Account"

    # ── SHA-256 helper (mirrors Extensions.cs sha256_hash) ──────────────────
    # sha256_hex <string>  → lowercase hex digest
    _sha256_hex() {
        if command -v openssl &>/dev/null; then
            printf '%s' "$1" | openssl dgst -sha256 -hex | awk '{print $NF}'
        elif command -v sha256sum &>/dev/null; then
            printf '%s' "$1" | sha256sum | awk '{print $1}'
        else
            echo "  ❌ Neither openssl nor sha256sum found." >&2
            return 1
        fi
    }

    # reverse_hex_pairs <hex>  → hex string with every byte-pair reversed
    # e.g. "aabbcc" → "ccbbaa"  (mirrors the C# reverse loop with i+=2)
    _reverse_hex_pairs() {
        local hex="$1" reversed="" len="${#1}"
        for (( i=len-2; i>=0; i-=2 )); do
            reversed+="${hex:$i:2}"
        done
        echo "$reversed"
    }

    # ── Account creation loop (mirrors AddAccount while loop in C#) ──────────
    while true; do
        echo ""
        read -rp  "  BattleNet Email (login): " raw_email
        [ -z "$raw_email" ] && return

        read -rsp "  Password:                " raw_pass; echo ""
        if [ -z "$raw_pass" ]; then
            echo "  ⚠️  Login or password was empty. Please try again."
            continue
        fi

        # Uppercase both — mirrors .ToUpper() throughout the C# code
        local login_name="${raw_email^^}"
        local pass_upper="${raw_pass^^}"

        # Duplicate check — mirrors:
        #   SELECT IFNULL((SELECT email FROM battlenet_accounts WHERE email='{loginName}'),"-1")
        local existing
        existing=$(podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS --silent --skip-column-names \
            --database=legion_auth \
            -e "SELECT IFNULL((SELECT \`email\` FROM \`battlenet_accounts\` WHERE \`email\`='${login_name}'),'-1');" \
            2>/dev/null)

        if [ "$existing" != "-1" ]; then
            echo "  ⚠️  BattleNet login \"${login_name}\" already exists. Please try again."
            continue
        fi

        # ── Build the password hash (exact port of the C# two-pass SHA-256) ──
        #   step1 = SHA256(UPPER(email))           → lowercase hex → uppercased
        #   step2 = SHA256(step1 + ":" + UPPER(pass))  with reverse=true
        #   final = UPPER(reversed_step2)
        local step1 step1_upper step2_raw step2_rev pass_hash
        step1=$(_sha256_hex "$login_name")          || { read -rp "  Press Enter..."; return 1; }
        step1_upper="${step1^^}"
        step2_raw=$(_sha256_hex "${step1_upper}:${pass_upper}")
        step2_rev=$(_reverse_hex_pairs "$step2_raw")
        pass_hash="${step2_rev^^}"

        # ── INSERT 1: battlenet_accounts (must come first to get its auto-ID) ─
        #   INSERT INTO `legion_auth`.`battlenet_accounts`
        #     (`email`,`sha_pass_hash`) VALUES ('{loginName}','{passHash}')
        podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS --silent \
            --database=legion_auth \
            -e "INSERT INTO \`battlenet_accounts\` (\`email\`,\`sha_pass_hash\`) VALUES ('${login_name}','${pass_hash}');" \
            2>/dev/null

        # ── Retrieve the new battlenet ID ─────────────────────────────────────
        #   SELECT `id` FROM `legion_auth`.`battlenet_accounts` WHERE `email`='{loginName}'
        local bnet_id
        bnet_id=$(podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS --silent --skip-column-names \
            --database=legion_auth \
            -e "SELECT \`id\` FROM \`battlenet_accounts\` WHERE \`email\`='${login_name}';" \
            2>/dev/null)

        if [ -z "$bnet_id" ]; then
            echo "  ❌ Failed to retrieve new battlenet_accounts ID. Aborting."
            read -rp "  Press Enter..."; return 1
        fi

        # ── INSERT 2: account, linked to the battlenet row ────────────────────
        #   INSERT INTO `legion_auth`.`account`
        #     (`username`,`email`,`battlenet_account`)
        #     VALUES ('{loginName}','{loginName}','{battlenetID}')
        podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS --silent \
            --database=legion_auth \
            -e "INSERT INTO \`account\` (\`username\`,\`email\`,\`battlenet_account\`) VALUES ('${login_name}','${login_name}','${bnet_id}');" \
            2>/dev/null

        local acct_id
        acct_id=$(podman exec "$CTR_DATABASE" \
            mysql $DB_CREDS --silent --skip-column-names \
            --database=legion_auth \
            -e "SELECT \`id\` FROM \`account\` WHERE \`username\`='${login_name}' ORDER BY \`id\` DESC LIMIT 1;" \
            2>/dev/null)

        echo ""
        echo "  ✅ Account created successfully!"
        echo "     Email (login)  : ${login_name}"
        echo "     account.id     : ${acct_id}"
        echo "     battlenet_id   : ${bnet_id}"
        break
    done

    echo ""
    read -rp "  Press Enter..."
}

cmd_set_password() {
    clear
    section "Set Password"
    read -rp "  Username: " username
    [ -z "$username" ] && return
    read -rsp "  New password: " password; echo ""
    [ -z "$password" ] && return

    if ctr_running "$CTR_WORLD"; then
        podman exec "$CTR_WORLD" \
            bash -c "echo 'account set password $username $password $password' > /tmp/worldserver-stdin" \
            2>/dev/null
        echo "  ✅ Password change command sent."
    else
        local sha_pass
        sha_pass=$(echo -n "${username^^}:${password^^}" | sha1sum | awk '{print toupper($1)}')
        db_query_db "legion_auth" \
            "UPDATE account SET sha_pass_hash='$sha_pass' WHERE username='${username^^}';"
        echo "  ✅ Password updated."
    fi
    echo ""
    read -rp "  Press Enter..."
}

cmd_set_gm() {
    clear
    section "Set GM Level"
    echo "   Levels: 0=Player  1=Moderator  2=GameMaster  3=Administrator"
    echo ""
    read -rp "  Username: " username
    [ -z "$username" ] && return
    read -rp "  GM Level (0-3): " level

    if ctr_running "$CTR_WORLD"; then
        podman exec "$CTR_WORLD" \
            bash -c "echo 'account set gmlevel $username $level -1' > /tmp/worldserver-stdin" \
            2>/dev/null
        echo "  ✅ GM level command sent."
    else
        db_query_db "legion_auth" \
            "UPDATE account SET gmlevel=$level WHERE username='${username^^}';"
        echo "  ✅ GM level updated."
    fi
    echo ""
    read -rp "  Press Enter..."
}

# ────────────────────────────────────────────────────────────
# SAVES MANAGER  (bat: saves_manager)
# Saves legion_auth + legion_characters to SPP_HOST_PATH/Saves/N/
# ────────────────────────────────────────────────────────────
cmd_saves() {
    while true; do
        mkdir -p "$(get_saves_dir)"
        clear
        section "Saves Manager"
        local i
        for i in 1 2 3 4 5 6 7 8 9; do
            local slotname="Empty slot"
            [ -f "$(get_saves_dir)/$i/name.txt" ] && slotname=$(cat "$(get_saves_dir)/$i/name.txt")
            printf "   %d - [%s]\n" "$i" "$slotname"
        done
        echo ""
        echo "   ──────────────────────────────────"
        echo "   s - Save    l - Load    d - Delete"
        echo ""
        echo "   0 - Back"
        echo ""
        read -rp "  Choice (s/l/d/0): " action
        [ "$action" = "0" ] && return

        read -rp "  Slot (1-9): " slot
        [[ ! "$slot" =~ ^[1-9]$ ]] && continue

        case "$action" in
            s|S) cmd_save_export "$slot" ;;
            l|L) cmd_save_import "$slot" ;;
            d|D) cmd_save_delete "$slot" ;;
        esac
    done
}

# ── Temporary database helper ───────────────────────────────
# Starts spp-database alone (no bnet/world) if it isn't running,
# runs a callback function, then shuts it down if WE started it.
# Usage: _with_db <callback_function> [args...]
_with_db() {
    local callback="$1"; shift
    local we_started=false

    _ensure_database || { read -rp "  Press Enter..."; return 1; }



    # Run the actual operation
    "$callback" "$@"
    local result=$?

    # Shut down if we started it
    if [ "$we_started" = true ]; then
        echo ""
        echo "  🛑 Shutting down temporary database instance..."
        podman stop   "$CTR_DATABASE" 2>/dev/null || true
        podman rm     "$CTR_DATABASE" 2>/dev/null || true
        echo "  ✅ Temporary database stopped."
    fi

    return $result
}

# ── Internal export (called inside _with_db) ────────────────
_do_export() {
    local slot="$1"
    local savename="$2"
    local slotdir="$(get_saves_dir)/$slot"

    echo "  💾 Creating save #$slot '$savename'..."
    echo ""
    echo "  Exporting legion_auth..."
    podman exec "$CTR_DATABASE" \
        mysqldump \
        --socket=/run/mysqld/mysqld.sock \
        --user=spp_user --password=123456 \
        --default-character-set=utf8mb4 \
        --single-transaction \
        --skip-lock-tables \
        --databases legion_auth \
        --add-drop-database \
        > "$slotdir/auth.sql" 2>"$slotdir/auth.err"
    if [ $? -ne 0 ] || [ ! -s "$slotdir/auth.sql" ]; then
        echo "  Export of legion_auth failed:"
        cat "$slotdir/auth.err" 2>/dev/null | sed 's/^/     /'
        read -rp "  Press Enter..."; return 1
    fi
    rm -f "$slotdir/auth.err"

    echo "  Exporting legion_characters..."
    podman exec "$CTR_DATABASE" \
        mysqldump \
        --socket=/run/mysqld/mysqld.sock \
        --user=spp_user --password=123456 \
        --default-character-set=utf8mb4 \
        --single-transaction \
        --skip-lock-tables \
        --databases legion_characters \
        --add-drop-database \
        > "$slotdir/characters.sql" 2>"$slotdir/characters.err"
    if [ $? -ne 0 ] || [ ! -s "$slotdir/characters.sql" ]; then
        echo "  Export of legion_characters failed:"
        cat "$slotdir/characters.err" 2>/dev/null | sed 's/^/     /'
        read -rp "  Press Enter..."; return 1
    fi
    rm -f "$slotdir/characters.err"


    echo ""
    echo "  ✅ Save #$slot '$savename' created successfully."
    read -rp "  Press Enter..."
}

cmd_save_export() {
    local slot="$1"
    local slotdir="$(get_saves_dir)/$slot"
    mkdir -p "$slotdir"

    if [ -f "$slotdir/auth.sql" ]; then
        read -rp "  Slot $slot has a save. Overwrite? (y/N): " c
        [[ ! "$c" =~ ^[Yy]$ ]] && return
    fi

    read -rp "  Save name (no spaces): " savename
    [ -z "$savename" ] && return
    echo "$savename" > "$slotdir/name.txt"

    _with_db _do_export "$slot" "$savename"
}

# ── Internal import (called inside _with_db) ────────────────
_do_import() {
    local slot="$1"
    local savename="$2"
    local slotdir="$(get_saves_dir)/$slot"

    echo "  📂 Loading save #$slot '$savename'..."
    echo ""
    echo "  Importing legion_auth..."
    if ! podman exec -i "$CTR_DATABASE"             mysql $DB_CREDS             --default-character-set=utf8mb4             < "$slotdir/auth.sql" 2>/dev/null; then
        echo "  ❌ Import of legion_auth failed."
        read -rp "  Press Enter..."; return 1
    fi

    echo "  Importing legion_characters..."
    if ! podman exec -i "$CTR_DATABASE"             mysql $DB_CREDS             --default-character-set=utf8mb4             < "$slotdir/characters.sql" 2>/dev/null; then
        echo "  ❌ Import of legion_characters failed."
        read -rp "  Press Enter..."; return 1
    fi

    echo ""
    echo "  ✅ Save #$slot '$savename' loaded successfully."
    read -rp "  Press Enter..."
}

cmd_save_import() {
    local slot="$1"
    local slotdir="$(get_saves_dir)/$slot"

    if [ ! -f "$slotdir/auth.sql" ]; then
        echo "  ❌ Slot $slot is empty."; read -rp "  Press Enter..."; return
    fi

    local savename="unnamed"
    [ -f "$slotdir/name.txt" ] && savename=$(cat "$slotdir/name.txt")

    echo ""
    echo "  ⚠️  This will overwrite your current databases!"
    echo "  It is recommended to stop bnet and world servers first."
    read -rp "  Load save #$slot '$savename'? (y/N): " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return

    _with_db _do_import "$slot" "$savename"
}

cmd_save_delete() {
    local slot="$1"
    local slotdir="$(get_saves_dir)/$slot"

    if [ ! -f "$slotdir/auth.sql" ]; then
        echo "  ❌ Slot $slot is empty."; read -rp "  Press Enter..."; return
    fi

    local savename="unnamed"
    [ -f "$slotdir/name.txt" ] && savename=$(cat "$slotdir/name.txt")

    read -rp "  Delete save #$slot '$savename'? (y/N): " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return

    rm -rf "$slotdir"
    mkdir -p "$slotdir"
    echo "  ✅ Save #$slot deleted."
    read -rp "  Press Enter..."
}

# ────────────────────────────────────────────────────────────
# MAIN INTERACTIVE MENU  (bat: menu / launch)
# ────────────────────────────────────────────────────────────
cmd_menu() {
    while true; do
        local db_st bnet_st world_st
        db_st=$(ctr_running "$CTR_DATABASE" && echo "🟢" || echo "🔴")
        bnet_st=$(ctr_running "$CTR_BNET"     && echo "🟢" || echo "🔴")
        world_st=$(ctr_running "$CTR_WORLD"   && echo "🟢" || echo "🔴")

        local conn_ip
        conn_ip="$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null \
            || echo "$(get_host_ip)")"

        clear
        echo ""
        echo "  ╔═══════════════════════════════════════════╗"
        echo "  ║     SPP-LegionV2 Server Manager           ║"
        echo "  ╚═══════════════════════════════════════════╝"
        echo ""
        echo "   $db_st  Database    $bnet_st  Bnet    $world_st  World"
        echo "   🌐  $conn_ip"
        echo ""
        echo "   1 - Start Server"
        echo "   2 - Server Manager"
        echo "   3 - Server Settings"
        echo "   4 - Saves Manager"
        echo "   5 - Accounts"
        echo "   6 - Update Server"
        echo ""
        echo "   0 - Stop & Exit"
        echo ""
        read -rp "  Choice: " opt
        case "$opt" in
            1) cmd_start ;;
            2) cmd_server_manager ;;
            3) cmd_server_settings ;;
            4) cmd_saves ;;
            5) cmd_accounts ;;
            6) cmd_update ;;
            0) cmd_stop; exit 0 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────
cmd_upgrade_db() {
    _ensure_database || return 1
    echo "🔧 Running mariadb-upgrade (fixes mysql.proc schema mismatch)..."
    podman exec "$CTR_DATABASE"         mariadb-upgrade         --socket=/run/mysqld/mysqld.sock         --user=spp_user --password=123456         --silent 2>/dev/null ||     podman exec "$CTR_DATABASE"         mysql_upgrade         --socket=/run/mysqld/mysqld.sock         --user=spp_user --password=123456         --silent 2>/dev/null || true

    # Remove the marker so the entrypoint re-runs it cleanly on next restart
    local marker="$(podman exec "$CTR_DATABASE"         sh -c 'echo $SPP_ROOT')/Database/data/.mariadb_upgraded"
    rm -f "$SPP_HOST_PATH/Database/data/.mariadb_upgraded" 2>/dev/null || true
    touch "$SPP_HOST_PATH/Database/data/.mariadb_upgraded" 2>/dev/null || true

    echo "✅ Upgrade complete. You can now use saves/backups."
}


# ────────────────────────────────────────────────────────────
cmd_fix_proc() {
    _ensure_database || return 1
    echo "🔧 Fixing mysql.proc column count mismatch..."
    echo ""

    # Container runs as root — connect directly via socket with no password
    local fix_sql="ALTER TABLE mysql.proc ADD COLUMN IF NOT EXISTS \`aggregate\` enum('NONE','GROUP') NOT NULL DEFAULT 'NONE' AFTER \`comment\`; FLUSH TABLES;"

    podman exec "$CTR_DATABASE" \
        bash -c "mysql --socket=/run/mysqld/mysqld.sock -u root -e \"$fix_sql\" 2>&1" \
        && echo "  ✅ mysql.proc column fixed." \
        || echo "  ⚠️  Could not fix — column may already exist or root auth is blocked."

    touch "$SPP_HOST_PATH/Database/data/.mariadb_upgraded" 2>/dev/null || true
    echo ""
    echo "✅ Done."
}


# ────────────────────────────────────────────────────────────
# SQL IMPORTER
# ────────────────────────────────────────────────────────────
cmd_sql_import() {
    local file="${1:-}"

    clear
    section "SQL Importer"

    _ensure_database || return 1

    # ── File selection ───────────────────────────────────────
    if [ -z "$file" ]; then
        echo "  Enter the full path to your .sql file."
        echo "  Tip: drag the file into this terminal to paste its path."
        echo ""
        read -rp "  SQL file path: " file
        # Strip surrounding quotes and whitespace from drag-and-drop paths
        file=$(echo "$file" | sed "s/[\x27\x22]//g" | xargs)
    fi

    if [ -z "$file" ]; then
        echo "  Cancelled."
        read -rp "  Press Enter..."; return
    fi

    if [ ! -f "$file" ]; then
        echo "  ❌ File not found: $file"
        read -rp "  Press Enter..."; return 1
    fi

    local filesize
    filesize=$(du -sh "$file" 2>/dev/null | cut -f1)
    local linecount
    linecount=$(wc -l < "$file" 2>/dev/null)

    echo ""
    echo "  File   : $file"
    echo "  Size   : $filesize  ($linecount lines)"
    echo ""

    # ── Auto-detect target database from SQL content ────────
    local dbname=""

    # Tables that belong to each database
    # legion_world  — anything game-world related
    local world_tables="creature_template|creature |gameobject|spell_|item_template|quest_|gossip_|loot_|waypoint|smart_script|npc_|spawngroup|areatrigger|conditions|phase|event_|pool_|disables|points_of_interest|trainer|vendor|access_requirement|dungeon_|instance_|vehicle|transports|game_event|fishing|skill_|exploration_|battleground_"
    # legion_auth   — accounts, realms, store, bnet
    local auth_tables="account|realmlist|battlenet|uptime|ip_banned|ip2nation|store_|transfert|realm_"
    # legion_characters — character data
    local char_tables="characters|character_|item_instance|guild|arena_|group_|mail|pet_|auction|calendar|corpse|ticket_"

    if grep -qiE "$world_tables" "$file" 2>/dev/null; then
        dbname="legion_world"
    elif grep -qiE "$auth_tables" "$file" 2>/dev/null; then
        dbname="legion_auth"
    elif grep -qiE "$char_tables" "$file" 2>/dev/null; then
        dbname="legion_characters"
    fi

    if [ -n "$dbname" ]; then
        echo "  🔍 Auto-detected database: $dbname"

        # If stdin is not a terminal (e.g. called from a loop), accept auto-detected silently
        if [ ! -t 0 ]; then
            dbchoice=""
        else
            echo ""
            echo "  Override? Leave blank to accept, or choose:"
            echo "   1 - legion_auth        (accounts, realms, store)"
            echo "   2 - legion_characters  (characters, items, quests)"
            echo "   3 - legion_world       (world data, spawns, quests)"
            echo "   4 - legion_hotfixes    (hotfix overrides)"
            echo "   5 - Other (type manually)"
            echo "   Enter - Accept auto-detected ($dbname)"
            echo ""
            read -rp "  Database [Enter=$dbname]: " dbchoice </dev/tty
        fi
    else
        echo "  Could not auto-detect database. Please choose:"
        echo ""
        echo "   1 - legion_auth        (accounts, realms, store)"
        echo "   2 - legion_characters  (characters, items, quests)"
        echo "   3 - legion_world       (world data, spawns, quests)"
        echo "   4 - legion_hotfixes    (hotfix overrides)"
        echo "   5 - Other (type manually)"
        echo ""
        echo "   0 - Cancel"
        echo ""
        read -rp "  Database: " dbchoice
    fi

    case "$dbchoice" in
        1) dbname="legion_auth" ;;
        2) dbname="legion_characters" ;;
        3) dbname="legion_world" ;;
        4) dbname="legion_hotfixes" ;;
        5)
            read -rp "  Enter database name: " dbname
            [ -z "$dbname" ] && echo "  Cancelled." && read -rp "  Press Enter..." && return
            ;;
        0) echo "  Cancelled." ; read -rp "  Press Enter..."; return ;;
        "") ;;  # Accept auto-detected — dbname already set
        *) echo "  Invalid choice." ; read -rp "  Press Enter..."; return 1 ;;
    esac

    if [ -z "$dbname" ]; then
        echo "  ❌ No database selected."
        read -rp "  Press Enter..."; return 1
    fi

    # ── Confirm ──────────────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    printf "  │  File     : %-27s│
" "$(basename "$file")"
    printf "  │  Database : %-27s│
" "$dbname"
    printf "  │  Size     : %-27s│
" "$filesize"
    echo "  └─────────────────────────────────────────┘"
    echo ""
    echo "  ⚠️  This will execute SQL directly against $dbname."
    echo "     Make sure you have a save/backup first."
    echo ""
    if [ -t 0 ]; then
        read -rp "  Run it? (y/N): " confirm </dev/tty
    else
        confirm="y"  # non-interactive: auto-confirm
    fi
    [[ ! "$confirm" =~ ^[Yy]$ ]] && echo "  Cancelled." && return

    # ── Execute ──────────────────────────────────────────────
    echo ""
    echo "  ⏳ Running $(basename "$file") against $dbname..."

    # Strip stored procedure/function blocks using a temp Python script
    # (avoids bash heredoc escaping issues)
    local import_file="$file"
    local tmpfile=""
    if grep -qiE "PROCEDURE|FUNCTION|DELIMITER" "$file" 2>/dev/null; then
        echo "  ℹ️  File contains stored procedures — stripping them..."
        tmpfile=$(mktemp /tmp/spp-sql-stripped-XXXX.sql)
        local pystrip
        pystrip=$(mktemp /tmp/spp-strip-XXXX.py)
        printf '%s\n' \
            'import sys, re' \
            'in_block = False' \
            'fin = open(sys.argv[1], "r", errors="replace")' \
            'fout = open(sys.argv[2], "w")' \
            'for line in fin:' \
            '    s = line.strip()' \
            '    if re.match("DELIMITER\\s+[^\\s;]", s, re.IGNORECASE): in_block=True; continue' \
            '    if re.match("DELIMITER\\s*;", s, re.IGNORECASE): in_block=False; continue' \
            '    if in_block: continue' \
            '    if re.match("(DROP|CREATE)\\s+(DEFINER\\s*=\\s*\\S+\\s+)?(PROCEDURE|FUNCTION)\\b", s, re.IGNORECASE): continue' \
            '    fout.write(line)' \
            'fin.close(); fout.close()' \
            > "$pystrip"
        python3 "$pystrip" "$file" "$tmpfile"
        rm -f "$pystrip"
        import_file="$tmpfile"
        echo "  ℹ️  Stripped procedure/function definitions. Proceeding with clean version."
    fi
    echo ""

    local errfile
    errfile="$(mktemp /tmp/spp-sql-import-XXXX.err)"

    # Pick credentials based on which database we're targeting
    # spp_userDB has access to legion_world and legion_hotfixes
    # spp_user has access to legion_auth and legion_characters
    local db_user db_pass
    case "$dbname" in
        legion_world|legion_hotfixes)
            db_user="spp_userDB"
            db_pass='wl0BlZ@4QB7V@Bpg'
            ;;
        *)
            db_user="spp_user"
            db_pass="123456"
            ;;
    esac

    local filesize_bytes
    filesize_bytes=$(wc -c < "$import_file" 2>/dev/null || echo 0)

    # Show line counter for large files (>100KB), plain import for small ones
    if [ "$filesize_bytes" -gt 102400 ] && [ -t 1 ]; then
        local linecount
        linecount=$(wc -l < "$import_file")
        awk -v total="$linecount" 'NR % 10000 == 0 {
            printf "\r  Lines: %d / %d (%.0f%%)", NR, total, (NR/total)*100 > "/dev/tty"
        } { print }' "$import_file" | \
            podman exec -i "$CTR_DATABASE" \
            mysql \
            --socket=/run/mysqld/mysqld.sock \
            --user="$db_user" --password="$db_pass" \
            --database="$dbname" \
            --default-character-set=utf8mb4 \
            2>"$errfile"
        printf "\r  Lines: %d / %d (100%%)\n" "$linecount" "$linecount"
    else
        podman exec -i "$CTR_DATABASE" \
            mysql \
            --socket=/run/mysqld/mysqld.sock \
            --user="$db_user" --password="$db_pass" \
            --database="$dbname" \
            --default-character-set=utf8mb4 \
            < "$import_file" 2>"$errfile"
    fi

    local rc=$?
    local errors
    errors=$(cat "$errfile" 2>/dev/null)
    rm -f "$errfile"
    [ -n "$tmpfile" ] && rm -f "$tmpfile"
    [ -n "$tmpfile" ] && rm -f "$tmpfile"

    echo ""
    if [ $rc -eq 0 ] && [ -z "$errors" ]; then
        echo "  ✅ Import completed successfully."
    elif [ $rc -eq 0 ] && [ -n "$errors" ]; then
        echo "  ✅ Import completed with warnings:"
        echo "$errors" | head -20 | sed 's/^/     /'
    else
        echo "  ❌ Import failed (exit code $rc):"
        echo "$errors" | head -30 | sed 's/^/     /'
    fi

    echo ""
    read -rp "  Press Enter..."
}


# ────────────────────────────────────────────────────────────
cmd_grant_local() {
    # Grants spp_user access via localhost socket (needed for sql-import
    # and other direct mysql calls inside the container)
    _ensure_database || return 1
    echo "🔧 Granting spp_user local socket access..."

    # We need to run this via the bootstrap trick since the user
    # granting privileges needs GRANT OPTION which root has
    local datadir="$SPP_HOST_PATH/Database/data"

    podman exec "$CTR_DATABASE"         mysqladmin --socket=/run/mysqld/mysqld.sock         --user=spp_user --password=123456 shutdown 2>/dev/null || true
    sleep 3

    podman exec -d "$CTR_DATABASE"         mysqld         --user=root         --datadir="$datadir"         --socket=/run/mysqld/mysqld.sock         --skip-networking         --skip-grant-tables         --log-warnings=0         --explicit_defaults_for_timestamp         --sql-mode=""

    for i in $(seq 1 30); do
        podman exec "$CTR_DATABASE"             mysqladmin --socket=/run/mysqld/mysqld.sock ping --silent 2>/dev/null && break
        sleep 1
    done

    podman exec "$CTR_DATABASE"         mysql --socket=/run/mysqld/mysqld.sock << 'SQL'
FLUSH PRIVILEGES;
GRANT ALL PRIVILEGES ON *.* TO 'spp_user'@'localhost'  IDENTIFIED BY '123456'            WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_user'@'%'          IDENTIFIED BY '123456'            WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_userDB'@'localhost' IDENTIFIED BY 'wl0BlZ@4QB7V@Bpg' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'spp_userDB'@'%'        IDENTIFIED BY 'wl0BlZ@4QB7V@Bpg' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost'      IDENTIFIED BY ''                  WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

    podman exec "$CTR_DATABASE"         mysqladmin --socket=/run/mysqld/mysqld.sock shutdown 2>/dev/null || true
    sleep 3

    # Restart normally
    local ini="$SPP_HOST_PATH/Database/SPP-Database.ini"
    podman exec -d "$CTR_DATABASE"         mysqld         --defaults-file="$ini"         --user=root         --datadir="$datadir"         --socket=/run/mysqld/mysqld.sock         --bind-address=0.0.0.0         --log-warnings=1         --explicit_defaults_for_timestamp         --sql-mode=""

    for i in $(seq 1 30); do
        podman exec "$CTR_DATABASE"             mysqladmin --socket=/run/mysqld/mysqld.sock             --user=spp_user --password=123456 ping --silent 2>/dev/null && break
        sleep 1
    done

    echo "✅ Local socket grants applied."
    echo "   spp_user now has access to all databases via localhost."
}


# ────────────────────────────────────────────────────────────
# SERVER UPDATER  (ported from Update.bat)
# ────────────────────────────────────────────────────────────
cmd_update() {
    clear
    section "Server Updater"

    echo "  This will download and apply the latest SPP-LegionV2 update."
    echo ""
    echo "  ⚠️  Recommended: stop all servers and take a save first."
    echo ""

    local running=false
    ctr_running "$CTR_WORLD" && running=true
    ctr_running "$CTR_BNET"  && running=true

    if [ "$running" = true ]; then
        echo "  ⚠️  Game servers are currently running."
        read -rp "  Stop them before updating? (Y/n): " stop_first
        if [[ ! "$stop_first" =~ ^[Nn]$ ]]; then
            echo "  Stopping servers..."
            _srv_stop "world"
            _srv_stop "bnet"
            echo ""
        fi
    fi

    read -rp "  Proceed with update? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && echo "  Cancelled." && read -rp "  Press Enter..." && return

    local update_dir="$SPP_HOST_PATH"
    local tmp_file="$update_dir/Update.tmp"
    local update_url="http://mdicsdildoemporium.com/dicpics/legion_update//Update.tmp"
    local update_pass="https://spp-forum.de/games/document.txt"

    echo ""
    echo "  ⏳ Downloading update..."
    echo "     From: $update_url"
    echo ""

    # Clean up any previous partial download
    rm -f "$tmp_file"

    # Download — try wget, fall back to curl
    if command -v wget &>/dev/null; then
        wget -N --no-check-certificate "$update_url" -O "$tmp_file" 2>&1 |             grep -E "saved|error|failed|%|404|200" | tail -5
    elif command -v curl &>/dev/null; then
        curl -L --insecure -o "$tmp_file" "$update_url"             --progress-bar 2>&1
    else
        echo "  ❌ Neither wget nor curl found on this system."
        read -rp "  Press Enter..."; return 1
    fi

    if [ ! -f "$tmp_file" ] || [ ! -s "$tmp_file" ]; then
        echo ""
        echo "  ❌ Download failed or file is empty."
        echo "     Check your internet connection or try again later."
        read -rp "  Press Enter..."; return 1
    fi

    local filesize
    filesize=$(du -sh "$tmp_file" | cut -f1)
    echo ""
    echo "  ✅ Downloaded ($filesize)"
    echo ""
    echo "  ⏳ Extracting update..."

    # Extract with 7z — password matches the bat exactly
    if command -v 7z &>/dev/null; then
        7z x "$tmp_file"             -p"$update_pass"             -o"$update_dir"             -aoa             2>&1 | grep -E "Extracting|Error|Everything|file" | tail -10
    elif [ -f "$update_dir/Tools/7za" ]; then
        "$update_dir/Tools/7za" x "$tmp_file"             -p"$update_pass"             -o"$update_dir"             -aoa             2>&1 | grep -E "Extracting|Error|Everything|file" | tail -10
    else
        echo "  ❌ 7z not found. Install it with: sudo rpm-ostree install p7zip"
        read -rp "  Press Enter..."; return 1
    fi

    local extract_rc=$?

    # Clean up the downloaded archive
    rm -f "$tmp_file"

    if [ $extract_rc -ne 0 ]; then
        echo ""
        echo "  ❌ Extraction failed (code $extract_rc)."
        echo "     The update file may be corrupt or the password changed."
        read -rp "  Press Enter..."; return 1
    fi

    echo ""
    echo "  ✅ Update extracted."

    # Run Website/Update.bat equivalent if it exists
    # The bat runs this as a post-update hook for web panel updates
    local web_update="$update_dir/Website/Update.bat"
    if [ -f "$web_update" ]; then
        echo ""
        echo "  Running web panel post-update hook..."
        # Execute any SQL or file operations it contains
        # (We run it via wine as a fallback since it may be Windows-only)
        pushd "$update_dir" > /dev/null
        bash "$web_update" 2>/dev/null ||             wine cmd /c "$web_update" 2>/dev/null || true
        popd > /dev/null
    fi

    # ── Apply update SQL migrations automatically ────────────
    local sql_dir="$update_dir/Servers/sql"
    if [ -d "$sql_dir" ]; then
        echo ""
        echo "  📂 Found SQL migrations in Servers/sql/ — applying now..."
        echo ""

        # Ensure database container is running for migrations
        if ! ctr_running "$CTR_DATABASE"; then
            echo "  🚀 Starting database container for migrations..."
            _ensure_pod
            _srv_start "database"
            echo "  ⏳ Waiting for MariaDB to be ready..."
            local db_retries=0
            until podman exec "$CTR_DATABASE"                     mysqladmin --socket=/run/mysqld/mysqld.sock                     --user=spp_user --password=123456 ping --silent 2>/dev/null; do
                db_retries=$((db_retries+1))
                [ "$db_retries" -ge 60 ] && echo "  ❌ Database did not start." && return 1
                printf "."; sleep 2
            done
            echo ""
            echo "  ✅ Database ready."
        fi

        # Apply in correct dependency order:
        # 1. Auth first (account structure)
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            echo "  → Auth: $(basename "$f")"
            podman exec -i "$CTR_DATABASE"                 mysql --socket=/run/mysqld/mysqld.sock                 --user=spp_userDB --password='wl0BlZ@4QB7V@Bpg'                 --database=legion_auth                 --default-character-set=utf8mb4                 < "$f" 2>&1 | grep -v "^$" | sed "s/^/     /" || true
        done < <(find "$sql_dir/auth/" -name "*.sql" 2>/dev/null | sort)

        # 2. Characters
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            echo "  → Characters: $(basename "$f")"
            podman exec -i "$CTR_DATABASE"                 mysql --socket=/run/mysqld/mysqld.sock                 --user=spp_userDB --password='wl0BlZ@4QB7V@Bpg'                 --database=legion_characters                 --default-character-set=utf8mb4                 < "$f" 2>&1 | grep -v "^$" | sed "s/^/     /" || true
        done < <(find "$sql_dir/characters/" -name "*.sql" 2>/dev/null | sort)

        # 3. World DB — route through cmd_sql_import for proc stripping + progress
        if [ -f "$sql_dir/World_DB.sql" ]; then
            local wsize; wsize=$(du -sh "$sql_dir/World_DB.sql" | cut -f1)
            echo "  → World DB ($wsize) — this may take a while..."
            cmd_sql_import "$sql_dir/World_DB.sql"
        fi

        # 4. Hotfixes — route through cmd_sql_import for proc stripping + progress
        if [ -f "$sql_dir/Hotfixes_DB.sql" ]; then
            local hsize; hsize=$(du -sh "$sql_dir/Hotfixes_DB.sql" | cut -f1)
            echo "  → Hotfixes DB ($hsize)..."
            cmd_sql_import "$sql_dir/Hotfixes_DB.sql"
        fi

        echo ""
        echo "  ✅ All SQL migrations applied."
    elif [ -f "$update_dir/Update.sql" ]; then
        echo "  Found Update.sql — applying database changes..."
        cmd_sql_import "$update_dir/Update.sql"
    fi

    echo ""
    echo "  ✅ Update complete!"
    echo ""
    echo "  Restart the stack to apply changes:"
    echo "   1 - Restart now"
    echo "   2 - Restart later"
    echo ""
    read -rp "  Choice: " restart_choice
    if [ "$restart_choice" = "1" ]; then
        cmd_stop
        echo ""
        cmd_start
    fi
}


# ────────────────────────────────────────────────────────────
# CHANGE SERVER IP
# Updates 4 locations:
#   1. bnetserver.conf → LoginREST.ExternalAddress
#   2. bnetserver.conf → LoginREST.LocalAddress
#   3. legion_auth.realmlist → address
#   4. legion_auth.realmlist → localAddress
# ────────────────────────────────────────────────────────────
cmd_change_ip() {
    clear
    section "Change Server IP"

    # Show current values
    local conf="$SPP_HOST_PATH/Servers/bnetserver.conf"
    local current_ip=""

    if [ -f "$conf" ]; then
        current_ip=$(grep -E "^LoginREST\.ExternalAddress" "$conf"             | sed 's/.*= *//' | tr -d '[:space:]')
    fi

    # Fall back to DB if conf not readable
    if [ -z "$current_ip" ] && ctr_running "$CTR_DATABASE"; then
        current_ip=$(podman exec "$CTR_DATABASE"             mysql --socket=/run/mysqld/mysqld.sock             --user=spp_user --password=123456             --database=legion_auth             --silent --skip-column-names             -e "SELECT address FROM realmlist WHERE id=1;" 2>/dev/null | tr -d '[:space:]')
    fi

    echo "  Current IP : ${current_ip:-unknown}"
    echo ""
    echo "  This will update:"
    echo "   • bnetserver.conf → LoginREST.ExternalAddress"
    echo "   • bnetserver.conf → LoginREST.LocalAddress"
    echo "   • legion_auth.realmlist → address"
    echo "   • legion_auth.realmlist → localAddress"
    echo ""

    local new_ip=""

    # ── Offer Tailscale IP if available ──────────────────
    local ts_ip=""
    if [ -n "$TS_AUTHKEY" ] && ctr_running "$CTR_TAILSCALE" 2>/dev/null; then
        ts_ip=$(podman exec "$CTR_TAILSCALE" tailscale ip -4 2>/dev/null || true)
    fi

    if [ -n "$ts_ip" ]; then
        echo "  🌐 Tailscale is active — detected IP: $ts_ip"
        echo ""
        echo "   1 - Use Tailscale IP"
        echo "   2 - Enter a custom IP"
        echo "   0 - Cancel"
        echo ""
        read -rp "  Choice: " ip_choice </dev/tty
        case "$ip_choice" in
            1) new_ip="$ts_ip" ;;
            2) ;;   # fall through to custom entry below
            0|"") echo "  Cancelled." && read -rp "  Press Enter..." && return ;;
            *) echo "  Invalid choice." && read -rp "  Press Enter..." && return 1 ;;
        esac
    fi

    # ── Custom IP entry ───────────────────────────────────
    if [ -z "$new_ip" ]; then
        echo ""
        read -rp "  New IP address (Enter to cancel): " new_ip </dev/tty
        [ -z "$new_ip" ] && echo "  Cancelled." && read -rp "  Press Enter..." && return
    fi

    # Basic IPv4 validation
    if ! echo "$new_ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        echo "  ❌ '$new_ip' does not look like a valid IPv4 address."
        read -rp "  Press Enter..."; return 1
    fi

    echo ""
    echo "  Updating to: $new_ip"
    echo ""

    # ── 1 & 2: bnetserver.conf ────────────────────────────
    if [ ! -f "$conf" ]; then
        echo "  ⚠️  bnetserver.conf not found at: $conf"
        echo "     Skipping conf update."
    else
        # Update ExternalAddress
        if grep -q "^LoginREST\.ExternalAddress" "$conf"; then
            sed -i "s|^LoginREST\.ExternalAddress.*|LoginREST.ExternalAddress = $new_ip|" "$conf"
            echo "  ✅ bnetserver.conf → LoginREST.ExternalAddress = $new_ip"
        else
            echo "LoginREST.ExternalAddress = $new_ip" >> "$conf"
            echo "  ✅ bnetserver.conf → LoginREST.ExternalAddress = $new_ip (appended)"
        fi

        # Update LocalAddress
        if grep -q "^LoginREST\.LocalAddress" "$conf"; then
            sed -i "s|^LoginREST\.LocalAddress.*|LoginREST.LocalAddress = $new_ip|" "$conf"
            echo "  ✅ bnetserver.conf → LoginREST.LocalAddress = $new_ip"
        else
            echo "LoginREST.LocalAddress = $new_ip" >> "$conf"
            echo "  ✅ bnetserver.conf → LoginREST.LocalAddress = $new_ip (appended)"
        fi
    fi

    # ── 3 & 4: realmlist table ────────────────────────────
    _ensure_database || { read -rp "  Press Enter..."; return 1; }

    podman exec "$CTR_DATABASE"         mysql --socket=/run/mysqld/mysqld.sock         --user=spp_user --password=123456         --database=legion_auth         -e "UPDATE realmlist SET address='$new_ip', localAddress='$new_ip' WHERE id=1;"         2>/dev/null

    if [ $? -eq 0 ]; then
        echo "  ✅ legion_auth.realmlist → address = $new_ip"
        echo "  ✅ legion_auth.realmlist → localAddress = $new_ip"
    else
        echo "  ❌ Database update failed."
        read -rp "  Press Enter..."; return 1
    fi

    echo ""
    echo "  ✅ All 4 settings updated to: $new_ip"
    echo ""
    echo "  Restart bnetserver to apply the conf changes:"

    if ctr_running "$CTR_BNET"; then
        read -rp "  Restart bnetserver now? (y/N): " restart_bnet </dev/tty
        if [[ "$restart_bnet" =~ ^[Yy]$ ]]; then
            echo "  Restarting bnetserver..."
            podman restart "$CTR_BNET" 2>/dev/null || true
            echo "  ✅ Bnetserver restarted."
        fi
    else
        echo "  (bnetserver is not running — changes will apply on next start)"
    fi

    echo ""
    read -rp "  Press Enter..."
}


# ────────────────────────────────────────────────────────────
# Command dispatch
# ────────────────────────────────────────────────────────────
case "${1:-menu}" in
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    restart)          cmd_stop; echo ""; cmd_start ;;
    status)           cmd_status ;;
    logs)             cmd_logs "${2:-}" ;;
    rebuild)          cmd_rebuild ;;
    set-path)         cmd_set_path "${2:-}" ;;
    set-ts-key)       cmd_set_ts_key "${2:-}" ;;
    set-ts-hostname)  cmd_set_ts_hostname "${2:-}" ;;
    ts-ip)            cmd_ts_ip ;;
    ts-login)         cmd_ts_login ;;
    set-ip)           cmd_set_ip "${2:-}" ;;
    set-iface)        cmd_set_iface "${2:-}" ;;
    fix-db)           cmd_fix_db "${2:-}" ;;
    upgrade-db)       cmd_upgrade_db ;;
    fix-proc)         cmd_fix_proc ;;
    grant-local)      cmd_grant_local ;;
    update)           cmd_update ;;
    sql-import)       cmd_sql_import "${2:-}" ;;
    menu)             cmd_menu ;;
    servers)          cmd_server_manager ;;
    settings)         cmd_server_settings ;;
    accounts)         cmd_accounts ;;
    saves)            cmd_saves ;;
    realm)            cmd_change_realmname ;;
    change-ip)        cmd_change_ip ;;
    help|--help|-h)
        echo ""
        echo "SPP-LegionV2 Server Manager"
        echo ""
        echo "── Interactive ───────────────────────────────────────"
        echo "  menu                   Full interactive launcher (default)"
        echo "  servers                Server manager submenu"
        echo "  settings               Realm name, edit conf files"
        echo "  accounts               Create/list/GM accounts"
        echo "  saves                  Save/load/delete DB snapshots (9 slots)"
        echo "  realm                  Quick realm name change
  change-ip              Change server IP (bnetserver.conf + realmlist DB)"
        echo ""
        echo "── Container Control ─────────────────────────────────"
        echo "  start                  Start all containers"
        echo "  stop                   Stop all containers"
        echo "  restart                Stop then start"
        echo "  status                 Show container status"
        echo "  logs [name]            Show/follow logs"
        echo "  rebuild                Rebuild all images from scratch"
        echo ""
        echo "── Configuration ─────────────────────────────────────"
        echo "  set-path <path>        Path to SPP server files"
        echo "  set-ts-key <key>       Tailscale pre-auth key"
        echo "  set-ts-hostname <n>    Tailscale node name"
        echo "  set-ip <IPv4>          Macvlan pod IP"
        echo "  set-iface <nic>        Host NIC for macvlan"
        echo ""
        echo "── Database ──────────────────────────────────────────"
       #echo "  fix-db [file.sql]      Create missing legion_auth tables"
       #echo "  fix-proc               Fix mysql.proc column mismatch (run if saves/backup fail)"
       #echo "  grant-local            Grant spp_user local socket access to all databases"
        echo "  update                 Download and apply latest SPP-LegionV2 server update"
        echo "  sql-import [file]      Run a custom .sql file against any SPP database"
       #echo "  upgrade-db             Run mariadb-upgrade on system tables"
        echo "  ts-ip                  Show Tailscale IP"
        echo "  ts-login               Interactive Tailscale login"
        echo ""
        echo "Current config:"
        echo "  SPP path : $SPP_HOST_PATH"
        echo "  TS key   : ${TS_AUTHKEY:+set (hidden)}${TS_AUTHKEY:-not set}"
        echo "  Mode     : $(networking_mode)"
        ;;
    *)
        echo "Unknown command: $1  —  run './spp-manage.sh help' for usage"
        exit 1
        ;;
esac
