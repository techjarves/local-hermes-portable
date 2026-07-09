#!/bin/bash
# ============================================================================
# Hermes Portable - Reset Script (macOS / Linux)
# ============================================================================
# Deletes downloaded runtimes and source code to trigger fresh first-run setup.
#
# Usage:
#   bash scripts/reset-unix.sh soft    # Keep data/ folder (API keys, config)
#   bash scripts/reset-unix.sh full    # Delete everything including data/
# ============================================================================

set -e

MODE="${1:-}"

# If no mode provided, ask interactively
if [ -z "$MODE" ]; then
    echo "========================================"
    echo "   Hermes Portable - Reset"
    echo "========================================"
    echo ""
    echo "Choose reset mode:"
    echo "  [1] Soft reset  - Delete runtimes + source, keep data/ (API keys, config, history)"
    echo "  [2] Full reset  - Delete everything including data/ (completely fresh start)"
    echo ""
    read -p "Enter 1 or 2: " choice
    if [ "$choice" = "2" ]; then
        MODE="full"
    else
        MODE="soft"
    fi
fi

if [ "$MODE" != "soft" ] && [ "$MODE" != "full" ]; then
    echo "Usage: $0 [soft|full]"
    echo ""
    echo "  soft  - Delete runtimes + source, keep data/ (API keys, config, history)"
    echo "  full  - Delete everything including data/ (completely fresh start)"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "========================================"
echo "   Hermes Portable - Reset ($MODE)"
echo "========================================"

# Stop any running gateway first
LOCK_FILE="$ROOT/data/auth.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "[INFO]  Stopping gateway (removing lock) ..."
    rm -f "$LOCK_FILE"
fi

# Try to kill any hermes gateway processes
pkill -f "hermes.*gateway" 2>/dev/null || true

# Collect folders to delete
FOLDERS=()

if [ -d "$ROOT/.cache/runtimes" ]; then
    FOLDERS+=("$ROOT/.cache/runtimes")
fi

if [ -d "$ROOT/src/hermes-agent" ]; then
    FOLDERS+=("$ROOT/src/hermes-agent")
fi

if [ "$MODE" = "full" ]; then
    if [ -d "$ROOT/data" ]; then
        FOLDERS+=("$ROOT/data")
    fi
    if [ -d "$ROOT/.cache" ]; then
        FOLDERS+=("$ROOT/.cache")
    fi
fi

# Show what will be deleted
echo ""
echo "The following folders will be DELETED:"
for f in "${FOLDERS[@]}"; do
    if [ -d "$f" ]; then
        SIZE=$(du -sm "$f" 2>/dev/null | cut -f1)
        echo "  - $f (${SIZE} MB)"
    fi
done

if [ "$MODE" = "soft" ]; then
    echo ""
    echo "Your data folder is PRESERVED:"
    echo "  - $ROOT/data/.env        (API keys)"
    echo "  - $ROOT/data/config.yaml  (settings)"
    echo "  - $ROOT/data/sessions/    (chat history)"
fi

echo ""
read -p "Type 'yes' to confirm deletion: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled. Nothing was deleted."
    exit 0
fi

# Perform deletion
for f in "${FOLDERS[@]}"; do
    if [ -d "$f" ]; then
        echo -n "[DEL]   $f ..."
        rm -rf "$f"
        echo " done"
    fi
done

echo ""
echo "========================================"
echo "   Reset Complete!"
echo "========================================"

if [ "$MODE" = "soft" ]; then
    echo ""
    echo "Next step: run ./launch.sh to re-download runtimes"
    echo "Your API keys and config are still saved in data/"
else
    echo ""
    echo "Next step: run ./launch.sh for a completely fresh start"
    echo "You'll need to re-run the setup wizard and re-enter API keys"
fi
