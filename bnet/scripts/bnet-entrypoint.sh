#!/usr/bin/env bash
# ============================================================
# spp-bnet entrypoint — bnetserver.exe via Wine
# Same FIFO stdin trick as worldserver to prevent "Halting process"
# ============================================================

MAINFOLDER="${SPP_ROOT:-/opt/spp/server}"
SERVERS_DIR="$MAINFOLDER/Servers"
STDIN_FIFO="/tmp/bnetserver-stdin"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   SPP-Legion V2  Bnetserver  (Wine)      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "[BNET] SPP root    : $MAINFOLDER"
echo "[BNET] Servers dir : $SERVERS_DIR"
echo ""

if [ ! -d "$SERVERS_DIR" ]; then
    echo "[ERROR] Servers directory not found: $SERVERS_DIR"
    exit 1
fi

if [ ! -f "$SERVERS_DIR/bnetserver.exe" ]; then
    echo "[ERROR] bnetserver.exe not found at: $SERVERS_DIR/bnetserver.exe"
    echo "        Files present in Servers/:"
    ls "$SERVERS_DIR" 2>/dev/null || echo "  (directory is empty or unreadable)"
    exit 1
fi

if [ ! -f "$SERVERS_DIR/bnetserver.conf" ]; then
    echo "[WARN]  bnetserver.conf not found in $SERVERS_DIR"
fi

# ── Create the stdin FIFO ──────────────────────────────────
rm -f "$STDIN_FIFO"
mkfifo "$STDIN_FIFO"

tail -f /dev/null > "$STDIN_FIFO" &
TAIL_PID=$!

cleanup() {
    kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$STDIN_FIFO"
}
trap cleanup EXIT

echo "[BNET] Launching bnetserver.exe via Wine..."
echo ""

cd "$SERVERS_DIR"

WINEDEBUG="err+all,fixme-all" wine bnetserver.exe < "$STDIN_FIFO"
EXIT_CODE=$?

echo ""
echo "[BNET] bnetserver.exe exited with code: $EXIT_CODE"
if [ $EXIT_CODE -ne 0 ]; then
    echo "[BNET] Check above for 'err:' lines from Wine."
fi

exit $EXIT_CODE
