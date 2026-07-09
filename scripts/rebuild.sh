#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# =============================================================================
# Rebuild Script - Downloads ROCm SDK + Builds llama.cpp
# =============================================================================
# Handles full setup from a fresh checkout:
#   Linux + AMD:  Vulkan (default) or ROCm/HIP - downloads ROCm SDK
#   macOS (Apple Silicon): Metal backend - uses Xcode toolchain
#
# Usage:
#   ./scripts/rebuild.sh             # Default backend for this platform
#   ./scripts/rebuild.sh --rebuild   # Full rebuild (wipe deps/, re-download SDK)
#   ./scripts/rebuild.sh --rocm      # Build ROCm backend only (Linux)
#   ./scripts/rebuild.sh --vulkan    # Build Vulkan backend only (Linux)
#   ./scripts/rebuild.sh --metal     # Build Metal backend (macOS)
#   ./scripts/rebuild.sh --both      # Build both ROCm and Vulkan (Linux)
#   ./scripts/rebuild.sh --help      # Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_DIR="$PROJECT_ROOT/llama/CachyLLama"
DEPS_DIR="$PROJECT_ROOT/deps"

# AMD nightly tarball base URL
ROCM_NIGHTLY_URL="https://rocm.nightlies.amd.com/tarball"

# Default ROCm version (latest available as of 2026-05-03)
ROCM_VERSION="${ROCM_VERSION:-7.14.0a20260612}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }
log_ok()   { printf '%b[OK]%b   %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
log_error(){ printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Build llama.cpp with the appropriate backend for the host platform.
  - Linux + AMD: downloads ROCm SDK, builds ROCm and/or Vulkan
  - macOS (Apple Silicon): builds Metal backend

OPTIONS:
    --rocm          Build ROCm/HIP backend only (Linux + AMD)
    --vulkan        Build Vulkan backend only (Linux + AMD)
    --metal         Build Metal backend (macOS)
    --both          Build both ROCm and Vulkan (Linux, default)
    --rebuild       Full rebuild (wipe deps/, re-download SDK)
    --clean         Clean build directories only (keep deps)
    -h, --help      Show this help

ENVIRONMENT:
    ROCM_VERSION    ROCm SDK version to download (default: $ROCM_VERSION)

EXAMPLES:
    $(basename "$0")                    # Build default backend for this platform
    $(basename "$0") --rebuild          # Full rebuild from scratch
    $(basename "$0") --rocm             # Build ROCm only (Linux)
    $(basename "$0") --vulkan           # Build Vulkan only (Linux)
    $(basename "$0") --metal            # Build Metal (macOS)

EOF
    exit 0
}

# =============================================================================
# Parse arguments and set platform-appropriate defaults
# =============================================================================

# Platform defaults: macOS -> Metal only; Linux -> Vulkan only.
case "$(uname -s)" in
    Darwin)
        BUILD_ROCM=false
        BUILD_VULKAN=false
        BUILD_METAL=true
        ;;
    *)
        BUILD_ROCM=false
        BUILD_VULKAN=true
        BUILD_METAL=false
        ;;
esac

CLEAN=false
REBUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rocm)
            BUILD_VULKAN=false
            BUILD_METAL=false
            BUILD_ROCM=true
            shift
            ;;
        --vulkan)
            BUILD_ROCM=false
            BUILD_METAL=false
            BUILD_VULKAN=true
            shift
            ;;
        --metal)
            BUILD_ROCM=false
            BUILD_VULKAN=false
            BUILD_METAL=true
            shift
            ;;
        --both)
            BUILD_ROCM=true
            BUILD_VULKAN=true
            BUILD_METAL=false
            shift
            ;;
        --rebuild)
            REBUILD=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Prerequisite checks
# =============================================================================

