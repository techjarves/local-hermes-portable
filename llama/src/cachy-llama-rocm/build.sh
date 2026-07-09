#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# Build script for cachy-llama-rocm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
LLAMA_DIR="$PROJECT_ROOT/CachyLLama"

BLUE="\033[0;34m"
GREEN="\033[0;32m"
NC="\033[0m"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
source "$PROJECT_ROOT/scripts/env.sh" rocm

# On SteamOS, system libraries may be in sf_root overlay
if [[ -d "/sf_root/rootfs" ]]; then
    sf_root_lib=""
    for d in /sf_root/rootfs/*/usr/lib; do
        if [[ -d "$d" ]]; then sf_root_lib="$d"; break; fi
    done
    if [[ -n "$sf_root_lib" ]]; then
        export LD_LIBRARY_PATH="$sf_root_lib:$LD_LIBRARY_PATH"
    fi
fi

cmake "$LLAMA_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_HIP_COMPILER="$ROCM_PATH/lib/llvm/bin/clang++" \
    -DCMAKE_HIP_PLATFORM=amd \
    -DGGML_HIP=ON \
    -DGGML_HIPBLAS=ON \
    -DGGML_VULKAN=OFF \
    -DGGML_CPU=ON \
    -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON

cmake --build . --config Release -j$(nproc)
log_ok "ROCm build complete"

