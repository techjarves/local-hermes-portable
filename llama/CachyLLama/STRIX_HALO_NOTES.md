# Strix Halo ROCm Notes

Last updated: 2026-06-27

## Goal

Optimize this `llama.cpp` fork for AMD Strix Halo / RDNA3.5 (`gfx1151`) on ROCm `7.2.4`, with priority on high prefill throughput and full-speed token generation.

This is a personal fork. Upstream compatibility is useful, but the current work is not targeting an upstream PR.

Priority update 2026-06-27:

- Favor MoE model throughput on Strix Halo.
- Dense-model regressions are now secondary unless they point to correctness problems.
- Main MoE canaries are Qwen 35B-A3B and GPT-OSS 20B MXFP4.
- Final local patch direction: keep `MMVQ+FA` K64 as the MoE-favored version.
- Accept that `Q2_K_XL` can be slightly better on `MMVQ-only`; choose `MMVQ+FA` because it is better for Q4/Q6/Q8 long-context mixed throughput and the user prefers this version.

Q4 focus update 2026-06-27:

- Active target was narrowed to Qwen3.6 35B-A3B `Q4_K_XL` on Strix Halo, with separate pure `pp` and pure `tg@depth` benchmarks at contexts `5000` and `10000`.
- Current main checkout extends the same safe scheduling idea beyond Q4: `IQ1_M`, `Q2_K`, `Q3_K`, `Q4_K`, `Q5_K`, `Q6_K`, and `Q8_0` use `nwarps=2` in the RDNA3.5 MMVQ `ncols_dst=1` path.
- Earlier `MMVQ+FA` K64 notes below are historical for broader MoE tuning; they are not the current source diff for the Q4-focused final patch.

## Environment

Machine:

- CPU/GPU: AMD Ryzen AI MAX+ 395 with Radeon 8060S
- ROCm GPU: AMD Radeon 8060S Graphics, `gfx1151`
- Visible VRAM/UMA: 126976 MiB
- Wave size: 32
- VMM: no

Host/toolbox:

- Host kernel: `7.0.12-201.fc44.x86_64`
- ROCm toolbox base: `rocm-7.2.4`
- Build flags of interest: `-DGGML_HIP=ON`, `-DAMDGPU_TARGETS=gfx1151`, `-DLLAMA_HIP_UMA=ON`, `-DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON`

## Local Builds

Baseline:

- Toolbox: `llama-rocm-7.2.4`
- Commit: `3fc4e1052`
- llama.cpp version: `9820`

Published fork:

- Repo: `https://github.com/gaetan-puleo/llama-cpp-strix-halo.git`
- Toolbox: `llama-rocm-7.2.4-strix`
- Commit: `e8c65e354`
- llama.cpp version: `9822`

Dirty local experimental build:

- Toolbox: `llama-rocm-7.2.4-strix-all`
- Source: `/home/gaetan/dev/llama.cpp-strix-halo`
- Dockerfile: `/home/gaetan/dev/Dockerfile.llama-rocm-7.2.4-local`
- Built with `COPY . .` so local uncommitted changes are included.

## Current Local Changes

Files changed locally:

- `ggml/src/ggml-cuda/gated_delta_net.cu`
- `ggml/src/ggml-cuda/mmvq.cu`

Selected MMVQ tuning:

- `MMVQ` RDNA3.5 `ncols_dst=1`: use `nwarps=2` for `IQ1_M`, `Q2_K`, `Q3_K`, `Q4_K`, `Q5_K`, `Q6_K`, and `Q8_0`.
- Post-commit local experiment: also test `GGML_TYPE_MXFP4` in the RDNA3.5 `ncols_dst=1` `nwarps=2` whitelist.
- Post-commit local experiment: add RDNA3.5-specific `MUL_MAT_ID` MMVQ max-batch thresholds for `IQ4_XS` and `Q5_K`, raising both to `MMVQ_MAX_BATCH_SIZE`.
- Post-commit local experiment: RDNA3.5 `GATED_DELTA_NET`, `S_v=128`, `KDA=false`, `keep_rs=false` uses `num_warps=8`; default path remains `num_warps=4`.
- Keep `VDR_Q4_K_Q8_1_MMVQ=2`; the attempted `VDR=4` change failed correctness.
- Keep RDNA3.5 MMQ `x_max=64`; the `48` experiment is rejected/removed.
- Keep Flash Attention source at baseline for this Q4 final patch; rejected FA K128/K64 experiment changes are removed from the current diff.
- Quantize changes are removed from the current diff.

## Important Findings

Generation path:

- Pure token generation with `ncols_dst=1` uses `MMVQ`, not `MMQ`.
- `MMVQ_MAX_BATCH_SIZE` is 8.
- `MMVQ nwarps=8` is bad for this target: it caused generation regression on the Qwen 4B Q8 canary.
- External/observed behavior suggests `Q8_0` likes `nwarps=2`, while `Q4_K` can prefer `nwarps=1`.
- For the active Qwen3.6 35B-A3B `Q4_K_XL` 5k/10k target, `Q4_K nwarps=2` is a correctness-safe win.

Prefill path:

- Quantized prefill goes through `quantize_mmq_q8_1_cuda`, then `MMQ`.
- The `mmq_x_max=48` experiment is mixed on a small dense Q8 canary. It may still matter more on larger or MoE/Q4/Q5 models.
- For the active Q4 5k/10k pass, `mmq_x_max=48` was not kept; use `64` as the safe final value.

Vulkan comparison:

- Vulkan `mul_mat_vecq` uses `block_q8_1_x4`, preloads `Q8_1`, unrolls K, and uses subgroup reduction without shared memory.
- HIP `MMVQ` currently uses simple `block_q8_1` and shared memory for multi-warp reductions.
- A larger future generation optimization may need to port some Vulkan ideas to HIP instead of only retuning existing launch parameters.

RDNA3.5 support already present:

- `ggml/src/ggml-cuda/vendors/hip.h` already recognizes `gfx1150/gfx1151/gfx1152/gfx1153` as `RDNA3_5`.
- `ggml_cuda_dp4a()` already uses `__builtin_amdgcn_sudot4` for `RDNA3` and `RDNA3_5`.

Potential host/runtime issue:

- `ggml/src/ggml-cuda/ggml-cuda.cu` still forces `integrated = false`.
- Boot params are not fully aligned with the Strix Halo README: missing `amd_iommu=off` and `amdgpu.gttsize=126976`.

## Validation

`test-backend-ops`:

- `test-backend-ops test -b ROCm0 -o MUL_MAT -j 1` passes on `strix-all` after the quantize zero-scale fix.
- Final result observed: `1134/1134` passed.
- Previous broken quantize attempt failed 4 `MUL_MAT` cases with NaNs.
- Latest safe Q4 patch, command `test-backend-ops -o MUL_MAT`, passes `1134/1134` on ROCm0.
- Latest safe Q4 log: `/home/gaetan/dev/bench-results/qwen36-q4-strix-q4k-nwarps2-only-correctness-20260627-035333`.
- Expanded MMVQ `nwarps=2` whitelist also passes `1134/1134` on ROCm0.
- Expanded whitelist correctness log: `/home/gaetan/dev/bench-results/qwen36-strix-expanded-nwarps2-correctness-20260627-040245`.
- Rejected `VDR_Q4_K_Q8_1_MMVQ=4` failed correctness: `1106/1134`, all failures in Q4_K small-m `MUL_MAT` cases. Do not keep it without a corrected Q4_K MMVQ vec-dot implementation.
- RDNA3.5 `MUL_MAT_ID` max-batch experiment passed targeted `IQ4_XS` and `Q5_K` checks, and full `test-backend-ops -o MUL_MAT_ID -j 1` passed `790/790`.
- RDNA3.5 `GATED_DELTA_NET num_warps=8` final targeted correctness passed `36/36`.

Known failed cases from the broken attempt, now fixed:

- `MUL_MAT(type_a=q4_0,type_b=f32,m=2880,n=32,k=2880,...)`
- `MUL_MAT(type_a=q8_0,type_b=f32,m=2880,n=32,k=2880,...)`
- `MUL_MAT(type_a=mxfp4,type_b=f32,m=2880,n=32,k=2880,...)`
- `MUL_MAT(type_a=q4_0,type_b=f32,m=576,n=512,k=576,...)`

## Canary Benchmarks

Model:

- `/home/gaetan/Downloads/Qwen3.5-4B-UD-Q8_K_XL.gguf`
- Reported by `llama-bench` as `qwen35 4B Q8_0`, size 5.53 GiB, 4.21 B params.
- Common options: `-ngl 999 -fa on -mmp 0 -o md`

Prefill only, tokens/s:

| Test | Baseline `llama-rocm-7.2.4` | Published fork `strix` | Dirty `strix-all` after quantize fix |
| --- | ---: | ---: | ---: |
| `pp3000` | 1835.19 +/- 19.41 | 1902.79 +/- 11.16 | 1818.05 +/- 4.32 |
| `pp6000` | 1767.93 +/- 1.27 | 1816.78 +/- 1.37 | 1779.14 +/- 1.59 |
| `pp9000` | 1659.90 +/- 1.16 | 1690.91 +/- 1.39 | 1672.51 +/- 1.00 |
| `pp16000` | 1533.61 +/- 0.62 | 1530.62 +/- 0.75 | 1555.94 +/- 1.58 |

Mixed prefill + generation, tokens/s:

