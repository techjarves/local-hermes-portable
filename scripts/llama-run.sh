#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# =============================================================================
# Llama.cpp Unified Runner — ROCm/HIP Optimized
# =============================================================================
# Auto-scans ./models for available GGUF files
# Supports Vulkan, ROCm/HIP, CPU backends

set -euo pipefail

# Fallback for systems lacking tac (e.g. macOS)
if ! command -v tac &>/dev/null; then
    tac() { tail -r; }
fi


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Auto-detect GPU and system resources
source "$PROJECT_ROOT/scripts/detect-gpu.sh"
THREADS="${LLAMA_THREADS:-$(nproc)}"

# =============================================================================
# Build paths - backend specific
# =============================================================================

# Platform detection (macOS needs different memory budgeting than Linux)
if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_DARWIN=true
    IS_DARWIN_ARM=false
    if [[ "$(uname -m)" == "arm64" ]]; then
        IS_DARWIN_ARM=true
    fi
else
    IS_DARWIN=false
    IS_DARWIN_ARM=false
fi

MODEL_DIR="$PROJECT_ROOT/models"

get_backend_binary() {
    local backend="$1"
    case "$backend" in
        rocm)
            echo "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build"
            ;;
        vulkan)
            echo "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build"
            ;;
        metal)
            echo "$PROJECT_ROOT/llama/src/cachy-llama-metal/build"
            ;;
        cpu)
            echo "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build"
            ;;
        auto)
            # Check which is available
            if [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin/llama-server" ]]; then
                echo "$PROJECT_ROOT/llama/src/cachy-llama-metal/build"
            elif [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin/llama-server" ]]; then
                echo "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build"
            elif [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin/llama-server" ]]; then
                echo "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build"
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# =============================================================================
# Backend detection
# =============================================================================

detect_backend() {
    if [[ "$BACKEND" != "auto" ]]; then
        return 0
    fi

    # macOS: prefer Metal (only Apple Silicon has GPU acceleration)
    if [[ "$(uname -s)" == "Darwin" ]] && [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-metal/build/bin/llama-server" ]]; then
        BACKEND="metal"
        return 0
    fi

    # Check for Vulkan first (default backend - best stability on RDNA3)
    if [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-vulkan/build/bin/llama-server" ]]; then
        BACKEND="vulkan"
        return 0
    fi

    # Check for ROCm (optional backend - known issues with some archs)
    if [[ -x "$PROJECT_ROOT/llama/src/cachy-llama-rocm/build/bin/llama-server" ]]; then
        BACKEND="rocm"
        return 0
    fi

    # Fallback
    if [[ "$(uname -s)" == "Darwin" ]]; then
        BACKEND="metal"
    else
        BACKEND="vulkan"
    fi
}

setup_backend_env() {
    if [[ -f "$PROJECT_ROOT/scripts/env.sh" ]]; then
        source "$PROJECT_ROOT/scripts/env.sh" "$BACKEND"
    fi
}

get_llama_binary() {
    local cmd="$1"  # server or cli
    if [[ "$IS_DARWIN" == true ]]; then
        if [[ -f "$PROJECT_ROOT/llama/mac/bin/llama-$cmd" ]]; then
            echo "$PROJECT_ROOT/llama/mac/bin/llama-$cmd"
            return
        fi
    else
        if [[ -f "$PROJECT_ROOT/llama/linux/bin/llama-$cmd" ]]; then
            echo "$PROJECT_ROOT/llama/linux/bin/llama-$cmd"
            return
        elif [[ -f "$PROJECT_ROOT/llama/windows/bin/llama-$cmd.exe" ]]; then
            echo "$PROJECT_ROOT/llama/windows/bin/llama-$cmd.exe"
            return
        fi
    fi
    local build_dir=$(get_backend_binary "$BACKEND")
    echo "$build_dir/bin/llama-$cmd"
}

# Returns total physical RAM in bytes (macOS / Linux compatible)
get_total_memory_bytes() {
    if [[ "$IS_DARWIN" == true ]]; then
        # hw.memsize returns bytes on macOS
        local bytes
        bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        echo "$bytes"
    else
        # /proc/meminfo on Linux
        awk '/^MemTotal:/ {printf "%d\n", $2 * 1024; exit}' /proc/meminfo 2>/dev/null || echo 0
    fi
}

# Returns roughly available memory in bytes (free + inactive on macOS,
# MemAvailable on Linux). Conservative estimate.
get_available_memory_bytes() {
    if [[ "$IS_DARWIN" == true ]]; then
        local page_size free_pages inactive_pages
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
        local vmstat_out
        vmstat_out=$(vm_stat 2>/dev/null)
        free_pages=$(echo "$vmstat_out" | awk "/Pages free/ {gsub(/\\./, \"\", \$3); print \$3}")
        inactive_pages=$(echo "$vmstat_out" | awk "/Pages inactive/ {gsub(/\\./, \"\", \$3); print \$3}")
        free_pages="${free_pages:-0}"
        inactive_pages="${inactive_pages:-0}"
        echo $(( (free_pages + inactive_pages) * page_size ))
    else
        awk '/^MemAvailable:/ {printf "%d\n", $2 * 1024; exit}' /proc/meminfo 2>/dev/null || echo 0
    fi
}

BACKEND="auto"
MODEL=""
MODEL_ALIAS=""
CTX_SIZE=65536
USER_CTX_SIZE=""  # set when user explicitly passes -c
N_PREDICT=256
GPU_LAYERS=99
KV_CACHE_TYPE_K="q8_0"
KV_CACHE_TYPE_V="q8_0"
INTERACTIVE=false
PRINT_PROFILE=false
SERVER_MODE=false
PORT=9090
HOST="0.0.0.0"
EXTRA_COMMON_ARGS=""
EXTRA_SERVER_ARGS=""
OVERRIDE_REASONING=""
OVERRIDE_FIT=""
SSD_PATH=""
SSD_HOT_WINDOW="4096"
SSD_WARM_WINDOW=""
SSD_MAX_COLD="32"
SSD_PAGE_SIZE=""
SSD_HOT_RAM=""
SSD_WARM_RAM=""
PROMPT_MAX="8"
SSD_CHECKPOINTS="64"
# System prompt KV cache defaults (cross-conversation prompt sharing)
# Override with --cache-ssd-system-prompts / --cache-ssd-system-max-days
SSD_SYSTEM_PROMPTS="8"
SSD_SYSTEM_MAX_DAYS="30"
OVERRIDE_CHECKPOINT_EVERY=""
OVERRIDE_CTX_CHECKPOINTS=""
OVERRIDE_CACHE_RAM=""
OVERRIDE_REASONING_BUDGET=""
PRESERVE_REASONING=""
OVERRIDE_N_PARALLEL=""
OVERRIDE_UBATCH_SIZE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }
log_ok()    { printf '%b[OK]%b   %s\n' "$GREEN" "$NC" "$1"; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"; }

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << USAGE
${BLUE}Llama.cpp Runner - Unified runner for Metal (macOS), Vulkan, ROCm, and CPU

${YELLOW}Usage:${NC}
    $0 [options] [model_or_file] [-- server options]
    $0 --download MODEL [--quant QUANT]

${YELLOW}Options:${NC}
    -b, --backend BACKEND    Backend: auto, rocm, vulkan, metal, cpu
    -m, --model MODEL       Model file or alias
    -a, --alias NAME        API model alias
    -t, --threads N         CPU threads (default: $THREADS)
    -c, --ctx-size N        Context size (default: $CTX_SIZE)
    -n, --n-predict N       Tokens to generate
    -ngl, --gpu-layers N    GPU layers (default: $GPU_LAYERS)
    --kv-cache-type TYPE    KV cache quantization (default: $KV_CACHE_TYPE_K)
    --interactive           Interactive chat mode
    --server                Run as API server
    --port PORT             Server port (default: $PORT)
    --fit                   Auto-fit GPU layers to available VRAM (disables -ngl)
    --host HOST             Server host (default: $HOST)
    --list-models           List available models
    --list-backends         List available backends
    --preserve-reasoning    Include reasoning/thinking in prior assistant messages
    --no-preserve-reasoning Strip reasoning from prior assistant messages (default)
    --reasoning-budget N    Max thinking tokens per response (default: 2048)
    --no-reasoning-budget   Disable thinking token limit
    -h, --help              Show this help

${YELLOW}Download Model:${NC}
    --download MODEL        Download model from Hugging Face
    --quant QUANT          Quantization (default: Q4_K_M)
    --download-help        Show download help

${YELLOW}Examples:${NC}
    $0 --server gemma-4-26B
    $0 --backend vulkan --interactive Qwen3-14B
    $0 --server -m ./models/my-model.gguf --port 9091
    $0 --download Qwen3.6-35B
    $0 --download Qwen3.6-35B --quant Q5_K_M

USAGE
    exit 0
}

# =============================================================================
# Dynamic Profile Assignment
# =============================================================================
# Profiles are auto-detected from model characteristics, not hard-coded names
# This allows any model to work with optimized settings regardless of filename

# Global profile name for logging
profile_name=""

# Auto-scale --cache-ram to available memory. Models mmap the full
# file but only resident pages matter; on macOS unified memory, the OS will
# page out model pages under pressure. Still, we want a sane upper bound
# so the server doesn't fight the OS.
# Args: $1 = desired cache-ram in MiB (from profile), echoes adjusted value
adjust_cache_ram_for_memory() {
    local desired_mib="$1"
    local model_bytes="${MODEL_BYTES:-0}"
    local avail_bytes
    avail_bytes=$(get_available_memory_bytes)
    if [[ "$avail_bytes" -le 0 ]]; then
        echo "$desired_mib"
        return
    fi
    # Reserve: 4 GB for system overhead, plus resident model footprint.
    # When all layers are GPU-offloaded (-ngl >= 99), the model lives in VRAM/GTT
    # and doesn't consume system RAM. Only subtract model_resident for CPU models.
    local reserve_bytes=$((4 * 1024 * 1024 * 1024))
    local model_resident_bytes=0
    if [[ "$model_bytes" -gt 0 ]] && [[ "${GPU_LAYERS:-0}" -lt 99 ]]; then
        local total_bytes half_total
        total_bytes=$(get_total_memory_bytes)
        half_total=$((total_bytes / 2))
        if [[ "$model_bytes" -lt "$half_total" ]]; then
            model_resident_bytes=$model_bytes
        else
            model_resident_bytes=$half_total
        fi
    fi
    local max_cache_bytes=$((avail_bytes - reserve_bytes - model_resident_bytes))
    if [[ "$max_cache_bytes" -le 0 ]]; then
        echo 0
        return
    fi
    local max_cache_mib=$((max_cache_bytes / 1024 / 1024))
    if [[ "$desired_mib" -gt "$max_cache_mib" ]]; then
        echo "$max_cache_mib"
    else
        echo "$desired_mib"
    fi
}

assign_profile() {
    local model_path="$1"
    local filename=$(basename "$model_path")
    local size_bytes=$(stat -c%s "$model_path" 2>/dev/null || stat -f%z "$model_path" 2>/dev/null || echo 0)
    MODEL_BYTES="$size_bytes"
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))

    # Hardware tier from detect-gpu.sh (handheld / standard / halo).
    local tier="${LLAMA_HARDWARE_TIER:-handheld}"

    # Reset all variables to sensible defaults
    [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=32768
    KV_CACHE_TYPE_K="q8_0"
    KV_CACHE_TYPE_V="q8_0"
    GPU_LAYERS=99
    EXTRA_COMMON_ARGS=""
    EXTRA_SERVER_ARGS=""
    OVERRIDE_REASONING=""
    OVERRIDE_BATCH_SIZE=""
    EXTRA_SERVER_ARGS+=" --no-mmproj"
    
    # Detect model characteristics from filename
    local is_moe=false
    local is_ssm=false
    local is_qwen3=false

    if echo "$filename" | grep -qiE "moe|a3b|a8b|flash|expert|gpt-oss"; then
        is_moe=true
    fi
    if echo "$filename" | grep -qiE "ssm|mamba|jamba|falcon-h1|rwkv"; then
        is_ssm=true
    fi
    # Detect Qwen 3.x models (Qwen3, Qwen3.5, Qwen3.6) for fixed template
    if echo "$filename" | grep -qiE "qwen3(\.|-)?(5|6)"; then
        is_qwen3=true
    fi
    
    # Profile selection based on characteristics
    if [[ "$is_ssm" == true ]]; then
        # SSM/Mamba models: cache_reuse doesn't work, need different settings
        # Halo pushes context much further; handheld stays at 64K.
        case "$tier" in
            halo)
                # SSM hidden state is constant-size; attention KV is a small
                # fraction of total context. 256K fits comfortably.
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=262144
                ;;
            *)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=65536
                ;;
        esac
        KV_CACHE_TYPE_K="q8_0"
        KV_CACHE_TYPE_V="q8_0"
        GPU_LAYERS=99
        OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
        EXTRA_SERVER_ARGS+=" --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00"
        # No checkpoint strategy - SSM models handle context internally
        # No reasoning format - SSM models don't support it
        # cache-ram scales with tier: handheld 6GB, halo 16GB
        local _ssm_cache_ram=6144
        [[ "$tier" == "halo" ]] && _ssm_cache_ram=16384
        EXTRA_SERVER_ARGS+=" --no-context-shift --ctx-checkpoints 0 --cache-ram ${_ssm_cache_ram}"
        OVERRIDE_REASONING="on"
        OVERRIDE_REASONING_BUDGET="2048"
        # SSM models don't support llama_state_seq_set_data_ext, so no SSD cache
        SSD_PATH=""
        # System prompt cache depends on KV serialization, also unavailable for SSM
        SSD_SYSTEM_PROMPTS=""
        SSD_SYSTEM_MAX_DAYS=""
        profile_name="ssm-optimized"
    elif [[ "$is_moe" == true ]]; then
        # MoE models: balanced batch size for GPU utilization, q8_0 KV cache saves memory
        # Single parallel slot for MoE: 2x slots doubles KV cache memory,
        # and agentic workloads use 1 slot at a time anyway
        OVERRIDE_N_PARALLEL="1"
        # Tier-aware MoE tuning. Halo has 96GB VRAM so we switch to f16 KV
        # (no compression needed), push batch+ubatch, and widen context to 128K.
        # Handheld stays at conservative ubatch 256 (compute-buffer safety).
        case "$tier" in
            halo)
                # MoE 22GB model + 192K context f16 KV ~= 70GB total.
                # Pushes close to the 96GB VRAM ceiling while staying under
                # it. 256K would overflow once cache-ram is included.
                #
                # SSD checkpoint strategy is intentionally minimal here vs.
                # the Flip KB tier. On Halo the 96GB VRAM/GTT budget holds
                # the working set comfortably; SSD writes are pure overhead
                # on the prefill critical path. Only the system prompt
                # cache (separate, 370 MiB per distinct prompt) is worth
                # the disk traffic for cross-restart speedup. Per-turn
                # checkpoints add up to 3 SSD writes (62 MiB each) for a
                # 15K-token prefill - 4s of disk time on the critical path
                # for protection we don't need when VRAM holds everything.
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=196608
                KV_CACHE_TYPE_K="f16"
                KV_CACHE_TYPE_V="f16"
                OVERRIDE_BATCH_SIZE="--batch-size 2048 --ubatch-size 512"
                # 16K checkpoint interval: 1 checkpoint for typical 8-15K
                # system prompts (instead of 2-3), 0 for short prompts.
                # --ctx-checkpoints 8 keeps the in-memory ring small enough
                # that speculative decoding doesn't churn VRAM. The system
                # prompt cache (separate mechanism) handles cross-restart
                # warm-start; per-turn checkpoints are just eviction
                # insurance for long single-conversation runs.
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 16384 --ctx-checkpoints 8 --cache-ram 16384"
                # 8 SSD checkpoints is enough for the system prompt entry
                # plus a couple per-turn safety nets. 64 (default) just
                # accumulates stale checkpoints on disk.
                SSD_CHECKPOINTS="8"
                SSD_HOT_WINDOW="8192"
                SSD_WARM_WINDOW="16384"
                SSD_HOT_RAM="4096"
                SSD_WARM_RAM="6144"
                SSD_MAX_COLD="32"
                ;;
            standard)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=65536
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 4096 --ctx-checkpoints 8 --cache-ram 8192"
                SSD_HOT_WINDOW="4096"
                SSD_WARM_WINDOW="8192"
                SSD_HOT_RAM="960"
                SSD_WARM_RAM="1440"
                SSD_MAX_COLD="32"
                ;;
            *)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=65536
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                # batch 1024 for throughput, ubatch 256 for VRAM safety on iGPUs
                # ubatch 512 causes GPU hard-lock at ~3K tokens (compute buffers exceed VRAM)
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 256"
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 4096 --ctx-checkpoints 8 --cache-ram 6144"
                SSD_HOT_WINDOW="4096"
                SSD_WARM_WINDOW="8192"
                SSD_HOT_RAM="960"
                SSD_WARM_RAM="1440"
                SSD_MAX_COLD="32"
                ;;
        esac
        EXTRA_SERVER_ARGS+=" --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00"
        # Sampling (Unsloth recommended for Qwen 3.6 thinking mode):
        # temp=1.0 + top_p=0.95 + top_k=20 + min_p=0.0 + no penalties.
        # Qwen3 was trained without repetition penalty - applying any
        # value >1.0 degrades the model and causes repetitive tool call
        # loops in agentic workloads. presence_penalty=0.0 is also required;
        # the non-thinking (instruct) mode uses 1.5 but that mode strips
        # reasoning and is not what CLIO sends.
        # https://unsloth.ai/docs/models/qwen3.6
        EXTRA_SERVER_ARGS+=" --repeat-penalty 1.0 --presence-penalty 0.0"
        EXTRA_SERVER_ARGS+=" --reasoning-format auto"
        # SSD cache enabled by global default
        OVERRIDE_REASONING="on"
        OVERRIDE_REASONING_BUDGET="2048"
        profile_name="moe-optimized"
    elif [[ $size_gb -gt 15 ]]; then
        # Tier-aware large-dense. Halo uses q8_0 KV and bigger cache since
        # 30B+ models fit comfortably with 96GB VRAM.
        case "$tier" in
            halo)
                # Dense 20GB + 128K f16 KV ~= 52GB. Leaves headroom for
                # the cache-ram and SSD cache layers.
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=131072
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                OVERRIDE_BATCH_SIZE="--batch-size 2048 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 4096 --ctx-checkpoints 8 --cache-ram 16384"
                ;;
            standard)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=32768
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 4096 --ctx-checkpoints 4 --cache-ram 8192"
                ;;
            *)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=32768
                KV_CACHE_TYPE_K="q4_0"
                KV_CACHE_TYPE_V="q4_0"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --checkpoint-min-step 4096 --ctx-checkpoints 4 --cache-ram 6144"
                ;;
        esac
        EXTRA_SERVER_ARGS+=" --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00"
        # Qwen3.6 thinking mode: see moe-optimized profile above for rationale
        EXTRA_SERVER_ARGS+=" --repeat-penalty 1.0 --presence-penalty 0.0"
        EXTRA_SERVER_ARGS+=" --reasoning-format auto"
        OVERRIDE_REASONING="on"
        OVERRIDE_REASONING_BUDGET="2048"
        profile_name="large-dense"
    elif [[ $size_gb -gt 10 ]]; then
        # Medium models (10-15GB): balanced settings
        case "$tier" in
            halo)
                # Medium models (10-15GB) leave ~80GB of VRAM free, plenty
                # for long context without compression.
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=131072
                KV_CACHE_TYPE_K="f16"
                KV_CACHE_TYPE_V="f16"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --cache-ram 16384"
                ;;
            standard)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=32768
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 512"
                EXTRA_SERVER_ARGS+=" --cache-ram 8192"
                ;;
            *)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=32768
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                OVERRIDE_BATCH_SIZE="--batch-size 1024 --ubatch-size 256"
                EXTRA_SERVER_ARGS+=" --cache-ram 4096"
                ;;
        esac
        EXTRA_SERVER_ARGS+=" --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00"
        # Qwen3.6 thinking mode: see moe-optimized profile above for rationale
        EXTRA_SERVER_ARGS+=" --repeat-penalty 1.0 --presence-penalty 0.0"
        EXTRA_SERVER_ARGS+=" --reasoning-format auto"
        OVERRIDE_REASONING="on"
        OVERRIDE_REASONING_BUDGET="2048"
        profile_name="medium-dense"
    else
        # Small models (<10GB): full power
        case "$tier" in
            halo)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=131072
                KV_CACHE_TYPE_K="f16"
                KV_CACHE_TYPE_V="f16"
                EXTRA_SERVER_ARGS+=" --cache-ram 16384 --slot-prompt-similarity 0.15"
                ;;
            *)
                [[ -z "$USER_CTX_SIZE" ]] && CTX_SIZE=65536
                KV_CACHE_TYPE_K="q8_0"
                KV_CACHE_TYPE_V="q8_0"
                EXTRA_SERVER_ARGS+=" --cache-ram 4096 --slot-prompt-similarity 0.15"
                ;;
        esac
        profile_name="small-efficient"
    fi
    
    # Adjust --cache-ram to available memory on memory-constrained systems
    # (e.g. 24 GB macOS laptops running 20+ GB MoE models)
    if [[ "${LLAMA_ADJUST_CACHE:-1}" == "1" ]]; then
        local _orig_cache_ram _new_cache_ram
        _orig_cache_ram=$(echo "$EXTRA_SERVER_ARGS" | sed -nE 's/.*--cache-ram ([0-9]+).*/\1/p')
        if [[ -n "$_orig_cache_ram" ]]; then
            _new_cache_ram=$(adjust_cache_ram_for_memory "$_orig_cache_ram")
            if [[ "$_new_cache_ram" -le 0 ]]; then
                EXTRA_SERVER_ARGS=$(echo "$EXTRA_SERVER_ARGS" | sed -E 's/ --cache-ram [0-9]+//')
                log_info "cache-ram disabled (insufficient memory headroom); SSD cache remains"
            elif [[ "$_new_cache_ram" -lt "$_orig_cache_ram" ]]; then
                EXTRA_SERVER_ARGS=$(echo "$EXTRA_SERVER_ARGS" | sed -E "s/--cache-ram [0-9]+/--cache-ram $_new_cache_ram/")
                log_info "cache-ram reduced: ${_orig_cache_ram} MiB -> ${_new_cache_ram} MiB (memory-constrained)"
            fi
        fi
    fi

    printf '%bAuto profile: %b%s%b (%sGB, MoE=%s, SSM=%s)%b\n' "$CYAN" "$GREEN" "$profile_name" "$NC" "$size_gb" "$is_moe" "$is_ssm" "$NC"
}