check_prereqs() {
    local missing=()

    # --- Build tools ---
    # cmake: can be system-installed, pip-installed, or bundled with ROCm LLVM
    local has_cmake=false
    for cmake_bin in cmake "$HOME/.local/bin/cmake" "$PROJECT_ROOT/deps/lib/llvm/bin/cmake"; do
        if command -v "$cmake_bin" &>/dev/null; then
            has_cmake=true
            break
        fi
    done
    if [[ "$has_cmake" == false ]]; then
        missing+=("cmake")
    fi

    # make: required by cmake's Makefile generator (Linux only)
    # macOS uses ninja or the default Xcode generator; ninja is checked later
    if [[ "$(uname -s)" != "Darwin" ]]; then
        if ! command -v make &>/dev/null; then
            missing+=("make")
        fi
    fi

    # curl, git: used for downloading and submodule management
    for tool in curl git; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    # --- C/C++ compiler ---
    # Priority: ROCm bundled clang > system clang > system gcc (Linux)
    # On macOS, prefer Apple's clang (from Xcode Command Line Tools)
    local has_compiler=false
    for compiler in clang++ g++; do
        if command -v "$compiler" &>/dev/null; then
            has_compiler=true
            break
        fi
    done
    if [[ "$has_compiler" == false ]]; then
        missing+=("clang++ or g++ (C++ compiler)")
    fi

    # --- GCC runtime libraries (Linux ROCm builds) ---
    # The ROCm SDK's bundled clang links against system libgcc/libstdc++.
    # On minimal distros (SteamOS, etc.) GCC may not be installed.
    if [[ "$(uname -s)" != "Darwin" ]]; then
        if ! command -v gcc &>/dev/null; then
            # Check if libgcc is available (some distros ship libgcc_s without gcc)
            if ! ldconfig -p 2>/dev/null | grep -q libgcc; then
                missing+=("gcc (provides libgcc/libstdc++ needed by ROCm clang linker)")
            fi
        fi
    fi

   # --- Vulkan-specific ---
    if [[ "$BUILD_VULKAN" == true ]]; then
        # Vulkan shader compilation needs glslc or glslangValidator
        if ! command -v glslc &>/dev/null && ! command -v glslangValidator &>/dev/null; then
            missing+=("glslc (vulkan-shaders)")
        fi
    fi

    # --- Metal-specific (macOS) ---
    if [[ "$BUILD_METAL" == true ]]; then
        if ! command -v xcrun &>/dev/null; then
            missing+=("xcrun (Xcode Command Line Tools)")
        fi
    fi

    # Report any missing prerequisites
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo ""
            echo "Install Xcode Command Line Tools:"
            echo "  xcode-select --install"
        fi
        exit 1
    fi
}

# =============================================================================
# GPU detection
# =============================================================================

source "$SCRIPT_DIR/detect-gpu.sh"

# Show the detected platform/GPU
if [[ "$(uname -s)" == "Darwin" ]]; then
    log_info "Platform: macOS (${LLAMA_GPU_NAME:-unknown})"
    log_info "Metal acceleration enabled via Apple Silicon GPU"
else
    if [[ -z "$LLAMA_ROCM_VARIANT" ]]; then
        log_warn "GPU not in detection map. Defaulting to gfx110X."
        log_warn "Set LLAMA_ROCM_VARIANT in your environment if this is wrong."
        LLAMA_ROCM_VARIANT="gfx110X"
    fi
    log_info "GPU: ${LLAMA_GPU_NAME:-unknown} ($LLAMA_GPU_PCI_ID)"
    log_info "GFX: $LLAMA_GFX_ARCH ($LLAMA_GFX_VERSION)"
    log_info "SDK variant: $LLAMA_ROCM_VARIANT"
fi

# =============================================================================
# Download ROCm SDK (Linux only)
# =============================================================================

