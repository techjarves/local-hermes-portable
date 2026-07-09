#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
# =============================================================================
# Llama.cpp Benchmark Script - Prompt Cache Performance
# Tests SSD prompt caching by sending identical prompts at 3 sizes
# (small ~1K, medium ~5K, large ~15K tokens) in cold (empty cache)
# and warm (SSD cache restore) states. Measures prompt eval speedup.
#
# Prompts use public domain text from Project Gutenberg (Count of Monte Cristo)
# cached in scratch/pg1184.txt. Each prompt appends a short instruction.
#
# Output: per-model summary.json + summary.md, aggregate across models.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_DIR="$PROJECT_ROOT/models"
SSD_CACHE_DIR="$PROJECT_ROOT/llama/ssd-cache"
SCRATCH_DIR="$PROJECT_ROOT/scratch"

# Timestamped output directory
TIMESTAMP=$(date +%Y%m%d-%H%M)
BENCH_DIR="$PROJECT_ROOT/llama/benchmarks/$TIMESTAMP"
mkdir -p "$BENCH_DIR"

# Backend paths
ROCM_BIN="$PROJECT_ROOT/llama/CachyLLama/build_temp/bin"
VULKAN_BIN="$PROJECT_ROOT/llama/CachyLLama/build_temp/bin"

# Default settings
PORT=9090
# CTX_SIZE scales with hardware tier so prompt-eval benchmarks exercise
# realistic agentic context sizes. Handheld stays at 32K (matches Ayaneo
# KB limits), halo pushes to 128K (well within Strix Halo's 96GB VRAM).
case "${LLAMA_HARDWARE_TIER:-handheld}" in
    halo)     CTX_SIZE=131072 ;;
    standard) CTX_SIZE=49152 ;;
    *)        CTX_SIZE=32768 ;;
esac
NGL=99
MAX_TOKENS=128
BENCH_TIMEOUT=900

# Prompt sizes (bytes of Gutenberg text to use as prefix)
# Approximate token mapping: 1 byte ~ 0.25 tokens for English prose
# Small:  4KB  ~ 1K tokens
# Medium: 20KB ~ 5K tokens
# Large:  60KB ~ 15K tokens
PROMPT_SIZES=(
    "small:4096"
    "medium:20480"
    "large:61440"
)
PROMPT_INSTRUCTION="Summarize this passage in one sentence."