# =============================================================================
# Auto-discover models from ./models directory
# =============================================================================

# Lightweight model registry. Use parallel MODELS_NAME[] / MODELS_PATH[] arrays
# (macOS ships bash 3.2 which lacks associative arrays).
declare -a MODELS_NAME=()
declare -a MODELS_PATH=()

scan_models() {
    MODELS_NAME=()
    MODELS_PATH=()
    if [[ ! -d "$MODEL_DIR" ]]; then
        echo -e "${YELLOW}Warning: Models directory not found: $MODEL_DIR${NC}"
        return
    fi

    # Scan for .gguf files in top-level of models dir
    while IFS= read -r -d '' file; do
        local basename
        basename=$(basename "$file" .gguf)
        MODELS_NAME+=("$basename")
        MODELS_PATH+=("$file")
    done < <(find "$MODEL_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
}

# Initialize models from directory
scan_models

# =============================================================================
# Functions
# =============================================================================

list_models() {
    echo -e "${BLUE}Available Models:${NC}"
    echo -e "${BLUE}(auto-scanned from $MODEL_DIR)${NC}"
    echo ""
    
    local found=0
    # Sort output for consistent ordering
    local i
    for i in $(printf '%s\n' "${!MODELS_NAME[@]}" | sort -n); do
        local name="${MODELS_NAME[$i]}"
        local model="${MODELS_PATH[$i]}"
        if [[ -f "$model" ]]; then
            local size
            size=$(du -h "$model" 2>/dev/null | cut -f1)
            echo -e "  ${GREEN}$name${NC}  - $size"
            found=1
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No models found in $MODEL_DIR${NC}"
        echo -e "  ${CYAN}Place .gguf files in that directory${NC}"
    fi
    exit 0
}

list_backends() {
    # Single source of truth: list_backends_v2 covers rocm/vulkan/metal/cpu.
    list_backends_v2
}

list_backends_v2() {
    echo -e "${BLUE}Available Backends:${NC}"
    local binary_rocm="$PROJECT_ROOT/src/cachy-llama-rocm/build/bin/llama-cli"
    local binary_vulkan="$PROJECT_ROOT/src/cachy-llama-vulkan/build/bin/llama-cli"
    local binary_metal="$PROJECT_ROOT/src/cachy-llama-metal/build/bin/llama-cli"
    if [[ -x "$binary_rocm" ]]; then
        if [[ -n "$LLAMA_GPU_NAME" ]]; then
            echo -e "  ${GREEN}[*] ROCm/HIP${NC}   - $LLAMA_GPU_NAME ($LLAMA_GFX_ARCH)"
        else
            echo -e "  ${CYAN}[ ] ROCm/HIP${NC}   - installed (GPU not in detection map)"
        fi
    else
        echo -e "  ${YELLOW}[ ] ROCm/HIP${NC}   - not built"
    fi
    if [[ -x "$binary_vulkan" ]]; then
        echo -e "  ${GREEN}[*] Vulkan${NC}      - available"
    else
        echo -e "  ${YELLOW}[ ] Vulkan${NC}      - not built"
    fi
    if [[ -x "$binary_metal" ]]; then
        if [[ -n "$LLAMA_GPU_NAME" ]]; then
            echo -e "  ${GREEN}[*] Metal${NC}       - $LLAMA_GPU_NAME"
        else
            echo -e "  ${GREEN}[*] Metal${NC}       - available (Apple Silicon)"
        fi
    else
        echo -e "  ${YELLOW}[ ] Metal${NC}       - not built (macOS only)"
    fi
    echo -e "  ${GREEN}[*] CPU${NC}         - always available"
    exit 0
}

setup_performance() {
    # CPU frequency (needs sudo, graceful fallback)
    if command -v cpupower &>/dev/null; then
        sudo cpupower frequency-set -g performance 2>/dev/null || true
    fi
    
    # CPU energy performance preference - use performance governor during inference
    # balance_performance is too conservative for GPU-bound workloads where
    # the CPU handles graph construction and scheduling
    for p in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
        if [[ -f "$p" ]]; then
            echo performance | sudo tee "$p" >/dev/null 2>&1 || true
        fi
    done
    # Set GPU to auto (high causes near instant APU hangs)
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        if [[ -f "$card" ]]; then
            echo "auto" | sudo tee "$card" >/dev/null 2>&1 || true
        fi
    done
}

# Restore power settings to balanced/auto after inference
restore_performance() {
    for p in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
        if [[ -f "$p" ]]; then
            echo balance_performance | sudo tee "$p" >/dev/null 2>&1 || true
        fi
    done
}

_cleanup() {
    restore_performance
}
trap _cleanup EXIT

setup_rocm_env() {
    export ROCM_PATH="$PROJECT_ROOT/deps"
    export HIP_PATH="$ROCM_PATH"
    export HIP_PLATFORM=amd
    export HIP_VISIBLE_DEVICES=0
    export HSA_OVERRIDE_GFX_VERSION="${LLAMA_GFX_VERSION:-11.0.3}"
    export LD_LIBRARY_PATH="${PROJECT_ROOT:-.}/deps/lib:${LD_LIBRARY_PATH:-}"
}

setup_vulkan_env() {
    export LD_LIBRARY_PATH="${PROJECT_ROOT:-.}/deps/lib:${LD_LIBRARY_PATH:-}"
    # Vulkan shader pipeline cache - larger cache reduces recompilation stalls
    export MESA_SHADER_CACHE_MAX_SIZE="${MESA_SHADER_CACHE_MAX_SIZE:-2G}"
    # Ensure cache directory exists and is persisted
    export MESA_SHADER_CACHE_DIR="${MESA_SHADER_CACHE_DIR:-$HOME/.cache/mesa_shader_cache}"
    mkdir -p "$MESA_SHADER_CACHE_DIR"
    # RADV performance tuning for compute workloads
    export RADV_PERFTEST="${RADV_PERFTEST:-gplp}"
}

setup_metal_env() {
    # Metal uses no special runtime env; unified memory is automatic on Apple Silicon.
    # Setting GPU_HONEST_CELLS=1 can help on devices with binned/inactive GPU cores
    # but is harmless on healthy hardware.
    export GGML_METAL_DEVICE_DEBUG=0
}

apply_backend_env() {
    case "$BACKEND" in
        rocm)   setup_rocm_env ;;
        vulkan) setup_vulkan_env ;;
        metal)  setup_metal_env ;;
    esac
}