| Test | Baseline `llama-rocm-7.2.4` | Published fork `strix` | Dirty `strix-all` after quantize fix |
| --- | ---: | ---: | ---: |
| `pp512` | 1900.51 +/- 37.23 | 1931.89 +/- 46.34 | 1833.46 +/- 34.88 |
| `tg128` | 32.16 +/- 0.02 | 30.86 +/- 0.07 | 31.89 +/- 0.02 |
| `pp3000+tg128` | 549.16 +/- 1.14 | 539.89 +/- 0.94 | 547.10 +/- 0.53 |
| `pp6000+tg128` | 814.01 +/- 1.38 | 804.04 +/- 0.96 | 798.73 +/- 1.03 |
| `pp9000+tg128` | 947.96 +/- 0.83 | 945.65 +/- 1.90 | 943.10 +/- 2.98 |
| `pp16000+tg128` | 1075.07 +/- 1.35 | 1074.95 +/- 2.42 | 1086.75 +/- 2.12 |

Interpretation:

- The dirty `strix-all` variant is not a clear win on the small dense Q8 canary.
- The current dirty variant recovers generation compared with published `strix`, but does not beat baseline on pure `tg128`.
- `pp16000` and `pp16000+tg128` improve, but shorter prefill and mixed mid-context results regress.
- Do not commit all dirty changes as-is based only on this canary.

Bench result files:

- `/home/gaetan/dev/bench-results/qwen3.5-4b-ud-q8_k_xl-rocm-7.2.4-strix-all-fixed-prefill-20260626-224417.md`
- `/home/gaetan/dev/bench-results/qwen3.5-4b-ud-q8_k_xl-rocm-7.2.4-strix-all-fixed-mixed-20260626-224637.md`

## Isolation Run 2026-06-26

Purpose:

- Separate the dirty `strix-all` changes into independent variants.
- Keep all variants available for further investigation.
- Do not clean or reduce the main dirty checkout yet.

Variant toolboxes created:

| Toolbox | Source clone | Changes |
| --- | --- | --- |
| `llama-rocm-7.2.4-strix-mmvq` | `/home/gaetan/dev/llama.cpp-strix-variant-mmvq` | `MMVQ` RDNA3.5 warp tuning only |
| `llama-rocm-7.2.4-strix-mmq48` | `/home/gaetan/dev/llama.cpp-strix-variant-mmq48` | `MMQ` `mmq_x_max=48` only |
| `llama-rocm-7.2.4-strix-fa` | `/home/gaetan/dev/llama.cpp-strix-variant-fa` | Flash Attention RDNA3.5 tile override only |
| `llama-rocm-7.2.4-strix-quant` | `/home/gaetan/dev/llama.cpp-strix-variant-quant` | quantize intrinsic + zero-scale fix only |
| `llama-rocm-7.2.4-strix-mmvq-fa` | `/home/gaetan/dev/llama.cpp-strix-variant-mmvq-fa` | `MMVQ` warp tuning + Flash Attention override |
| `llama-rocm-7.2.4-strix-mmvq-fa-k256` | `/home/gaetan/dev/llama.cpp-strix-variant-mmvq-fa-k256` | `MMVQ` warp tuning + Flash Attention override with `nbatch_K=256` |
| `llama-rocm-7.2.4-strix-mmvq-fa-b64k128` | `/home/gaetan/dev/llama.cpp-strix-variant-mmvq-fa-b64k128` | `MMVQ` warp tuning + Flash Attention override with `nbatch_fa=64`, `nbatch_K=128` |

### Qwen 4B Q8 Canary

Model:

- `/home/gaetan/Downloads/Qwen3.5-4B-UD-Q8_K_XL.gguf`

`MMVQ-only`, mixed short, same-run comparison against published `strix`:

| Test | `strix` | `MMVQ-only` |
| --- | ---: | ---: |
| `pp512` | 1940.38 +/- 41.16 | 1922.84 +/- 64.20 |
| `tg128` | 30.90 +/- 0.01 | 32.06 +/- 0.08 |
| `pp3000+tg128` | 536.24 +/- 1.35 | 555.59 +/- 0.10 |
| `pp16000+tg128` | 1083.37 +/- 1.33 | 1090.45 +/- 1.24 |

Interpretation:

- `MMVQ-only` clearly recovers the generation regression on this canary.
- The change also improves mixed tests, especially `pp3000+tg128`.
- This remains a strong investigation candidate.

`MMQ48-only`, prefill short, same-run comparison against published `strix`:

| Test | `strix` | `MMQ48-only` |
| --- | ---: | ---: |
| `pp3000` | 1881.56 +/- 11.48 | 1816.10 +/- 1.68 |
| `pp16000` | 1528.75 +/- 0.87 | 1478.99 +/- 0.53 |

Interpretation:

- `MMQ48-only` regresses this Q8 dense canary clearly.
- It should not be considered a generic win unless a larger Q4/MoE case proves otherwise.

`FA-only`, Qwen 4B:

| Test | `strix` reference | `FA-only` |
| --- | ---: | ---: |
| `pp3000` | 1881.56 +/- 11.48 | 1888.30 +/- 5.16 |
| `pp16000` | 1528.75 +/- 0.87 | 1584.21 +/- 2.00 |
| `tg128` | 30.90 +/- 0.01 | 30.89 +/- 0.02 |
| `pp3000+tg128` | 536.24 +/- 1.35 | 540.45 +/- 1.36 |
| `pp16000+tg128` | 1083.37 +/- 1.33 | 1115.15 +/- 2.25 |

Interpretation:

- `FA-only` helps Qwen long context strongly.
- It does not fix pure generation because it does not touch `MMVQ`.
- It must be checked across model families because FA tile tuning can be shape-sensitive.

`quantize-only`:

| Test | `strix` reference | `quantize-only` |
| --- | ---: | ---: |
| `pp3000` | 1881.56 +/- 11.48 | 1886.24 +/- 7.47 |
| `pp16000` | 1528.75 +/- 0.87 | 1528.36 +/- 1.86 |

Correctness:

- `test-backend-ops test -b ROCm0 -o MUL_MAT -j 1` passes: `1134/1134`.
- Log: `/home/gaetan/dev/bench-results/test-backend-ops-mulmat-strix-quant-20260626-232141.log`

Interpretation:

- Correctness is fixed.
- Qwen perf is neutral, so the intrinsic change is not yet justified by performance.
- Keep it as a possible correctness/safety fix, not as a proven speed optimization.

`MMVQ+FA`, Qwen 4B:

| Test | `MMVQ+FA` |
| --- | ---: |
| `pp3000` | 1909.94 +/- 6.66 |
| `pp16000` | 1621.94 +/- 2.08 |
| `pp512` | 1919.25 +/- 49.45 |
| `tg128` | 31.98 +/- 0.09 |
| `pp3000+tg128` | 550.79 +/- 0.55 |
| `pp16000+tg128` | 1123.63 +/- 1.84 |

Interpretation:

- `MMVQ+FA` is the best Qwen 4B Q8 canary so far.
- It combines the generation recovery from `MMVQ-only` and the long-context prefill improvement from `FA-only`.
- This result alone is not enough to keep FA globally because Gemma 31B Q4 behaves differently.

### Gemma 31B Q4_K

Model:

- `/home/gaetan/Downloads/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf`
- Reported by `llama-bench` as `gemma4 31B Q4_0`, size 16.09 GiB, 30.70 B params.

Published `strix` vs `MMVQ+FA`:

| Test | `strix` | `MMVQ+FA` |
| --- | ---: | ---: |
| `pp2048` | 340.32 +/- 1.13 | 326.71 +/- 5.04 |
| `pp4096` | 321.42 +/- 0.50 | 306.09 +/- 0.57 |
| `pp2048+tg128` | 117.05 +/- 0.37 | 117.32 +/- 0.69 |
| `tg128` | 11.56 +/- 0.01 | 11.70 +/- 0.04 |

`MMVQ-only` on Gemma 31B Q4_K:

| Test | `MMVQ-only` |
| --- | ---: |
| `pp2048` | 339.96 +/- 0.76 |
| `pp4096` | 321.22 +/- 0.67 |
| `tg128` | 11.71 +/- 0.02 |

Interpretation:

- `MMVQ-only` is good on Gemma: prefill remains neutral and generation improves slightly.
- The Gemma prefill regression in `MMVQ+FA` likely comes from the FA tile override, not the MMVQ warp tuning.
- `FA-only` / `MMVQ+FA` should remain under investigation rather than be kept globally.

Current working hypotheses:

- `MMVQ` RDNA3.5 warp tuning is the most robust candidate so far.
- FA RDNA3.5 tile override may be beneficial for Qwen 4B Q8 long context but harmful for Gemma 31B Q4 prefill.
- `MMQ48` is likely too small for this target on dense Q8 and should be tested only if a specific larger/MoE shape suggests it.
- Quantize intrinsic is correctness-safe after the zero-scale fix, but performance-neutral in the current Qwen canary.

Open investigations:

- Determine whether FA override should be gated more narrowly by shape/model dimensions instead of all RDNA3.5 `DKQ=256,DV=256,ncols=32`.
- Consider more FA tile variants instead of only one override.
- Continue comparing `MMVQ-only`, `FA-only`, and `MMVQ+FA` before deciding what to put into the main fork.
- Re-test promising variants with longer contexts and higher `-r` once the search space is smaller.

### GPT-OSS 20B MXFP4 MoE

Model:

- `/home/gaetan/models/gpt-oss/20B/bartowski/openai_gpt-oss-20b-MXFP4.gguf`
- Reported by `llama-bench` as `gpt-oss 20B MXFP4 MoE`, size 11.27 GiB, 20.91 B params.

Results:

