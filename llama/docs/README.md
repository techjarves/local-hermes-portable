Local LLM inference on AMD APU hardware. Built around
[CachyLLama](https://github.com/fewtarius/CachyLLama), our fork of
[llama.cpp](https://github.com/ggml-org/llama.cpp), with an SSD-backed
KV cache, agentic workflow tuning, and tight
[CLIO](https://github.com/SyntheticAutonomicMind/CLIO) integration.
Self-contained - no system ROCm install required. Vulkan (RADV) is the
default backend for best stability on RDNA3 iGPUs.

## Introduction

llama-ai is a deployment of CachyLLama aimed at running MoE models
(hybrid and dense) on AMD APUs. The primary target is a Nimo Axis N161 
 (Ryzen AI Max+ 395, Radeon 8060S, 128GB unified memory with
96GB pre-allocated to the APU). It also runs on the Ayaneo Flip KB
(7840U / Radeon 780M / 32GB) and the Minisforum UM580 (5800H / 16GB),
and any other AMD APU in the supported detection map.

Profiles scale automatically with the APU's VRAM carveout via
`LLAMA_HARDWARE_TIER` (`handheld` / `standard` / `halo`): halo gets
192K-token context on MoE models (fp16 KV) and 196K on GPT-OSS (q8_ KV),
handheld keeps the conservative 64K-token / q8_0 / 6GB settings tuned
for the 780M's 6GB VRAM envelope.

The fork exists so performance work on hybrid architectures (Qwen3.5/3.6,
GLM-4.7, Gemma 4) lives as code in the
[CachyLLama](https://github.com/fewtarius/CachyLLama) git history rather
than as patches layered on releases. The submodule in this repo points
at the fork, not at ggml-org/llama.cpp.

On top of CachyLLama, llama-ai adds:

- SSD-backed KV cache that survives reboots and power outages, with
  hot/warm/cold tiering and a global system prompt cache
- CLIO integration tuned for cache reuse across agentic turns
  (deterministic JSON serialization, slot affinity, per-user isolation)
- Auto GPU and CPU ISA detection for AMD APUs across generations
- A benchmarking harness for measuring prompt-eval speedup
- Auto-profile model selection and a runner that strips reasoning
  blocks to keep prompt tokens small

## Why

The goal is reasonably-performing agentic AI development on AMD APU
hardware - usable when there is no network. No API keys, no per-token
costs, no cloud dependency. Primary target is the Strix Halo "max"
platform (Ryzen AI Max+ 395 / Radeon 8060S / 96GB APU VRAM / 128GB
total). Also runs well on the [Ayaneo Flip KB](https://ayaneo.com/product/AYANEO-FLIP-KB)
(7840U / 32GB) and similar Zen 4 APUs.

[CLIO](https://github.com/SyntheticAutonomicMind/CLIO) is optimized for this implementation. It serializes tool definitions with deterministic JSON key ordering and reuses conversation state to maximize cache hits across agentic turns. System prompts, tool descriptions, and compressed context - the static content sent on every API call - are cached and persisted to disk so they're available immediately on the next request.

## Table of contents

- [Introduction](#introduction)
- [Why](#why)
- [Quick start](#quick-start)
- [Backends](#backends)
  - [Vulkan (Linux/AMD)](#vulkan-linuxamd)
  - [ROCm (Linux/AMD)](#rocm-linuxamd)
  - [Metal (macOS)](#metal-macos)
- [GPU memory](#gpu-memory)
- [GPU detection](#gpu-detection)
  - [CPU ISA detection](#cpu-isa-detection)
- [Usage](#usage)
- [How it works](#how-it-works)
  - [Auto-profiling](#auto-profiling)
  - [KV cache](#kv-cache)
    - [Hot/warm/cold tiering](#hotwarmcold-tiering)
    - [Search strategy](#search-strategy)
    - [System prompt cache](#system-prompt-cache)
    - [Kernel readahead](#kernel-readahead)
  - [User isolation](#user-isolation)
  - [MoE expert tracking](#moe-expert-tracking)
- [Benchmarking](#benchmarking)
  - [Test methodology](#test-methodology)
  - [Results](#results)
  - [Running the benchmark](#running-the-benchmark)
  - [Output](#output)
- [Real-world CLIO performance](#real-world-clio-performance)
  - [Workload profile](#workload-profile)
  - [Test scenario](#test-scenario)
  - [Results - cold start](#results-cold-start-no-cache)
  - [Results - warm restart](#results-warm-restart-cache-populated)
  - [Takeaways](#takeaways)
- [What CachyLLama adds](#what-cachyllama-adds)
- [Structure](#structure)
- [License](#license)

## Quick start

```bash
git clone --recurse-submodules https://github.com/fewtarius/llama-ai.git
cd llama-ai

# Build Vulkan backend (default)
./scripts/rebuild.sh

# Drop a GGUF model in models/, then:
./llama-run.sh --server
# -> http://localhost:9090
```

## Backends

### Vulkan (Linux/AMD)

Default backend. Uses the Mesa RADV driver - no ROCm install required. Best stability on RDNA3 iGPUs (Phoenix, Hawk Point, Strix Point) and earlier GCN/RDNA generations. CPU offloading works for models that don't fit in GPU memory.

### ROCm (Linux/AMD)

Optional. Has known stability issues on some architectures - GLM-4.7-Flash and DeepSeek2 MLA models produce zero generation tokens on RDNA3. Use Vulkan unless you have a specific reason to try ROCm.

### Metal (macOS)

Apple Silicon (M1/M2/M3/M4) and Intel Macs with Metal-capable GPUs. Build with `./scripts/rebuild.sh` on macOS - it auto-detects the platform and builds the Metal backend.

## GPU memory

AMD APUs share system RAM with the GPU. Use `apply-ttm-kernel-params.sh`
to configure GTT:

```bash
# Phoenix/Hawk Point: cap firmware VRAM at 6GB, add 18GB GTT
sudo ./scripts/apply-ttm-kernel-params.sh 18

# Nimo Axis N161 (Strix Halo): 128GB, 96GB BIOS-allocated VRAM carveout,
# 32GB to OS. No GTT configuration needed — just run with defaults
# (vis_vramlimit is skipped entirely so the BIOS allocation is preserved)
sudo ./scripts/apply-ttm-kernel-params.sh
sudo reboot
```

Writes kernel parameters (`amdgpu.gttsize`, `amdgpu.vis_vramlimit`,
`ttm.pages_limit`) to your bootloader config. Also calls `amd-smi set -G`
as a runtime hint, but kernel parameters are the authoritative method
that persists across reboots.

Supports GRUB (SteamFork 3.7) and systemd-boot (SteamFork 3.8+). Tested
on JELOS - should work with any distro that exposes the AMD GPU through
sysfs and supports `amdgpu.vis_vramlimit` / `amdgpu.gttsize` kernel
parameters (i.e. most modern Linux distributions with a 6.x kernel).

GTT size and `vis_vramlimit` default to tier-aware values:

| Tier    | Examples                  | vis_vramlimit | GTT      |
|---------|---------------------------|---------------|----------|
| handheld| 780M, 890M (Phoenix/Hawk) | 6GB           | RAM-6GB  |
| standard| 16-32GB APU VRAM          | 16GB          | 8GB      |
| halo    | 8060S (Strix Halo, Nimo Axis N161) | not set | 4GB    |

The `halo` tier skips `vis_vramlimit` because the BIOS carveout
(typically 96GB) must be preserved - capping it would shrink the
addressable VRAM. Override with `VIS_VRAM_LIMIT_MB` env var or the
first positional argument.

Verify after reboot:
```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E "amdgpu|ttm"
```

## GPU detection

Auto-detects AMD GPU via PCI device ID and sets `HSA_OVERRIDE_GFX_VERSION`
for ROCm.

Supported: Cezanne (5800H), Phoenix (780M), Hawk Point (890M/780M),
Strix Point (890M/880M), Strix Halo (8060S), Sephiroth, Rembrandt
(680M/660M), Mendocino (610M), Renoir, Lucienne. Falls back to
`amd-smi` for authoritative detection when PCI IDs are ambiguous
(e.g. Cezanne and Van Gogh share the same PCI ID). To add your device,
edit the `GPU_MAP` in `scripts/detect-gpu.sh`.

Override detection:
```bash
LLAMA_GFX_VERSION_OVERRIDE=11.0.3 ./llama-run.sh --server
```

### CPU ISA detection

`detect-gpu.sh` also detects the CPU ISA level and generates optimal cmake flags:

| CPU | ISA Level | CMake Flags |
|-----|-----------|-------------|
| Zen 4 (7840U) | avx512_bf16 | `-DGGML_AVX512=ON -DGGML_AVX512_BF16=ON -DGGML_AVX512_VNNI=ON` |
| Zen 3 (5800H) | avx2 | `-DGGML_AVX2=ON -DGGML_AVX=ON -DGGML_FMA=ON` |
| Apple Silicon | apple_silicon | (none - ARM NEON auto-detected) |

Previously, the Vulkan build was compiled with `GGML_NATIVE=OFF` and `GGML_AVX512=OFF`, leaving AVX-512 code paths compiled out on Zen 4 hardware that supports them. This cost 5-15% generation speed on Vulkan and 30-100% on CPU-offloaded layers. Now `rebuild.sh` uses `$LLAMA_CMAKE_CPU_FLAGS` to enable the right ISA level.

Override:
```bash
LLAMA_CPU_ISA_OVERRIDE=avx2 ./scripts/rebuild.sh
```

## Usage

```bash
# List models found in models/
./llama-run.sh --list-models

# Start server (auto-detects model, Vulkan backend)
./llama-run.sh --server

# Specific model and backend
./llama-run.sh --server gemma-4-26b --backend vulkan

# Download a model
./llama-run.sh --download Qwen3-14B --quant Q4_K_M

# List available backends
./llama-run.sh --list-backends

# Rebuild options
./scripts/rebuild.sh              # Vulkan only (default)
./scripts/rebuild.sh --rocm       # ROCm only
./scripts/rebuild.sh --both       # Vulkan + ROCm
./scripts/rebuild.sh --rebuild    # Full rebuild from scratch
```

Reasoning models (DeepSeek-R1, Qwen3.6, GLM-4.7) emit thinking blocks before each response. By default the runner strips these from prior assistant messages in the conversation history so they don't waste prompt tokens. To preserve them across turns (some workflows benefit from this), pass `--preserve-reasoning`. The `--reasoning-budget N` flag caps thinking tokens per response (default: 2048) to prevent runaway generation.

## How it works

### Auto-profiling

Models are auto-profiled based on filename characteristics. MoE models get checkpoint strategies and reasoning format; SSM/Mamba models get context-shift disabled; large dense models get optimized batch sizes. Profiles are assigned dynamically - no hard-coded model names. The profile name is logged at server startup (e.g. `Auto profile: moe-optimized (20GB, MoE=true, SSM=false)`).

### KV cache

SSD-backed KV cache persists conversation state across server restarts. Enabled by default for all non-SSM models. The cache directory is `kv-cache/`. When a `user_id` is supplied (see [User isolation](#user-isolation)), checkpoints route to a separate `kv-cache/u/` namespace.

#### Hot/warm/cold tiering

The cache has three tiers with automatic promotion and demotion:

- **Hot tier** - Checkpoints from the current session, kept in RAM. Instant restore when the same conversation continues. After 2 turns of inactivity, hot checkpoints are demoted to warm.
- **Warm tier** - Checkpoints from previous sessions in the same server run. In RAM until memory pressure forces demotion to cold. After 4 turns of inactivity, warm checkpoints are demoted to cold.
- **Cold tier** - On-disk checkpoints with token prefixes. Survives server restarts. Each conversation gets up to the ring buffer limit of cold checkpoints on disk. When the limit is exceeded, the oldest cold checkpoint is deleted. Up to 16 conversations are tracked simultaneously (configurable with `--cache-ssd-max-conversations`).

#### System prompt cache

The system prompt cache is a global (cross-conversation) cache that stores the system section of any prompt after first evaluation. On cold start - server restart, first request, or a model that has not been seen before - the server checks the system prompt cache before falling through to full evaluation. A hit returns the cached state directly, skipping the entire system prompt re-eval.

The cache lives at `{kv-cache-path}/{model-stem}/sys-{hash}.bin`. Entries are keyed by the first N tokens of the prompt (the system section) and stored with a model compatibility hash that rejects mismatches on load. Default: 8 entries per model, 30 days unused before expiry. Override with `--cache-ssd-system-prompts N` and `--cache-ssd-system-max-days N`.

The system prompt cache works for both standard transformer and hybrid (MoE/SSM) models. For hybrid architectures, the recurrent state is stored per-position in the state file, so a state saved after processing the full prompt can be restored with `n_past` capped to the system prompt boundary - the inference engine reads the cell at that position regardless of how many tokens came after.

#### Search strategy

When an API request arrives, the server searches for a matching checkpoint in three stages:

1. **Same-conversation** (Tier 1) - Matches by conversation hash (`conv_hash`), a FNV-1a hash of the first 1024 task tokens. This finds the checkpoint from a previous turn of the same conversation. Fast, accurate, and the most common hit path.

2. **Shared prefix** (Tier 2) - Cross-conversation match using `n_past` (the common prefix length). This reuses cached system prompt evaluation across different conversations with the same model. Works because the first N tokens are identical - tool definitions, system instructions, etc.

3. **Cold-start token prefix** (Tier 3) - Used on server restart when `n_past == 0`. The server compares the prompt's first tokens against every checkpoint's stored token prefix (up to 4096 tokens per checkpoint). This has two phases:
   - **Chain match** - Same conversation, full prefix matches. The largest checkpoint from the same conversation is preferred, even if it's large - the recurrent state is content-accurate.
   - **Safe match** - Cross-conversation or partial prefix. Only checkpoints whose `n_tokens` fits within the common prefix (LCP) are considered. This avoids restoring recurrent state computed from different conversation content.

Overflow handling differs by match type. Same-conversation checkpoints (Tier 1 and Tier 3 chain) skip size and staleness checks entirely - the recurrent state is content-accurate, so any same-conv checkpoint is valid. If the checkpoint covers more tokens than the current task, `n_past` is capped in the restore layer to leave room for new token evaluation instead of resetting. Cross-conversation matches (Tier 2 and Tier 3 safe) skip oversized checkpoints at the search layer, since the recurrent state was computed from different conversation content.

Each checkpoint is stored as a separate file (`ckpt-N.bin`) in `kv-cache/{conv_hash}/` with metadata in `index.bin`. Turn tracking survives server restarts - the next turn counter is seeded from the maximum turn ID found on disk, so warm-tier entries from a previous server run start aging from turn 0 of the new run rather than being immediately demoted.

Every checkpoint carries:
- `conv_hash` - Conversation identity (first 1024 tokens)
- `compat_hash` - Model configuration hash (architecture, dimensions, cache types). Checkpoints with mismatched compat hashes are rejected, preventing silent corruption when switching between models.
- `token_prefix` - First 4096 tokens for cold-start prefix matching
- `turn_id` - Tracks when the checkpoint was last accessed for tier management

#### Kernel readahead

When a cold checkpoint is identified for loading, the server issues `posix_fadvise(POSIX_FADV_WILLNEED)` on Linux (or `readahead()` on macOS) to trigger kernel page cache prefetch. This overlaps SSD I/O with CPU work (token matching, state restoration setup) and reduces cold TTFT by ~0.5-0.75s for typical checkpoint sizes.

#### What happens on cache hit

The KV cache (attention state) and recurrent state (for hybrid MoE models) are restored from the checkpoint. Only tokens beyond the checkpoint's coverage need evaluation. A 18-30K-token prompt might need just a handful of new tokens evaluated - the rest is restored from disk in 1-5 seconds depending on checkpoint size.

The cache is persisted automatically after each turn. No manual management needed.

### User isolation

Multi-tenant deployments need isolation between users sharing the same server. This fork adds three dimensions of isolation:

#### Identity

The `user_id` field is a first-class request parameter. Pass it in the request body:

```json
{
  "model": "...",
  "messages": [...],
  "llama_user_id": "tenant-42-user-7"
}
```

OpenAI SDK callers pass it through `extra_body`:

```python
client.chat.completions.create(
    model="...",
    messages=[...],
    extra_body={"llama_user_id": "tenant-42-user-7"},
)
```

Validated to `^[a-zA-Z0-9\-_]+$` with a 512-char ceiling. Empty string is valid (anonymous bucket).

#### KV cache routing

When `user_id` is present, the SSD page manager routes checkpoints to a separate `u/` namespace on disk:

```
{ssd_path}/{hash_hex}/    # anonymous (conv_hash)
{ssd_path}/u/{hash_hex}/  # user-scoped (fnv1a(user_id))
```

Cross-user lookup is disabled for user-scoped requests. A user can only access their own cached state, never another user's directory.

#### Scheduling isolation

`--max-concurrent-per-user N` caps the number of simultaneous slots a single user_id can occupy. When the cap is hit, the server returns HTTP 429 with a `rate_limit_error` type:

```json
{
  "error": {
    "code": 429,
    "message": "per-user concurrency cap reached for user_id=tenant-42-user-7",
    "type": "rate_limit_error"
  }
}
```

Slot allocation also prefers slots already owned by the requesting user (cache affinity). An empty slot (post-release) is fair game for any user.

Default: 0 (unlimited). Set to 1 for strict one-at-a-time, or 2-3 for concurrent with backpressure.

Design rationale: [`docs/development/user-isolation-design.md`](CachyLLama/docs/development/user-isolation-design.md)

### MoE expert tracking

MoE models (Qwen3.5/3.6, Gemma 4, GLM-4.7) activate only a subset of experts per token. This fork adds real-time expert activation tracking via two HTTP endpoints:

#### GET /expert-stats

Returns per-layer expert activation counts, frequencies, and token counts:

```json
{
  "n_expert": 256,
  "n_expert_used": 8,
  "total_tokens": 1500,
  "tracking_enabled": true,
  "layers": [
    {
      "layer": 0,
      "activations": [
        {"expert": 42, "count": 150, "frequency": 0.0125},
        {"expert": 7, "count": 148, "frequency": 0.0123},
        ...
      ]
    },
    ...
  ]
}
```

#### POST /expert-tracking

Enable/disable tracking and optionally reset counters:

```json
{"enabled": true, "reset": true}
```

This is Phase 1 of the MoE expert tiering design - instrumentation only, no compute changes. Future phases will use this data to reorder experts for cache locality and offload cold experts to RAM/SSD.

## Benchmarking

The bottleneck in agentic AI isn't generation speed (the model produces tokens as fast as the GPU allows). The bottleneck is **prompt evaluation** - reprocessing the entire prompt before the model can generate its first token.

Every API call in an agentic workflow sends static content: system prompt, tool definitions, prior conversation context. Without caching, this content is re-evaluated from scratch on every single call. An 18-30K-token prompt means it could be several minutes before the model starts responding on an APU like the 780M. With SSD cache and a 17,800-token prefix hit, only the divergent tail of the prompt is evaluated - typically a few seconds when only the latest tool result is new.

### Test methodology

Real agentic workloads send 12-20K tokens of system prompt and tool definitions on every API call, growing to 32-64K tokens with compressed conversation context. Every token is re-evaluated from scratch without caching.

The benchmark uses scaled-down prompts to demonstrate cache mechanics and prove the speedup is real. The same principles apply at production sizes - speedup ratios increase with prompt length.

| Size | Tokens | What it measures |
|------|--------|-----------------|
| Small | ~1,100 | Cache overhead and baseline speedup |
| Medium | ~5,200 | Checkpoint matching and partial restore |
| Large | ~15,500 | Full checkpoint restore with large prefix |

Each size runs twice:

1. **Cold** - Empty cache, server starts fresh. The entire prompt is evaluated from scratch.
2. **Warm** - Server restarts with existing SSD cache. The server restores the matching checkpoint from disk and evaluates only the delta.

The key metric is **TTFT** (Time To First Token) - how long before the model starts generating. Generation speed doesn't change with caching (same model, same hardware). What changes is the wait before generation begins.

### Results

Benchmarks run on the Strix Halo "max" platform (Ryzen AI Max+ 395,
Radeon 8060S, 96GB APU VRAM) and the Ayaneo Flip
KB (7840U / 780M / 32GB / Vulkan). Both use the same Vulkan backend
(Mesa RADV) and the same SSD cache machinery - the only thing that
changes is the underlying compute, memory, and context size.

#### Strix Halo (Nimo Axis N161)

Radeon 8060S, 96GB APU VRAM, 128 output tokens, all GPU layers.
Benchmark data:
[GPT-OSS-120B Q8_K_XL](benchmarks/20260625-1849/) (ctx 131072),
[Nemotron-3-Super-120B Q4_K_XL](benchmarks/20260628-1506/) (ctx 32768),
[all Strix Halo models below](benchmarks/20260626-1836/) (ctx 131072-196608).

| Model | Size | Cold TTFT | Warm TTFT | Speedup | Cached |
|-------|------|-----------|-----------|---------|--------|
| GPT-OSS-120B Q8_K_XL (120B MoE, 128 experts) | small (~1.2K) | 2.5s | 0.21s | **12.1x** | 1201/1205 |
| | medium (~5.2K) | 9.0s | 0.62s | **14.6x** | 5246/5250 |
| | large (~15.4K) | 27.9s | 1.46s | **19.2x** | 15376/15380 |
| NVIDIA-Nemotron-3-Super-120B-A12B Q4_K_XL (120B MoE, 12B active) | small (~1.5K) | 7.7s | 0.32s | **24.1x** | 1453/1457 |
| | medium (~6.3K) | 25.3s | 0.36s | **70.2x** | 6248/6252 |
| | large (~17.8K) | 71.6s | 0.49s | **145.2x** | 17806/17810 |
| gpt-oss-20b Q6_K_XL (20B dense, ctx 131072) | small (~1.2K) | 1.1s | 0.04s | **28.9x** | 1201/1205 |
| | medium (~5.2K) | 3.7s | 0.09s | **42.4x** | 5246/5250 |
| | large (~15.4K) | 12.4s | 0.16s | **79.1x** | 15376/15380 |
| GLM-4.7-Flash Q8_K_XL (30B MoE, 3B active) | small (~1.1K) | 1.5s | 0.18s | **8.5x** | 1141/1145 |
| | medium (~5.2K) | 8.0s | 0.38s | **20.7x** | 5233/5237 |
| | large (~15.5K) | 39.0s | 1.08s | **36.0x** | 15485/15489 |
| Qwen3.6-35B-A3B Q8_K_XL (35B MoE hybrid, 3B active) | small (~1.2K) | 2.2s | 0.16s | **14.2x** | 1239/1243 |
| | medium (~5.4K) | 6.9s | 0.25s | **27.6x** | 5405/5409 |
| | large (~15.7K) | 19.7s | 0.56s | **35.0x** | 15717/15721 |
| gemma-4-26B-A4B Q5_K_M (26B MoE, 4B active) | small (~1.4K) | 1.5s | 0.07s | **21.4x** | 1409/1413 |
| | medium (~6.1K) | 7.7s | 0.08s | **92.3x** | 6079/6083 |
| | large (~17.3K) | 22.9s | 0.12s | **185.8x** | 17343/17347 |
| Qwen3.6-27B Q8_K_XL (27B dense) | small (~1.2K) | 6.6s | 0.42s | **15.8x** | 1239/1243 |
| | medium (~5.4K) | 22.8s | 0.50s | **45.5x** | 5405/5409 |
| | large (~15.7K) | 66.6s | 1.14s | **58.4x** | 15717/15721 |

Speedup is **prompt eval speedup** (cold prompt_ms / warm prompt_ms) -
the pure measure of cache effectiveness, excluding server restart and
generation time. Cached shows tokens restored from SSD / total tokens.
All warm runs restore from SSD (`ssd_warm` cache state; warm-tier
in-memory checkpoints after server restart).

Cold prompt eval at full TDP: 188-1,433 t/s across models. MoE models
evaluate at 189-1,433 t/s (0.7-5.3 ms/tok) with 3-12B parameters
active per token. The dense Qwen3.6-27B Q8 evaluates at 188-236 t/s
(4.2-5.3 ms/tok) - every token goes through all 27B parameters.
Generation speed: 8-58 t/s for MoE models; 5 t/s for the dense 27B.
The warm path is SSD-bound - Q8/Q4 checkpoints are
large but the absolute warm TTFT stays under 1.2s for all models at
all sizes.
gpt-oss-20b Q6 is the fastest model tested: 1,084-1,433 t/s cold eval
and 31-58 t/s generation. Its small 20B parameter count means every
token is cheap.
The hybrid MoE architectures (Qwen3.6, GLM-4.7-Flash) restore both
attention KV state and recurrent state
from disk - Mamba layers are checkpoint-aware and the cache works
across restarts. GPT-OSS-120B, Nemotron-3-Super-120B, and gpt-oss-20b are dense architectures (no hybrid layers):
`cache_reuse` is not supported but the SSD checkpoint machinery works
identically. GPT-OSS-120B Q8_K_XL is a 2-file split GGUF, Nemotron-3-Super-120B Q4_K_XL is a 3-file split. The benchmark
loads only part 00001; the remaining files provide tensor data loaded on demand during inference.

#### Halo caching strategy

The Strix Halo's 96GB APU VRAM carveout changes the caching tradeoff
versus memory-constrained APUs (Ayaneo Flip KB: 6GB VRAM + 18GB GTT).
A 35B MoE with 192K context at f16 KV uses ~50GB - comfortably within
the 96GB ceiling with headroom for the in-memory prompt cache and the
working set. The SSD cache serves two purposes:

1. **System prompt cache** (cross-restart) - the global cache at
   `{ssd-path}/{model-stem}/sys-{hash}.bin`. One entry per distinct
   system prompt, restores 15-18K tokens in 0.5s. This is the
   warm-path win on cross-restart.
2. **Eviction insurance** - if a single chat thread grows past what
   VRAM can hold, on-disk checkpoints step in. Rare on Halo with
   96GB VRAM, but the guard is there.

Halo uses a lean checkpoint strategy: `--checkpoint-every-n-tokens
16384` (one checkpoint per typical system prompt), `--ctx-checkpoints
8`, `--cache-ssd-checkpoints 8`. The in-memory prompt cache
(`--cache-ram 16384`, 16GB) is the primary cache layer for warm
within-server restarts — SSD is the cross-restart persistence layer.

#### Ayaneo Flip KB

Radeon 780M, 6GB VRAM + 18GB GTT, ctx 32768, 128 output tokens, all
GPU layers. [Full per-test data](benchmarks/20260611-0656/).

#### GLM-4.7-Flash (Q4_K_M, 30B MoE, 3B active)

| Size | Tokens | Cold TTFT | Warm TTFT | Speedup | Gen TPS |
|------|--------|-----------|-----------|---------|---------|
| Small | ~1,145 | 9.7s | 0.34s | 28.4x | 20.2 |
| Medium | ~5,237 | 74.2s (1.2min) | 1.0s | 72.7x | 12.1 |
| Large | ~15.5K | 467.6s (7.8min) | 2.7s | 174.1x | 5.7 |

Cold prompt eval: 33.1-117.6 t/s. Cached: 15,485/15,489 tokens at large size (4 tokens evaluated on warm).

#### Gemma 4 26B (Q5_K_M, 26B MoE, 4B active)

| Size | Tokens | Cold TTFT | Warm TTFT | Speedup | Gen TPS |
|------|--------|-----------|-----------|---------|---------|
| Small | ~1,413 | 8.5s | 0.71s | 12.0x | 16.2 |
| Medium | ~6,083 | 38.0s | 0.97s | 39.2x | 15.3 |
| Large | ~17.3K | 130.9s (2.2min) | 1.4s | 92.9x | 13.8 |

Cold prompt eval: 132.6-165.6 t/s. Cached: 17,343/17,347 tokens at large size (4 tokens evaluated on warm).

#### Qwen3.6-35B (Q4_K_XL, 35B MoE hybrid, 3B active)

| Size | Tokens | Cold TTFT | Warm TTFT | Speedup | Gen TPS |
|------|--------|-----------|-----------|---------|---------|
| Small | ~1,243 | 9.3s | 0.41s | 23.0x | 21.7 |
| Medium | ~5,409 | 43.3s | 0.57s | 76.2x | 20.5 |
| Large | ~15.7K | 143.1s (2.4min) | 0.99s | 144.5x | 18.6 |

Cold prompt eval: 109.9-133.4 t/s. Cached: 15,717/15,721 tokens at large size (4 tokens evaluated on warm).
35B parameters with only 3B active keeps the eval rate high. The SSD cache restores both attention KV state and recurrent state from disk - the hybrid architecture's Mamba layers are checkpoint-aware and restore correctly across restarts.

#### Summary

Strix Halo (top row per model) vs Ayaneo Flip KB (bottom row), large
prompt only. All Strix Halo numbers use prompt eval speedup (not
wall-clock). Data from
[Strix Halo full suite](benchmarks/20260626-1836/),
[GPT-OSS-120B Q8](benchmarks/20260625-1849/), and
[Nemotron-3-Super-120B Q4](benchmarks/20260628-1506/).

| Model | Strix Halo cold | Strix Halo warm | Strix speedup | Flip cold | Flip warm | Flip speedup |
|-------|----------------:|----------------:|--------------:|----------:|----------:|-------------:|
| GLM-4.7-Flash Q8 | 39.0s | 1.08s | **36.0x** | 467.6s (7.8min) | 2.7s | 174.1x |
| Qwen3.6-35B Q8 | 19.7s | 0.56s | **35.0x** | 143.1s (2.4min) | 1.0s | 144.5x |
| gemma-4-26B Q5 | 22.9s | 0.12s | **185.8x** | 130.9s (2.2min) | 1.4s | 92.9x |
| gpt-oss-20b Q6 | 12.4s | 0.16s | **79.1x** | --- | --- | --- |
| GPT-OSS-120B Q8 | 27.9s | 1.46s | **19.2x** | --- | --- | --- |
| Nemotron-3-Super-120B Q4 | 71.6s | 0.49s | **145.2x** | --- | --- | --- |

The Strix Halo's 8060S evaluates MoE prompts 5-20x faster than the
780M, so absolute warm-cache TTFT is much smaller. The cache
saves 17-68 seconds per turn on the Strix Halo in long-context
agentic workloads. GPT-OSS-120B Q8 and Nemotron-3-Super-120B Q4 are the largest models tested at 120B
parameters each. GPT-OSS-120B (128 experts) runs comfortably in 96GB VRAM at 131K context
with q8_0 KV cache
(61GB model + 3.7GB KV + 16GB cache-ram = 80.7GB). Qwen3.6-35B Q8 and
GLM-4.7 Q8 run at 196K context: 35GB model + 16GB KV cache-ram ~51GB
total, leaving 45GB for generation batch buffers and concurrent slots.
gpt-oss-20b Q6 is a 20B dense model, the smallest tested at only 17GB -
the fastest cold eval (1,084-1,433 t/s) and generation (31-58 t/s) in
this benchmark.

Full benchmark data (server logs, API responses, timing stats):
[Ayaneo Flip KB](benchmarks/20260611-0656/),
[Strix Halo full suite](benchmarks/20260626-1836/),
[Strix Halo GPT-OSS-120B Q8](benchmarks/20260625-1849/),
[Strix Halo Nemotron-3-Super-120B Q4](benchmarks/20260628-1506/).

### Running the benchmark

```bash
# Full benchmark: all models, Vulkan backend
./scripts/benchmark.sh

# Single model
./scripts/benchmark.sh --model GLM-4.7-Flash-Q4_K_M.gguf

# Custom context size
./scripts/benchmark.sh --model gpt-oss-120b-UD-Q8_K_XL.gguf --ctx 196608

# Both backends
./scripts/benchmark.sh --backend both
```

Uses public domain text from The Count of Monte Cristo (Project
Gutenberg), cached locally in `scratch/pg1184.txt`. Each prompt appends
"Summarize this passage in one sentence." to keep generation short
(128 tokens). Models are listed in the `MODELS` array inside
`benchmark.sh` - default models: GLM-4.7-Flash, Qwen3-14B, gemma-4-26B,
Qwen3.5-27B, Qwen3.6-35B.

### Output

```
benchmarks/YYYYMMDD-HHMM/
├── vulkan/
│   ├── GLM-4.7-Flash-Q4_K_M/
│   │   ├── server-small-cold.log       # Server log (cold run)
│   │   ├── server-small-warm.log       # Server log (warm run)
│   │   ├── small-cold-response.json    # Raw API response
│   │   ├── small-cold-stats.json       # Extracted timing stats
│   │   ├── small-warm-response.json
│   │   ├── small-warm-stats.json
│   │   ├── small-result.json           # Cold vs warm comparison
│   │   ├── summary.json               # All sizes aggregated
│   │   └── summary.md                 # Human-readable table
│   └── summary.json / summary.md       # Aggregate across models
└── rocm/ ...
```

## Real-world CLIO performance

[CLIO](https://github.com/SyntheticAutonomicMind/CLIO) sends 18-30K tokens of system prompt, tool definitions, and prior conversation context on every API call. Without KV caching, every turn would re-evaluate the entire prompt from scratch.

Every prompt has two regions: a **static prefix** (~18K tokens - system prompt, tool definitions, initial messages) that's identical across all turns, and a **dynamic tail** (grows to ~12K tokens over the conversation) of tool results and new assistant responses. On each turn, the cache restores the static prefix entirely and whatever portion of the dynamic tail was already evaluated on prior turns. Only the genuinely new content since the last turn needs fresh evaluation.

This is the number that matters for agentic workflows: not generation speed (the model writes as fast as the GPU allows), but **prompt eval time** — how long you wait before the first token arrives.

### Test setup

Same workload across both systems. CLIO with the prompt *"Please evaluate this project and share your opinion of it."* The model reads files, checks git history, runs commands, then writes a final evaluation. Cold server start, no cache populated. Same prompt, same tool set, same model architecture — only the hardware and quantization differ.

### Strix Halo (Nimo Axis N161) — Qwen3.6-35B Q8_K_XL

196K context, 32 threads, Vulkan backend, 120W TDP. Six turns: five tool-calling turns followed by the final evaluation.

| Turn | Prompt tokens | TTFT | Gen t/s | Notes |
|------|---------------|------|---------|-------|
| T0 | 17,396 | 22.2s | 40.5 | Full system prompt + tools + user message. 782 t/s prompt eval (1.28 ms/tok). |
| T1 | 2,081 | 3.9s | 40.6 | Tool result reads. In-memory checkpoint restores static prefix. 533 t/s on tail. |
| T2 | 2,559 | 4.9s | 39.8 | More file reads, git commands. 525 t/s on tail. |
| T3 | 11,798 | 19.2s | 39.1 | Repositions to system prompt area. 616 t/s. |
| T4 | 7,737 | 13.2s | 39.7 | Follow-up reads, terminal commands. 587 t/s. |
| T5 | 11,894 | 19.3s | 38.7 | Writes the project evaluation. 1,070 tokens of analysis. 617 t/s. |

**Total server time: 2 minutes 21 seconds** (53,465 prompt tokens + 2,314 generated). Generation speed holds steady at 38-41 t/s across all six turns. Prompt eval runs 525-782 t/s — the in-memory checkpoint and LCP-based prefix matching restore the cached conversation prefix on every turn. The system prompt cache created a 402.8 MiB entry on T0 (n_sys=17,280 tokens), and SSD checkpoints range from 400-635 MiB per snapshot.

### Ayaneo Flip KB — Qwen3.6-35B Q4_K_XL

65K context, 8 threads, Vulkan backend, 6GB VRAM + 18GB GTT. Seven turns: six tool-calling turns followed by the final evaluation.

| Turn | Prompt tokens | TTFT | Gen t/s | Notes |
|------|---------------|------|---------|-------|
| T0 | 19,311 | 170.6s | 20.2 | Full system prompt + tools + user message. 113 t/s prompt eval (8.84 ms/tok). |
| T1 | 2,755 | 31.3s | 19.9 | Tool result reads. In-memory checkpoint restores static prefix. 88 t/s on tail. |
| T2 | 3,174 | 36.3s | 19.8 | More file reads, git commands. 88 t/s on tail. |
| T3 | 5,779 | 66.4s | 19.0 | Tool result reads, terminal commands. 87 t/s on tail. |
| T4 | 8,744 | 99.9s | 19.1 | Follow-up reads into source scripts. 88 t/s on tail. |
| T5 | 10,218 | 117.5s | 18.9 | Final file reads, git log inspection. 87 t/s on tail. |
| T6 | 490 | 8.1s | 18.6 | Writes the project evaluation. 1,374 tokens of analysis. 60 t/s. |

**Total server time: 11 minutes 19 seconds** (50,471 prompt tokens + 2,846 generated). Generation holds steady at 18.6-20.2 t/s across all seven turns. Prompt eval rate 60-113 t/s — the in-memory checkpoint and LCP-based prefix matching restore the cached conversation prefix on each turn. The T6 drop to 60 t/s is expected: with only 490 new tokens to evaluate, overhead dominates the measurement.

### Ayaneo Flip KB — Qwen3.6-35B Q8_K_XL

Won't fit. The Q8_K_XL quantization is 37 GiB; the Flip's 780M iGPU has 24 GiB of VRAM available and the system has 25.8 GiB of CPU RAM. With Vulkan offloading all layers to the GPU, the model needs ~37 GiB of contiguous device memory — 13 GiB more than available.

### Takeaways

- **Hardware is the difference.** Strix Halo Q8 finishes the same session in 2.4 minutes. The Flip Q4 takes 11.3 minutes. Same model architecture, same prompt, same cache machinery — the difference is the Radeon 8060S (96GB VRAM, 120W) vs the 780M (24GB VRAM, 6-30W).
- **Generation speed is flat across turns.** 38-41 t/s on Halo, 19-20 t/s on Flip. Generation is pure compute — caching doesn't change it, and it's stable from first turn to last.
- **Prompt eval rate is the real differentiator.** Halo Q8: 525-782 t/s. Flip Q4: 60-113 t/s. The Halo's 5-6x lead in prompt eval is what makes agentic work practical — turns complete in seconds instead of minutes.
- **The system prompt cache is the highest-value optimization.** A warm server restart restores the entire ~18K-token system prompt from the global cross-conversation cache. On the Flip, this drops TTFT from ~3 minutes to ~3 seconds on the very first request of every restart — the difference between usable and "go get coffee."
- **Local inference trades latency for privacy and cost.** No API keys, no per-token billing, no network dependency. Usable offline. The cache makes the tradeoff bearable even on lower-end hardware.

## What CachyLLama adds

CachyLLama is a fork of [llama.cpp](https://github.com/ggml-org/llama.cpp)
maintained as a standalone repo
([fewtarius/CachyLLama](https://github.com/fewtarius/CachyLLama)). All
custom changes - performance work, agentic workflow tuning, AMD APU
optimizations - are committed directly to that repo's git history. The
full design lives in [KV cache](#kv-cache), [User
isolation](#user-isolation), and [MoE expert tracking](#moe-expert-tracking).
The high-level changes:

### SSD-backed KV cache

Persistent cross-session KV cache that survives server restarts. Hot/warm/cold tiering with automatic promotion and demotion keeps frequently-used conversation state in RAM while evicting stale entries to disk. Per-conversation ring buffer prevents unbounded disk growth. Three-tier search (same-conversation, shared-prefix, cold-start token prefix) with chain/safe phases for cross-conversation safety. Kernel readahead overlaps SSD I/O with CPU work. Checkpoint overflow prevention handles cases where the saved state covers more tokens than the current task needs. Conversation hash and model compatibility hash prevent mismatched checkpoint restoration. Per-conversation directories (`kv-cache/{conv_hash}/`) let multiple chat threads run in parallel without interference. MLA model support for DeepSeek2/DeepSeek3.

CLI flags: `--cache-ssd`, `--cache-ssd-checkpoints`, `--cache-ssd-hot-window`, `--cache-ssd-warm-window`, `--cache-ssd-max-cold`, `--cache-ssd-page-size`, `--cache-ssd-max-conversations`, `--cache-ssd-hot-ram`, `--cache-ssd-warm-ram`, `--cache-ssd-system-prompts`, `--cache-ssd-system-max-days`.

### System prompt cache

Global cross-conversation cache for the system section of any prompt. First eval writes the state, subsequent requests skip the system prompt re-eval entirely. Default: 8 entries per model, 30 days unused before expiry. See the [System prompt cache](#system-prompt-cache) section for the full design including the per-position recurrent state handling for hybrid MoE/SSM models.

### Hybrid MoE support (Qwen3.5/3.6, GLM-4.7, Gemma 4)

Hybrid architectures mix attention and recurrent (Mamba) layers, which need different checkpoint handling than dense transformers. CachyLLama adds the right primitives for this:

- **KV cache shifting**: Hybrid models need different position tracking than dense models - pos_min/pos_max don't capture recurrent state coverage
- **Checkpoint erasure**: When conversation content diverges, only attention cells are cleared, preserving recurrent state for reuse
- **Checkpoint overflow prevention**: Same-conversation checkpoints accepted regardless of size (recurrent state is content-accurate), cross-conversation oversized checkpoints skipped at search
- **seq_rm_attn_only**: New API that clears attention KV entries without disturbing recurrent state
- **QWEN35MOE architecture filter**: Correctly identifies attention vs. recurrent layers
- **Checkpoint search condition**: Checkpoints are accepted only when
  `n_tokens >= n_past` (covers the prompt prefix) and `n_tokens <
  task_n_tokens` (fits within the current task). The first guard rejects
  divergent checkpoints whose stored state is shorter than the shared
  prefix; the second rejects checkpoints larger than the new task, which
  would leave no tokens to decode.

### User isolation

- **Per-user concurrency cap**: `--max-concurrent-per-user N` limits simultaneous slots per user. Returns HTTP 429 when the cap is hit.
- **User-scoped KV cache**: `user_id` routes checkpoints to `u/` namespace on disk, preventing cross-user cache contamination
- **Slot affinity**: Slot allocation prefers slots already owned by the requesting user for cache locality
- **Request threading**: `user_id` is threaded from the HTTP request body through `server_task` to slot allocation and cache routing

### MoE expert activation tracking

- **GET /expert-stats**: Per-layer expert activation counts, frequencies, and token counts
- **POST /expert-tracking**: Enable/disable tracking and reset counters
- **C API**: `llama_expert_tracking_enable()`, `llama_expert_stats_get()`, `llama_model_n_expert()`, `llama_model_n_expert_used()`
- Reads `ffn_moe_argsort` tensors from the compute graph after each decode to track which experts are activated per token

### Cache optimizations

- **Scoring-based prompt cache eviction**: Eviction is scored by age, size, and task token overlap rather than FIFO. Conversations with long common prefixes stay cached longer.
- **Cache divergence logging**: Server logs show the actual token content where prompt evaluation diverged from the cached prefix, so prompt structure changes are visible and debuggable.
- **Checkpoint eviction under memory pressure**: Automatically frees checkpoints when KV cache hits capacity limits
- **Conversation-aware checkpoint matching**: Uses model config validation to prevent mismatched checkpoint restoration

### Infrastructure

- **CLIO integration**: [CLIO](https://github.com/SyntheticAutonomicMind/CLIO) serializes tool definitions with deterministic JSON key ordering and reuses conversation state to maximize cache hits across agentic turns. System prompts, tool descriptions, and compressed context sent on every API call are cached and persisted to disk.
- **Auto-mlock tuning**: `llama-run.sh` compares model size against `RLIMIT_MEMLOCK` and disables `--mlock` when the limit is too small, eliminating startup warnings
- **SSD cache defaults**: Enabled by default for all non-SSM models in `llama-run.sh`. The `--cache-ssd-max-conversations` flag (default: 16) controls how many conversation directories are tracked simultaneously.
- **CPU ISA auto-detection**: `detect-gpu.sh` reads `/proc/cpuinfo` and generates optimal cmake flags for the detected CPU (AVX-512 BF16 on Zen 4, AVX2 on Zen 3, etc.), so AVX-512 code paths are enabled on hardware that supports them.

## Structure

```
├── llama-run.sh              # Main entry point
├── CachyLLama/               # Submodule - our fork of llama.cpp
├── scripts/
│   ├── rebuild.sh            # Build script (Vulkan default, optional ROCm)
│   ├── env.sh                # Environment setup (source before using tools)
│   ├── detect-gpu.sh         # GPU/APU and CPU ISA auto-detection library
│   ├── benchmark.sh          # Prompt cache performance testing
│   └── apply-ttm-kernel-params.sh  # GPU memory config (GRUB + systemd-boot)
├── src/
│   ├── cachy-llama-rocm/     # ROCm build output + build.sh
│   ├── cachy-llama-vulkan/   # Vulkan build output + build.sh
│   └── cachy-llama-metal/    # Metal build output + build.sh (macOS)
├── deps/                     # ROCm SDK (downloaded by rebuild.sh)
├── models/                   # GGUF files
├── kv-cache/                 # SSD-backed KV cache (per-conversation directories)
├── scratch/                  # Transient working files (benchmark source text)
└── benchmarks/               # Benchmark results with full server logs
```

See [AGENTS.md](AGENTS.md) for the technical reference (directory structure, build commands, code style).

## License

Source code: [GPL-3.0-or-later](LICENSE)
Documentation: [CC-BY-NC-SA-4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)

llama.cpp is MIT-licensed. ROCm components carry AMD's license.