# =============================================================================
# Model Download
# =============================================================================

# Query HuggingFace API for model information
# Returns JSON with model metadata
hf_api_get() {
    local endpoint="$1"
    local url="https://huggingface.co/api/$endpoint"
    curl -s -L --fail "$url" 2>/dev/null
}

# Search for models on HuggingFace matching a pattern
# Output: repo_id lines (owner/repo format)
hf_search_models() {
    local query="$1"
    local limit="${2:-10}"
    local encoded_query="${query// /+}"
    hf_api_get "models?search=$encoded_query&sort=downloads&direction=-1&limit=$limit" 2>/dev/null | \
        jq -r '.[].id // empty' 2>/dev/null
}

# List files in a HuggingFace repository
# Output: filenames
hf_list_files() {
    local repo="$1"
    hf_api_get "models/$repo" 2>/dev/null | \
        jq -r '.siblings[].rfilename // empty' 2>/dev/null
}

# Get metadata for a specific file in a repo
# Returns JSON with size, etag, etc.
hf_file_info() {
    local repo="$1"
    local filename="$2"
    hf_api_get "repo_info?repo_id=$repo&repoType=model&file=$filename" 2>/dev/null
}

# Find GGUF files in a repo matching a quantization pattern
# Args: repo quant_pattern
# Output: matching filename(s), best match first
hf_find_gguf() {
    local repo="$1"
    local quant_pattern="${2:-Q4_K_M}"
    local files
    files=$(hf_list_files "$repo") || return 1
    
    # Normalize quant pattern for matching
    # Handle formats like "Q4_K_M", "UD-Q4_K_M", "IQ4_NL", etc.
    local quant_base="${quant_pattern#*-}"  # Remove prefix like "UD-"
    local quant_family="${quant_base%%_*}"  # Get base like "Q4"

    # Lowercase via tr for bash 3.2 compatibility (macOS default)
    local quant_lc quant_base_lc quant_family_lc
    quant_lc=$(printf '%s' "$quant_pattern" | tr 'A-Z' 'a-z')
    quant_base_lc=$(printf '%s' "$quant_base" | tr 'A-Z' 'a-z')
    quant_family_lc=$(printf '%s' "$quant_family" | tr 'A-Z' 'a-z')

    # Extract matching GGUF files
    local matches=()
    while IFS= read -r f; do
        [[ "$f" == *.gguf ]] || continue
        # Lowercase the filename for case-insensitive comparison
        local f_lc
        f_lc=$(printf '%s' "$f" | tr 'A-Z' 'a-z')
        # Match: Q4_K_M style OR unsloth UD-Q4_K_M style OR IQ4_NL style
        # Order matters - most specific first
        if [[ "$f_lc" =~ [-_]${quant_lc}[-_.] ]] || \
           [[ "$f_lc" =~ [-_]${quant_lc}$ ]] || \
           [[ "$f_lc" =~ [-_]${quant_base_lc}[-_.] ]] || \
           [[ "$f_lc" =~ [-_]${quant_base_lc}$ ]] || \
           [[ "$f_lc" =~ [-_]${quant_family_lc}[-_] ]]; then
            matches+=("$f")
        fi
    done <<< "$files"
    
    # If no specific quant matches, return all GGUF files
    if [[ ${#matches[@]} -eq 0 ]]; then
        while IFS= read -r f; do
            [[ "$f" == *.gguf ]] && matches+=("$f")
        done <<< "$files"
    fi
    
    # Sort by size (prefer larger quants)
    printf '%s\n' "${matches[@]}" | sort -t'_' -k2 -V | tac
}

# Detect available quantization options in a repo
hf_list_quants() {
    local repo="$1"
    local files
    files=$(hf_list_files "$repo") 2>/dev/null || return 1
    
    # Extract unique quant types from filenames
    echo "$files" | grep -oE '[Qq][0-9]+[_-]?K?_?[SMXL]?' | sort -u | head -20
}

download_model() {
    local input="$1"
    local quant="${2:-Q4_K_M}"
    local target_dir="$MODEL_DIR"
    
    local repo=""
    local filename=""
    
    # Detect input format
    if [[ "$input" == *"/"* ]]; then
        # Direct repo format: owner/repo or owner/repo:quant
        repo="${input%%:*}"
        if [[ "$input" == *":"* ]]; then
            quant="${input##*:}"
        fi
    else
        # Search for model by name
        echo -e "${BLUE}Searching HuggingFace for: $input${NC}"
        local search_results
        search_results=$(hf_search_models "$input" 10)
        
        if [[ -z "$search_results" ]]; then
            echo -e "${RED}No models found matching: $input${NC}"
            return 1
        fi
        
        # Find a repo with GGUF files
        local found=false
        while IFS= read -r candidate; do
            local gguf_files
            gguf_files=$(hf_find_gguf "$candidate" 2>/dev/null)
            if [[ -n "$gguf_files" ]]; then
                repo="$candidate"
                echo -e "${GREEN}Found repo: $repo${NC}"
                found=true
                break
            fi
        done <<< "$search_results"
        
        if [[ "$found" != "true" ]]; then
            echo -e "${RED}No GGUF files found for any matching model${NC}"
            echo -e "${YELLOW}Try specifying the repo directly:${NC}"
            echo -e "  $0 --download owner/repo --quant $quant"
            return 1
        fi
    fi
    
    # List available quantizations
    echo -e "\n${BLUE}Available quantizations in $repo:${NC}"
    local quants
    quants=$(hf_list_quants "$repo")
    if [[ -n "$quants" ]]; then
        echo "$quants" | head -15 | while read -r q; do
            [[ "$q" == "$quant" ]] && echo -e "  $q (selected)" || echo "  $q"
        done
    fi
    
    # Find best matching file
    echo -e "\n${BLUE}Finding best GGUF file for quant: $quant${NC}"
    
    # Try exact match first, then fuzzy
    local candidates
    candidates=$(hf_find_gguf "$repo" "$quant")
    
    if [[ -z "$candidates" ]]; then
        echo -e "${RED}No GGUF files found in $repo${NC}"
        return 1
    fi
    
    # Pick the best match for the requested quantization
    local selected=""
    local selected_base=""
    local part_count=1
    local total_parts=1
    # Lowercase via tr for bash 3.2 compatibility (macOS default)
    local quant_lc quant_family_lc quant_base_lc
    quant_lc=$(printf '%s' "$quant" | tr 'A-Z' 'a-z')
    quant_family_lc=$(printf '%s' "${quant%%_*}" | tr 'A-Z' 'a-z')
    quant_base_lc=$(printf '%s' "${quant#*-}" | tr 'A-Z' 'a-z')

    # Priority: exact quant match > same quant family > largest available
    # Use case-insensitive matching since HF filenames are lowercase
    while IFS= read -r f; do
        local f_lc
        f_lc=$(printf '%s' "$f" | tr 'A-Z' 'a-z')
        if [[ "$f_lc" =~ [-_]${quant_lc}[-_.] ]] || [[ "$f_lc" =~ [-_]${quant_lc}$ ]] || [[ "$f_lc" == *"${quant_lc}"*.gguf ]]; then
            selected="$f"
            break
        fi
    done <<< "$candidates"

    # Fallback: same quant family (e.g., Q4_K_M -> Q4_K_S)
    if [[ -z "$selected" ]]; then
        while IFS= read -r f; do
            local f_lc
            f_lc=$(printf '%s' "$f" | tr 'A-Z' 'a-z')
            if [[ "$f_lc" =~ [-_]${quant_family_lc}[-_] ]]; then
                selected="$f"
                break
            fi
        done <<< "$candidates"
    fi

    # Fallback: largest file
    if [[ -z "$selected" ]]; then
        selected=$(echo "$candidates" | head -1)
    fi

    if [[ -z "$selected" ]]; then
        echo -e "${RED}Could not determine filename${NC}"
        return 1
    fi

    # Detect multi-part files: base-00001-of-00003.gguf pattern
    # Use non-greedy .*? to avoid consuming part numbers
    if [[ "$selected" =~ ^(.*?)-([0-9]+)-of-([0-9]+)\.gguf$ ]]; then
        selected_base="${BASH_REMATCH[1]}"
        part_count="${BASH_REMATCH[2]}"
        total_parts="${BASH_REMATCH[3]}"
        echo -e "${BLUE}Detected multi-part file ($part_count of $total_parts)${NC}"
    fi

    # Collect all files to download
    local all_files=()
    all_files+=("$selected")

    if [[ -n "$selected_base" ]]; then
        while IFS= read -r f; do
            [[ " ${all_files[*]} " == *" $f "* ]] && continue
            # Bash 3.2 safe: escape slashes via tr instead of ${var//pat/repl}
            local escaped_base
            escaped_base=$(printf '%s' "$selected_base" | tr '/' '\\/')
            if [[ "$f" =~ ^${escaped_base}-[0-9]+-of-[0-9]+\.gguf$ ]]; then
                all_files+=("$f")
            fi
        done <<< "$candidates"
    fi

    # Sort by part number
    IFS=$'\n' sorted_files=($(sort -t'_' -k2 -V <<< "${all_files[*]}")); unset IFS

    mkdir -p "$target_dir"

    echo -e "\n${BLUE}Model Download Information${NC}"
    echo ""
    echo -e "  ${GREEN}Repo:${NC}     $repo"
    echo -e "  ${GREEN}Parts:${NC}    ${#sorted_files[@]} file(s) to download"
    for f in "${sorted_files[@]}"; do
        echo -e "    - $f"
    done
    echo -e "  ${GREEN}Quant:${NC}    $quant (requested)"
    echo -e "  ${GREEN}Target:${NC}   $target_dir"
    echo ""

    # Check which files already exist
    local files_to_download=()
    for f in "${sorted_files[@]}"; do
        if [[ -f "$target_dir/$f" ]]; then
            echo -e "${GREEN}Already exists: $f${NC}"
        else
            files_to_download+=("$f")
        fi
    done

    if [[ ${#files_to_download[@]} -eq 0 ]]; then
        echo -e "${GREEN}All files already cached.${NC}"
        return 0
    fi

    echo -e "${BLUE}Downloading ${#files_to_download[@]} file(s)...${NC}"
    echo ""

    # Try hf (recommended) or huggingface-cli for downloads
    local use_python=false
    local download_tool=""
    local idx=0
    
    if command -v hf &>/dev/null; then
        download_tool="hf"
    elif command -v huggingface-cli &>/dev/null; then
        download_tool="huggingface-cli"
    else
        use_python=true
    fi
    
    if [[ "$download_tool" == "hf" ]]; then
        # hf is the recommended tool
        for f in "${files_to_download[@]}"; do
            idx=$((idx + 1))
            echo -e "${BLUE}[$idx/${#files_to_download[@]}] $f${NC}"
            if hf download "$repo" "$f" --local-dir "$target_dir" 2>&1; then
                echo -e "${GREEN}  Downloaded: $f${NC}"
            else
                use_python=true
                break
            fi
        done
    elif [[ "$download_tool" == "huggingface-cli" ]]; then
        echo -e "${YELLOW}Note: huggingface-cli is deprecated. Consider installing 'hf' instead.${NC}"
        for f in "${files_to_download[@]}"; do
            idx=$((idx + 1))
            echo -e "${BLUE}[$idx/${#files_to_download[@]}] $f${NC}"
            if huggingface-cli download "$repo" "$f" \
                --local-dir "$target_dir" \
                --local-dir-use-symlinks False 2>&1; then
                echo -e "${GREEN}  Downloaded: $f${NC}"
            else
                use_python=true
                break
            fi
        done
    fi

    # Fallback to Python API if huggingface-cli not available or failed
    if [[ "$use_python" == "true" ]]; then
        if ! python3 -c "import huggingface_hub" 2>/dev/null; then
            echo -e "${RED}huggingface_hub not available. Cannot download.${NC}"
            return 1
        fi

        local idx=0
        for f in "${files_to_download[@]}"; do
            idx=$((idx + 1))
            echo -e "${BLUE}[$idx/${#files_to_download[@]}] $f${NC}"

            if python3 << PYEOF
from huggingface_hub import hf_hub_download
try:
    path = hf_hub_download(
        repo_id='$repo',
        filename='$f',
        local_dir='$target_dir',
        local_dir_use_symlinks=False
    )
    print(f'  Downloaded to: {path}')
except Exception as e:
    print(f'  Error: {e}')
    exit(1)
PYEOF
            then
                echo -e "${GREEN}  Downloaded: $f${NC}"
            else
                echo -e "${RED}  Failed: $f${NC}"
            fi
        done
    fi

    # Verify all files exist
    local missing=0
    for f in "${files_to_download[@]}"; do
        if [[ ! -f "$target_dir/$f" ]]; then
            echo -e "${RED}Missing: $f${NC}"
            missing=1
        fi
    done

    if [[ $missing -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}All files downloaded successfully!${NC}"
        return 0
    else
        return 1
    fi
}

download_usage() {
    cat << USAGE
${BLUE}Download Model from Hugging Face${NC}

${YELLOW}Usage:${NC}
    $0 --download MODEL [--quant QUANTIZATION]

${YELLOW}Arguments:${NC}
    MODEL          Model name or HuggingFace repo (owner/repo)
                   Examples:
                     - "Qwen3.6-35B" (searches by name)
                     - "unsloth/Qwen3.6-35B-A3B-GGUF" (direct repo)
                     - "bartowski/Mistral-7B-GGUF:Q4_K_M" (repo:quant format)
    --quant        Quantization preference (default: Q4_K_M)
                   Options: Q2_K, Q3_K_M, Q4_K_M, Q4_0, Q5_K_M, Q6_K, Q8_0

${YELLOW}How it works:${NC}
    1. If MODEL contains '/', it's treated as a direct HuggingFace repo
    2. Otherwise, searches HuggingFace for matching models with GGUF files
    3. Finds the best GGUF file matching your quantization preference
    4. Downloads using hf, huggingface-cli, or Python huggingface_hub

${YELLOW}Examples:${NC}
    $0 --download Qwen3.6-35B
    $0 --download Qwen3.6-35B --quant Q5_K_M
    $0 --download mistral-small-3-2 --quant Q4_K_M
    $0 --download unsloth/Qwen3.6-35B-A3B-GGUF
    $0 --download bartowski/Mistral-Small-3.1-24B-Instruct-GGUF --quant Q4_K_M
    $0 --download unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF:Q5_K_M

USAGE
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================

# Parse download arguments first
DOWNLOAD_MODEL=""
DOWNLOAD_QUANT="Q4_K_M"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --download)
            DOWNLOAD_MODEL="$2"
            shift 2
            ;;
        --quant)
            DOWNLOAD_QUANT="$2"
            shift 2
            ;;
        *) break ;;
    esac
done

if [[ -n "$DOWNLOAD_MODEL" ]]; then
    download_model "$DOWNLOAD_MODEL" "$DOWNLOAD_QUANT"
    exit $?
fi

# Now parse remaining arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--backend) BACKEND="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -a|--alias) MODEL_ALIAS="$2"; shift 2 ;;
        -t|--threads) THREADS="$2"; shift 2 ;;
        -c|--ctx-size) CTX_SIZE="$2"; USER_CTX_SIZE=1; shift 2 ;;
        -n|--n-predict) N_PREDICT="$2"; shift 2 ;;
        -ngl|--gpu-layers) GPU_LAYERS="$2"; shift 2 ;;
        --kv-cache-type)
            KV_CACHE_TYPE_K="$2"; KV_CACHE_TYPE_V="$2"; shift 2 ;;
        --cache-ssd) SSD_PATH="$2"; shift 2 ;;
        --cache-ssd-checkpoints) SSD_CHECKPOINTS="$2"; shift 2 ;;
        --cache-ssd-hot-window) SSD_HOT_WINDOW="$2"; shift 2 ;;
        --cache-ssd-warm-window) SSD_WARM_WINDOW="$2"; shift 2 ;;
        --cache-ssd-max-cold) SSD_MAX_COLD="$2"; shift 2 ;;
        --cache-ssd-page-size) SSD_PAGE_SIZE="$2"; shift 2 ;;
        --cache-ssd-hot-ram) SSD_HOT_RAM="$2"; shift 2 ;;
        --cache-ssd-warm-ram) SSD_WARM_RAM="$2"; shift 2 ;;
        --cache-ssd-system-prompts) SSD_SYSTEM_PROMPTS="$2"; shift 2 ;;
        --cache-ssd-system-max-days) SSD_SYSTEM_MAX_DAYS="$2"; shift 2 ;;
        --prompt-max) PROMPT_MAX="$2"; shift 2 ;;
        --checkpoint-min-step)
            OVERRIDE_CHECKPOINT_EVERY="$2"; shift 2 ;;
        --ctx-checkpoints)
            OVERRIDE_CTX_CHECKPOINTS="$2"; shift 2 ;;
        --cache-ram)
            OVERRIDE_CACHE_RAM="$2"; shift 2 ;;
        --ubatch-size)
            OVERRIDE_UBATCH_SIZE="$2"; shift 2 ;;
        --np)
            OVERRIDE_N_PARALLEL="$2"; shift 2 ;;
        --preserve-reasoning) PRESERVE_REASONING="true"; shift ;;
        --no-preserve-reasoning) PRESERVE_REASONING="false"; shift ;;
        --reasoning-budget) OVERRIDE_REASONING_BUDGET="$2"; shift 2 ;;
        --no-reasoning-budget) OVERRIDE_REASONING_BUDGET="0"; shift ;;
        --interactive|-i) INTERACTIVE=true; shift ;;
        --server|-s) SERVER_MODE=true; shift ;;
        --fit) OVERRIDE_FIT="on"; shift ;;
        --print-profile) PRINT_PROFILE=true; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --list-models) list_models ;;
        --list-backends) list_backends_v2 ;;
        --download-help) download_usage ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *) [[ -z "$MODEL" ]] && MODEL="$1"; shift ;;
    esac
