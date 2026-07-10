#!/bin/sh
# linux.sh - Linux Launcher for llama-ai portable setup
# Usage: sh linux.sh [args]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
mkdir -p "$PROJECT_ROOT/models"
echo "=== llama-ai Linux Portable Setup & Launcher ==="

# 1. Setup Portable Python
if [ ! -d "$PROJECT_ROOT/llama/linux/python" ]; then
    echo "Installing portable Python..."
    mkdir -p "$PROJECT_ROOT/llama/linux"
    
    # Detect CPU Architecture for portable runtime compatibility
    ARCH="$(uname -m)"
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.10.13+20240107-aarch64-unknown-linux-gnu-install_only.tar.gz"
    else
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.10.13+20240107-x86_64-unknown-linux-gnu-install_only.tar.gz"
    fi
    
    echo "Downloading from: $PYTHON_URL"
    if ! curl -L -o "$PROJECT_ROOT/llama/linux/python.tar.gz" "$PYTHON_URL"; then
        echo "Error: Failed to download portable Python."
        exit 1
    fi
    
    mkdir -p "$PROJECT_ROOT/llama/linux/python"
    echo "Extracting..."
    if ! tar -xzf "$PROJECT_ROOT/llama/linux/python.tar.gz" -C "$PROJECT_ROOT/llama/linux/python" --strip-components=1; then
        echo "Error: Failed to extract Python."
        rm -rf "$PROJECT_ROOT/llama/linux/python"
        exit 1
    fi
    rm "$PROJECT_ROOT/llama/linux/python.tar.gz"
    
    # Resolve Symlinks for exFAT compatibility
    echo "Resolving symlinks in Python folder for exFAT compatibility..."
    find "$PROJECT_ROOT/llama/linux/python" -type l | while read -r symlink; do
        target="$(readlink "$symlink")"
        dir="$(dirname "$symlink")"
        abs_target="$(cd "$dir" && pwd)/$target"
        rm "$symlink"
        if [ -d "$abs_target" ]; then
            cp -R "$abs_target" "$symlink"
        else
            cp "$abs_target" "$symlink"
        fi
    done
    
    echo "Bootstrapping pip and dependencies..."
    "$PROJECT_ROOT/llama/linux/python/bin/python3" -m pip install --upgrade pip
    "$PROJECT_ROOT/llama/linux/python/bin/python3" -m pip install huggingface_hub urllib3
fi

# 2. Build CachyLLama if binaries are missing
# 2. Download precompiled CachyLLama if missing
if [ ! -f "$PROJECT_ROOT/llama/linux/bin/llama-server" ] || [ ! -f "$PROJECT_ROOT/llama/linux/bin/llama-cli" ]; then
    echo "Downloading precompiled CachyLLama Vulkan backend..."
    mkdir -p "$PROJECT_ROOT/llama/linux/bin"
    
    local_arch="$(uname -m)"
    if [ "$local_arch" = "aarch64" ] || [ "$local_arch" = "arm64" ]; then
        llama_url="https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-ubuntu-vulkan-arm64.tar.gz"
    else
        llama_url="https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-ubuntu-vulkan-x64.tar.gz"
    fi
    
    if curl -L -s "$llama_url" -o "$PROJECT_ROOT/llama/linux/bin/llama_linux.tar.gz"; then
        tar -xzf "$PROJECT_ROOT/llama/linux/bin/llama_linux.tar.gz" -C "$PROJECT_ROOT/llama/linux/bin" --strip-components=1
        rm -f "$PROJECT_ROOT/llama/linux/bin/llama_linux.tar.gz"
        
        # Ensure executable
        chmod +x "$PROJECT_ROOT/llama/linux/bin/llama-server" "$PROJECT_ROOT/llama/linux/bin/llama-cli" 2>/dev/null || true
        echo "Download and setup complete."
    else
        echo "Error: Failed to download precompiled CachyLLama binaries."
        exit 1
    fi
fi

# 2b. Download llmfit if not present
if [ ! -f "$PROJECT_ROOT/llama/linux/bin/llmfit" ]; then
    echo "Downloading portable hardware analyzer (llmfit)..."
    mkdir -p "$PROJECT_ROOT/llama/linux/bin"
    
    # Detect CPU arch to download correct aarch64 vs x86_64 binary
    local_arch="$(uname -m)"
    if [ "$local_arch" = "aarch64" ] || [ "$local_arch" = "arm64" ]; then
        download_url="https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-aarch64-unknown-linux-gnu.tar.gz"
    else
        download_url="https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-x86_64-unknown-linux-gnu.tar.gz"
    fi
    
    if curl -L "$download_url" -o "$PROJECT_ROOT/llama/linux/bin/llmfit.tar.gz"; then
        tar -xzf "$PROJECT_ROOT/llama/linux/bin/llmfit.tar.gz" -C "$PROJECT_ROOT/llama/linux/bin"
        mv "$PROJECT_ROOT/llama/linux/bin"/llmfit-*/llmfit "$PROJECT_ROOT/llama/linux/bin/llmfit"
        rm -rf "$PROJECT_ROOT/llama/linux/bin"/llmfit-*
        rm -f "$PROJECT_ROOT/llama/linux/bin/llmfit.tar.gz"
        chmod +x "$PROJECT_ROOT/llama/linux/bin/llmfit"
        echo "llmfit installed portably."
    else
        echo "Warning: Failed to download llmfit. Continuing setup..."
    fi
fi

