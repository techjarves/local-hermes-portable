# 🦙 local-hermes-portable

[![Platform: Windows | macOS | Linux](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue?style=flat-square)](#-quick-start)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Engine: llama.cpp](https://img.shields.io/badge/engine-llama.cpp%20(CachyLLama)-orange?style=flat-square)](https://github.com/fewtarius/CachyLLama)
[![Agent: Hermes v0.18](https://img.shields.io/badge/agent-Hermes%20v0.18-red?style=flat-square)](https://github.com/NousResearch/Hermes-Agent)

A self-contained, plug-and-play local AI inference & agentic workspace that runs out-of-the-box on **Windows**, **macOS**, and **Linux** with **zero system-level dependencies**. 

This suite bundles optimized local LLM inference engines (CachyLLama/llama.cpp) with the **Nous Research Hermes Agent** and **llmfit** diagnostics, preconfigured to run portably from any storage drive (including USB / exFAT partitions).

---

## 🚀 Quick Start

To start, run the appropriate launcher script from the root of the project:

### 🪟 Windows
```powershell
.\windows.bat
```
*   **What it does:** Automatically bootstraps a portable Python environment, installs VC++ Redistributable and llama.cpp Vulkan precompiled binaries if needed, and launches the interactive menu.

### 🍏 macOS
```bash
./mac.sh
```
*   **What it does:** Auto-detects Apple Silicon/Intel hardware, configures portable Python, and launches the server with Metal-accelerated binaries.

### 🐧 Linux
```bash
./linux.sh
```
*   **What it does:** Auto-detects Vulkan/ROCm GPU environments, builds runtime libraries, and configures portable Python.

---

## 🛠️ Main Menu Options

When you run a launcher, you're presented with a terminal dashboard:

```text
=== llama-ai Portable Setup & Launcher ===

Choose an action:
1] Start Chat Server and Web UI [default]
2] Run Hardware Analysis and Model Fit [llmfit]
3] Start Hermes Agent
4] Quit
```

1.  **Start Chat Server (Option 1):** Starts `llama-server` on `http://localhost:9090` with full GPU offloading, auto-detects complete local GGUF models, and opens the Web UI. If no model exists, Windows, macOS, and Linux all offer the same browser setup: llmfit detects total and currently available RAM, presents recommended models, and supports searches such as Gemma or Qwen. Downloads show inline progress and can be canceled/resumed. An optional first-chat prompt can be entered before continuing into the normal Chat Web UI.
2.  **Hardware Analysis (Option 2):** Runs `llmfit` to scan your CPU, GPU, RAM, and VRAM and recommends the best-fitting GGUF models for your system.
3.  **Start Hermes Agent (Option 3):** Launches the **Hermes Agent TUI** (Nous Research), fully configured to use your local server and active model for automated coding and browser tasks.

---

## ✨ Core Features

*   **Integrated Hermes Agent (Nous Research):** Ready-to-go terminal coding agent with capabilities for file editing, web browsing, code execution, and subagent delegation.
*   **Auto-Syncing Configuration:** The server launcher automatically updates the Hermes configuration (`config.yaml`) with the active model's path, setting up the `llamacpp` provider with no manual editing required.
*   **Memory & Performance Optimizations:**
    *   **GPU Acceleration (`-ngl 99`):** Automatically offloads model layers to Vulkan/Metal compatible GPUs, boosting prompt prefill speeds up to 50x compared to CPU execution.
    *   **Single-Slot Restricting (`-np 1`):** Limits parallel server slots to 1 for agent chats, saving up to 75% of KV cache memory.
    *   **8-bit Quantized KV Cache (`--cache-type-k q8_0 --cache-type-v q8_0`):** Compresses key-value storage, keeping RAM usage low and avoiding system disk swapping.
    *   **Context & Timeout Management:** Caps repository context file loads (e.g. `AGENTS.md`) to 5,000 characters to ensure sub-10 second prompt evaluations, and extends client timeouts to 10 minutes (`600s`) to prevent connection timeouts during heavy reasoning workloads.
*   **Guided Zero-Model Startup:** If no complete GGUF exists, the launcher asks before opening a focused llmfit-powered model setup page. Downloads are resumable, stay in `models/`, and multi-part models are only offered to the server after every shard is complete.
*   **Process Protection:** The script automatically finds and kills zombie background processes (like lingering `llama-server.exe` instances) on startup to prevent port collisions.

---

## 📂 Project Layout

The repository keeps a clean, multi-platform file structure:

```
local-hermes-portable/
├── windows.bat         # Windows setup & menu launcher
├── mac.sh              # macOS setup & menu launcher
├── linux.sh            # Linux setup & menu launcher
├── models/             # Place your downloaded GGUF models here
├── scripts/            # Platform-specific utilities (GPU detection, benchmarks)
├── hermes/             # Nous Research Hermes Agent folder
│   ├── data/           # Settings & active database (config.yaml, session history)
│   └── src/            # Agent codebase and tools
└── llama/              # Local inference binaries & configs
    ├── kv-cache/       # Cache directory for prompt sharing
    └── windows/        # Bootstrapped Python, binaries, and wait-server scripts
```

---

## 📚 Advanced Options

You can configure environment variables to override launcher defaults:

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `LLAMA_CTX_SIZE` | `65536` | Context window size for `llama-server` (Hermes requires $\ge$ 64K). |
| `LLAMA_SLOTS` | `1` | Number of parallel sequence slots (lower saves memory). |
| `LLAMA_GPU_LAYERS` | `99` | Number of layers to offload to the GPU (99 offloads the full model). |
| `AUTO_LAUNCH_BROWSER`| `false` | Whether to automatically open the web browser when the server is ready. |

---

## 📝 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
All bundled components (llama.cpp, Hermes Agent, llmfit) are property of their respective creators and licensed under their original open-source terms.