done


PROMPT="$*"

# =============================================================================
# Resolve model
# =============================================================================

# If MODEL is a file path, use it directly
if [[ -f "$MODEL" ]]; then
    MODEL="$(realpath "$MODEL")"
# If MODEL matches an alias or basename, resolve it
elif [[ -n "$MODEL" ]]; then
    RESOLVE_IDX=0
    RESOLVE_FOUND=-1
    for entry in "${MODELS_NAME[@]}"; do
        if [[ "$entry" == "$MODEL" ]]; then
            RESOLVE_FOUND=$RESOLVE_IDX
            break
        fi
        RESOLVE_IDX=$((RESOLVE_IDX + 1))
    done
    if [[ $RESOLVE_FOUND -ge 0 ]]; then
        MODEL="${MODELS_PATH[$RESOLVE_FOUND]}"
    fi
    unset RESOLVE_IDX RESOLVE_FOUND
fi

if [[ -z "$MODEL" ]]; then
    echo -e "${YELLOW}No model specified. Use --list-models${NC}"; exit 1
fi

if [[ ! -f "$MODEL" ]]; then
    echo -e "${RED}Model not found: $MODEL${NC}"; exit 1
fi

# Auto-sync model path to Hermes config if we're running as a server
if [[ "$SERVER_MODE" == true ]]; then
    HERMES_CONFIG="$PROJECT_ROOT/hermes/data/config.yaml"
    if [[ -f "$HERMES_CONFIG" ]]; then
        python3 -c "
