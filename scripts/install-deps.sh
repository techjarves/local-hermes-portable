#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# =============================================================================
# install-deps.sh - Install all build dependencies for llama.cpp (CachyLLama)
# =============================================================================
# Idempotent: safe to re-run, only installs missing packages.
# Detects and repairs broken pip-installed cmake wrappers that shadow
# the system cmake in ~/bin/.
#
# Platform: Arch Linux and derivatives (SteamOS, JELOS, Manjaro, EndeavourOS).
# On other distros, install the equivalent packages with your package manager.
#
# Usage:
#   ./scripts/install-deps.sh            # Install everything
#   ./scripts/install-deps.sh --check    # Show what is already installed
#   ./scripts/install-deps.sh --help     # Show help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use sudo only if not already root
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { printf '%b[INFO]%b  %s\n' "$BLUE" "$NC" "$1"; }
log_ok()    { printf '%b[OK]%b    %s\n' "$GREEN" "$NC" "$1"; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Install all build dependencies for the llama.cpp (CachyLLama) fork on
Arch Linux and derivatives (SteamOS, JELOS, Manjaro, EndeavourOS).

The script is idempotent - packages that are already installed are skipped.

OPTIONS:
    --check         Report which required packages are installed and which
                    are missing. Does not install anything.
    --no-fix-pip    Skip the broken pip-cmake wrapper repair step.
    -h, --help      Show this help.

EXAMPLES:
    $(basename "$0")             # Install everything
    $(basename "$0") --check     # Just show status

NOTES:
    * The ROCm SDK is NOT installed by this script. It is downloaded
      automatically by scripts/rebuild.sh when building the ROCm backend.
    * For macOS, install Xcode Command Line Tools: xcode-select --install
    * For Debian/Ubuntu, translate the package list to apt-get equivalents.
EOF
    exit 0
}

# =============================================================================
# Argument parsing
# =============================================================================

CHECK_ONLY=false
FIX_PIP=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --no-fix-pip)
            FIX_PIP=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1
            ;;
    esac
done

# =============================================================================
# Platform detection
# =============================================================================

if ! command -v pacman &>/dev/null; then
    log_error "pacman not found. This script targets Arch-based systems."
    log_error "On other distros, install the equivalent packages manually:"
    echo ""
    echo "  Debian/Ubuntu: apt install build-essential cmake ninja-build ccache"
    echo "                 clang libomp-dev libgomp1 libssl-dev zlib1g-dev"
    echo "                 libbz2-dev liblzma-dev libcurl4-openssl-dev"
    echo "                 libvulkan-dev vulkan-tools spirv-tools spirv-headers"
    echo "                 glslc glslang-tools git curl wget"
    echo ""
    echo "  Fedora:        dnf install gcc gcc-c++ clang cmake ninja-build ccache"
    echo "                 libomp-devel openssl-devel zlib-devel bzip2-devel"
    echo "                 xz-devel libcurl-devel vulkan-loader-devel"
    echo "                 vulkan-tools glslc glslang spirv-tools spirv-headers"
    echo "                 git curl wget"
    exit 1
fi

# =============================================================================
# Package list
# =============================================================================
# Organized by purpose so a missing package is easy to identify.
# --needed skips already-installed packages so this is safe to re-run.