# Source text URL
GUTENBERG_URL="http://aleph.gutenberg.org/cache/epub/1184/pg1184.txt"
GUTENBERG_CACHE="$SCRATCH_DIR/pg1184.txt"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
NC='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }
log_ok()    { printf '%b[OK]%b   %s\n' "$GREEN" "$NC" "$1"; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"; }
log_header(){ printf '%b=== %s ===%b\n' "$MAGENTA" "$1" "$NC"; }

# Models to test - auto-discovered from models/ directory.
# Excludes GGUF split-file shards (e.g. model-00002-of-00005.gguf).
# Set --model to test a specific model only.
discover_models() {
    local -a found=()
    for f in "$MODEL_DIR"/*.gguf; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f")
        # Skip split-file shards (contain -NNNNN-of-NNNNN in filename)
        if [[ "$name" =~ -[0-9]{5}-of-[0-9]{5}\.gguf$ ]]; then
            continue
        fi
        found+=("$name:")
    done
    printf '%s\n' "${found[@]}"
}

MODELS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && MODELS+=("$line")
done < <(discover_models)

# If no models found, show error
if [[ ${#MODELS[@]} -eq 0 ]]; then
    log_error "No .gguf models found in $MODEL_DIR"
    exit 1
fi

# =============================================================================
# Helper functions
# =============================================================================

get_binary() {
    local backend="$1"
    if [[ "$backend" == "metal" ]]; then
        if [[ -d "$PROJECT_ROOT/llama/mac/bin" ]]; then
            echo "$PROJECT_ROOT/llama/mac/bin"
        else
            echo "$PROJECT_ROOT/llama/CachyLLama/build_temp/bin"
        fi
    elif [[ "$backend" == "vulkan" ]]; then
        if [[ -d "$PROJECT_ROOT/llama/linux/bin" ]]; then
            echo "$PROJECT_ROOT/llama/linux/bin"
        elif [[ -d "$PROJECT_ROOT/llama/windows/bin" ]]; then
            echo "$PROJECT_ROOT/llama/windows/bin"
        else
            echo "$VULKAN_BIN"
        fi
    else
        echo "$ROCM_BIN"
    fi
}

setup_backend_env() {
    local backend="$1"
    source "$PROJECT_ROOT/scripts/env.sh" "$backend"
    source "$PROJECT_ROOT/scripts/detect-gpu.sh"
    [[ "$backend" == "rocm" ]] && export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
}

# =============================================================================
# Prompt builder - extracts prefix of given byte size from cached text
# =============================================================================

build_prompt() {
    local size_bytes="$1"
    local text_file="$2"

    # Strip BOM and header, take first N bytes, add instruction
    # Use process substitution to avoid SIGPIPE on sed when head exits early
    local prefix
    prefix=$(head -c "$size_bytes" <(sed '1s/^\xEF\xBB\xBF//' "$text_file"))
    # Escape for JSON embedding
    python3 -c "
import json, sys
text = sys.stdin.read()
prompt = text + '\n\n' + '$PROMPT_INSTRUCTION'
print(json.dumps(prompt))
" <<< "$prefix"
}

# =============================================================================
# Server management
# =============================================================================

SERVER_PID=""
SERVER_LOG=""

get_server_status() {
    curl -s -w "\n%{http_code}" "$API_BASE/v1/models" 2>/dev/null
}

wait_for_server() {
    local max_attempts=900
    local attempt=0

    printf "    Waiting for server"

    while [[ $attempt -lt $max_attempts ]]; do
        local resp
        resp=$(get_server_status)
        local http_code
        http_code=$(echo "$resp" | tail -1)
        local body
        body=$(echo "$resp" | sed '$d')

        if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "gguf"; then
            return 0
        fi

        if [[ -f "$SERVER_LOG" ]]; then
            local fatal
            fatal=$(grep -iE "killed|signal|segfault|segmentation fault|abort" "$SERVER_LOG" 2>/dev/null | tail -1 || echo "")
            if [[ -n "$fatal" ]]; then
                log_error "Server crashed: $fatal"
                return 1
            fi
        fi
        # Check if server process is still alive (catches segfaults that produce no log output)
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log_error "Server exited unexpectedly (PID $SERVER_PID)"
            tail -20 "$SERVER_LOG" 2>/dev/null || true
            return 1
        fi

        attempt=$((attempt + 1))
        if [[ $((attempt % 5)) -eq 0 ]]; then
            printf "."
        fi
        if [[ $((attempt % 30)) -eq 0 ]]; then
            printf " %ds\n" "$attempt"
        fi
        sleep 1
    done

    printf "\n"
    log_error "Server did not respond after ${max_attempts}s"
    return 1
}

start_server() {
    local model="$1"
    local extra_flags="$2"
    local backend="$3"
    local ssd_path="$4"

    log_info "Starting server: $model (backend: $backend, ssd: ${ssd_path:-none})"

    pkill -9 llama-server 2>/dev/null || true
    sleep 3

    # Get profile from llama-run.sh
    local profile
    profile=$("$SCRIPT_DIR/llama-run.sh" --print-profile --server --model "$MODEL_DIR/$model" --backend "$backend" | tail -n +2) || {
        log_error "Failed to get profile from llama-run.sh"
        return 1
    }
    eval "$profile"

    setup_backend_env "$backend"

    local llama_bin
    llama_bin=$(get_binary "$backend")
    [[ ! -f "$llama_bin/llama-server" ]] && { log_error "Binary not found: $llama_bin/llama-server"; return 1; }

    local cmd=("$llama_bin/llama-server")
    cmd+=(-m "$MODEL_PATH")
    cmd+=(-c "$CTX_SIZE")
    cmd+=(-ngl "$GPU_LAYERS")
    cmd+=(--threads "$THREADS" --threads-batch "$THREADS")
    cmd+=(--port "$PORT" --host 0.0.0.0)
    cmd+=($OVERRIDE_BATCH_SIZE)
    cmd+=(--cache-type-k "$KV_CACHE_TYPE_K" --cache-type-v "$KV_CACHE_TYPE_V")
    cmd+=(-fa on --jinja)
    cmd+=(--reasoning "$OVERRIDE_REASONING")
    cmd+=(--slot-prompt-similarity 0.20)
    cmd+=(--slot-save-path "$SSD_CACHE_DIR")
    cmd+=(--kv-unified)
    cmd+=(-np 1 --prio 3 --prio-batch 3 --metrics)
    # --ctx-checkpoints: per-slot in-memory checkpoint ring for speculative decoding.
    # Use the profile value (was hardcoded to 64, which inflated VRAM use on Halo).
    cmd+=(--ctx-checkpoints "${SSD_CHECKPOINTS:-8}" --cache-reuse 512)

    if [[ -n "$EXTRA_SERVER_ARGS" ]]; then
        IFS=' ' read -ra PROFILE_ARGS <<< "$EXTRA_SERVER_ARGS"
        cmd+=("${PROFILE_ARGS[@]}")
    fi

    if [[ -n "$ssd_path" ]]; then
        mkdir -p "$ssd_path"
        cmd+=(--cache-ssd "$ssd_path")
        [[ -n "${SSD_CHECKPOINTS:-}" ]] && cmd+=(--cache-ssd-checkpoints "$SSD_CHECKPOINTS")
        [[ -n "${SSD_HOT_WINDOW:-}" ]] && cmd+=(--cache-ssd-hot-window "$SSD_HOT_WINDOW")
        [[ -n "${SSD_WARM_WINDOW:-}" ]] && cmd+=(--cache-ssd-warm-window "$SSD_WARM_WINDOW")
        [[ -n "${SSD_MAX_COLD:-}" ]] && cmd+=(--cache-ssd-max-cold "$SSD_MAX_COLD")
        [[ -n "${SSD_PAGE_SIZE:-}" ]] && cmd+=(--cache-ssd-page-size "$SSD_PAGE_SIZE")
        [[ -n "${SSD_HOT_RAM:-}" ]] && cmd+=(--cache-ssd-hot-ram "$SSD_HOT_RAM")
        [[ -n "${SSD_WARM_RAM:-}" ]] && cmd+=(--cache-ssd-warm-ram "$SSD_WARM_RAM")
    fi

    [[ -n "$extra_flags" ]] && IFS=' ' read -ra FLAGS <<< "$extra_flags" && cmd+=("${FLAGS[@]}")

    {
        printf "BENCHMARK COMMAND:"
        for arg in "${cmd[@]}"; do
            printf " %q" "$arg"
        done
        printf "\n"
    } >> "$SERVER_LOG"

    "${cmd[@]}" > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    export API_BASE="http://localhost:$PORT"
    if ! wait_for_server; then
        log_error "Server failed to start"
        tail -30 "$SERVER_LOG"
        return 1
    fi

    sleep 2
    log_ok "Server ready (PID: $SERVER_PID)"
    return 0
}

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    pkill -9 llama-server 2>/dev/null || true
    sleep 2
}

# =============================================================================
# Direct API call - send prompt, extract timing from response
# =============================================================================

call_api() {
    local prompt_json="$1"
    local run_label="$2"
    local out_dir="$3"
    local timeout="${4:-$BENCH_TIMEOUT}"

    local raw_resp_file="$out_dir/${run_label}-response.json"
    local stats_file="$out_dir/${run_label}-stats.json"

    local start_ns
    start_ns=$(date +%s%N)

    # Write response body directly to file via -o, capture HTTP code from -w
    local http_code
    http_code=$(curl -s --max-time "$timeout" \
        -w "%{http_code}" \
        -o "$raw_resp_file" \
        "$API_BASE/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":$prompt_json}],\"max_tokens\":$MAX_TOKENS}") || {
        echo "{\"error\": \"curl failed (timeout ${timeout}s)\", \"wall_ms\": 0}" > "$stats_file"
        cat "$stats_file"
        return 1
    }

    local end_ns
    end_ns=$(date +%s%N)
    local wall_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [[ "$http_code" != "200" ]]; then
        local body_preview
        body_preview=$(head -c 500 "$raw_resp_file" 2>/dev/null || echo "(empty)")
        python3 -c "import json,sys
print(json.dumps({'error': 'HTTP $http_code', 'wall_ms': $wall_ms, 'body_preview': sys.stdin.read()}))" <<< "$body_preview" > "$stats_file"
        cat "$stats_file"
        return 1
    fi

    # Extract timing stats from response file (avoid shell variable JSON embedding)
    python3 - "$raw_resp_file" "$wall_ms" "$stats_file" << 'PYEOF'
import json, sys

resp_file = sys.argv[1]
wall_ms = int(sys.argv[2])
stats_file = sys.argv[3]

try:
    with open(resp_file, 'r') as f:
        data = json.load(f)

    u = data.get('usage', {})
    t = data.get('timings', {})
    pt = u.get('prompt_tokens', 0)
    ct = u.get('completion_tokens', 0)
    pms = t.get('prompt_ms', 0)
    gms = t.get('predicted_ms', 0)
    cached = u.get('prompt_tokens_details', {}).get('cached_tokens', 0)

    result = {
        'prompt_tokens': pt,
        'completion_tokens': ct,
        'cached_tokens': cached,
        'prompt_ms': round(pms, 1),
        'generation_ms': round(gms, 1),
        'total_ms': round(t.get('total_ms', pms + gms), 1),
        'ttft_ms': round(pms, 1),
        'wall_ttft_ms': wall_ms,
        'tps': round(ct * 1000 / gms, 1) if gms > 0 else 0,
        'prompt_tps': round(pt * 1000 / pms, 1) if pms > 0 else 0,
        'prompt_per_token_ms': round(t.get('prompt_per_token_ms', pms / pt if pt > 0 else 0), 1),
        'predicted_per_token_ms': round(t.get('predicted_per_token_ms', gms / ct if ct > 0 else 0), 1),
        'wall_ms': wall_ms,
    }
except Exception as e:
    result = {'error': str(e), 'wall_ms': wall_ms}

with open(stats_file, 'w') as f:
    json.dump(result, f, indent=2)
PYEOF

    cat "$stats_file"
}

# =============================================================================
# Cache hit detection from server log
# =============================================================================

detect_cache_state() {
    local log_file="$1"

    python3 -c "
import re, json

with open('$log_file', 'r') as f:
    text = f.read()

# Cache restore events. The server emits several distinct messages:
#   - 'cold-start: system prompt cache hit (n_past=N)' - the global system
#     prompt cache (cross-conversation) restored N tokens before the eval.
#   - 'loaded N checkpoints from <path>' - the SSD-backed per-conversation
#     checkpoint index was loaded on startup. N must be > 0 to count.
#   - 'restored system prompt from cache (n_sys=N, ..., skipping N tokens)'
#     - the slot actually used the restored state.
# Any of these means we have a cache hit. The legacy 'cold-start restored
# SSD' / 'restored in-memory checkpoint' strings were never emitted by
# this server, so the prior detector always reported 'miss' on warm runs.
sys_cache_hit = bool(re.search(r'system prompt cache hit', text))
sys_prompt_restored = bool(re.search(r'restored system prompt from cache', text))
loaded_match = re.search(r'loaded ([0-9]+) checkpoints from', text)
loaded_checkpoints = loaded_match is not None and int(loaded_match.group(1)) > 0
cold_restored = bool(re.search(r'cold-start restored SSD', text))
warm_restored = bool(re.search(r'restored in-memory checkpoint', text))

stored = len(re.findall(r'SSD cache: stored checkpoint', text))
divergences = len(re.findall(r'cache prefix divergence', text))

# Determine cache state
if cold_restored:
    state = 'ssd_cold'
elif warm_restored or sys_cache_hit or sys_prompt_restored or loaded_checkpoints:
    # 'ssd_warm' subsumes both in-memory and SSD-backed restores - the
    # benchmark cares about whether tokens were skipped, not the tier.
    state = 'ssd_warm'
else:
    state = 'miss'

total_checkpoints = len(re.findall(r'SSD cache: (stored|promoted|demoted) checkpoint', text))

print(json.dumps({
    'cache_state': state,
    'ssd_stored': stored,
    'divergences': divergences,
    'total_checkpoints': total_checkpoints
}))
"
}

# =============================================================================
# Run a single test: cold + warm for one prompt size
# =============================================================================

run_size_test() {
    local model="$1"
    local extra_flags="$2"
    local backend="$3"
    local out_dir="$4"
    local size_label="$5"
    local size_bytes="$6"

    printf "    ${YELLOW}▶ %s (%d bytes)${NC}\n" "$size_label" "$size_bytes" >&2

    local prompt_json
    prompt_json=$(build_prompt "$size_bytes" "$GUTENBERG_CACHE")

    local cold_pass=true warm_pass=true

    # Scale timeout by prompt size (large prompts need more eval time)
    local timeout=$BENCH_TIMEOUT
    if [[ "$size_bytes" -ge 40000 ]]; then
        timeout=$((BENCH_TIMEOUT * 3))
    elif [[ "$size_bytes" -ge 15000 ]]; then
        timeout=$((BENCH_TIMEOUT * 2))
    fi

    # ── Cold run: empty SSD cache ───────────────────────────────────────
    rm -rf "$SSD_CACHE_DIR"
    SERVER_LOG="$out_dir/server-${size_label}-cold.log"
    start_server "$model" "$extra_flags" "$backend" "$SSD_CACHE_DIR" || return 1

    printf "      cold: " >&2
    call_api "$prompt_json" "${size_label}-cold" "$out_dir" "$timeout" > /dev/null || cold_pass=false
    local cold_stats_file="$out_dir/${size_label}-cold-stats.json"
    if $cold_pass && [[ -f "$cold_stats_file" ]]; then
        local cold_pt cold_ttft
        cold_pt=$(python3 -c "import json; print(json.load(open('$cold_stats_file')).get('prompt_tokens', 0))" 2>/dev/null || echo 0)
        cold_ttft=$(python3 -c "import json; print(json.load(open('$cold_stats_file')).get('ttft_ms', 0))" 2>/dev/null || echo 0)
        printf "${GREEN}%s tokens, TTFT %sms${NC}\n" "$cold_pt" "$cold_ttft" >&2
    else
        printf "${RED}failed${NC}\n" >&2
    fi

    local cache_cold
    cache_cold=$(detect_cache_state "$SERVER_LOG") || cache_cold='{"cache_state":"unknown"}'
    stop_server

    # ── Warm run: restart with SSD cache ─────────────────────────────────
    SERVER_LOG="$out_dir/server-${size_label}-warm.log"
    start_server "$model" "$extra_flags" "$backend" "$SSD_CACHE_DIR" || return 1

    printf "      warm: " >&2
    call_api "$prompt_json" "${size_label}-warm" "$out_dir" "$timeout" > /dev/null || warm_pass=false
    local warm_stats_file="$out_dir/${size_label}-warm-stats.json"
    if $warm_pass && [[ -f "$warm_stats_file" ]]; then
        local warm_pt warm_ttft
        warm_pt=$(python3 -c "import json; print(json.load(open('$warm_stats_file')).get('prompt_tokens', 0))" 2>/dev/null || echo 0)
        warm_ttft=$(python3 -c "import json; print(json.load(open('$warm_stats_file')).get('ttft_ms', 0))" 2>/dev/null || echo 0)
        printf "${GREEN}%s tokens, TTFT %sms${NC}\n" "$warm_pt" "$warm_ttft" >&2
    else
        printf "${RED}failed${NC}\n" >&2
    fi

    local cache_warm
    cache_warm=$(detect_cache_state "$SERVER_LOG") || cache_warm='{"cache_state":"unknown"}'
    stop_server

    # ── Assemble result via temp file (no shell JSON embedding) ───────────
    local result_file="$out_dir/${size_label}-result.json"
    python3 - "$out_dir" "$size_label" "$size_bytes" "$cold_pass" "$warm_pass" "$cache_cold" "$cache_warm" "$result_file" << 'PYEOF'
import json, sys, os

out_dir = sys.argv[1]
size_label = sys.argv[2]
size_bytes = int(sys.argv[3])
cold_pass = sys.argv[4] == 'true'
warm_pass = sys.argv[5] == 'true'
cache_cold = json.loads(sys.argv[6])
cache_warm = json.loads(sys.argv[7])
result_file = sys.argv[8]

def load_stats(label):
    path = os.path.join(out_dir, f'{label}-stats.json')
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        return {'error': str(e)}

cold = load_stats(f'{size_label}-cold') if cold_pass else {'error': 'failed'}
warm = load_stats(f'{size_label}-warm') if warm_pass else {'error': 'failed'}

cold_prompt_ms = cold.get('prompt_ms', 0)
warm_prompt_ms = warm.get('prompt_ms', 0)

speedup = round(cold_prompt_ms / warm_prompt_ms, 2) if warm_prompt_ms > 0 and cold_prompt_ms > 0 else 0

# TTFT speedup (wall-clock)
cold_wall = cold.get('wall_ttft_ms', 0)
warm_wall = warm.get('wall_ttft_ms', 0)
ttft_speedup = round(cold_wall / warm_wall, 2) if warm_wall > 0 and cold_wall > 0 else 0

result = {
    'size_label': size_label,
    'size_bytes': size_bytes,
    'cold': cold,
    'warm': warm,
    'cache_cold': cache_cold,
    'cache_warm': cache_warm,
    'prompt_eval_speedup': speedup,
    'ttft_speedup': ttft_speedup,
    'cold_prompt_tps': cold.get('prompt_tps', 0),
    'warm_prompt_tps': warm.get('prompt_tps', 0),
    'cold_ppt_ms': cold.get('prompt_per_token_ms', 0),
    'warm_ppt_ms': warm.get('prompt_per_token_ms', 0),
    'cold_gen_ppt_ms': cold.get('predicted_per_token_ms', 0),
    'warm_gen_ppt_ms': warm.get('predicted_per_token_ms', 0),
    'cold_ttft_ms': cold.get('ttft_ms', 0),
    'warm_ttft_ms': warm.get('ttft_ms', 0),
    'cold_wall_ttft_ms': cold.get('wall_ttft_ms', 0),
    'warm_wall_ttft_ms': warm.get('wall_ttft_ms', 0),
}

with open(result_file, 'w') as f:
    json.dump(result, f, indent=2)

print(json.dumps(result))
PYEOF
}

# =============================================================================
# Per-model benchmark
# =============================================================================

run_model_benchmark() {
    local model="$1"
    local extra_flags="$2"
    local backend="$3"

    exec 3>&1 1>&2

    local model_name
    model_name=$(basename "$model" .gguf)
    local out_dir="$BENCH_DIR/$backend/$model_name"
    mkdir -p "$out_dir"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $model_name"
    echo "  Backend: $backend"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local model_start=$SECONDS

    for size_entry in "${PROMPT_SIZES[@]}"; do
        IFS=':' read -r size_label size_bytes <<< "$size_entry"

        run_size_test "$model" "$extra_flags" "$backend" "$out_dir" "$size_label" "$size_bytes" || {
            log_error "Size test $size_label failed for $model_name"
            # Write an error result file so the summary can pick it up
            python3 -c "import json; json.dump({'size_label':'$size_label','error':'test failed'}, open('$out_dir/${size_label}-result.json','w'))"
            continue
        }

        # Show inline result from the result file (not shell variables)
        local result_file="$out_dir/${size_label}-result.json"
        if [[ -f "$result_file" ]]; then
            local speedup warm_state cold_ppt warm_ppt cold_ttft warm_ttft
            speedup=$(python3 -c "import json; print(json.load(open('$result_file')).get('prompt_eval_speedup', 0))" 2>/dev/null || echo 0)
            warm_state=$(python3 -c "import json; print(json.load(open('$result_file')).get('cache_warm',{}).get('cache_state','?'))" 2>/dev/null || echo "?")
            cold_ppt=$(python3 -c "import json; print(json.load(open('$result_file')).get('cold_ppt_ms', 0))" 2>/dev/null || echo 0)
            warm_ppt=$(python3 -c "import json; print(json.load(open('$result_file')).get('warm_ppt_ms', 0))" 2>/dev/null || echo 0)
            cold_ttft=$(python3 -c "import json; print(json.load(open('$result_file')).get('cold_ttft_ms', 0))" 2>/dev/null || echo 0)
            warm_ttft=$(python3 -c "import json; print(json.load(open('$result_file')).get('warm_ttft_ms', 0))" 2>/dev/null || echo 0)
            printf "    -> ${GREEN}%s${NC}: warm=${CYAN}%s${NC} speedup=${MAGENTA}%.1fx${NC} TTFT=${DIM}%s/%sms${NC} eval=${DIM}%.1f/%.1f ms/tok${NC}\n" \
                "$size_label" "$warm_state" "$speedup" "$cold_ttft" "$warm_ttft" "$cold_ppt" "$warm_ppt"
        fi
    done

    # ── Generate per-model summary from result files ─────────────────────
    python3 - "$out_dir" "$model_name" "$backend" "$CTX_SIZE" "$MAX_TOKENS" "$TIMESTAMP" << 'PYEOF'
import json, sys, os, glob

out_dir = sys.argv[1]
model_name = sys.argv[2]
backend = sys.argv[3]
ctx_size = int(sys.argv[4])
max_tokens = int(sys.argv[5])
timestamp = sys.argv[6]

# Collect all result files
results = []
for rf in sorted(glob.glob(os.path.join(out_dir, '*-result.json'))):
    try:
        with open(rf) as f:
            results.append(json.load(f))
    except Exception as e:
        results.append({'error': str(e), 'size_label': os.path.basename(rf)})

summary = {
    'model': model_name,
    'backend': backend,
    'context': ctx_size,
    'max_tokens': max_tokens,
    'timestamp': timestamp,
    'results': results
}

with open(os.path.join(out_dir, 'summary.json'), 'w') as f:
    json.dump(summary, f, indent=2)

# Generate summary.md
md = f'''# {model_name} ({backend})

**Context:** {ctx_size} | **Output tokens/req:** {max_tokens}

## Prompt Cache Performance

| Size | Cold Tok | Cold TTFT | Warm Tok | Warm TTFT | TTFT Speedup | Cold ms/tok | Warm ms/tok | Gen ms/tok | Cache |
|------|----------|-----------|----------|-----------|-------------|-------------|-------------|------------|-------|
'''

for r in results:
    if r.get('error'):
        md += f'| {r.get("size_label", "?")} | - | - | - | - | - | - | - | - | error |\n'
        continue
    c = r.get('cold', {})
    w = r.get('warm', {})
    cw = r.get('cache_warm', {})
    md += f'| {r["size_label"]} | {c.get("prompt_tokens", 0)} | {r.get("cold_ttft_ms", 0)}ms | {w.get("prompt_tokens", 0)} | {r.get("warm_ttft_ms", 0)}ms | {r.get("ttft_speedup", 0)}x | {r.get("cold_ppt_ms", 0)}ms | {r.get("warm_ppt_ms", 0)}ms | {r.get("cold_gen_ppt_ms", 0)}ms | {cw.get("cache_state", "?")} |\n'

md += '''
**Cache states:** `ssd_cold` = restored from SSD after restart, `ssd_warm` = in-memory checkpoint, `miss` = no cache hit
**TTFT** = Time To First Token (server-side prompt eval time)
**TTFT Speedup** = cold TTFT / warm TTFT
'''

with open(os.path.join(out_dir, 'summary.md'), 'w') as f:
    f.write(md)
PYEOF

    local elapsed=$(( SECONDS - model_start ))
    log_ok "$model_name complete in ${elapsed}s"
    echo "  Output: $out_dir/"

    echo "$out_dir/summary.json" >&3
}
# =============================================================================

generate_aggregate() {
    local backend="$1"
    shift
    local summary_files=("$@")

    local agg_file="$BENCH_DIR/$backend/summary.json"
    local agg_md="$BENCH_DIR/$backend/summary.md"

    # Build aggregate JSON
    python3 -c "
import json, sys

models = []
for f in sys.argv[1:]:
    try:
        with open(f, 'r') as fh:
            models.append(json.load(fh))
    except:
        pass

with open('$agg_file', 'w') as f:
    json.dump({'backend': '$backend', 'timestamp': '$TIMESTAMP', 'models': models}, f, indent=2)
" "${summary_files[@]}"

    # Build aggregate markdown
    python3 - "$agg_file" "$agg_md" << 'PYEOF'
import json, sys

agg_file = sys.argv[1]
agg_md = sys.argv[2]

with open(agg_file, 'r') as f:
    data = json.load(f)

ctx_size = data.get('context', '?')

md = f'''# Benchmark Results: {data['backend'].upper()}

**Date:** {data['timestamp']} | **Context:** {ctx_size}

## TTFT Speedup by Size

| Model | Small (1K tok) | Medium (5K tok) | Large (15K tok) |
|-------|---------------|-----------------|-----------------|
'''

for m in data['models']:
    row = [m['model']]
    for label in ['small', 'medium', 'large']:
        found = [r for r in m['results'] if r.get('size_label') == label]
        if found:
            ttft_speedup = found[0].get('ttft_speedup', 0)
            eval_speedup = found[0].get('prompt_eval_speedup', 0)
            state = found[0].get('cache_warm', {}).get('cache_state', '?')
            cold_ttft = found[0].get('cold_ttft_ms', 0)
            warm_ttft = found[0].get('warm_ttft_ms', 0)
            row.append(f'TTFT {ttft_speedup}x ({cold_ttft}/{warm_ttft}ms, {state})')
        else:
            row.append('-')
    md += '| ' + ' | '.join(row) + ' |\n'

md += '''
**TTFT Speedup** = cold TTFT / warm TTFT (higher is better)
**Format:** TTFT speedup (cold_ms/warm_ms, cache_state)
**Cache states:** `ssd_cold` = restored from SSD after restart, `ssd_warm` = in-memory cache, `miss` = no hit

## Per-Model Detail
'''

for m in data['models']:
    md += f'''
### {m['model']}

| Size | Cold TTFT | Warm TTFT | TTFT Speedup | Cold ms/tok | Warm ms/tok | Gen ms/tok | Cache |
|------|-----------|-----------|-------------|-------------|-------------|------------|-------|
'''
    for r in m['results']:
        if r.get('error'):
            md += f'| {r.get("size_label", "?")} | - | - | - | - | - | - | error |\n'
            continue
        cw = r.get('cache_warm', {})
        md += f'| {r["size_label"]} | {r.get("cold_ttft_ms", 0)}ms | {r.get("warm_ttft_ms", 0)}ms | {r.get("ttft_speedup", 0)}x | {r.get("cold_ppt_ms", 0)}ms | {r.get("warm_ppt_ms", 0)}ms | {r.get("cold_gen_ppt_ms", 0)}ms | {cw.get("cache_state", "?")} |\n'

with open(agg_md, 'w') as f:
    f.write(md)

print(f'Aggregate written to {agg_md}')
PYEOF
}

# =============================================================================
# Download source text
# =============================================================================

fetch_source_text() {
    mkdir -p "$SCRATCH_DIR"

    if [[ -f "$GUTENBERG_CACHE" ]]; then
        local size
        size=$(wc -c < "$GUTENBERG_CACHE" 2>/dev/null || echo 0)
        if [[ "$size" -gt 100000 ]]; then
            log_ok "Source text cached: $GUTENBERG_CACHE ($size bytes)"
            return 0
        fi
    fi

    log_info "Downloading source text from Project Gutenberg..."
    if curl -sL --max-time 120 -o "$GUTENBERG_CACHE" "$GUTENBERG_URL"; then
        local size
        size=$(wc -c < "$GUTENBERG_CACHE" 2>/dev/null || echo 0)
        log_ok "Downloaded: $size bytes"
    else
        log_error "Failed to download source text"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Tests SSD prompt caching performance using direct API calls at 3 prompt sizes
(small ~1K, medium ~5K, large ~15K tokens) in cold and warm cache states.

Prompts use public domain text from The Count of Monte Cristo (Project Gutenberg).

OPTIONS:
    --backend BACKEND   Backend: rocm, vulkan, metal, or both (default: vulkan)
    --port PORT         Server port (default: 9090)
    --ctx SIZE          Context size (default: 32768)
    --ngl LAYERS        GPU layers (default: 99)
    --tokens N          Max output tokens per request (default: 128)
    --model MODEL       Test specific model only
    --help              Show this help

OUTPUT:
    benchmarks/YYYYMMDD-HHMM/
    ├── vulkan/
    │   ├── ModelName/
    │   │   ├── server-{size}-{cold,warm}.log    # Server logs
    │   │   ├── {size}-{cold,warm}-response.json  # API responses
    │   │   ├── summary.json                     # Machine-readable
    │   │   └── summary.md                       # Human-readable
    │   └── summary.json / summary.md            # Aggregate
    └── rocm/ ...

EXAMPLES:
    $(basename "$0")                                    # Test all models on vulkan
    $(basename "$0") --backend vulkan --model GLM-4.7-Flash-Q4_K_M.gguf
    $(basename "$0") --backend both --model Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf

EOF
}

# Parse args
BACKEND="vulkan"
TEST_MODEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            BACKEND="$2"; shift 2 ;;
        --port)
            PORT="$2"; shift 2 ;;
        --ctx)
            CTX_SIZE="$2"; shift 2 ;;
        --ngl)
            NGL="$2"; shift 2 ;;
        --tokens)
            MAX_TOKENS="$2"; shift 2 ;;
        --model)
            TEST_MODEL="$2"; shift 2 ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            usage; exit 1 ;;
    esac
done

[[ "$BACKEND" != "rocm" && "$BACKEND" != "vulkan" && "$BACKEND" != "metal" && "$BACKEND" != "both" ]] && { log_error "Invalid backend: $BACKEND"; usage; exit 1; }

echo ""
echo "========================================"
echo "  Prompt Cache Benchmark"
echo "  Backend: $BACKEND"
echo "  Context: $CTX_SIZE"
echo "  Sizes: ${#PROMPT_SIZES[@]} (small, medium, large)"
echo "  Source: The Count of Monte Cristo (Gutenberg)"
echo "  Output: $BENCH_DIR"
echo "========================================"
echo ""

# Ensure source text is available
fetch_source_text || exit 1

# Check binaries
for be in rocm vulkan metal; do
    if [[ "$BACKEND" == "both" ]] || [[ "$BACKEND" == "$be" ]]; then
        bin_dir=$(get_binary "$be")
        if [[ ! -f "$bin_dir/llama-server" ]]; then
            log_error "$be binary not found: $bin_dir/llama-server"
            log_info "Run: ./mac.sh or ./scripts/rebuild.sh"
            exit 1
        fi
        log_ok "$be binary: $bin_dir/llama-server"
    fi
done

# Filter models if specific one requested
[[ -n "$TEST_MODEL" ]] && MODELS=("$TEST_MODEL")

# Ensure clean state
trap 'stop_server' EXIT

# Run benchmarks
for be in rocm vulkan metal; do
    if [[ "$BACKEND" == "both" ]] || [[ "$BACKEND" == "$be" ]]; then
        mkdir -p "$BENCH_DIR/$be"

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  $be backend"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        summaries=()

        for model_entry in "${MODELS[@]}"; do
            IFS=':' read -r model extra_flags <<< "$model_entry"

            if [[ ! -f "$MODEL_DIR/$model" ]]; then
                log_warn "Skipping $model (not found)"
                continue
            fi

            summary=$(run_model_benchmark "$model" "$extra_flags" "$be") || {
                log_error "Benchmark failed for $model on $be"
                continue
            }
            summaries+=("$summary")
        done

        if [[ ${#summaries[@]} -gt 0 ]]; then
            generate_aggregate "$be" "${summaries[@]}"
        fi
    fi
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark Complete"
echo "  Results: $BENCH_DIR"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
