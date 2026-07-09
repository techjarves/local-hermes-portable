# llama-ai: Portable Local AI Inference Suite

A self-contained, plug-and-play local LLM inference package that runs out-of-the-box on **macOS**, **Linux**, and **Windows**. 

Built around [CachyLLama](https://github.com/fewtarius/CachyLLama) (our optimized fork of [llama.cpp](https://github.com/ggml-org/llama.cpp)) and integrated with [llmfit](https://github.com/AlexsJones/llmfit), this project is optimized to run portably from any storage drive (including USB/exFAT partitions) with zero system-level dependencies.

---

## 🚀 Quick Start

Run the appropriate launcher script from the root of the project:

### 🍏 macOS
```bash
./mac.sh
```
*Auto-detects Apple Silicon/Intel and configures portable Python & Metal binaries.*

### 🐧 Linux
```bash
./linux.sh
```
*Auto-detects GPU environment (Vulkan/ROCm) and configures portable Python & runtime libraries.*

### 🪟 Windows
```cmd
windows.bat
```
*Native, flat CMD/PowerShell setup. Automatically handles portable Python boot and compiles/downloads prebuilt Vulkan & CPU fallbacks.*

---

## 🛠️ Features

* **Interactive Setup & Routing Menu**: Run the launchers without arguments to choose between starting the server, scanning hardware, listing models, or quitting.
* **Router Mode (Zero-Model Web GUI)**: If no models are present in your `models/` folder, the launcher automatically starts the server in Router Mode and pops open your default browser to `http://localhost:9090` to download models visually via Hugging Face.
* **Portable Hardware Recommendation (`llmfit`)**:
  * Pass `--recommend` to list the top 10 models matching your exact system specs (CPU, GPU, RAM, VRAM).
  * Pass `--fit-tui` to launch the full interactive terminal diagnostic dashboard.
* **Automated Port Listener**: Background watchers check when the llama port goes live and launch your system browser automatically.
* **Grammar Limits Patch**: Modified repetition thresholds to `1,000,000` to prevent grammar compilation crashes when agentic IDEs request structured output schemas.

---

## 📂 Project Layout

The root folder has been cleaned up to show only the 3 multi-platform launcher scripts and 3 main folders:

```
/ (Root Directory)
├── windows.bat         <-- Windows launcher
├── linux.sh            <-- Linux launcher
├── mac.sh              <-- macOS launcher
├── models/             <-- Put your GGUF models here
├── scripts/            <-- System utilities (detect-gpu, benchmark, reset)
└── llama/              <-- Consolidated core engine directory
    ├── CachyLLama/     <-- CachyLLama C++ source repository
    ├── docs/           <-- Advanced documentation (AGENTS, LICENSES, architecture)
    ├── mac/            <-- macOS portable python & runtime binaries
    ├── linux/          <-- Linux portable python & runtime binaries
    ├── windows/        <-- Windows portable python & runtime binaries
    └── kv-cache/       <-- Local prompt cache folder
```

---

## 📚 Advanced Documentation

For in-depth explanations on the custom CachyLLama features, SSD prompt caches, memory allocations, kernel tuning, and real-world benchmark statistics:
* [llama/docs/README.md](file:///Users/jarves/Youtube/llama-ai/llama/docs/README.md) - Core architecture, ROCm, Vulkan, and caching strategy.
* [llama/docs/AGENTS.md](file:///Users/jarves/Youtube/llama-ai/llama/docs/AGENTS.md) - Code style, build instructions, and developer guidelines.