| Variant | `pp2048` | `pp4096` | `tg128` | `pp2048+tg128` |
| --- | ---: | ---: | ---: | ---: |
| `strix` | 2087.89 +/- 47.68 | 2091.10 +/- 39.88 | 67.62 +/- 0.04 | 744.95 +/- 1.49 |
| `MMVQ-only` | 2141.19 +/- 9.42 | 2119.29 +/- 3.34 | 72.04 +/- 0.36 | 778.50 +/- 1.00 |
| `FA-only` | 2152.82 +/- 8.76 | 2114.71 +/- 2.43 | 67.56 +/- 0.08 | 745.46 +/- 1.21 |
| `MMVQ+FA` | 2161.46 +/- 8.87 | 2117.03 +/- 3.64 | 73.09 +/- 0.26 | 787.93 +/- 2.35 |

Interpretation:

- `MMVQ-only` improves MXFP4 MoE generation and mixed throughput strongly.
- `FA-only` improves prefill but does not help generation.
- `MMVQ+FA` is best overall on this model.
- The MXFP4 result supports continuing with a combined search, not just dropping FA because of the Gemma Q4 regression.

Result files:

- `/home/gaetan/dev/bench-results/gpt-oss-20b-mxfp4-strix-prefill-tg-mixed-20260626-234434.md`
- `/home/gaetan/dev/bench-results/gpt-oss-20b-mxfp4-strix-mmvq-prefill-tg-mixed-20260626-234434.md`
- `/home/gaetan/dev/bench-results/gpt-oss-20b-mxfp4-strix-fa-prefill-tg-mixed-20260626-234434.md`
- `/home/gaetan/dev/bench-results/gpt-oss-20b-mxfp4-strix-mmvq-fa-prefill-tg-mixed-20260626-234434.md`

### Qwen 35B-A3B Q8 MoE

Model:

- `/home/gaetan/models/qwen3.6/35B-A3B/unsloth/mtp/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf`
- Reported by `llama-bench` as `qwen35moe 35B.A3B Q8_0`, size 36.40 GiB, 35.51 B params.

Results:

| Variant | `pp1024` | `pp2048` | `tg128` | `pp1024+tg128` |
| --- | ---: | ---: | ---: | ---: |
| `strix` | 1219.53 +/- 7.92 | 1217.32 +/- 6.90 | 36.26 +/- 0.07 | 262.68 +/- 0.19 |
| `MMVQ-only` | 1195.26 +/- 8.09 | 1200.74 +/- 5.44 | 43.81 +/- 0.07 | 304.17 +/- 0.35 |
| `FA-only` | 1234.02 +/- 15.88 | 1231.71 +/- 6.19 | 38.49 +/- 0.10 | 276.17 +/- 1.51 |
| `MMVQ+FA` | 1237.31 +/- 8.15 | 1206.93 +/- 6.20 | 44.30 +/- 0.04 | 307.40 +/- 0.34 |

Interpretation:

- `MMVQ-only` gives a large Q8 MoE generation gain: `36.26 -> 43.81 t/s`.
- `MMVQ-only` also improves mixed throughput: `262.68 -> 304.17 t/s`.
- `FA-only` improves prefill and mixed modestly, but generation stays far below `MMVQ-only`.
- `MMVQ+FA` is best for generation and mixed throughput on this model.
- `MMVQ+FA` has mixed prefill behavior: `pp1024` improves, `pp2048` is slightly below `strix` and below `FA-only`.

Result files:

- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-q8-strix-prefill-tg-mixed-20260626-234657.md`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-q8-strix-mmvq-prefill-tg-mixed-20260626-234657.md`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-q8-strix-fa-prefill-tg-mixed-20260626-234657.md`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-q8-strix-mmvq-fa-prefill-tg-mixed-20260626-234657.md`

### Correctness After Combined Variant

`MMVQ+FA` correctness:

- `test-backend-ops test -b ROCm0 -o MUL_MAT -j 1` passes: `1134/1134`.
- Log: `/home/gaetan/dev/bench-results/test-backend-ops-mulmat-strix-mmvq-fa-20260626-235002.log`
- Final selected `MMVQ+FA` verification also passes: `1134/1134`.
- Final log: `/home/gaetan/dev/bench-results/test-backend-ops-mulmat-strix-mmvq-fa-final-20260627-014318.log`
- `git diff --check` is clean for the selected patch.
- Final patch snapshot: `/home/gaetan/dev/strix-halo-patches/strix-moe-mmvq-fa-final.patch`

Updated hypotheses after MXFP4/MoE:

- `MMVQ` warp tuning is now strongly supported for generation, especially MoE Q8 and MXFP4.
- `FA` tile override is shape-sensitive: excellent on Qwen 4B long context, useful on MXFP4/MoE, bad on Gemma 31B Q4 prefill.
- `MMVQ+FA` is worth further investigation because it wins on Qwen 4B Q8, GPT-OSS 20B MXFP4, and Qwen 35B-A3B Q8 mixed/generation.
- Gemma 31B Q4 prevents blindly keeping the current FA override as a universal RDNA3.5 rule.
- Next FA work should test alternate tile configs or narrower gating rather than removing FA from the search.

### FA K256 Rejection

Purpose:

- Test whether changing the RDNA3.5 Flash Attention override from `nbatch_K=64` to `nbatch_K=256` recovers Gemma 31B Q4 prefill while keeping the Qwen/GPT-OSS wins.

Results:

| Model | Test | `MMVQ+FA` | `MMVQ+FA-K256` |
| --- | --- | ---: | ---: |
| Qwen 4B Q8 | `pp3000` | 1909.94 +/- 6.66 | 1798.01 +/- 12.64 |
| Qwen 4B Q8 | `pp16000` | 1621.94 +/- 2.08 | 1478.56 +/- 2.02 |
| Qwen 4B Q8 | `tg128` | 31.98 +/- 0.09 | 31.41 +/- 0.04 |
| Qwen 4B Q8 | `pp16000+tg128` | 1123.63 +/- 1.84 | 1041.64 +/- 3.12 |
| Gemma 31B Q4 | `pp2048` | 326.71 +/- 5.04 | 323.32 +/- 1.65 |
| Gemma 31B Q4 | `pp4096` | 306.09 +/- 0.57 | 306.70 +/- 0.78 |
| Gemma 31B Q4 | `tg128` | 11.70 +/- 0.04 | 11.42 +/- 0.01 |
| GPT-OSS 20B MXFP4 | `pp2048` | 2161.46 +/- 8.87 | 2086.37 +/- 7.53 |
| GPT-OSS 20B MXFP4 | `tg128` | 73.09 +/- 0.26 | 71.11 +/- 0.12 |
| GPT-OSS 20B MXFP4 | `pp2048+tg128` | 787.93 +/- 2.35 | 769.21 +/- 1.33 |
| Qwen 35B-A3B Q8 | `pp1024` | 1237.31 +/- 8.15 | 1175.34 +/- 11.82 |
| Qwen 35B-A3B Q8 | `pp2048` | 1206.93 +/- 6.20 | 1161.91 +/- 3.12 |
| Qwen 35B-A3B Q8 | `tg128` | 44.30 +/- 0.04 | 38.14 +/- 7.18 |
| Qwen 35B-A3B Q8 | `pp1024+tg128` | 307.40 +/- 0.34 | 277.42 +/- 35.71 |

Interpretation:

- `nbatch_K=256` does not fix the Gemma prefill regression.
- It clearly loses the Qwen 4B long-context and GPT-OSS wins from the original `MMVQ+FA` variant.
- Qwen MoE generation/mixed results are both worse and very noisy, so this variant is not worth pursuing.
- Reject `MMVQ+FA-K256`; keep future FA experiments focused on narrower gating or other tile fields.

Result files:

- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-k256-prefill-tg-20260626-235903.md`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-q8-strix-mmvq-fa-k256-prefill-tg-mixed-20260626-235903.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-k256-spot-20260627-000515.md`
- `/home/gaetan/dev/bench-results/gptoss20b-mxfp4-strix-mmvq-fa-k256-spot-20260627-000515.md`

### FA B64K128 Control

Purpose:

- Use `nbatch_K=128` as a no-K64 control for the RDNA3.5 branch.
- Important correction: RDNA baseline for `DKQ=256,DV=256,ncols=32` is already `256 threads`, `occupancy=3`, `nbatch_fa=64`, `nbatch_K=128`.

Results:

| Model | Test | `MMVQ+FA` | `MMVQ+FA-B64K128` |
| --- | --- | ---: | ---: |
| Qwen 4B Q8 | `pp3000` | 1909.94 +/- 6.66 | 1842.01 +/- 22.35 |
| Qwen 4B Q8 | `pp16000` | 1621.94 +/- 2.08 | 1505.47 +/- 6.34 |
| Qwen 4B Q8 | `tg128` | 31.98 +/- 0.09 | 30.07 +/- 0.01 |
| Qwen 4B Q8 | `pp16000+tg128` | 1123.63 +/- 1.84 | 1075.56 +/- 1.00 |
| Gemma 31B Q4 | `pp2048` | 326.71 +/- 5.04 | 321.25 +/- 2.98 |
| Gemma 31B Q4 | `pp4096` | 306.09 +/- 0.57 | 297.60 +/- 1.27 |
| Gemma 31B Q4 | `tg128` | 11.70 +/- 0.04 | 11.47 +/- 0.03 |

Interpretation:

- The first `B64K128` spot-check looked bad, but follow-up calibration showed run drift: `MMVQ-only` also dropped under the same conditions.
- Treat `B64K128` as a control/no-K64 variant, not as an optimization candidate.
- The useful Qwen behavior appears tied to `nbatch_K=64`, but the K64 tuple is unsafe as a universal RDNA3.5 rule.

Follow-up calibration:

| Model | Test | `MMVQ-only` | `MMVQ+FA-B64K128` | `MMVQ+FA` K64 |
| --- | --- | ---: | ---: | ---: |
| Qwen 4B Q8 | `pp16000` | 1455.28 +/- 0.70 | 1495.10 +/- 2.85 | 1529.12 +/- 0.63 |
| Qwen 4B Q8 | `tg128` | 31.58 +/- 0.10 | 31.77 +/- 0.06 | 31.84 +/- 0.04 |
| Qwen 4B Q8 | `pp16000+tg128` | 1067.61 +/- 0.33 | 1084.12 +/- 0.18 | 1100.68 +/- 8.93 |
| Gemma 31B Q4 | `pp4096` | 300.45 +/- 2.13 | 303.05 +/- 2.20 | 301.82 +/- 2.01 |
| Gemma 31B Q4 | `tg128` | 11.53 +/- 0.01 | 11.59 +/- 0.01 | 11.58 +/- 0.01 |

Paired higher-rep checks:

| Model | Test | `MMVQ+FA-B64K128` | `MMVQ+FA` K64 |
| --- | --- | ---: | ---: |
| Gemma 31B Q4 | `pp2048` | 333.34 +/- 1.89 | 330.40 +/- 4.63 |
| Gemma 31B Q4 | `pp4096` | 315.64 +/- 0.54 | 306.46 +/- 0.37 |
| Gemma 31B Q4 | `tg128` | 11.63 +/- 0.02 | 11.64 +/- 0.01 |
| Qwen 4B Q8 | `pp3000` | 1893.02 +/- 13.15 | 1846.57 +/- 8.48 |
| Qwen 4B Q8 | `pp16000` | 1532.01 +/- 0.47 | 1536.61 +/- 1.24 |
| Qwen 4B Q8 | `tg128` | 31.74 +/- 0.02 | 31.79 +/- 0.10 |
| Qwen 4B Q8 | `pp16000+tg128` | 1062.02 +/- 2.20 | 1099.70 +/- 1.38 |

Updated interpretation:

- In paired checks, K64 improves Qwen long-context mixed throughput, but does not reliably improve pure Qwen prefill.
- In paired checks, K64 hurts Gemma `pp4096` versus the no-K64 control.
- Do not keep the K64 FA tuple globally unless a narrower runtime gate is added.

Result files:

- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-b64k128-spot-20260627-001312.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-b64k128-spot-20260627-001312.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-calibration-20260627-001958.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-b64k128-calibration-20260627-001958.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-calibration-20260627-001958.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-b64k128-calibration-20260627-001958.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-calibration-20260627-002719.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-calibration-20260627-002719.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-b64k128-paired-20260627-003157.md`
- `/home/gaetan/dev/bench-results/gemma4-31b-q4k-strix-mmvq-fa-k64-paired-20260627-003157.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-b64k128-paired-20260627-003841.md`
- `/home/gaetan/dev/bench-results/qwen35-4b-q8-strix-mmvq-fa-k64-paired-20260627-003841.md`

### FA Shape Notes

Observed model metadata:

| Model | `n_embd_head_k` | `n_embd_head_v` | `n_gqa` | SWA | MoE |
| --- | ---: | ---: | --- | --- | --- |
| Qwen 4B Q8 | 256 | 256 | 4 | no | no |
| Qwen 35B-A3B Q8 | 256 | 256 | 8 | no | yes, 256 experts / 8 used |
| Gemma 31B Q4 | 512 full, 256 SWA | 512 full, 256 SWA | 2 full, 8 SWA | yes, 1024 | no |
| GPT-OSS 20B MXFP4 | 64 | 64 | 8 | yes, 128 | yes, 32 experts / 4 used |

Interpretation:

- The current K64 override only targets `DKQ=256,DV=256,ncols=32`.
- It plausibly helps Qwen long-context mixed throughput because Qwen dense/MoE use 256-wide attention heads without SWA.
- It plausibly hurts Gemma because Gemma has 256-wide SWA layers in addition to 512-wide full-attention layers.
- GPT-OSS 20B has 64-wide heads, so the `DKQ=256,DV=256,ncols=32` override should not be responsible for its small FA differences; those may be noise or generic RDNA table behavior.
- `ggml_cuda_fattn_tile_get_config()` only keys on `DKQ`, `DV`, and total `ncols`, so it cannot safely distinguish Qwen no-SWA 256-head attention from Gemma SWA 256-head attention without a larger dispatch/signature change.

### Qwen 35B-A3B Downloads MoE Sweep

User priority changed to MoE-first on 2026-06-27.

Downloaded models found:

- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-IQ1_M.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf`
- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf`

No `Qwant` / `qwant` model files were found in `/home/gaetan/Downloads`.

All-quant screen on `MMVQ+FA` K64:

| Quant | Size | `pp1024` | `pp2048` | `tg128` | `pp1024+tg128` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `IQ1_M` | 9.35 GiB | 1371.83 +/- 10.97 | 1322.34 +/- 3.63 | 55.24 +/- 0.34 | 373.27 +/- 5.69 |
| `Q2_K_XL` | 11.44 GiB | 1241.08 +/- 16.75 | 1259.61 +/- 7.67 | 57.47 +/- 0.25 | 373.44 +/- 0.45 |
| `Q3_K_XL` | 15.68 GiB | 1284.07 +/- 12.25 | 1267.07 +/- 6.53 | 50.31 +/- 0.20 | 346.19 +/- 1.22 |
| `Q4_K_XL` | 20.81 GiB | 1311.07 +/- 3.49 | 1305.20 +/- 0.52 | 48.52 +/- 0.21 | 336.70 +/- 0.55 |
| `Q5_K_XL` | 24.76 GiB | 1267.96 +/- 13.95 | 1284.08 +/- 2.47 | 47.26 +/- 0.26 | 325.91 +/- 0.64 |
| `Q6_K_XL` | 29.65 GiB | 1147.22 +/- 10.77 | 1189.86 +/- 0.98 | 45.89 +/- 0.08 | 313.20 +/- 0.11 |
| `Q8_K_XL` | 35.80 GiB | 1160.86 +/- 7.78 | 1188.21 +/- 3.46 | 44.08 +/- 0.07 | 303.40 +/- 0.14 |

Interpretation:

- Fastest generation: `Q2_K_XL`, `57.47 t/s`.
- Best mixed throughput is effectively tied between `Q2_K_XL` and `IQ1_M`, both around `373 t/s`.
- Best prefill in this sweep: `IQ1_M`, with `pp1024 1371.83` and `pp2048 1322.34`.
- Higher-quality quantizations lose generation roughly monotonically: Q4 `48.52`, Q5 `47.26`, Q6 `45.89`, Q8 `44.08 t/s`.

Variant comparison on likely MoE candidates:

| Quant | Variant | `pp1024` | `pp2048` | `tg128` | `pp1024+tg128` |
| --- | --- | ---: | ---: | ---: | ---: |
| `IQ1_M` | `strix` | 1355.91 +/- 6.96 | 1323.80 +/- 8.05 | 57.84 +/- 1.46 | 383.42 +/- 1.41 |
| `IQ1_M` | `MMVQ-only` | 1375.68 +/- 4.45 | 1325.42 +/- 1.46 | 57.99 +/- 0.29 | 383.68 +/- 1.86 |
| `IQ1_M` | `B64K128` control | 1375.11 +/- 5.17 | 1329.21 +/- 3.24 | 58.03 +/- 0.11 | 381.87 +/- 0.48 |
| `IQ1_M` | `MMVQ+FA` K64 | 1377.87 +/- 6.76 | 1349.08 +/- 0.82 | 58.22 +/- 0.22 | 381.99 +/- 2.28 |
| `Q2_K_XL` | `strix` | 1304.41 +/- 9.79 | 1248.95 +/- 4.36 | 57.67 +/- 0.28 | 375.84 +/- 0.48 |
| `Q2_K_XL` | `MMVQ-only` | 1292.65 +/- 7.40 | 1262.85 +/- 5.12 | 57.85 +/- 0.18 | 376.58 +/- 0.77 |
| `Q2_K_XL` | `B64K128` control | 1276.56 +/- 4.40 | 1233.42 +/- 9.37 | 57.83 +/- 0.18 | 376.59 +/- 0.59 |
| `Q2_K_XL` | `MMVQ+FA` K64 | 1274.14 +/- 8.51 | 1260.33 +/- 5.96 | 57.33 +/- 0.58 | 375.43 +/- 0.71 |
| `Q4_K_XL` | `strix` | 1284.05 +/- 14.69 | 1285.66 +/- 3.65 | 45.45 +/- 0.19 | 320.16 +/- 1.23 |
| `Q4_K_XL` | `MMVQ-only` | 1370.89 +/- 12.03 | 1308.89 +/- 3.82 | 49.08 +/- 0.21 | 340.48 +/- 0.30 |
| `Q4_K_XL` | `B64K128` control | 1375.56 +/- 12.50 | 1323.56 +/- 5.41 | 48.92 +/- 0.13 | 338.93 +/- 0.11 |
| `Q4_K_XL` | `MMVQ+FA` K64 | 1340.93 +/- 5.88 | 1350.22 +/- 1.41 | 49.38 +/- 0.12 | 343.30 +/- 1.01 |

MoE-first interpretation:

- If speed is the main target, `Q2_K_XL` is the best downloaded quantization: fastest `tg128` and tied-best mixed throughput.
- If quality/speed balance matters, `Q4_K_XL` benefits strongly from `MMVQ` tuning: `tg128 45.45 -> 49.08/49.38` and mixed `320.16 -> 340.48/343.30`.
- K64 FA helps `Q4_K_XL` mixed and `pp2048`, but does not help `Q2_K_XL` and is neutral/slightly negative for `IQ1_M` mixed.
- `MMVQ-only` is still the safest MoE optimization across quantizations.
- `MMVQ+FA` K64 is acceptable if we explicitly favor Qwen MoE Q4 and higher-quality quantizations over dense Gemma and over low-bit Q2/IQ1.

Result directories:

- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-downloads-mmvq-fa-20260627-005431`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-downloads-variant-compare-20260627-005959`

Long-context `MMVQ-only` vs `MMVQ+FA` K64 follow-up:

| Quant | Variant | `pp4096` | `pp8192` | `tg128` | `pp4096+tg128` | `pp8192+tg128` |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `Q2_K_XL` | `MMVQ-only` | 1228.23 +/- 7.38 | 1146.68 +/- 3.34 | 57.99 +/- 0.18 | 748.59 +/- 2.87 | 866.95 +/- 1.74 |
| `Q2_K_XL` | `MMVQ+FA` K64 | 1206.74 +/- 2.26 | 1160.43 +/- 4.35 | 57.70 +/- 0.03 | 737.81 +/- 3.88 | 864.73 +/- 2.16 |
| `Q4_K_XL` | `MMVQ-only` | 1280.87 +/- 8.94 | 1204.16 +/- 11.05 | 49.67 +/- 0.27 | 723.41 +/- 1.24 | 877.11 +/- 2.18 |
| `Q4_K_XL` | `MMVQ+FA` K64 | 1282.05 +/- 12.54 | 1196.54 +/- 9.01 | 49.51 +/- 0.14 | 730.37 +/- 1.70 | 884.12 +/- 2.90 |
| `Q8_K_XL` | `MMVQ-only` | 1137.51 +/- 2.69 | 1101.86 +/- 10.40 | 44.28 +/- 0.08 | 645.98 +/- 0.82 | 791.83 +/- 1.72 |
| `Q8_K_XL` | `MMVQ+FA` K64 | 1129.51 +/- 4.34 | 1080.32 +/- 10.99 | 44.29 +/- 0.12 | 654.08 +/- 2.40 | 802.92 +/- 1.89 |

Additional Q3/Q5/Q6 long-context follow-up:

| Quant | Variant | `pp4096` | `pp8192` | `tg128` | `pp4096+tg128` | `pp8192+tg128` |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `Q3_K_XL` | `MMVQ-only` | 1268.54 +/- 5.40 | 1226.58 +/- 6.40 | 50.60 +/- 0.16 | 727.37 +/- 0.52 | 887.72 +/- 2.41 |
| `Q3_K_XL` | `MMVQ+FA` K64 | 1292.09 +/- 5.92 | 1171.11 +/- 6.54 | 50.67 +/- 0.10 | 727.96 +/- 0.56 | 876.51 +/- 3.54 |
| `Q5_K_XL` | `MMVQ-only` | 1185.05 +/- 6.78 | 1118.76 +/- 12.08 | 47.21 +/- 0.20 | 688.36 +/- 1.87 | 834.76 +/- 3.24 |
| `Q5_K_XL` | `MMVQ+FA` K64 | 1232.58 +/- 10.64 | 1128.46 +/- 7.11 | 47.38 +/- 0.12 | 688.45 +/- 2.01 | 832.17 +/- 3.07 |
| `Q6_K_XL` | `MMVQ-only` | 1127.55 +/- 1.42 | 1053.54 +/- 10.61 | 46.11 +/- 0.30 | 653.02 +/- 2.24 | 786.16 +/- 3.56 |
| `Q6_K_XL` | `MMVQ+FA` K64 | 1152.18 +/- 11.69 | 1063.37 +/- 7.22 | 46.45 +/- 0.17 | 661.69 +/- 2.11 | 796.97 +/- 3.58 |

Long-context interpretation:

- `Q2_K_XL`: `MMVQ-only` remains better overall. K64 FA loses `pp4096+tg128` and is flat/slightly worse for `pp8192+tg128`.
- `Q3_K_XL`: K64 FA is neutral at `pp4096+tg128` but loses at `pp8192+tg128`.
- `Q4_K_XL`: K64 FA improves mixed long-context throughput: `723.41 -> 730.37` and `877.11 -> 884.12`, while generation is effectively unchanged.
- `Q5_K_XL`: K64 FA improves pure prefill but mixed throughput is effectively neutral.
- `Q6_K_XL`: K64 FA improves both mixed long-context cases: `653.02 -> 661.69` and `786.16 -> 796.97`.
- `Q8_K_XL`: K64 FA improves mixed long-context throughput: `645.98 -> 654.08` and `791.83 -> 802.92`, while pure prefill regresses and generation is unchanged.
- Final decision: use `MMVQ+FA` K64 for the MoE-favored fork, prioritizing Qwen MoE Q4/Q6/Q8 long-context mixed throughput over low-bit Q2/Q3 edge cases.

Result directory:

- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-downloads-longctx-mmvq-vs-fa-20260627-010901`
- `/home/gaetan/dev/bench-results/qwen36-35b-a3b-downloads-q3q5q6-longctx-mmvq-vs-fa-20260627-012610`