import sys, re
config_path = sys.argv[1]
model_path = sys.argv[2]
try:
    with open(config_path, 'r', encoding='utf-8') as f:
        content = f.read()
    content = re.sub(r'(?m)^([ \t]*default:[ \t]*).*', r'\g<1>' + model_path, content)
    content = re.sub(r'(?m)^([ \t]*model:[ \t]*).*?\.gguf', r'\g<1>' + model_path, content)
    with open(config_path, 'w', encoding='utf-8') as f:
        f.write(content)
except Exception as e:
    pass
" "$HERMES_CONFIG" "$MODEL" 2>/dev/null || true
    fi
fi

if [[ "$BACKEND" == "auto" ]]; then
    detect_backend  # Sets BACKEND in current shell (not a subshell)
fi

# All models use dynamic profiling based on file characteristics
assign_profile "$MODEL"

# Check if this is a Qwen 3.x model and the fixed template exists
# The fixed template fixes a looping issue with Qwen 3.x models
MODEL_FILENAME=$(basename "$MODEL" .gguf)
if echo "$MODEL_FILENAME" | grep -qiE "qwen3(\.|-)?(5|6)?"; then
    FIXED_TEMPLATE="$PROJECT_ROOT/models/qwen3.5-fixed-template.jinja"
    if [[ -f "$FIXED_TEMPLATE" ]]; then
        EXTRA_SERVER_ARGS="$EXTRA_SERVER_ARGS --chat-template-file '$FIXED_TEMPLATE'"
        log_info "Using fixed Qwen 3.x chat template: $FIXED_TEMPLATE"
    fi
