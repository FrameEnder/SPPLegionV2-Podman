#!/usr/bin/env bash
# ============================================================
# spp-tailscale entrypoint
#
# First run:  tailscaled starts, then 'tailscale up' prints an
#             auth URL — check logs to get it and log in once.
# After that: state is saved in /var/lib/tailscale (persisted
#             via volume mount) so no re-auth needed on restart.
#
# Auth options (set via environment variables):
#   TS_AUTHKEY   — pre-auth key from tailscale.com/settings/keys
#                  (recommended — no interactive login needed)
#   TS_HOSTNAME  — name this node appears as in Tailscale admin
#                  (default: spp-server)
# ============================================================

TS_HOSTNAME="${TS_HOSTNAME:-spp-server}"
TS_STATE_DIR="/var/lib/tailscale"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

mkdir -p "$TS_STATE_DIR" /var/run/tailscale

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   SPP Tailscale Sidecar                  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "[TS] Hostname : $TS_HOSTNAME"
echo "[TS] State dir: $TS_STATE_DIR"
echo ""

# Start tailscaled daemon in background
tailscaled \
    --state="$TS_STATE_DIR/tailscaled.state" \
    --socket="$TS_SOCKET" \
    --tun=userspace-networking \
    &
DAEMON_PID=$!

# Wait for the socket to be ready
echo "[TS] Waiting for tailscaled to start..."
for i in $(seq 1 30); do
    [ -S "$TS_SOCKET" ] && break
    sleep 1
done

if [ ! -S "$TS_SOCKET" ]; then
    echo "[TS] ERROR: tailscaled did not start in time."
    exit 1
fi

echo "[TS] tailscaled is running."
echo ""

# Build the 'tailscale up' arguments
UP_ARGS=(
    --hostname="$TS_HOSTNAME"
    --accept-routes
    --accept-dns=false   # don't override container DNS
)

# Use pre-auth key if provided — no browser needed
if [ -n "$TS_AUTHKEY" ]; then
    echo "[TS] Authenticating with pre-auth key..."
    UP_ARGS+=(--authkey="$TS_AUTHKEY")
fi

tailscale up "${UP_ARGS[@]}"

# Print the Tailscale IP so it's visible in the logs
TS_IP="$(tailscale ip -4 2>/dev/null || echo 'pending...')"
echo ""
echo "[TS] ✅ Connected to Tailscale!"
echo "[TS] Pod Tailscale IP: $TS_IP"
echo ""
echo "[TS] Set your WoW realmlist to this IP:"
echo "     set realmlist $TS_IP"
echo ""
echo "[TS] Use this IP in bnetserver.conf and worldserver.conf"
echo "     for any fields that require the server's own address."
echo ""

# Keep the container alive by waiting on the daemon
wait "$DAEMON_PID"
