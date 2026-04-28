#!/usr/bin/env bash
# ============================================================
# spp-world entrypoint — worldserver.exe via Wine
#
# TrinityCore worldserver detects whether it has an interactive
# terminal. If stdin is not a TTY it prints "Halting process..."
# and exits cleanly (code 0). The fix: create a named pipe (FIFO)
# and feed it to worldserver as stdin — this keeps the process
# alive indefinitely. The FIFO writer (tail -f /dev/null) never
# closes, so worldserver never sees EOF and never halts.
#
# To send console commands to a running worldserver:
#   podman exec -it spp-world bash
#   echo "server info" > /tmp/worldserver-stdin
# ============================================================

MAINFOLDER="${SPP_ROOT:-/opt/spp/server}"
SERVERS_DIR="$MAINFOLDER/Servers"
STDIN_FIFO="/tmp/worldserver-stdin"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   SPP-Legion V2  Worldserver  (Wine)     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "[WORLD] SPP root    : $MAINFOLDER"
echo "[WORLD] Servers dir : $SERVERS_DIR"
echo ""

if [ ! -d "$SERVERS_DIR" ]; then
    echo "[ERROR] Servers directory not found: $SERVERS_DIR"
    echo "        Check your SPP_HOST_PATH mount."
    exit 1
fi

if [ ! -f "$SERVERS_DIR/worldserver.exe" ]; then
    echo "[ERROR] worldserver.exe not found at: $SERVERS_DIR/worldserver.exe"
    echo "        Files present in Servers/:"
    ls "$SERVERS_DIR" 2>/dev/null || echo "  (directory is empty or unreadable)"
    exit 1
fi

if [ ! -f "$SERVERS_DIR/worldserver.conf" ]; then
    echo "[WARN]  worldserver.conf not found in $SERVERS_DIR"
    echo "        worldserver.exe will likely exit immediately."
fi

# ── Create the stdin FIFO ──────────────────────────────────
# This keeps worldserver's stdin open forever so it doesn't
# detect a closed terminal and halt itself.
rm -f "$STDIN_FIFO"
mkfifo "$STDIN_FIFO"

# Keep the write-end of the FIFO open in the background.
# Without this, the first read by worldserver would get EOF.
tail -f /dev/null > "$STDIN_FIFO" &
TAIL_PID=$!

# Cleanup on exit
cleanup() {
    kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$STDIN_FIFO"
}
trap cleanup EXIT

echo "[WORLD] Launching worldserver.exe via Wine..."
echo "        (World load takes ~40 seconds — this is normal)"
echo ""
echo "[WORLD] To send console commands while running:"
echo "        podman exec spp-world bash -c 'echo \"server info\" > /tmp/worldserver-stdin'"
echo ""

cd "$SERVERS_DIR"

# Feed the FIFO as stdin so worldserver thinks it has a console
WINEDEBUG="err+all,fixme-all" wine worldserver.exe < "$STDIN_FIFO"
EXIT_CODE=$?

echo ""
echo "[WORLD] worldserver.exe exited with code: $EXIT_CODE"
if [ $EXIT_CODE -ne 0 ]; then
    echo "[WORLD] Check above for 'err:' lines from Wine."
fi

exit $EXIT_CODE