fi

# CLI overrides take precedence over profile-set values. We re-parse
# EXTRA_SERVER_ARGS to drop matching tokens, then append the override.
# The sed patterns are anchored to a leading space so we only match whole
# tokens (avoids --cache-ram eating --cache-ram-mlock or similar).
# Use a space between pattern and number so we match "--cache-ram 6144"
# (the value is a separate token, not glued onto the flag name).
# This runs before PRINT_PROFILE so the printed profile reflects overrides.
strip_and_append() {
    local pattern="$1" replacement="$2" var_name="EXTRA_SERVER_ARGS"
    local stripped
    stripped=$(echo "${!var_name}" | sed -E "s/ ${pattern} [0-9]+//g")
    eval "$var_name=\"\$stripped \$replacement\""
}
[[ -n "$OVERRIDE_CHECKPOINT_EVERY"  ]] && strip_and_append --checkpoint-min-step "--checkpoint-min-step $OVERRIDE_CHECKPOINT_EVERY"
[[ -n "$OVERRIDE_CTX_CHECKPOINTS"    ]] && strip_and_append --ctx-checkpoints            "--ctx-checkpoints $OVERRIDE_CTX_CHECKPOINTS"
[[ -n "$OVERRIDE_CACHE_RAM"          ]] && strip_and_append --cache-ram                  "--cache-ram $OVERRIDE_CACHE_RAM"

