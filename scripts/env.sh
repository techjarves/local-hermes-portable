#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# =============================================================================
# Llama.cpp Environment Setup
# =============================================================================
# Source this file to set up the environment for llama.cpp
#   source scripts/env.sh
#   source scripts/env.sh rocm   # or: source scripts/env.sh vulkan
#
# This sets up paths for the specified backend.

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse backend argument (default: rocm)
BACKEND="${1:-rocm}"
BACKEND=$(echo "$BACKEND" | tr "[:upper:]" "[:lower:]")  # lowercase (POSIX-safe)

# Validate backend
if [[ "$BACKEND" != "rocm" && "$BACKEND" != "vulkan" && "$BACKEND" != "metal" ]]; then
    echo "ERROR: Invalid backend '$BACKEND'. Use 'rocm', 'vulkan', or 'metal'"
    return 1 2>/dev/null || exit 1
fi

# =============================================================================
# Common paths
# =============================================================================
export LLAMA_PROJECT_ROOT="$PROJECT_ROOT"

# =============================================================================
# Backend-specific setup
# =============================================================================
if [[ "$BACKEND" == "rocm" ]]; then
    export ROCM_PATH="$PROJECT_ROOT/deps"
    export HIP_PATH="$ROCM_PATH"
    export HIP_PLATFORM=amd
    export HSA_PATH="$ROCM_PATH"
    export ROCM_DIR="$ROCM_PATH"
    
    # Library paths
    export LD_LIBRARY_PATH="$ROCM_PATH/lib/llvm/lib:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/lib:${LD_LIBRARY_PATH:-}"
    
    # Enable unified memory for APUs (uses GTT/system RAM via hipMallocManaged)
    export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
    
    # Binary paths (includes ROCm's bundled clang/lld)
    export PATH="$ROCM_PATH/bin:$ROCM_PATH/lib/llvm/bin:$PATH"
    
    # Llama.cpp binary
    export LLAMA_BIN="$PROJECT_ROOT/src/cachy-llama-rocm/build/bin"
    export PATH="$LLAMA_BIN:$PATH"
    
    # Verify ROCm
    if [[ ! -d "$ROCM_PATH" ]]; then
        echo "ERROR: ROCm SDK not found at $ROCM_PATH"
        echo "Run ./scripts/rebuild.sh first"
        return 1 2>/dev/null || exit 1
    fi
    
    # Auto-detect GPU and set GFX version
    if [[ -f "$PROJECT_ROOT/scripts/detect-gpu.sh" ]]; then
        source "$PROJECT_ROOT/scripts/detect-gpu.sh"
    fi
    export HSA_OVERRIDE_GFX_VERSION="${LLAMA_GFX_VERSION:-11.0.3}"
    
    # Source ROCm environment if exists
    if [[ -f "$ROCM_PATH/etc/rocm.bashrc" ]]; then
        source "$ROCM_PATH/etc/rocm.bashrc" 2>/dev/null || true
    fi
    
    echo "ROCm environment loaded:"
    echo "  BACKEND=$BACKEND"
    echo "  ROCM_PATH=$ROCM_PATH"
    echo "  LLAMA_BIN=$LLAMA_BIN"
    echo "  HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION"
    
elif [[ "$BACKEND" == "vulkan" ]]; then
    # Vulkan doesn't need ROCm paths
    export LLAMA_BIN="$PROJECT_ROOT/src/cachy-llama-vulkan/build/bin"
    export PATH="$LLAMA_BIN:$PATH"

    # Set Vulkan backend env var
    export GGML_BACKEND=vulkan

    # Ensure LD_LIBRARY_PATH is defined (required by llama-run.sh set -u)
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

    echo "Vulkan environment loaded:"
    echo "  BACKEND=$BACKEND"
    echo "  LLAMA_BIN=$LLAMA_BIN"
    echo "  GGML_BACKEND=$GGML_BACKEND"

elif [[ "$BACKEND" == "metal" ]]; then
    # Metal uses macOS system frameworks; nothing to set besides LLAMA_BIN
    export LLAMA_BIN="$PROJECT_ROOT/src/cachy-llama-metal/build/bin"
    export PATH="$LLAMA_BIN:$PATH"

    # Metal uses unified memory automatically on Apple Silicon
    export GGML_METAL_DEVICE_DEBUG=0

    # Ensure LD_LIBRARY_PATH is defined (required by llama-run.sh set -u)
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

    echo "Metal environment loaded:"
    echo "  BACKEND=$BACKEND"
    echo "  LLAMA_BIN=$LLAMA_BIN"
    echo "  GGML_METAL_DEVICE_DEBUG=$GGML_METAL_DEVICE_DEBUG"
fi

# Alias for convenience
alias llama-server="$LLAMA_BIN/llama-server"