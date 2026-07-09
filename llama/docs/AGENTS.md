# AGENTS.md

Technical reference for AI agents working on this project.

## Directory structure

```
llama-ai/
├── llama-run.sh              # Main entry point — model detection, server launch
├── CachyLLama/               # Submodule — fork of ggml-org/llama.cpp
├── scripts/
│   ├── rebuild.sh            # Download ROCm SDK + build both backends
│   ├── env.sh                # Environment setup (source before ROCm tools)
│   ├── detect-gpu.sh         # GPU/APU auto-detection library
│   ├── benchmark.sh          # Performance testing
│   └── apply-ttm-kernel-params.sh  # GPU memory config (GRUB + systemd-boot)
├── src/
│   ├── cachy-llama-rocm/     # ROCm build
│   │   ├── build.sh          # Build script (references $PROJECT_ROOT/CachyLLama)
│   │   └── build/            # Build output (binaries, libs)
│   └── cachy-llama-vulkan/   # Vulkan build
│       ├── build.sh          # Build script (references $PROJECT_ROOT/CachyLLama)
│       └── build/            # Build output (binaries, libs)
├── deps/                     # ROCm SDK (downloaded, gitignored)
├── models/                   # GGUF files (gitignored)
├── kv-cache/                 # Persistent KV cache (gitignored)
├── ssd-cache/                # SSD-backed KV cache (gitignored)
├── scratch/                  # Transient working files (gitignored)
└── patches/                  # DEPRECATED - kept for historical reference only
```

## Build

```bash
# Full setup from fresh checkout (builds Vulkan backend by default)
./scripts/rebuild.sh

# Full rebuild with ROCm support (adds --rocm flag)
./scripts/rebuild.sh --rocm

# Build Vulkan only (default)
./scripts/rebuild.sh

# Build ROCm only (optional - ROCm has stability issues on RDNA3)
./scripts/rebuild.sh --rocm

# Build both backends
./scripts/rebuild.sh --rocm  # (Vulkan is always built by default)
```

Build scripts in `src/cachy-llama-rocm/build.sh` and `src/cachy-llama-vulkan/build.sh` reference `$PROJECT_ROOT/CachyLLama` for the source.

`scripts/rebuild.sh` automatically applies patches from `patches/` to the submodule before building. Patches are checked for idempotency — if already applied, they're skipped.
Note: patch application is deprecated since we now maintain CachyLLama directly.
The `patches/` directory is kept for historical reference only.

## Environment

```bash
# Required before using Vulkan tools (default)
source scripts/env.sh vulkan

# Or for ROCm (optional - ROCm has stability issues on RDNA3)
source scripts/env.sh rocm
```

Sets `ROCM_PATH`, `HIP_PATH`, `LD_LIBRARY_PATH`, `PATH`.

## GPU Detection

`scripts/detect-gpu.sh` auto-detects the AMD GPU via PCI ID and sets:
- `HSA_OVERRIDE_GFX_VERSION` (e.g. `11.0.3` for Phoenix, `11.5.1` for Strix Halo)
- `LLAMA_GFX_ARCH` (e.g. `gfx1103`, `gfx1151`)
- `LLAMA_GPU_NAME` (e.g. `Radeon 780M`, `Radeon 8060S`)
- `LLAMA_THREADS` (optimal thread count)
- `LLAMA_TOTAL_RAM_GB` / `LLAMA_APU_VRAM_GB` / `LLAMA_RECOMMENDED_GTT_GB`
- `LLAMA_HARDWARE_TIER` (`handheld` / `standard` / `halo`) - drives
  profile selection in `llama-run.sh`

User overrides via environment:
```bash
LLAMA_GFX_VERSION_OVERRIDE=11.0.3  # skip detection
LLAMA_GTT_SIZE=18                  # override GTT recommendation
```

The GPU map (`GPU_MAP` array in `detect-gpu.sh`) maps PCI device IDs to GFX versions. To add a new device, find your PCI ID with `lspci -nn | grep VGA` and add an entry.

## Code style

All scripts are bash:

- `set -euo pipefail` at top
- `$(command)` for expansion (not backticks)
- `[[ ]]` for conditionals
- `function_name()` for functions
- 4-space indent
- `SCRIPT_DIR` / `PROJECT_ROOT` for paths (never hardcode)

Logging helpers:
```bash
log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_ok()   { echo -e "\033[0;32m[OK]\033[0m   $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
```

## Key constraints

- Everything self-contained in this directory — no system ROCm
- `deps/`, `models/`, `kv-cache/`, `build/` directories are gitignored
- `CachyLLama/` is a git submodule — use `--recurse-submodules` when cloning
- **Vulkan (RADV) is the default backend** — ROCm has stability issues on RDNA3
  (GLM-4.7-Flash/DeepSeek2 MLA produces zero generation tokens on ROCm)
- **Primary target: Nimo Axis N161 (Strix Halo "max")** — AMD Ryzen AI Max+ 395,
  Radeon 8060S iGPU on RDNA3.5 / gfx1151, 128GB unified memory with 96GB
  BIOS-allocated to the APU and 32GB remaining to the OS. No GTT tuning needed —
  VRAM carveout is set in firmware and `amdgpu.vis_vramlimit` is left unset to
  preserve it.
- **Secondary: Ayaneo Flip KB** (7840U / gfx1103 / Radeon 780M, 32GB physical RAM,
  6GB VRAM carveout via `amdgpu.vis_vramlimit=6144`, 18GB GTT via
  `amdgpu.gttsize=18432`, ~26GB available to OS).
- **Tertiary: Minisforum UM580 "zaphod"** (5800H / gfx90c / 16GB RAM)

Profiles are tier-aware via `LLAMA_HARDWARE_TIER` (`handheld` / `standard` /
`halo`), set automatically by `detect-gpu.sh` from the APU's VRAM carveout
size. Override with `LLAMA_HARDWARE_TIER_OVERRIDE`.

## Patch management

The `patches/` directory is **deprecated**. We now maintain `CachyLLama` directly as a fork rather than applying patches to an upstream submodule. The git history in `CachyLLama/` is the canonical source of truth.

### Historical reference

The old patch workflow (generating incremental and consolidated patches after each commit) is no longer needed. All custom changes are committed directly to the `CachyLLama/` fork's git history.

## License

Source code: GPL-3.0-or-later (see LICENSE)
Documentation: CC-BY-NC-SA-4.0