### Qwen 35B-A3B Q4_K_XL 5k/10k Final Safe Patch

Purpose:

- Focus on Qwen3.6 35B-A3B `Q4_K_XL` only.
- Use separate pure prefill and pure generation-at-depth measurements.
- Benchmark only contexts `5000` and `10000`.
- Preserve quality and correctness; scheduling-only final source diff.

Accepted code change:

- `ggml/src/ggml-cuda/mmvq.cu`: add `GGML_TYPE_Q4_K` to the RDNA3.5 `ncols_dst=1` `nwarps=2` whitelist.

Benchmark comparison, `llama-bench -r 5 -ngl 999 -fa on -mmp 0 -o md`:

| Test | Stable baseline | Final safe patch | Delta |
| --- | ---: | ---: | ---: |
| `pp5000` | 1278.83 +/- 8.93 | 1288.05 +/- 3.99 | +0.7% |
| `pp10000` | 1164.90 +/- 2.43 | 1215.63 +/- 2.25 | +4.4% |
| `tg128 @ d5000` | 47.52 +/- 0.17 | 47.92 +/- 0.06 | +0.8% |
| `tg128 @ d10000` | 46.68 +/- 0.16 | 46.93 +/- 0.18 | +0.5% |

Correctness:

- `test-backend-ops -o MUL_MAT` passes: `1134/1134` on ROCm0.

Rejected during this Q4 pass:

- `VDR_Q4_K_Q8_1_MMVQ=4`: rejected because it failed correctness (`1106/1134`) on Q4_K small-m `MUL_MAT` cases.
- `MMQ x_max=48`: not kept; source restored to `64`.
- FA K128 for `DKQ=256,DV=256,ncols=32`: rejected because Q4 `pp10000` regressed.
- MoE `rows_per_block=4`: rejected; source restored to `2` in the MoE path from earlier tuning, and current final diff does not include a rows-per-block change.

Result directories:

- Stable baseline: `/home/gaetan/dev/bench-results/qwen36-q4-strix-current-context-5k10k-repeat-20260627-025152`
- Final benchmark: `/home/gaetan/dev/bench-results/qwen36-q4-strix-q4k-nwarps2-only-final-context-5k10k-repeat-20260627-035407`
- Final correctness: `/home/gaetan/dev/bench-results/qwen36-q4-strix-q4k-nwarps2-only-correctness-20260627-035333`

### Qwen 35B-A3B Q8_K_XL Original ROCm vs Strix Prefill

Purpose:

- Compare original ROCm toolbox against the patched Strix toolbox on Q8 pure prefill.
- Contexts: `5000`, `15000`, `30000`, `60000`.
- Command shape: `llama-bench -p 5000,15000,30000,60000 -n 0 -r 3 -ngl 999 -fa on -mmp 0 -o md`.

Model:

- `/home/gaetan/Downloads/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf`

Results:

| Test | Original ROCm `3fc4e1052` | Patched Strix `f7b3aa558+dirty` | Delta |
| --- | ---: | ---: | ---: |
| `pp5000` | 976.68 +/- 6.13 | 1108.68 +/- 4.52 | +13.5% |
| `pp15000` | 896.31 +/- 3.51 | 1022.75 +/- 2.86 | +14.1% |
| `pp30000` | 770.67 +/- 6.71 | 884.14 +/- 1.96 | +14.7% |
| `pp60000` | 607.98 +/- 0.94 | 701.22 +/- 0.52 | +15.3% |

Result directory:

- `/home/gaetan/dev/bench-results/qwen36-q8-original-vs-strix-prefill-5k15k30k60k-20260627-040338`

### Quant-Specific Code Experiments

Current selected patch:

- `MMVQ` RDNA3.5 warp tuning in `ggml/src/ggml-cuda/mmvq.cu`.
- Active RDNA3.5 `ncols_dst=1` `nwarps=2` whitelist: `IQ1_M`, `Q2_K`, `Q3_K`, `Q4_K`, `Q5_K`, `Q6_K`, `Q8_0`.
- The main checkout has been reduced to this one code-change area for the active patch.
- Rejected `VDR=4`, `MMQ48`, FA, and `quantize-only` changes were removed from the main working tree.

MMVQ generation code paths:

| Quant | MMVQ vecdot path | Current VDR | Observed direction |
| --- | --- | ---: | --- |
| `IQ1_M` | `vec_dot_iq1_m_q8_1` | 1 | Now included in RDNA3.5 `nwarps=2`; needs generation benchmark confirmation. |
| `Q2_K_XL` | `vec_dot_q2_K_q8_1` | 1 | Now included in RDNA3.5 `nwarps=2`; fastest generation historically, verify no regression. |
| `Q3_K_XL` | `vec_dot_q3_K_q8_1` | 1 | Now included in RDNA3.5 `nwarps=2`; verify because Q3 has higher unpack/scale overhead. |
| `Q4_K_XL` | `vec_dot_q4_K_q8_1` | 2 | Active target; keep VDR at 2, use RDNA3.5 `nwarps=2`, and explore vecdot packing only with correctness first. |
| `Q5_K_XL` | `vec_dot_q5_K_q8_1` | 2 | Now included in RDNA3.5 `nwarps=2`; similar MMVQ behavior expected to Q4. |
| `Q6_K_XL` | `vec_dot_q6_K_q8_1` | 1 | Now included in RDNA3.5 `nwarps=2`; verify because VDR remains 1. |
| `Q8_K_XL` | `vec_dot_q8_0_q8_1` | existing Q8 path | Already included in RDNA3.5 `nwarps=2`; Q8 prefill comparison versus original ROCm is strong. |

Candidate experiments, in priority order:

- Q4: keep the safe `nwarps=2` patch; any `VDR=4` revisit must first fix Q4_K coverage and pass `test-backend-ops`.
- Q4/Q5: investigate whether the `VDR=2` K-quant vecdot path can reuse/preload Q8_1 data more efficiently, similar to Vulkan `block_q8_1_x4` ideas.
- Q1/Q2/Q3/Q5/Q6: run pure `tg@depth` checks to confirm the expanded `nwarps=2` whitelist is a performance win, not just correctness-safe.
- Q6: test a local-only `VDR_Q6_K_Q8_1_MMVQ=2` variant only after the `nwarps=2` result is measured; current Q6 uses VDR 1.
- Q2/Q3: avoid FA changes; if optimizing later, focus on reducing scale/unpack overhead inside `vec_dot_q2_K_q8_1` and `vec_dot_q3_K_q8_1`.
- IQ1_M: no immediate kernel work unless it becomes the deployed quantization; current tuning has little effect.
- Cross-cutting: explore a Vulkan-style MMVQ redesign with packed `Q8_1` activation loads and fewer shared-memory reductions, but only after the small selected patch is preserved.

## MoE MMID Max-Batch Experiment 2026-06-27

Change under test:

- Add `get_mmvq_mmid_max_batch_rdna3_5()` in `ggml/src/ggml-cuda/mmvq.cu`.
- On RDNA3.5, route `IQ4_XS` and `Q5_K` `MUL_MAT_ID` batches up to `MMVQ_MAX_BATCH_SIZE` through MMVQ.
- Host dispatch must test `GGML_CUDA_CC_IS_RDNA3_5(cc)` before `GGML_CUDA_CC_IS_RDNA3(cc)` because `gfx1151` matches both.

Primary models:

- Step-3.7-flash IQ4_XS: `/home/gaetan/models/step-3.7-flash/unsloth/Step-3.7-flash-IQ4_XS-00001-of-00003.gguf`
- Qwen3.5 122B-A10B Q5_K_M: `/home/gaetan/models/qwen3.5/122B/unsloth/mtp/Qwen3.5-122B-A10B-UD-Q5_K_M-00001-of-00003.gguf`
- MiniMax: blocked, no matching local GGUF found under `/home/gaetan`.

Qwen3.5 122B tensor mix from split shards `00002/00003`:

- `ffn_gate_exps`: `Q5_K`, 49 tensors, shape `(3072, 1024, 256)`.
- `ffn_up_exps`: `Q5_K`, 49 tensors, shape `(3072, 1024, 256)`.
- `ffn_down_exps`: mostly `Q6_K`, 48 tensors, shape `(1024, 3072, 256)`, plus one `Q8_0` tensor.
- Shared experts are `Q8_0`; router/gating tensors are `F32`/`BF16`.

Same-run comparison against clean `llama-rocm-7.2.4-strix-mxfp4only` where available:

| Model | Test | Clean/control | MMID max-batch experiment |
| --- | --- | ---: | ---: |
| Step-3.7-flash IQ4_XS | `pp10000` | 370.01 +/- 7.07 | 375.53 +/- 1.45 |
| Step-3.7-flash IQ4_XS | `tg128 @ d10000` | 24.30 +/- 0.08 | 24.32 +/- 0.07 |
| Qwen3.5 122B-A10B Q5_K_M | `tg128 @ d10000` | 17.44 +/- 1.87 | 18.28 +/- 0.02 |
| Qwen3.5 122B-A10B Q5_K_M | `pp10000` | 341.36 +/- 18.78 | 346.52 +/- 6.27; rerun 344.90 +/- 4.45 |

Rejected follow-ups from hipEngine-inspired Qwen122 pass:

| Change | Qwen122 `tg128 @ d10000` | Qwen122 `pp10000` | Decision |
| --- | ---: | ---: | --- |
| Add `Q6_K` to RDNA3.5 MMID max-batch | 17.61 +/- 0.12 | 340.62 +/- 4.81 | Reject; down-expert `Q6_K` MMVQ at batch 8 is slower. |
| Set MoE MMVQ `rows_per_block=4` | 17.93 +/- 0.20 | not run | Reject; worse than default `2`. |

Interpretation:

- Correctness is clean for `MUL_MAT_ID`.
- `IQ4_XS` appears neutral for Step generation and likely positive/stabilizing for Step prefill.
- `Q5_K` appears positive for Qwen122 generation, but Qwen122 prefill is noisy. Earlier non-A/B baseline was 354.53 +/- 1.46, so do not claim a prefill win yet.
- Keep this as an experiment until a higher-confidence Qwen122 prefill comparison or a generation-priority decision is made.
- hipEngine useful ideas are layout/repack/fusion oriented: T16 selected GGUF layouts for `Q4_K/Q5_K/Q6_K`, compact selected-MoE WMMA prefill, selected GEMV decode, graph replay, and launch-count reduction. These are not small source tweaks in llama.cpp and should be treated as larger future work. Because hipEngine is AGPL-3.0, use it only as design reference, not as copied code.

Result directory:

- `/home/gaetan/dev/bench-results/moe-mmid-rdna35-maxbatch-20260627-055213`
- `/home/gaetan/dev/bench-results/qwen122-mmid-q5q6-rdna35-20260627-101206`
- `/home/gaetan/dev/bench-results/qwen122-mmid-q5-rpb4-rdna35-20260627-102607`

## Qwen122 ROCm Profiling And GDN Experiment 2026-06-27

Primary model:

- `/home/gaetan/models/qwen3.5/122B/unsloth/mtp/Qwen3.5-122B-A10B-UD-Q5_K_M-00001-of-00003.gguf`

Decode profile, `tg32`:

- Result directory: `/home/gaetan/dev/bench-results/qwen122-rocprof-tg32-20260627-103922`.
- Benchmark under profiler: `tg32 17.41 +/- 0.00`.
- Kernel dispatch total: `1.596569133s`, `61767` dispatches.
- Dominant kernels:

| Kernel family | Calls | Time | Share |
| --- | ---: | ---: | ---: |
| `mul_mat_vec_q` `Q8_0`, no fusion | 6208 | 805.87 ms | 50.48% |
| `mul_mat_vec_q` `Q5_K`, fusion | 1536 | 257.09 ms | 16.10% |
| `mul_mat_vec_q` `Q6_K`, no fusion | 1504 | 181.65 ms | 11.38% |
| `mul_mat_vec_q` `Q8_0`, fusion | 1920 | 100.48 ms | 6.29% |
| `mul_mat_vec_f` | 5376 | 59.59 ms | 3.73% |

Decode interpretation:

- Pure generation is dominated by `ncols_dst=1` MMVQ kernels, not the multi-token MoE `mul_mat_vec_q_moe` path.
- This explains why further `MUL_MAT_ID` max-batch tuning is not the main decode lever.
- Simple `nwarps=4` follow-ups were tested and rejected.

Prefill profile, `pp10000`:

- Result directory: `/home/gaetan/dev/bench-results/qwen122-rocprof-pp10000-20260627-110314`.
- Benchmark under profiler: `pp10000 339.04 +/- 0.00`.
- Kernel dispatch total: `29.250170559s`, `53039` dispatches.
- Dominant kernels:

| Kernel family | Calls | Time | Share |
| --- | ---: | ---: | ---: |
| `mul_mat_q` `Q5_K`, MMQ | 1920 | 6.598 s | 22.56% |
| `gated_delta_net_cuda<128,false,false>` | 720 | 6.306 s | 21.56% |
| `mul_mat_q` `Q6_K`, MMQ | 940 | 5.212 s | 17.82% |
| `mul_mat_q` `Q8_0`, MMQ | 6020 | 4.074 s | 13.93% |
| `flash_attn_tile<256,256,4,8,false>` | 240 | 2.221 s | 7.59% |

GDN trace notes:

- Qwen122 uses `gated_delta_net_cuda<128,false,false>` with `block=(32,4,1)` and `grid=(2048,4,32)` in the baseline.
- One GDN dispatch was a `1038.149 ms` outlier; without that, GDN still remains a major prefill hotspot.
- GDN duration distribution from trace: p50 `7.405 ms`, p90 `10.787 ms`, p95 `11.432 ms`, p99 `12.350 ms`.

Rejected follow-ups:

| Change | Correctness | Main result | Decision |
| --- | --- | --- | --- |
| `Q8_0 nwarps=4` for RDNA3.5 MMVQ `ncols_dst=1` | `Q8_0 MUL_MAT 47/47` | `tg32` noise-positive, but `tg128 @ d10000` `17.25 +/- 1.40` vs control `17.30 +/- 1.36` | Reject; no priority decode win. |
| `Q5_K/Q6_K nwarps=4` for RDNA3.5 MMVQ `ncols_dst=1` | targeted `46/46` | `tg32` `18.13 +/- 0.17` vs control `18.80 +/- 0.16` | Reject; clear decode regression. |
| `GATED_DELTA_NET num_warps=2` | `36/36` | `pp10000` `350.21 +/- 1.43` vs control `354.59 +/- 0.95` | Reject; prefill regression. |