download_rocm() {
    if [[ "$BUILD_ROCM" != true ]]; then
        return 0
    fi

    # Check if already extracted
    if [[ -f "$DEPS_DIR/lib/libamdhip64.so" ]] && [[ "$REBUILD" != true ]]; then
        log_ok "ROCm SDK already installed at $DEPS_DIR"
        return 0
    fi

    # Full rebuild: wipe deps
    if [[ "$REBUILD" == true ]] && [[ -d "$DEPS_DIR" ]]; then
        log_info "Removing existing deps for full rebuild..."
        rm -rf "$DEPS_DIR"
    fi

    # Tarball naming: gfx900 uses plain name, others use -all- suffix
    # gfx115* and gfx9* tarballs: no suffix (native architecture)
    # gfx110X, gfx120X and other combined variants: -all- suffix
    local tarball_suffix="-all-"
    case "$LLAMA_ROCM_VARIANT" in
        gfx900|gfx906|gfx908|gfx90a)
            # Native architecture tarballs don't use -all- suffix
            tarball_suffix="-"
            ;;
    esac
    local tarball="therock-dist-linux-${LLAMA_ROCM_VARIANT}${tarball_suffix}${ROCM_VERSION}.tar.gz"
    local tarball_url="${ROCM_NIGHTLY_URL}/${tarball}"

    mkdir -p "$DEPS_DIR"
    cd "$DEPS_DIR"

    # Check for existing tarball
    if [[ -f "$tarball" ]]; then
        log_ok "Using existing tarball: $tarball"
    else
       log_info "Downloading ROCm SDK: $tarball"
        log_info "URL: $tarball_url (3-4 GB, this may take several minutes...)"
        if ! curl -L --retry 3 -sS -o "$tarball" "$tarball_url"; then
            log_error "Failed to download ROCm SDK"
            log_error "Tarball URL: $tarball_url"
            exit 1
        fi
    fi

    # Extract
    log_info "Extracting ROCm SDK..."
    tar -xzf "$tarball"

    # The tarball extracts to a directory named after itself (minus .tar.gz)
    local extracted_dir="${tarball%.tar.gz}"
    if [[ -d "$extracted_dir" ]] && [[ ! -d "$DEPS_DIR/lib" ]]; then
        # Move contents from versioned directory to deps/
        mv "$extracted_dir"/* "$DEPS_DIR/" 2>/dev/null || true
        rm -rf "$extracted_dir"
    elif [[ -d "$extracted_dir" ]]; then
        rm -rf "$extracted_dir"
    fi

    # Clean up tarball
    rm -f "$tarball"

    # Verify
    if [[ -f "$DEPS_DIR/lib/libamdhip64.so" ]]; then
        log_ok "ROCm SDK installed to $DEPS_DIR"
        log_info "Libraries: $(ls "$DEPS_DIR/lib/"*.so 2>/dev/null | wc -l) shared objects"
    else
        log_error "ROCm SDK extraction failed - libamdhip64.so not found"
        log_error "Check that the tarball URL is correct: $tarball_url"
        exit 1
    fi

    # Verify ROCm bundled tools are accessible
    local rocm_clang="$DEPS_DIR/lib/llvm/bin/clang"
    if [[ ! -x "$rocm_clang" ]]; then
        log_error "ROCm clang not found at $rocm_clang"
        log_error "The SDK may be incomplete or corrupted. Try --rebuild."
        exit 1
    fi
}

# =============================================================================
# Initialize submodule
# =============================================================================

init_submodule() {
    if [[ ! -f "$LLAMA_DIR/CMakeLists.txt" ]]; then
        log_info "Initializing llama.cpp submodule..."
        cd "$PROJECT_ROOT"
        git submodule update --init --recursive
    fi
}

# =============================================================================
# Patch management
# =============================================================================

apply_patches() {
    local patch_dir="$PROJECT_ROOT/patches"

    if [[ ! -d "$patch_dir" ]]; then
        return 0
    fi

    for patch_file in "$patch_dir"/*.patch; do
        [[ -f "$patch_file" ]] || continue

        local patch_name
        patch_name=$(basename "$patch_file")

        # Check if patch is already applied using git apply --check
        # If --check fails, the patch is already applied or conflicts
        if ! git -C "$LLAMA_DIR" apply --check "$patch_file" 2>/dev/null; then
            log_info "Patch already applied or not applicable: $patch_name"
            continue
        fi

        log_info "Applying patch: $patch_name"
        git -C "$LLAMA_DIR" apply "$patch_file"
        log_ok "Applied: $patch_name"
    done
}

# =============================================================================
# Build functions
# =============================================================================

build_rocm() {
    log_info "Building ROCm backend..."

    local build_dir="$PROJECT_ROOT/llama/src/cachy-llama-rocm/build"

    # Clean if requested
    [[ "$CLEAN" == true || "$REBUILD" == true ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # Apply patches to submodule
    apply_patches

    # Configure
    cd "$build_dir"

    # Use detected GFX architecture for HIP compilation target
    local hip_arch="${LLAMA_GFX_ARCH:-gfx1103}"
    log_info "HIP target architecture: $hip_arch"

    cmake "$LLAMA_DIR" \
       -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_C_COMPILER=clang \
       -DCMAKE_CXX_COMPILER=clang++ \
       -DCMAKE_HIP_COMPILER="$ROCM_PATH/lib/llvm/bin/clang++" \
      -DCMAKE_HIP_PLATFORM=amd \
      -DCMAKE_HIP_ARCHITECTURES="$hip_arch" \
       -DGGML_HIP=ON \
        -DGGML_HIPBLAS=ON \
        -DGGML_HIP_NO_VMM=OFF \
        -DGGML_VULKAN=OFF \
        -DGGML_CPU=ON \
        -DGGML_NATIVE=OFF \
        $LLAMA_CMAKE_CPU_FLAGS \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON

    # Build
    cmake --build . --config Release -j$(nproc)

    log_ok "ROCm build complete: $build_dir/bin/llama-server"
    log_info "CPU ISA level: $LLAMA_CPU_ISA"
}

build_vulkan() {
    log_info "Building Vulkan backend..."

    local build_dir="$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build"

    # Clean if requested
    [[ "$CLEAN" == true || "$REBUILD" == true ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # Apply patches to submodule
    apply_patches

    # Configure
    cd "$build_dir"
    cmake "$LLAMA_DIR" \
       -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_C_COMPILER=clang \
       -DCMAKE_CXX_COMPILER=clang++ \
      -DGGML_HIP=OFF \
       -DGGML_HIPBLAS=OFF \
        -DGGML_VULKAN=ON \
        -DGGML_CPU=ON \
        -DGGML_NATIVE=OFF \
        $LLAMA_CMAKE_CPU_FLAGS \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON \
        2>&1 | tail -5

    # Build
    cmake --build . --config Release -j$(nproc)

    log_ok "Vulkan build complete: $build_dir/bin/llama-server"
    log_info "CPU ISA level: $LLAMA_CPU_ISA"
}

build_metal() {
    log_info "Building Metal backend (macOS)..."

    local build_dir="$PROJECT_ROOT/llama/src/cachy-llama-metal/build"

    # Clean if requested
    [[ "$CLEAN" == true || "$REBUILD" == true ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # Apply patches to submodule
    apply_patches

    # Configure
    cd "$build_dir"

    # Use Apple clang. GGML_METAL defaults to ON on Apple platforms in llama.cpp,
    # so we set it explicitly to be safe.
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
        -DGGML_NATIVE=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON \
        2>&1 | tail -5

    # Build with the detected logical core count
    local jobs
    jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "$(nproc)")
    cmake --build . --config Release -j"$jobs"

    log_ok "Metal build complete: $build_dir/bin/llama-server"
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${CYAN}=== Llama.cpp Build Script ===${NC}"
echo -e "${CYAN}  Platform: $(uname -s) $(uname -m)${NC}"
echo -e "${CYAN}  GPU: ${LLAMA_GPU_NAME:-unknown} (${LLAMA_GFX_ARCH:-?})${NC}"
echo -e "${CYAN}  CPU ISA: ${LLAMA_CPU_ISA:-unknown}${NC}"
echo -e "${CYAN}  CMake CPU flags: ${LLAMA_CMAKE_CPU_FLAGS:-none}${NC}"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo -e "${CYAN}  ROCm: ${ROCM_VERSION}${NC}"
fi
echo ""

# Step 1: Initialize submodule
init_submodule

# Step 2: Download ROCm SDK (Linux ROCm builds only)
download_rocm

# Step 3: Source environment so ROCm tools (clang, etc.) are on PATH (Linux only)
if [[ "$(uname -s)" != "Darwin" ]]; then
    if [[ "$BUILD_ROCM" == true || "$BUILD_VULKAN" == true ]]; then
        if [[ "$BUILD_ROCM" == true ]]; then
            source "$PROJECT_ROOT/scripts/env.sh" rocm
        else
            # Vulkan builds still need ROCm's bundled clang/lld for compilation
            export PATH="$PROJECT_ROOT/deps/lib/llvm/bin:$PATH"
        fi
    fi
fi

# Step 4: Check prerequisites
check_prereqs

# Step 5: Build requested backends
[[ "$BUILD_ROCM" == true ]]   && build_rocm
[[ "$BUILD_VULKAN" == true ]] && build_vulkan
[[ "$BUILD_METAL" == true ]]  && build_metal

# Copy binaries to target execution folders for launchers
if [[ "$BUILD_METAL" == true ]]; then
    mkdir -p "$PROJECT_ROOT/llama/mac/bin"
    cp "$PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin/llama-server" "$PROJECT_ROOT/llama/mac/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin/llama-cli" "$PROJECT_ROOT/llama/mac/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin"/*.dylib "$PROJECT_ROOT/llama/mac/bin/" 2>/dev/null || true
fi
if [[ "$BUILD_VULKAN" == true ]]; then
    mkdir -p "$PROJECT_ROOT/llama/linux/bin"
    cp "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin/llama-server" "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin/llama-cli" "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin"/*.so "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
fi
if [[ "$BUILD_ROCM" == true ]]; then
    mkdir -p "$PROJECT_ROOT/llama/linux/bin"
    cp "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin/llama-server" "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin/llama-cli" "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
    cp "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin"/*.so "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo ""
echo "Binaries:"
[[ "$BUILD_ROCM" == true ]]   && echo "  ROCm:   $PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin/llama-server"
[[ "$BUILD_VULKAN" == true ]] && echo "  Vulkan: $PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin/llama-server"
[[ "$BUILD_METAL" == true ]]  && echo "  Metal:  $PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin/llama-server"
echo ""
echo "Next: drop a GGUF model in models/ and run ./llama-run.sh --server"
echo ""
