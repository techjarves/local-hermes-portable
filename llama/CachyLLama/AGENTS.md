# AGENTS.md

**Version:** 1.0
**Date:** 2026-05-07
**Purpose:** Technical reference for llama.cpp development (methodology in .clio/instructions.md)

---

## Project Overview

**llama.cpp** is a C/C++ inference engine for LLM models in GGUF format, built on the ggml tensor library.

- **Languages:** C11, C++17, Python (conversion/scripts), JavaScript (server webui)
- **Build System:** CMake 3.14+
- **Architecture:** Modular C library with multi-backend hardware acceleration
- **License:** MIT (Copyright (c) 2023-2026 The ggml authors)

---

## Quick Setup

```bash
# Clone (with submodules for ggml)
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

# Build (CPU-only, Release)
cmake -B build
cmake --build build --config Release -j$(nproc)

# Build with CUDA
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc)

# Build with Vulkan
cmake -B build -DGGML_VULKAN=ON
cmake --build build --config Release -j$(nproc)

# Run the server
./build/bin/llama-server -m /path/to/model.gguf

# Run CLI chat
./build/bin/llama-cli -m /path/to/model.gguf

# Run tests
cd build && ctest --output-on-failure
```

---

## Architecture

```
                    include/llama.h (Public C API)
                          |
                    src/llama.cpp (API implementation)
                          |
         +----------------+----------------+
         |                |                |
   src/llama-model   src/llama-context  src/llama-sampler
   src/llama-chat    src/llama-vocab    src/llama-grammar
   src/llama-kv-cache  src/llama-graph  src/llama-batch
         |
    ggml/ (Tensor library - Git submodule)
         |
    +----+----+----+----+----+----+
    |    |    |    |    |    |    |
   CPU CUDA Metal Vulkan SYCL HIP ...
```

**Key subsystems:**
- **ggml** - Tensor library with hardware backends (CPU, CUDA, Metal, Vulkan, SYCL, HIP, etc.)
- **llama** - LLM inference engine built on ggml
- **common** - Shared utilities (arg parsing, sampling, chat, Jinja, PEG parser)
- **tools** - Executable programs (server, CLI, quantize, bench, perplexity, etc.)
- **gguf-py** - Python library for reading/writing GGUF files

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `include/` | Public C API headers (`llama.h`, `llama-cpp.h`) |
| `src/` | Core llama library implementation (model loading, inference, sampling) |
| `ggml/` | ggml tensor library (submodule: backends, quantization, graph execution) |
| `common/` | Shared utilities for tools/examples (arg parsing, chat, sampling, Jinja) |
| `common/jinja/` | Jinja template engine (chat templates) |
| `tools/` | Executable tools (server, CLI, bench, perplexity, quantize, etc.) |
| `tools/server/` | OpenAI-compatible HTTP server |
| `tests/` | CTest-based C++ unit tests |
| `examples/` | Example programs demonstrating API usage |
| `gguf-py/` | Python GGUF reader/writer library |
| `scripts/` | Build helpers, benchmarks, CI utilities |
| `docs/` | Documentation (build guides, architecture, development) |
| `convert_hf_to_gguf.py` | Convert HuggingFace models to GGUF format |
| `vendor/` | Vendored dependencies (cpp-httplib, nlohmann/json, miniaudio, stb, sheredom) |
| `grammars/` | GBNF grammar files |
| `ci/` | CI run scripts |
| `cmake/` | CMake modules and helpers |
| `benches/` | Benchmark configurations |

---

## Code Style

**C/C++ Conventions:**

- **C++17** standard, **C11** for ggml core
- **4 spaces** indentation, no tabs
- **LF line endings**, UTF-8 encoding
- **Vertical alignment** for readability
- Brackets on same line: `if (cond) {`
- Pointer/reference alignment: `void * ptr`, `int & a`
- `snake_case` for functions, variables, and types
- Naming optimizes for **longest common prefix** (e.g., `number_small`, `number_big`)
- Sized integer types in public API: `int32_t`, `uint32_t`
- Declare structs as `struct foo {}` not `typedef struct foo {} foo`
- In C++ omit `struct`/`enum` keyword when unnecessary
- Avoid templates, fancy STL constructs - use basic `for` loops
- Keep it simple, minimal dependencies

**Formatting:** Use `.clang-format` (clang-tools v15+) when in doubt. The project has a comprehensive `.clang-format` config at the root.

**EditorConfig:** Root `.editorconfig` enforces: spaces, indent 4, LF, UTF-8, trailing whitespace trimmed.

**Pre-commit hooks:** trailing-whitespace, end-of-file-fixer, check-yaml, check-added-large-files, flake8.

---

## Module Naming Conventions

| Prefix | Purpose | Examples |
|--------|---------|----------|
| `llama-*` | Core llama modules | `llama-model`, `llama-context`, `llama-sampler` |
| `ggml-*` | ggml backend modules | `ggml-cpu`, `ggml-cuda`, `ggml-metal`, `ggml-vulkan` |
| `test-*` | Test files | `test-backend-ops`, `test-tokenizer-0`, `test-sampling` |

Source files follow the pattern: `src/llama-{module}.cpp` / `src/llama-{module}.h`

---

## Testing

**Before Committing:**

```bash
# Build with tests enabled (default for standalone builds)
cmake -B build -DLLAMA_BUILD_TESTS=ON
cmake --build build -j$(nproc)

# Run all tests
cd build && ctest --output-on-failure

# Run specific test binary directly
./build/bin/test-backend-ops
./build/bin/test-sampling
./build/bin/test-tokenizer-0

# Run CI locally (comprehensive)
./ci/run.sh

# Performance regression check
./build/bin/llama-bench
./build/bin/llama-perplexity
```