Accepted local GDN change:

- On RDNA3.5 only, for `GATED_DELTA_NET` with `S_v=128`, `KDA=false`, and `keep_rs=false`, use `num_warps=8` instead of the default `4`.
- The default GDN path remains `num_warps=4` for other architectures and other GDN modes.
- Correctness: final targeted `test-backend-ops -o GATED_DELTA_NET -j 1` passed `36/36`.

Qwen122 A/B for GDN `num_warps=8`:

| Test | Control | GDN `num_warps=8` |
| --- | ---: | ---: |
| `pp10000` first A/B | 342.15 +/- 7.67 | 366.86 +/- 4.04 |
| `pp10000` rerun, reversed order | 343.47 +/- 7.47 | 367.62 +/- 6.87 |
| `pp10000` final targeted image | not rerun | 369.55 +/- 9.48 |
| `tg32` | 19.07 +/- 0.27 | 18.99 +/- 0.42; final image 19.08 +/- 0.24 |
| `tg128 @ d10000` | 17.37 +/- 1.36 | 17.42 +/- 1.33 |

GDN result directories:

- `/home/gaetan/dev/bench-results/qwen122-q8w4-rdna35-20260627-104852`
- `/home/gaetan/dev/bench-results/qwen122-q5q6w4-rdna35-20260627-105910`
- `/home/gaetan/dev/bench-results/qwen122-gdnw2-rdna35-20260627-110900`
- `/home/gaetan/dev/bench-results/qwen122-gdnw8-rdna35-20260627-111814`
- `/home/gaetan/dev/bench-results/qwen122-final-rdna35-20260627-114045`

Interpretation:

- The next small accepted optimization target is GDN prefill scheduling, not Flash Attention.
- The largest remaining prefill target is still quantized MMQ for `Q5_K/Q6_K/Q8_0`, likely requiring layout/repack or deeper kernel work rather than simple launch-parameter retuning.
- A future larger GDN optimization would be the existing TODO: a chunked prefill kernel.

Lychee Strix Halo build-flags check:

- Reference repo inspected: `https://github.com/Lychee-Technology/llama-cpp-for-strix-halo`.
- The repo packages upstream llama.cpp builds; it does not carry llama.cpp HIP/CUDA kernel patches.
- Tested local image: `llama-rocm-7.2.4-strix-lychee-flags`.
- Added only these build flags over the final source: `-DCMAKE_HIP_FLAGS="--rocm-path=/opt/rocm -mllvm --amdgpu-unroll-threshold-local=600"`, `-DCMAKE_C_FLAGS="-O3 -march=znver5 -mtune=znver5"`, and `-DCMAKE_CXX_FLAGS="-O3 -march=znver5 -mtune=znver5"`.
- Correctness: `GATED_DELTA_NET 36/36`, `MUL_MAT_ID 790/790`.
- Result directory: `/home/gaetan/dev/bench-results/lychee-flags-rdna35-20260627-133555`.

| Model | Test | Final | Lychee flags | Decision |
| --- | --- | ---: | ---: | --- |
| Qwen3.5 122B-A10B Q5_K_M | `pp10000`, `r3 --no-warmup` | 384.00 +/- 1.06 | 381.70 +/- 0.41 | Reject; small prefill regression. |
| Qwen3.5 122B-A10B Q5_K_M | `tg128 @ d10000`, `r3 --no-warmup` | 17.10 +/- 1.58 | 17.21 +/- 1.35 | Neutral/noisy. |
| GPT-OSS 20B MXFP4 | `pp10000`, `r5 --no-warmup` | 1909.37 +/- 31.29 | 1906.97 +/- 22.83 | Neutral/slightly negative. |
| GPT-OSS 20B MXFP4 | `tg128 @ d10000`, `r5 --no-warmup` | 64.42 +/- 0.21 | 64.51 +/- 0.27 | Neutral. |

- Do not keep the Lychee compiler flags in the final ROCm 7.2.4 Strix build based on these measurements.
- Still potentially worth testing separately later: a TheRock/ROCm 7.14 image. Do not infer a ROCm 7.14 result from this ROCm 7.2.4 flags-only A/B.

GDN fast-exp experimental check:

- Tested local image/toolbox: `llama-rocm-7.2.4-strix-gdnfastexp`.
- Source delta: GDN-only helper uses `__expf` instead of `expf` for `GGML_USE_HIP && RDNA3_5`; no MMQ/MMVQ/quantize/SiLU changes.
- Correctness: `test-backend-ops -o GATED_DELTA_NET -j 1` passed `36/36`.
- Result directory: `/home/gaetan/dev/bench-results/gdn-fast-exp-rdna35-20260627-141712`.

| Test | Final | GDN fast-exp | Decision |
| --- | ---: | ---: | --- |
| Qwen3.5 122B-A10B Q5_K_M `pp10000`, `r3 --no-warmup` | 389.78 +/- 0.28 | 393.14 +/- 0.57 | Small positive. |
| Qwen3.5 122B-A10B Q5_K_M `pp10000`, reversed rerun `r3 --no-warmup` | 365.89 +/- 8.73 | 378.25 +/- 9.40 | Positive but noisy. |
| Qwen3.5 122B-A10B Q5_K_M `pp10000`, `r5 --no-warmup` | 363.61 +/- 12.21 | 369.10 +/- 6.57 | Small positive, still noisy. |
| Qwen3.5 122B-A10B Q5_K_M `tg128 @ d10000`, `r3 --no-warmup` | 17.75 +/- 0.14 | 17.18 +/- 1.33 | Noisy/negative. |
| Qwen3.5 122B-A10B Q5_K_M `tg128 @ d10000`, `r5 --no-warmup` | 17.01 +/- 1.25 | 17.47 +/- 1.02 | Noisy/positive. |

GDN micro-perf highlights from `test-backend-ops perf -o GATED_DELTA_NET`:

| Case | Final | GDN fast-exp | Note |
| --- | ---: | ---: | --- |
| `head_count=32,head_size=128,n_seq_tokens=64,kda=0` | 160.85 us/run | 150.84 us/run | Faster. |
| `head_count=32,head_size=128,n_seq_tokens=512,kda=0` | 1829.18 us/run | 1510.88 us/run | Faster. |
| `head_count=32,head_size=128,n_seq_tokens=1024,kda=0` | 3551.08 us/run | 4186.42 us/run | Slower. |
| `head_count=32,head_size=128,n_seq_tokens=64,kda=1` | 197.77 us/run | 173.88 us/run | Faster. |

- Keep this as a separate risky/private experimental image only. Do not merge into the safe final branch without explicitly accepting the precision change from `expf` to `__expf`.

Issue 21284 / 24437 full-risk speed check:

- Issue 21284: `https://github.com/ggml-org/llama.cpp/issues/21284`.
- Issue 24437: `https://github.com/ggml-org/llama.cpp/issues/24437`.
- Tested local image/toolbox: `llama-rocm-7.2.4-strix-risky21284`.
- ROCm/rocWMMA policy from issue 24437: keep `GGML_HIP_ROCWMMA_FATTN=OFF` for `gfx1151`; our Dockerfile already leaves this off.
- Full-risk source delta over final source:
  - `mmq.cuh`: RDNA3.5 `mmq_x_max=48` instead of `64`.
  - `gated_delta_net.cu`: GDN-only `__expf` for `GGML_USE_HIP && RDNA3_5`.
  - `unary.cuh`: SiLU uses `__expf` for `GGML_USE_HIP && RDNA3_5`.
  - `quantize.cu`: `quantize_mmq_q8_1` uses `__float2int_rn` for `GGML_USE_HIP && RDNA3_5`.
  - `concat.cu`: corrected loop-invariant address hoist; not the gist's direct version, because the direct gist version double-counts offsets for non-zero concat dimensions.
- Not a delta: `common.cuh` `sudot4` is already active on `gfx1151` because `RDNA3` and `RDNA3_5` are both defined.
- Not a delta: RDNA3.5 `MMVQ` table split, `mmq_y=64`, and MMQ `nwarps=4` are already present in the current final source.
- Correctness passed on the full-risk image: `CONCAT 112/112`, `SILU 4/4`, `GATED_DELTA_NET 36/36`, `MUL_MAT 1134/1134`.
- Result directory: `/home/gaetan/dev/bench-results/risky21284-rdna35-20260627-145540`.

Issue-style local Q4 short-prefill A/B, `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`, `-p 128,256,512,1024,2048 -n 0 -r 3 -ngl 999 -fa on -mmp 0 -dio 1 -b 2048 -ub 2048`:

| Test | Final | Full-risk | Delta |
| --- | ---: | ---: | ---: |
| `pp128` | 848.82 +/- 21.67 | 841.60 +/- 61.33 | -0.85% |
| `pp256` | 1171.30 +/- 13.05 | 1194.85 +/- 13.54 | +2.01% |
| `pp512` | 1349.70 +/- 5.46 | 1375.54 +/- 1.54 | +1.91% |
| `pp1024` | 1435.91 +/- 10.79 | 1451.39 +/- 9.74 | +1.08% |
| `pp2048` | 1452.02 +/- 5.18 | 1463.66 +/- 19.12 | +0.80% |

Primary target A/B, `Qwen3.5-122B-A10B-UD-Q5_K_M`, `-r 3 --no-warmup -ngl 999 -fa on -mmp 0`:

| Test | Final | Full-risk | Delta |
| --- | ---: | ---: | ---: |
| `pp10000` | 370.61 +/- 0.46 | 379.81 +/- 0.93 | +2.48% |
| `tg128 @ d10000` | 16.62 +/- 2.35 | 17.24 +/- 1.34 | +3.73%, noisy |