PACKAGES=(
    # --- Compilers ---
    # gcc:           C/C++ compiler; provides libgomp (GCC's OpenMP runtime)
    #                and libstdc++ needed by the ROCm clang linker.
    # clang:         LLVM C/C++ compiler; used for HIP/AMDGPU and Vulkan builds.
    #                ROCm ships its own bundled clang, but a system clang
    #                is needed for sanity checks and for the host C compiler.
    # openmp:        LLVM OpenMP runtime (libomp.so). Required when clang
    #                uses -fopenmp. libgomp from gcc is the OpenMP runtime
    #                used by GCC-built code.
    # gmp:          GNU Multiple Precision Arithmetic Library. GCC dependency.
    # mpfr:         Multiple Precision Floating-Point Reliable Library. GCC dependency.
    # libmpc:       Multiple Precision Complex Library. GCC dependency.
    # isl:          Integer Set Library - transitive dependency of GCC.
    #               On SteamOS, this is stripped from the base image even though
    #               gcc is in the pacman DB. GCC's cc1plus fails without it.
    gcc
    gmp
    mpfr
    libmpc
    isl
    clang
    openmp

    # --- Build system ---
    # cmake:        Build system generator (CMakeLists.txt -> Makefiles/Ninja).
    # make:         Default generator for Linux CMake builds.
    # ninja:        Fast alternative to make, recommended for parallel builds.
    # ccache:       Compiler cache; speeds up rebuilds dramatically.
    # pkgconf:      Modern pkg-config; required by cmake find_package for
    #               many libraries.
    cmake
    make
    ninja
    ccache
    pkgconf

    # --- Libraries ---
    # ccache runtime dependencies. On SteamOS these transitively-required
    # libraries are often stripped from the base image even when the
    # pacman DB says they're installed.
    libblake3
    fmt
    hiredis

    # --- Source and download tools ---
    # git:          Submodule management.
    # curl:         CLI + libcurl (HTTPS downloads, HTTP client in llama-server).
    # wget:         Fallback downloader.
    git
    curl
    wget

    # --- Compression and TLS ---
    # bzip2/zlib/xz: Compression libraries used by GGUF reader.
    # openssl:       TLS for the llama-server HTTP API.
    bzip2
    zlib
    xz
    openssl

    # --- Python ---
    # python:       Required by several llama.cpp tooling scripts
    #               (convert_hf_to_gguf.py, etc.) and used by some user
    #               helpers in the repo.
    python

    # --- Vulkan backend ---
    # vulkan-headers:    Vulkan API C headers.
    # vulkan-tools:      vulkaninfo, vkmark, etc.
    # vulkan-icd-loader: Loader for Vulkan ICDs (AMDVLK, RADV, etc.).
    # shaderc:           Provides glslc and glslangValidator (shader compile).
    # spirv-tools:       SPIR-V processing utilities.
    # spirv-headers:     SPIR-V header files - REQUIRED by cmake's find_package
    #                    during the Vulkan build, even though the include path
    #                    is only used in a few files.
    vulkan-headers
    vulkan-tools
    vulkan-icd-loader
    shaderc
    spirv-tools
    spirv-headers
)

# =============================================================================
# --check mode: show what is installed vs missing
# =============================================================================

if [[ "$CHECK_ONLY" == true ]]; then
    log_info "Checking installed packages (no changes will be made)..."
    echo ""

    missing=()
    for pkg in "${PACKAGES[@]}"; do
        if pacman -Q "$pkg" &>/dev/null; then
            ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
            printf "  ${GREEN}[installed]${NC} %-22s %s\n" "$pkg" "$ver"
        else
            printf "  ${RED}[missing]${NC}   %-22s\n" "$pkg"
            missing+=("$pkg")
        fi
    done

    echo ""
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "All required packages are installed."
    else
        log_warn "Missing ${#missing[@]} package(s): ${missing[*]}"
        echo "Run '$(basename "$0")' (without --check) to install them."
    fi

    # Tool resolution check
    echo ""
    log_info "Tool resolution (what the build will actually call):"
    for tool in gcc g++ clang clang++ cmake make ccache ninja glslc glslangValidator git curl wget pkg-config python3; do
        path=$(command -v "$tool" 2>/dev/null || echo "NOT FOUND")
        if [[ "$path" == "NOT FOUND" ]]; then
            printf "  ${RED}[missing]${NC}   %-22s -> %s\n" "$tool" "$path"
        else
            printf "  ${GREEN}[ok]${NC}       %-22s -> %s\n" "$tool" "$path"
        fi
    done

    exit 0
fi

# =============================================================================
# Install packages
# =============================================================================

echo ""
echo -e "${CYAN}=== Llama.cpp Dependency Installer ===${NC}"
echo -e "${CYAN}  Distro: $(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')${NC}"
echo -e "${CYAN}  Packages to install: ${#PACKAGES[@]}${NC}"
echo ""

# SteamOS uses an immutable root filesystem (/usr is read-only).
# Disable it before any pacman operations so files can actually be written.
readonly_was_enabled=false
if command -v steamos-readonly &>/dev/null && steamos-readonly status 2>/dev/null | grep -q enabled; then
    log_info "Disabling SteamOS read-only filesystem (needed to install packages)..."
    $SUDO steamos-readonly disable
    readonly_was_enabled=true
    # Ensure readonly is re-enabled on script exit (even on error)
    trap 'if [[ "$readonly_was_enabled" == true ]]; then
        echo -e "${BLUE}[INFO]${NC}  Re-enabling SteamOS read-only filesystem (exit trap)..."
        '"$SUDO"' steamos-readonly enable
    fi' EXIT
fi

# Sync package database
log_info "Syncing package database..."
$SUDO pacman -Sy --noconfirm 2>&1 | tail -5

# Install (--needed skips already-installed packages)
log_info "Installing packages (this may take a few minutes)..."
if $SUDO pacman -S --needed --noconfirm "${PACKAGES[@]}" 2>&1 | tail -20; then
    log_ok "Package installation complete."
else
    log_error "Package installation failed."
    exit 1
fi