# =============================================================================

if [[ "$PRINT_PROFILE" == true ]]; then
    model_name=$(basename "$MODEL" .gguf)
    model_bytes=$(stat -c%s "$MODEL" 2>/dev/null || stat -f%z "$MODEL" 2>/dev/null || echo 0)
    # Suppress the "Auto profile:" line that assign_profile echo'd to stdout
    cat <<PROFILE_EOF
CTX_SIZE=$CTX_SIZE
MODEL_PATH='$MODEL'
MODEL_NAME=$model_name
MODEL_BYTES=$model_bytes
GPU_LAYERS=$GPU_LAYERS
THREADS=$THREADS
KV_CACHE_TYPE_K=$KV_CACHE_TYPE_K
KV_CACHE_TYPE_V=$KV_CACHE_TYPE_V
OVERRIDE_BATCH_SIZE='${OVERRIDE_BATCH_SIZE:-"--batch-size 1024 --ubatch-size 512"}'
OVERRIDE_REASONING='${OVERRIDE_REASONING:-off}'
OVERRIDE_REASONING_BUDGET='${OVERRIDE_REASONING_BUDGET:-0}'
EXTRA_SERVER_ARGS='${EXTRA_SERVER_ARGS:-}'
PRESERVE_REASONING='${PRESERVE_REASONING:-false}'
SSD_PATH='$SSD_PATH'
SSD_CHECKPOINTS=$SSD_CHECKPOINTS
SSD_HOT_WINDOW=$SSD_HOT_WINDOW
SSD_WARM_WINDOW=$SSD_WARM_WINDOW
SSD_MAX_COLD=$SSD_MAX_COLD
SSD_PAGE_SIZE=$SSD_PAGE_SIZE
SSD_HOT_RAM=$SSD_HOT_RAM
SSD_WARM_RAM=$SSD_WARM_RAM
SSD_SYSTEM_PROMPTS='$SSD_SYSTEM_PROMPTS'
SSD_SYSTEM_MAX_DAYS='$SSD_SYSTEM_MAX_DAYS'
OVERRIDE_FIT='$OVERRIDE_FIT'
PROFILE_EOF
    exit 0
fi
# Setup backend
# =============================================================================

# Default SSD cache for all non-SSM models (respects user override)
[[ -z "$SSD_PATH" ]] && SSD_PATH="$PROJECT_ROOT/llama/kv-cache"
setup_backend_env

# Get binary paths
LLAMA_BIN=$(get_llama_binary cli)
LLAMA_SERVER=$(get_llama_binary server)

if [[ ! -x "$LLAMA_BIN" ]]; then
    echo -e "${RED}Binary not found: $LLAMA_BIN${NC}"; exit 1
fi

echo -e "${BLUE}Using backend: ${GREEN}${BACKEND}${NC}"
echo -e "${BLUE}Binary: ${GREEN}$LLAMA_SERVER${NC}"

if [[ -n "$MODEL" ]]; then
    _total_mem_bytes=$(get_total_memory_bytes)
    _total_mem_gb=$((_total_mem_bytes / 1024 / 1024 / 1024))
    _model_size_gb=$((MODEL_BYTES / 1024 / 1024 / 1024))
    if [[ "$_model_size_gb" -gt $((_total_mem_gb - 2)) ]]; then
        # Model is more than ~92% of total RAM. Even mmap is risky on a busy system.
        echo -e "${YELLOW}Warning: model (${_model_size_gb}GB) is close to total RAM (${_total_mem_gb}GB).${NC}"
        if echo "$(basename "$MODEL" .gguf)" | grep -qiE "moe|a3b|a8b|flash|expert"; then
            echo -e "${YELLOW}         This is a MoE model: resident footprint is much smaller than file size.${NC}"
            echo -e "${YELLOW}         Only active experts are loaded; cold/expert pages stay on disk.${NC}"
        else
            echo -e "${YELLOW}         Dense model: full file will be resident. OOM is likely.${NC}"
            echo -e "${YELLOW}         Use a smaller quant (Q4 or Q3) or a smaller model.${NC}"
        fi
    fi

    # Apply backend-specific env (HSA override for ROCm, Metal debug, etc.)
    apply_backend_env
    setup_performance

    MODEL_SIZE=$(du -h "$MODEL" 2>/dev/null | cut -f1)
    MODEL_BYTES=$(stat -c%s "$MODEL" 2>/dev/null || stat -f%z "$MODEL" 2>/dev/null || echo 0)
    MODEL_NAME=$(basename "$MODEL" .gguf)
    echo -e "${BLUE}Model: ${GREEN}$MODEL_NAME${NC} ($MODEL_SIZE)"
else
    # Apply backend-specific env (HSA override for ROCm, Metal debug, etc.)
    apply_backend_env
    setup_performance

    MODEL_SIZE="0"
    MODEL_BYTES=0
    MODEL_NAME="None (Router Mode)"
    echo -e "${BLUE}Model: ${GREEN}None (Router Mode)${NC}"
fi

# =============================================================================
# Fit mode: auto-calculate GPU layers to fit available VRAM
# =============================================================================

# Only pass --fit when the user asked for it; don't inject --fit off by default
if [[ "$OVERRIDE_FIT" == "on" ]]; then
    GPU_LAYERS=-1
    EXTRA_SERVER_ARGS+=" --fit on"
fi

# Build args
# =============================================================================

if [[ -n "$MODEL" ]]; then
    COMMON_ARGS="-m '$MODEL'"
    [[ -n "$MODEL_ALIAS" ]] && COMMON_ARGS="$COMMON_ARGS -a '$MODEL_ALIAS'"
    MODEL_BYTES=${MODEL_BYTES:-0}
    MEMLOCK_LIMIT_KB=$(ulimit -l 2>/dev/null || true)
    if [[ "$MEMLOCK_LIMIT_KB" == "unlimited" || -z "$MEMLOCK_LIMIT_KB" ]]; then
        # mlock not enforced; treat as 0 so we don't mlock
        MEMLOCK_LIMIT_KB=0
    fi
    MEMLOCK_LIMIT_BYTES=$((MEMLOCK_LIMIT_KB * 1024))
    if [[ "$MODEL_BYTES" -gt 0 && "$MODEL_BYTES" -gt "$MEMLOCK_LIMIT_BYTES" ]]; then
        log_info "mlock disabled: model ($((MODEL_BYTES / 1048576)) MiB) larger than memlock limit ($((MEMLOCK_LIMIT_BYTES / 1048576)) MiB)"
    else
        COMMON_ARGS="$COMMON_ARGS --mlock"
    fi
else
    COMMON_ARGS=""
fi
COMMON_ARGS="$COMMON_ARGS -c $CTX_SIZE --threads $THREADS --threads-batch $THREADS"
COMMON_ARGS="$COMMON_ARGS ${OVERRIDE_BATCH_SIZE:---batch-size 1024 --ubatch-size 512} -ngl $GPU_LAYERS"
if [[ -n "$OVERRIDE_UBATCH_SIZE" ]]; then
    COMMON_ARGS=$(echo "$COMMON_ARGS" | sed -E 's/--ubatch-size [0-9]+/--ubatch-size '"$OVERRIDE_UBATCH_SIZE"'/')
fi
COMMON_ARGS="$COMMON_ARGS --cache-type-k $KV_CACHE_TYPE_K --cache-type-v $KV_CACHE_TYPE_V"
[[ -n "$EXTRA_COMMON_ARGS" ]] && COMMON_ARGS="$COMMON_ARGS $EXTRA_COMMON_ARGS"

# KV cache directory for persisting prompt state across restarts
KV_CACHE_DIR="$PROJECT_ROOT/llama/kv-cache"
mkdir -p "$KV_CACHE_DIR"

SERVER_ARGS="--host $HOST --port $PORT"
    SERVER_ARGS="$SERVER_ARGS -fa on --jinja --ui-mcp-proxy"
SERVER_ARGS="$SERVER_ARGS --reasoning ${OVERRIDE_REASONING:-off}"
# Cap reasoning tokens to prevent think loops (disabled for SSM models that don't think)
[[ -n "$OVERRIDE_REASONING_BUDGET" && "$OVERRIDE_REASONING_BUDGET" != "0" ]] && SERVER_ARGS="$SERVER_ARGS --reasoning-budget $OVERRIDE_REASONING_BUDGET"
SERVER_ARGS="$SERVER_ARGS -np ${OVERRIDE_N_PARALLEL:-1} --prio 3 --prio-batch 3 --metrics"
# Checkpoint capacity
SERVER_ARGS="$SERVER_ARGS -ctxcp 64"
# RAM cache reuse threshold
SERVER_ARGS="$SERVER_ARGS --cache-reuse 512"
# Persist KV cache to disk for faster restart (avoids OOM by writing async)
SERVER_ARGS="$SERVER_ARGS --slot-save-path $KV_CACHE_DIR"
# Higher similarity threshold for confident cache matches, unified KV
SERVER_ARGS="$SERVER_ARGS --slot-prompt-similarity 0.20 --kv-unified"