Flash Attention runtime check from issue 24437, with rocWMMA still off:

| Model | Build | Test | `-fa off` | `-fa on` | Decision |
| --- | --- | --- | ---: | ---: | --- |
| Qwen3.6 35B Q4_K_XL | Final | `pp512` | 1355.23 +/- 9.57 | 1347.21 +/- 5.72 | off slightly faster/noisy. |
| Qwen3.6 35B Q4_K_XL | Final | `pp2048` | 1381.71 +/- 8.65 | 1483.24 +/- 6.42 | keep FA on. |
| Qwen3.6 35B Q4_K_XL | Final | `pp8192` | 1155.13 +/- 2.11 | 1362.80 +/- 6.58 | keep FA on. |
| Qwen3.6 35B Q4_K_XL | Full-risk | `pp512` | 1363.55 +/- 7.11 | 1371.40 +/- 5.62 | keep FA on. |
| Qwen3.6 35B Q4_K_XL | Full-risk | `pp2048` | 1363.02 +/- 11.17 | 1412.32 +/- 3.85 | keep FA on. |
| Qwen3.6 35B Q4_K_XL | Full-risk | `pp8192` | 1206.93 +/- 3.60 | 1362.13 +/- 8.26 | keep FA on. |
| Qwen3.5 122B Q5_K_M | Final | `pp10000` | 303.61 +/- 66.56 | 385.20 +/- 7.22 | keep FA on. |
| Qwen3.5 122B Q5_K_M | Full-risk | `pp10000` | 311.10 +/- 62.37 | 393.94 +/- 4.48 | keep FA on. |

- Interpretation: issue 24437 means avoid `GGML_HIP_ROCWMMA_FATTN=ON`, not disable runtime Flash Attention. With rocWMMA off, `-fa on` remains best for primary and large-context local tests.
- Full-risk image is currently the fastest Qwen122 prefill variant measured on this branch, but it is not correctness/quality-conservative because it includes `__expf` and `__float2int_rn` numerical changes.

Follow-up precision cleanup:

- Removed the numerical changes from the current fork path: GDN and SiLU use `expf` again, and `quantize_mmq_q8_1` uses `roundf` again.
- Kept the non-numerical RDNA3.5 tuning and concat address-hoist changes.

## MoE Original-vs-Final Scan 2026-06-27

Comparison:

- Original container: `llama-rocm-7.2.4`, build `3fc4e1052 (9820)`.
- Final container: `llama-rocm-7.2.4-strix-final`, build `a63032352 (9825)`.
- Main scan used `-r 1 --no-warmup` for coverage across all local MoE GGUF entries.
- `qwen35-35b-a3b-q6 tg128 @ d10000` was rerun with `-r 3 --no-warmup` because the first single-run result looked like a regression.

Result directory:

- `/home/gaetan/dev/bench-results/moe-original-vs-final-20260627-120716`

Summary:

| Model | Test | Original | Final | Delta |
| --- | --- | ---: | ---: | ---: |
| Qwen3.5 122B-A10B Q5_K_M | `pp10000` | 231.97 | 359.92 | +55.16% |
| Qwen3.5 122B-A10B Q5_K_M | `tg128 @ d10000` | 18.14 | 18.45 | +1.71% |
| Step-3.7-flash IQ4_XS | `pp10000` | 258.88 | 377.73 | +45.91% |
| Step-3.7-flash IQ4_XS | `tg128 @ d10000` | 20.23 | 20.40 | +0.84% |
| GPT-OSS 120B MXFP4_MOE | `pp10000` | 617.48 | 739.47 | +19.76% |
| GPT-OSS 120B MXFP4_MOE | `tg128 @ d10000` | 32.98 | 45.04 | +36.57% |
| GPT-OSS 20B MXFP4 | `pp10000` | 1574.89 | 1892.08 | +20.14% |
| GPT-OSS 20B MXFP4 | `tg128 @ d10000` | 63.25 | 64.08 | +1.31% |
| Qwen3.6 35B-A3B Q8_K_XL | `pp10000` | 950.99 | 1112.12 | +16.94% |
| Qwen3.6 35B-A3B Q8_K_XL | `tg128 @ d10000` | 42.27 | 42.62 | +0.83% |
| Qwen3.6 35B-A3B Q6_K_XL | `pp10000` | 858.57 | 956.68 | +11.43% |
| Qwen3.6 35B-A3B Q6_K_XL | `tg128 @ d10000` | 43.77 | 44.54 | +1.76% |
| Qwen3.5 35B-A3B IQ4_XS | `pp10000` | 886.42 | 1096.12 | +23.66% |
| Qwen3.5 35B-A3B IQ4_XS | `tg128 @ d10000` | 49.09 | 50.86 | +3.61% |
| Qwen3.5 35B-A3B MXFP4_MOE | `pp10000` | 1000.44 | 1255.82 | +25.53% |
| Qwen3.5 35B-A3B MXFP4_MOE | `tg128 @ d10000` | 46.16 | 45.85 | -0.67% |
| Qwen3.5 35B-A3B Q6_K | `pp10000` | 751.76 | 964.42 | +28.29% |
| Qwen3.5 35B-A3B Q6_K | `tg128 @ d10000` | 41.86 +/- 7.31 | 47.33 +/- 0.26 | +13.07% |
| Qwen3.5 35B-A3B BF16 | `pp10000` | 455.99 | 462.70 | +1.47% |
| Qwen3.5 35B-A3B BF16 | `tg128 @ d10000` | 22.60 | 22.50 | -0.44% |
| Qwen3-Coder-Next Q8_K_XL | `pp10000` | 602.43 | 701.69 | +16.48% |
| Qwen3-Coder-Next Q8_K_XL | `tg128 @ d10000` | 33.03 | 33.77 | +2.24% |
| Qwen3-Coder-Next Q6_K_XL | `pp10000` | 542.49 | 697.10 | +28.50% |
| Qwen3-Coder-Next Q6_K_XL | `tg128 @ d10000` | 34.92 | 34.97 | +0.14% |
| Ornith 35B Q8_0 | `pp10000` | 879.10 | 1053.20 | +19.80% |
| Ornith 35B Q8_0 | `tg128 @ d10000` | 41.87 | 43.63 | +4.20% |

Notes:

- `Step3.7-flash-mtp-Q8_0.gguf` failed with exit `139` on both original and final, so it is not a final-build regression.
- Final is strongly better for prefill across usable local MoE models.
- Generation is mostly neutral-to-positive; small single-run negatives on MXFP4/BF16 are noise-level unless strict `-r 3` confirmation is needed.

## Blockers and Annoyances

`tbx`:

- Official `tbx` flow clones from `--repo` / `--branch`; it does not naturally build a dirty local checkout.
- Workaround is the local Dockerfile with `COPY . .`.

SSH in Podman build:

- SSH clone failed with host key verification.
- Workaround is HTTPS or local Dockerfile.

Toolbox shell noise:

- Every `toolbox run` prints `/home/gaetan/.bashrc: line 42: /home/linuxbrew/.linuxbrew/bin/brew: No such file or directory`.
- This is harmless for benchmarking but should be cleaned up.

## Next Steps

Immediate:

- Keep the main dirty checkout as-is for now.
- Keep all variant clones/toolboxes available for investigation.
- Treat `MMVQ+FA` K64 as the selected MoE-favored candidate.
- Dense Gemma regressions are no longer a hard blocker because MoE throughput is the priority.
- Keep `MMVQ-only` as the fallback/control for low-bit `Q2_K_XL` and `Q3_K_XL`, but not as the final chosen version.
- Drop `MMVQ+FA-K256`; it is worse than the original `MMVQ+FA` on every spot-check model and does not fix Gemma.
- Treat `MMVQ+FA-B64K128` as a control/no-K64 variant, not an optimization candidate.
- Do not spend more time on `MMQ48` unless a new model shape gives a reason.
- Keep `quantize-only` as correctness-safe but performance-unproven.

Benchmarks to rerun with higher confidence:

- Qwen 35B-A3B Downloads: optionally rerun `Q4_K_XL`, `Q6_K_XL`, and `Q8_K_XL` with higher `-r` to confirm the K64 mixed-throughput gains.
- GPT-OSS 20B MXFP4: rerun longer contexts and more reps because it is now a primary MoE target.
- Dense Qwen/Gemma: only revisit if needed for correctness or if the final fork should also be safe as a general default.

Code investigations:

- For a MoE-favored fork, consider keeping the K64 FA override despite dense Gemma regression.
- If keeping general safety, add a narrower runtime gate for `DKQ=256,DV=256,ncols=32` that can exclude Gemma SWA.
- Consider adding temporary debug logging for FA tile selection in local-only builds.

Useful commands:

```bash
toolbox run -c llama-rocm-7.2.4-strix-mmvq-fa test-backend-ops test -b ROCm0 -o MUL_MAT -j 1
toolbox run -c llama-rocm-7.2.4-strix-mmvq-fa llama-bench -m /home/gaetan/Downloads/Qwen3.5-4B-UD-Q8_K_XL.gguf -p 3000,6000,9000,16000 -n 0 -ngl 999 -fa on -mmp 0 -o md
toolbox run -c llama-rocm-7.2.4-strix-mmvq-fa llama-bench -m /home/gaetan/Downloads/Qwen3.5-4B-UD-Q8_K_XL.gguf -pg 3000,128 -pg 6000,128 -pg 9000,128 -pg 16000,128 -ngl 999 -fa on -mmp 0 -o md
```

Do not keep changes that fail `test-backend-ops` or only improve one narrow canary while regressing generation.