# =============================================================================
# Repair packages stripped from SteamOS base image
# =============================================================================
# SteamOS ships with package database entries for build tools (gcc, clang, etc.)
# but the actual binary files are stripped from the base image to save space.
# pacman -S --needed sees the DB entry and skips them, leaving nothing on disk.
# We detect this by checking if pacman claims the package is installed but its
# expected binary does not exist, then force-reinstall without --needed.

repair_stripped_packages() {
    log_info "Checking for packages with missing binaries (SteamOS stripped)..."

    # Package -> expected binary mapping. The binary must exist for the package
    # to be considered "actually installed" rather than just in the DB.
    declare -A PKG_BINARIES=(
        [gmp]="/usr/lib/libgmp.so.10"
        [mpfr]="/usr/lib/libmpfr.so.6"
        [libmpc]="/usr/lib/libmpc.so.3"
        [isl]="/usr/lib/libisl.so.23"
        [gcc]="/usr/bin/gcc"
        [clang]="/usr/bin/clang"
        [openmp]="/usr/lib/libomp.so"
        [ccache]="/usr/bin/ccache"
        [libblake3]="/usr/lib/libblake3.so"
        [fmt]="/usr/lib/libfmt.so"
        [hiredis]="/usr/lib/libhiredis.so"
        [make]="/usr/bin/make"
       [cmake]="/usr/bin/cmake"
       [ninja]="/usr/bin/ninja"
        [clang-libs]="/usr/lib/libclang-cpp.so.20.1"
       [pkgconf]="/usr/bin/pkg-config"
        [git]="/usr/bin/git"
        [curl]="/usr/bin/curl"
        [wget]="/usr/bin/wget"
        [bzip2]="/usr/bin/bzip2"
        [zlib]="/usr/lib/libz.so"
        [xz]="/usr/bin/xz"
        [openssl]="/usr/bin/openssl"
        [python]="/usr/bin/python"
        [vulkan-headers]="/usr/include/vulkan/vulkan.h"
        [vulkan-tools]="/usr/bin/vulkaninfo"
        [vulkan-icd-loader]="/usr/lib/libvulkan.so"
        [shaderc]="/usr/bin/glslc"
        [spirv-tools]="/usr/bin/spirv-as"
        [spirv-headers]="/usr/include/spirv/unified1/spirv.h"
    )

    local repaired=0
    for pkg in "${!PKG_BINARIES[@]}"; do
        local expected="${PKG_BINARIES[$pkg]}"

        # Skip if the binary already exists
        [[ -e "$expected" ]] && continue

        # Skip if pacman doesn't even know about this package
        pacman -Q "$pkg" &>/dev/null || continue

        # Package is in the DB but its binary is missing -> SteamOS stripped it
        log_warn "Package '$pkg' is in pacman DB but $expected is missing (stripped from base image)"
        log_info "Force-reinstalling $pkg..."
        if $SUDO pacman -S --noconfirm "$pkg" 2>&1 | tail -3; then
            if [[ -e "$expected" ]]; then
                log_ok "Repaired $pkg ($expected now exists)"
                repaired=$((repaired + 1))
            else
                log_error "Reinstall of $pkg reported success but $expected still missing"
            fi
        else
            log_error "Failed to reinstall $pkg"
        fi
    done

    if [[ $repaired -gt 0 ]]; then
        log_ok "Repaired $repaired stripped package(s)"
    else
        log_ok "No stripped packages found"
    fi
}

# SteamOS can also ship binaries that exist on disk but are broken because
# their transitive library dependencies were stripped. The -e check above
# passes for these, but the binary doesn't actually run. We do a functional
# test and force-reinstall the package (pulling all deps) if it fails.
repair_broken_binaries() {
    log_info "Checking for broken binaries (binaries that exist but don't run)..."

    # Binary -> package mapping with a functional test command.
    # The test command should exit 0 if the binary works.
    declare -A BROKEN_CHECKS=(
       [ccache]="ccache --version >/dev/null 2>&1"
        [clang]="clang --version >/dev/null 2>&1"
   )

    local repaired=0
    for pkg in "${!BROKEN_CHECKS[@]}"; do
        local test_cmd="${BROKEN_CHECKS[$pkg]}"

        # If the test passes, skip
        if eval "$test_cmd" 2>/dev/null; then
            continue
        fi

        # Binary exists but is broken
        log_warn "Package '$pkg' is installed but its binary is broken (missing transitive deps)"
        log_info "Force-reinstalling $pkg (pulls all dependencies)..."
        if $SUDO pacman -S --noconfirm "$pkg" 2>&1 | tail -3; then
            if eval "$test_cmd" 2>/dev/null; then
                log_ok "Repaired $pkg"
                repaired=$((repaired + 1))
            else
                log_error "Reinstall of $pkg reported success but binary still broken"
            fi
        else
            log_error "Failed to reinstall $pkg"
        fi
    done

    if [[ $repaired -gt 0 ]]; then
        log_ok "Repaired $repaired broken binary(/ies)"
    else
        log_ok "No broken binaries found"
    fi
}

