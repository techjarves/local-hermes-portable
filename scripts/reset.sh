#!/bin/sh
# reset.sh - Resets the portable environment for Windows, Linux, and Mac
# Keeps only the models/ directory at the root intact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
LLAMA_ROOT="$PROJECT_ROOT/llama"

echo "=== Resets llama-ai portable setup ==="
echo "Keeping models/ directory..."

for dir in windows linux mac kv-cache; do
    if [ -d "$LLAMA_ROOT/$dir" ]; then
        echo "Removing llama/$dir/ directory..."
        rm -rf "$LLAMA_ROOT/$dir"
    fi
done

echo "Reset complete."
