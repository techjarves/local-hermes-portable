# local-hermes-portable

<p align="center">
  <strong>A premium, zero-configuration local AI inference & agentic workspace. Powered by hardware-accelerated GPU execution on Windows, macOS, and Linux.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Offline-100%25-green?style=for-the-badge&logo=offline" alt="100% Offline" />
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-blue?style=for-the-badge" alt="Platforms" />
  <img src="https://img.shields.io/badge/Engine-llama.cpp-orange?style=for-the-badge" alt="Engine" />
  <img src="https://img.shields.io/badge/Agent-Hermes%20v0.18-red?style=for-the-badge" alt="Agent" />
  <img src="https://img.shields.io/badge/License-MIT-purple?style=for-the-badge" alt="License" />
</p>

<p align="center">
  🎥 <strong>Watch the Setup & Demo Video:</strong> <a href="https://youtu.be/TWZv6fo3JLc">https://youtu.be/TWZv6fo3JLc</a>
</p>

<p align="center">
  <a href="https://youtu.be/TWZv6fo3JLc" target="_blank">
    <img src="https://img.youtube.com/vi/TWZv6fo3JLc/maxresdefault.jpg" alt="Watch the Setup & Demo Video" width="800" style="border-radius: 8px; box-shadow: 0 4px 16px rgba(0,0,0,0.25);" />
  </a>
</p>

---

## Table of Contents
* [Key Features](#key-features)
* [System Requirements](#system-requirements)
* [Getting Started](#getting-started)
* [Main Menu Options](#main-menu-options)
* [Folder Architecture](#folder-architecture)
* [Advanced Options](#advanced-options)
* [License](#license)

---

## <a id="key-features"></a>Key Features

*   **100% Offline & Private:** Zero internet, telemetry, cloud logging, or API keys required.
*   **Zero-Install Portability:** Self-contained runtime (Python, llama.cpp binaries, and dependencies) running out of any storage drive.
*   **Autonomous Hermes Agent:** Preconfigured Nous Research terminal coding agent with file editing and web tasks capabilities.
*   **Auto-Configured Acceleration:** Auto-syncs launcher settings and offloads model layers to Vulkan/Metal compatible GPUs.
*   **Optimal Resource Management:** Preconfigured with 8-bit quantized KV cache, 64K context limits, and timeout protection.
*   **Guided Setup & Recovery:** Profiles hardware specs to download recommended GGUF models and cleans up zombie server instances.

---

## <a id="system-requirements"></a>System Requirements

Since `local-hermes-portable` is fully self-contained, it does not require system-wide Python or Node.js installations. However, you will need:

*   **Operating System:** 
    *   **Windows:** Windows 10 / 11 (64-bit)
    *   **macOS:** macOS 11.0 (Big Sur) or newer (Apple Silicon recommended, Intel supported)
    *   **Linux:** Modern 64-bit kernel (Vulkan / ROCm compatible for GPU acceleration)
*   **System Utilities:** `curl` and `tar` (pre-installed on most modern OS configurations, used for auto-bootstrapping runtime assets).
*   **Hardware Recommendations:**
    *   **RAM:** 8 GB minimum (16 GB or more recommended).
    *   **Disk Space:** 5 GB to 15 GB of free space on your drive (depending on the size of the downloaded GGUF models).
    *   **GPU Acceleration:**
        *   *Windows/Linux:* Vulkan-compatible GPU (NVIDIA, AMD, or Intel) for hardware acceleration.
        *   *macOS:* Apple Silicon (M-series chip) for Metal-accelerated inference.

---

## <a id="getting-started"></a>Getting Started

To start, run the appropriate launcher script from the root of the project:

### Windows Setup
```powershell
.\windows.bat
```
*   **What it does:** Automatically bootstraps a portable Python environment, installs VC++ Redistributable and llama.cpp Vulkan precompiled binaries if needed, and launches the interactive menu.

### macOS Setup
```bash
./mac.sh
```
*   **What it does:** Auto-detects Apple Silicon/Intel hardware, configures portable Python, and launches the server with Metal-accelerated binaries.

### Linux Setup
```bash
./linux.sh
```
*   **What it does:** Auto-detects Vulkan/ROCm GPU environments, builds runtime libraries, and configures portable Python.

---

## <a id="main-menu-options"></a>Main Menu Options

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

## <a id="folder-architecture"></a>Folder Architecture

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

## <a id="advanced-options"></a>Advanced Options

You can configure environment variables to override launcher defaults:

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `LLAMA_CTX_SIZE` | `65536` | Context window size for `llama-server` (Hermes requires $\ge$ 64K). |
| `LLAMA_SLOTS` | `1` | Number of parallel sequence slots (lower saves memory). |
| `LLAMA_GPU_LAYERS` | `99` | Number of layers to offload to the GPU (99 offloads the full model). |
| `AUTO_LAUNCH_BROWSER`| `false` | Whether to automatically open the web browser when the server is ready. |

---

## <a id="license"></a>License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
All bundled components (llama.cpp, Hermes Agent, llmfit) are property of their respective creators and licensed under their original open-source terms.