# 3. Handle specific launcher-integrated commands
for arg in "$@"; do
    case "$arg" in
        --recommend)
            if [ -f "$PROJECT_ROOT/llama/linux/bin/llmfit" ]; then
                "$PROJECT_ROOT/llama/linux/bin/llmfit" --cli fit -p -n 10
            else
                echo "Error: llmfit binary is missing."
            fi
            exit 0
            ;;
        --fit-tui)
            if [ -f "$PROJECT_ROOT/llama/linux/bin/llmfit" ]; then
                exec "$PROJECT_ROOT/llama/linux/bin/llmfit"
            else
                echo "Error: llmfit binary is missing."
            fi
            exit 0
            ;;
    esac
done

# 4. Interactive menu when run with no arguments
if [ $# -eq 0 ]; then
    GGUF_COUNT=$(ls "$PROJECT_ROOT/models"/*.gguf 2>/dev/null | wc -l)
    
    echo ""
    echo "Choose an action:"
    echo "1) Start Chat Server & Web UI (default)"
    echo "2) Run Hardware Analysis & Model Fit (llmfit)"
    echo "3) Start Hermes Agent"
    echo "4) Quit"
    echo -n "Select option [1]: "
    read -r choice
    choice=${choice:-1}
    
    if [ "$choice" = "1" ]; then
        if [ "$GGUF_COUNT" -eq 0 ]; then
            echo ""
            echo "No local GGUF models found in models/ directory."
            echo "Would you like to download a default model now?"
            echo "1) Download Llama-3-8B-Instruct (Recommended, ~4.9GB)"
            echo "2) Download Phi-3-Mini (Small/Fast, ~2.4GB)"
            echo "3) Skip and start server in router mode (Download via Web UI)"
            echo -n "Select option [1]: "
            read -r dl_choice
            dl_choice=${dl_choice:-1}
            
            export PATH="$PROJECT_ROOT/llama/linux/python/bin:$PATH"
            export LD_LIBRARY_PATH="$PROJECT_ROOT/llama/linux/bin:${LD_LIBRARY_PATH:-}"
            export PROJECT_ROOT
            
            if [ "$dl_choice" = "1" ]; then
                "$PROJECT_ROOT/llama/linux/python/bin/python3" "$PROJECT_ROOT/scripts/download-model.py" "bartowski/Meta-Llama-3-8B-Instruct-GGUF" "Meta-Llama-3-8B-Instruct-Q4_K_M.gguf" "$PROJECT_ROOT/models"
            elif [ "$dl_choice" = "2" ]; then
                "$PROJECT_ROOT/llama/linux/python/bin/python3" "$PROJECT_ROOT/scripts/download-model.py" "bartowski/Phi-3-mini-4k-instruct-GGUF" "Phi-3-mini-4k-instruct-Q4_K_M.gguf" "$PROJECT_ROOT/models"
            fi
            
            # Recalculate GGUF files
            shopt -s nullglob
            MODEL_FILES=("$PROJECT_ROOT/models/"*.gguf)
            GGUF_COUNT=${#MODEL_FILES[@]}
            shopt -u nullglob
            
            if [ "$GGUF_COUNT" -eq 0 ]; then
                echo "Starting server in router mode to allow downloads via UI..."
                export AUTO_LAUNCH_BROWSER=false
                exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server
                exit 0
            fi
        fi
        
        # Start server, prompting if multiple models are available
        MODEL_FILES=("$PROJECT_ROOT/models/"*.gguf)
        if [ "${#MODEL_FILES[@]}" -eq 1 ]; then
            DEFAULT_MODEL="${MODEL_FILES[0]}"
            DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
        else
            echo ""
            echo "Multiple models found. Please choose one to start:"
            i=1
            for m in "${MODEL_FILES[@]}"; do
                echo "  $i) $(basename "$m" .gguf)"
                i=$((i+1))
            done
            echo -n "Select model [1]: "
            read -r mod_choice
            mod_choice=${mod_choice:-1}
            idx=$((mod_choice-1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MODEL_FILES[@]}" ]; then
                DEFAULT_MODEL="${MODEL_FILES[$idx]}"
                DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
            else
                echo "Invalid choice. Defaulting to 1."
                DEFAULT_MODEL="${MODEL_FILES[0]}"
                DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
            fi
        fi
        echo ""
        echo "Starting server with model: $DEFAULT_MODEL_NAME"
        export AUTO_LAUNCH_BROWSER=false
        export PATH="$PROJECT_ROOT/llama/linux/python/bin:$PATH"
        export LD_LIBRARY_PATH="$PROJECT_ROOT/llama/linux/bin:${LD_LIBRARY_PATH:-}"
        export PROJECT_ROOT
        exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server -m "$DEFAULT_MODEL"
        exit 0
    elif [ "$choice" = "2" ]; then
        if [ -f "$PROJECT_ROOT/llama/linux/bin/llmfit" ]; then
            exec "$PROJECT_ROOT/llama/linux/bin/llmfit"
        else
            echo "Error: llmfit binary is missing."
        fi
        exit 0
    elif [ "$choice" = "3" ]; then
        if [ -f "$PROJECT_ROOT/hermes/launch.sh" ]; then
            cd "$PROJECT_ROOT/hermes" && exec bash launch.sh
        else
            echo "Error: Hermes not found in $PROJECT_ROOT/hermes"
            exit 1
        fi
    else
        exit 0
    fi
fi

# 5. Launch with portable path setup
export PATH="$PROJECT_ROOT/llama/linux/python/bin:$PATH"
export LD_LIBRARY_PATH="$PROJECT_ROOT/llama/linux/bin:${LD_LIBRARY_PATH:-}"
export PROJECT_ROOT

echo "Running llama-run.sh..."
exec bash "$PROJECT_ROOT/scripts/llama-run.sh" "$@"