**Key Test Binaries:**

| Test | Purpose |
|------|---------|
| `test-backend-ops` | Verify ggml operator consistency across backends |
| `test-sampling` | Token sampling correctness |
| `test-tokenizer-0` | Tokenizer roundtrip tests |
| `test-chat-template` | Chat template rendering |
| `test-grammar-parser` | GBNF grammar parsing |
| `test-quantize-fns` | Quantization function correctness |
| `test-chat.cpp` | End-to-end chat tests |

**Python Tests:**

```bash
# GGUF Python library tests
cd gguf-py && python -m pytest tests/

# Tokenizer tests
python tests/test-tokenizer-0.py
```

---

## Commit Format

Project maintainers squash-merge PRs with format:

```
<module> : <commit title> (#<issue_number>)
```

**Example:** `utils : fix typo in utils.py (#1234)`

Modules listed at: https://github.com/ggml-org/llama.cpp/wiki/Modules

---

## Development Tools

**Common Commands:**

```bash
# Quick rebuild (after initial cmake)
cmake --build build -j$(nproc)

# Debug build
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build

# Address sanitizer
cmake -B build -DLLAMA_SANITIZE_ADDRESS=ON
cmake --build build

# Run the server with a model
./build/bin/llama-server -m model.gguf --port 8080

# CLI inference
./build/bin/llama-cli -m model.gguf -p "Hello, world"

# Quantize a model
./build/bin/llama-quantize input.gguf output.gguf Q4_K_M

# Convert HuggingFace model
python convert_hf_to_gguf.py /path/to/model --outfile output.gguf

# Benchmark
./build/bin/llama-bench -m model.gguf

# Check GGUF file info
python -m gguf.scripts.gguf_dump model.gguf
```

---

## Common Patterns

**Matrix Multiplication Convention:**

`C = ggml_mul_mat(ctx, A, B)` means C^T = A * B^T, i.e. C = B * A^T. This is **unconventional** - always keep it in mind when working with tensor operations.

**Tensor Dimensions:**

Tensors store data in row-major order. Dimension 0 = columns, 1 = rows, 2 = matrices.

**Adding a New Model:**

See `docs/development/HOWTO-add-model.md` for the full guide. Key files:
- `src/llama-model.cpp` - Model forward pass
- `src/llama-arch.cpp` / `src/llama-arch.h` - Architecture definitions
- `src/llama-hparams.cpp` / `src/llama-hparams.h` - Hyperparameters
- `convert_hf_to_gguf.py` - Model conversion

**Chat Template Parsing:**

llama.cpp uses a custom PEG parser (not regex) for parsing model output. See `docs/development/parsing.md` and `docs/autoparser.md`.

**Server API:**

The server (`tools/server/`) is OpenAI-compatible. See `tools/server/README.md` (usage) and `tools/server/README-dev.md` (development).

---

## Documentation

### What Needs Documentation

| Change Type | Required Documentation |
|-------------|------------------------|
| New model architecture | `docs/development/HOWTO-add-model.md`, `src/` headers |
| New ggml operator | `docs/ops.md`, test cases in `test-backend-ops` |
| Server API change | `tools/server/README.md` |
| Build system change | `docs/build.md` |
| New quantization type | Perplexity data, KL divergence, performance benchmarks |
| Python API change | `gguf-py/` docstrings |
| New tool | `README.md` in tool directory |

### Key Documentation Files

- `docs/build.md` - Build instructions for all platforms/backends
- `docs/development/HOWTO-add-model.md` - Adding new model support
- `docs/development/parsing.md` - PEG parser for model output
- `docs/autoparser.md` - Auto-detecting model features
- `docs/ops.md` - ggml operator reference
- `tools/server/README.md` - Server usage
- `tools/server/README-dev.md` - Server development guide
- `CONTRIBUTING.md` - Contribution guidelines and coding standards
- `common/jinja/README.md` - Jinja template engine

---

## Anti-Patterns (What NOT To Do)

| Anti-Pattern | Why It's Wrong | What To Do |
|--------------|----------------|------------|
| Adding third-party dependencies | Project minimizes deps intentionally | Use vendored libs in `vendor/` or implement inline |
| Using `typedef struct foo {} foo` | Project convention is `struct foo {}` | Declare as `struct foo {}` |
| Fancy template metaprogramming | Codebase avoids complex STL constructs | Use basic loops and simple patterns |
| Mixing unrelated changes in one PR | Maintainers require separate PRs per feature | Create one PR per feature or fix |
| Adding new model with GPU support initially | Too much review scope | CPU-only first, GPU backends in follow-ups |
| Using regex for output parsing | Project uses PEG parser | Use `common/chat-peg-parser.h` |
| Ignoring clang-format | Project has strict formatting rules | Run clang-format, respect `.editorconfig` |
| AI-generated PR descriptions | Will result in immediate PR closure | Write descriptions yourself |
| Committing handoff files | Session notes are internal | Keep `ai-assisted/` out of git |

---

## Quick Reference

```bash
# Build
cmake -B build && cmake --build build -j$(nproc)

# Test
cd build && ctest --output-on-failure

# Server
./build/bin/llama-server -m model.gguf

# CLI
./build/bin/llama-cli -m model.gguf

# Quantize
./build/bin/llama-quantize input.gguf output.gguf Q4_K_M

# Convert
python convert_hf_to_gguf.py /path/to/hf-model

# CI locally
./ci/run.sh

# Format check
git diff --name-only | grep -E '\.(c|cpp|h|hpp)$' | xargs clang-format --dry-run -Werror

# Search code
grep -rn "pattern" src/ common/ include/
```

---

*For project methodology and workflow, see .clio/instructions.md*
