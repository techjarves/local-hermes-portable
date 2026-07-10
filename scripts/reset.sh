#!/bin/sh
# reset.sh - Resets the portable environment for Windows, Linux, and Mac
# Keeps only the models/ directory at the root intact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
LLAMA_ROOT="$PROJECT_ROOT/llama"

echo "=== Resets llama-ai portable setup ==="
echo "Keeping models/ directory..."

for dir in windows linux mac; do
    if [ -d "$LLAMA_ROOT/$dir" ]; then
        echo "Cleaning llama/$dir/ directory..."
        rm -rf "$LLAMA_ROOT/$dir/bin" "$LLAMA_ROOT/$dir/python" "$LLAMA_ROOT/$dir/CachyLLama"
        rm -f "$LLAMA_ROOT/$dir"/*.zip "$LLAMA_ROOT/$dir"/*.tar.gz
    fi
done

if [ -d "$LLAMA_ROOT/kv-cache" ]; then
    echo "Removing llama/kv-cache/ directory..."
    rm -rf "$LLAMA_ROOT/kv-cache"
fi

if [ -d "$PROJECT_ROOT/hermes/.cache" ]; then
    echo "Cleaning hermes/.cache/ directory..."
    rm -rf "$PROJECT_ROOT/hermes/.cache"
fi

echo "Reset complete."
