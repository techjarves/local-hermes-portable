#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# Build script for llama-cpp-metal (macOS / Apple Silicon / Intel Mac with Metal-capable GPU)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
LLAMA_DIR="$PROJECT_ROOT/CachyLLama"

# macOS only
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: Metal backend is macOS only. Detected: $(uname -s)" >&2
    exit 1
fi

# Need Xcode Command Line Tools (Apple clang)
if ! command -v clang++ &>/dev/null; then
    echo "ERROR: clang++ not found. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi

BLUE="\033[0;34m"
GREEN="\033[0;32m"
NC="\033[0m"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Use Apple clang. GGML_METAL defaults to ON on Apple platforms in llama.cpp,
# but we set it explicitly so the configure step is self-documenting.
cmake "$LLAMA_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DGGML_METAL=ON \
    -DGGML_METAL_NDEBUG=ON \
    -DGGML_HIP=OFF \
    -DGGML_HIPBLAS=OFF \
    -DGGML_VULKAN=OFF \
    -DGGML_CPU=ON \
    -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON

# Build with detected logical core count
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo "$(nproc)")"
cmake --build . --config Release -j"$JOBS"

log_ok "Metal build complete: $BUILD_DIR/bin/llama-server"