# Append the profile-set + override-merged EXTRA_SERVER_ARGS.
# CLI overrides are applied earlier (before --print-profile) so the printed
# profile reflects them.
[[ -n "$EXTRA_SERVER_ARGS" ]] && SERVER_ARGS="$SERVER_ARGS $EXTRA_SERVER_ARGS"

# Preserve reasoning/thinking in prior assistant messages
# Default: off (the agentic harness preserves knowledge, reasoning in context is redundant)
if [[ "$PRESERVE_REASONING" == "true" ]]; then
    SERVER_ARGS="$SERVER_ARGS --chat-template-kwargs '{\"preserve_thinking\":true}'"
fi



# SSD-backed KV cache
if [[ -n "$SSD_PATH" ]]; then
    mkdir -p "$SSD_PATH"
    if "$LLAMA_SERVER" --help 2>&1 | grep -q -- "--cache-ssd"; then
        SERVER_ARGS="$SERVER_ARGS --cache-ssd $SSD_PATH"
        [[ -n "$SSD_CHECKPOINTS" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-checkpoints $SSD_CHECKPOINTS"
        [[ -n "$SSD_HOT_WINDOW" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-hot-window $SSD_HOT_WINDOW"
        [[ -n "$SSD_WARM_WINDOW" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-warm-window $SSD_WARM_WINDOW"
        [[ -n "$SSD_MAX_COLD" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-max-cold $SSD_MAX_COLD"
        [[ -n "$SSD_PAGE_SIZE" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-page-size $SSD_PAGE_SIZE"
        [[ -n "$SSD_HOT_RAM" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-hot-ram $SSD_HOT_RAM"
        [[ -n "$SSD_WARM_RAM" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-warm-ram $SSD_WARM_RAM"
        [[ -n "${SSD_SYSTEM_PROMPTS:-}" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-system-prompts $SSD_SYSTEM_PROMPTS"
        [[ -n "${SSD_SYSTEM_MAX_DAYS:-}" ]] && SERVER_ARGS="$SERVER_ARGS --cache-ssd-system-max-days $SSD_SYSTEM_MAX_DAYS"
        [[ -n "$PROMPT_MAX" && "$PROMPT_MAX" != "0" ]] && SERVER_ARGS="$SERVER_ARGS --prompt-max $PROMPT_MAX"
    else
        echo -e "${YELLOW}Warning: --cache-ssd is not supported by this llama-server binary. Skipping SSD cache flags.${NC}"
    fi
fi

# =============================================================================
# Kill existing server (ensure only one running)
# =============================================================================

kill_existing_server() {
    local port="$1"
    # Kill any llama-server and llmfit processes
    pkill -9 llama-server 2>/dev/null || true
    pkill -9 llmfit 2>/dev/null || true
    # Also kill any process holding our ports (lsof works on macOS + Linux)
    if command -v lsof &>/dev/null; then
        local pids
        pids=$(lsof -ti tcp:"$port",tcp:8787 2>/dev/null) || true
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -9 2>/dev/null || true
        fi
    fi
    sleep 1
}

# =============================================================================
# Execute (no sudo needed - runs as local user)
# =============================================================================

# Build environment inline for direct execution (no sudo)
# Note: we use eval here because we need to set env vars (ROCM_PATH, LD_LIBRARY_PATH,
# etc.) in the same command line as launching the binary. A simple `env` prefix would
# re-define the env, but the values are computed by setup_*_env functions and need
# to be quoted to survive paths with spaces. eval is the simplest way to splice them
# in front of the binary invocation without breaking word splitting on $COMMON_ARGS.
EXEC_ENV=""
if [[ "$BACKEND" == "rocm" ]]; then
    EXEC_ENV="ROCM_PATH='$ROCM_PATH' HIP_PATH='$HIP_PATH' HIP_VISIBLE_DEVICES=0 HSA_OVERRIDE_GFX_VERSION='$HSA_OVERRIDE_GFX_VERSION' LD_LIBRARY_PATH='$LD_LIBRARY_PATH'"
elif [[ "$BACKEND" == "vulkan" ]]; then
    EXEC_ENV="LD_LIBRARY_PATH='$LD_LIBRARY_PATH'"
elif [[ "$BACKEND" == "metal" ]]; then
    # Metal needs no env vars at runtime; env is set in-process above
    EXEC_ENV=""
fi

if [[ "$SERVER_MODE" == true ]]; then
    kill_existing_server "$PORT"
    wait_for_tcp_port() {
        local host="$1"
        local port="$2"
        local attempts="${3:-40}"
        local count=0
        while ! python3 - "$host" "$port" <<'PY' 2>/dev/null && [[ $count -lt $attempts ]]; do
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket()
sock.settimeout(0.25)
sock.connect((host, port))
sock.close()
PY
            sleep 0.25
            count=$((count + 1))
        done
        [[ $count -lt $attempts ]]
    }

    start_llmfit_backend() {
        if [[ "$IS_DARWIN" == true ]]; then
            LLMFIT_BIN="$PROJECT_ROOT/llama/mac/bin/llmfit"
        else
            LLMFIT_BIN="$PROJECT_ROOT/llama/linux/bin/llmfit"
        fi

        if [[ ! -x "$LLMFIT_BIN" ]]; then
            echo -e "${YELLOW}Warning: llmfit binary is missing; Model Fit tab will be unavailable.${NC}"
            return 1
        fi

        local llmfit_log="$PROJECT_ROOT/llama/llmfit.log"
        echo -e "${BLUE}Starting llmfit model recommender backend on http://localhost:8787/...${NC}"
        "$LLMFIT_BIN" serve --port 8787 >"$llmfit_log" 2>&1 &
        local llmfit_pid=$!

        if wait_for_tcp_port 127.0.0.1 8787 40; then
            return 0
        fi

        if kill -0 "$llmfit_pid" 2>/dev/null; then
            echo -e "${YELLOW}Warning: llmfit did not become ready on port 8787 yet; continuing startup.${NC}"
        else
            echo -e "${YELLOW}Warning: llmfit exited before opening port 8787. See $llmfit_log.${NC}"
        fi
        return 1
    }

    start_llmfit_backend || true

    if [[ "${AUTO_LAUNCH_BROWSER:-}" == "true" ]]; then
        open_browser_when_ready() {
            local count=0
            # Wait for port to become active (check using python to be system-utility independent)
            while ! python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', $PORT))" 2>/dev/null && [ $count -lt 60 ]; do
                sleep 0.5
                count=$((count + 1))
            done
            echo -e "${GREEN}Opening Chat & Model Manager in your browser at http://localhost:${PORT}...${NC}"
            if [[ "$IS_DARWIN" == true ]]; then
                open "http://localhost:$PORT"
            elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* || "$(uname -s)" == MSYS* ]]; then
                start "http://localhost:$PORT" 2>/dev/null || explorer "http://localhost:$PORT" 2>/dev/null || true
            else
                xdg-open "http://localhost:$PORT" 2>/dev/null || sensible-browser "http://localhost:$PORT" 2>/dev/null || x-www-browser "http://localhost:$PORT" 2>/dev/null || true
            fi
        }
        open_browser_when_ready &
    else
        echo_browser_message_when_ready() {
            local count=0
            while ! python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', $PORT))" 2>/dev/null && [ $count -lt 60 ]; do
                sleep 0.5
                count=$((count + 1))
            done
            echo -e ""
            echo -e "${GREEN}====================================================${NC}"
            echo -e "${GREEN}  Server is ready!${NC}"
            echo -e "${GREEN}  Open ${CYAN}http://localhost:${PORT}${GREEN} in your browser to use the Web UI${NC}"
            echo -e "${GREEN}====================================================${NC}"
            echo -e ""
        }
        echo_browser_message_when_ready &
    fi
    echo -e "${BLUE}Starting server on ${HOST}:${PORT}...${NC}"
    eval "$EXEC_ENV" "$LLAMA_SERVER" $COMMON_ARGS $SERVER_ARGS
else
    if [[ "$INTERACTIVE" == true ]]; then
        eval "$EXEC_ENV" "$LLAMA_BIN" $COMMON_ARGS -i
    else
        eval "$EXEC_ENV" "$LLAMA_BIN" $COMMON_ARGS -n $N_PREDICT "$PROMPT"
    fi
fi