echo ""
repair_stripped_packages

echo ""
repair_broken_binaries

# Re-enable the read-only filesystem if we disabled it earlier
if [[ "$readonly_was_enabled" == true ]]; then
    log_info "Re-enabling SteamOS read-only filesystem..."
    $SUDO steamos-readonly enable
    readonly_was_enabled=false
fi

# =============================================================================
# Repair broken pip-installed cmake wrappers in ~/bin/
# =============================================================================
# The PyPI "cmake" package installs entry-point scripts (cmake, ccmake, cpack,
# ctest) into ~/.local/bin/ or ~/bin/. If the Python module gets uninstalled or
# the package is broken, these wrappers shadow the working system binaries and
# fail with "ModuleNotFoundError: No module named 'cmake'".
#
# We detect Python entry-point scripts (shebang "#!/usr/bin/python" or similar)
# and replace them with symlinks to the system binaries.

fix_pip_cmake_wrappers() {
    local home_bin="${HOME}/bin"
    local local_bin="${HOME}/.local/bin"

    for bin_dir in "$home_bin" "$local_bin"; do
        [[ -d "$bin_dir" ]] || continue
        log_info "Checking for broken pip wrappers in $bin_dir..."

        local fixed=0
        for tool in cmake ccmake cpack ctest; do
            local wrapper="$bin_dir/$tool"

            # Skip if it doesn't exist
            [[ -e "$wrapper" ]] || continue

            # Skip if it's already a symlink (already fixed)
            [[ -L "$wrapper" ]] && continue

            # Detect Python entry-point script. PyPI entry points look like:
            #   #!/usr/bin/python
            #   ...
            #   from cmake import cmake
            local first_line
            first_line=$(head -1 "$wrapper" 2>/dev/null || echo "")
            if [[ "$first_line" == "#!/usr/bin/python"* ]] || \
               [[ "$first_line" == "#!/usr/bin/env python"* ]]; then
                # Replace with symlink to system binary if available
                if [[ -x "/usr/bin/$tool" ]]; then
                    log_warn "Replacing broken pip wrapper: $wrapper"
                    mv "$wrapper" "${wrapper}.broken-pip-wrapper.bak"
                    ln -sf "/usr/bin/$tool" "$wrapper"
                    fixed=$((fixed + 1))
                else
                    log_warn "Found pip wrapper $wrapper but /usr/bin/$tool missing; leaving alone"
                fi
            fi
        done

        if [[ $fixed -gt 0 ]]; then
            log_ok "Fixed $fixed broken pip wrapper(s) in $bin_dir"
        else
            log_ok "No broken pip wrappers in $bin_dir"
        fi
    done
}

if [[ "$FIX_PIP" == true ]]; then
    echo ""
    fix_pip_cmake_wrappers
fi

# =============================================================================
# Final verification
# =============================================================================

echo ""
log_info "Verifying tool resolution..."
echo ""

ALL_OK=true
for tool in gcc g++ clang clang++ cmake make ccache ninja glslc git curl pkg-config; do
    path=$(command -v "$tool" 2>/dev/null || echo "")
    if [[ -z "$path" ]]; then
        printf "  ${RED}[FAIL]${NC} %-22s -> not found\n" "$tool"
        ALL_OK=false
    else
        printf "  ${GREEN}[OK]${NC}   %-22s -> %s\n" "$tool" "$path"
    fi
done

# Confirm OpenMP libraries are reachable
echo ""
log_info "OpenMP libraries:"
for lib in /usr/lib/libgomp.so /usr/lib/libomp.so; do
    if [[ -e "$lib" ]]; then
        printf "  ${GREEN}[OK]${NC}   %s\n" "$lib"
    else
        printf "  ${YELLOW}[skip]${NC} %s (not present)\n" "$lib"
    fi
done

echo ""
if [[ "$ALL_OK" == true ]]; then
    log_ok "All dependencies installed and verified."
    echo ""
    echo "Next steps:"
    echo "  ./scripts/rebuild.sh            # Build default backend (Vulkan on Linux)"
    echo "  ./scripts/rebuild.sh --vulkan   # Vulkan only"
    echo "  ./scripts/rebuild.sh --rocm     # ROCm only"
    echo "  ./scripts/rebuild.sh --both     # Both ROCm and Vulkan"
else
    log_error "Some tools are still missing. Check the output above."
    exit 1
fi
