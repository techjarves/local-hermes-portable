#!/bin/sh
# linux.sh - Linux Launcher for llama-ai portable setup
# Usage: sh linux.sh [args]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

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
if [ ! -f "$PROJECT_ROOT/llama/linux/bin/llama-server" ] || [ ! -f "$PROJECT_ROOT/llama/linux/bin/llama-cli" ]; then
    # Detect if glslc is available for Vulkan shader compilation
    if command -v glslc >/dev/null 2>&1; then
        echo "Building CachyLLama Vulkan backend (one-time build)..."
        VULKAN_FLAG="ON"
    else
        echo "Warning: glslc (Vulkan shader compiler) not found. Falling back to CPU-only backend..."
        VULKAN_FLAG="OFF"
    fi
    
    mkdir -p "$PROJECT_ROOT/llama/CachyLLama/build_temp"
    cd "$PROJECT_ROOT/llama/CachyLLama/build_temp" || exit 1
    
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_HIP=OFF \
        -DGGML_HIPBLAS=OFF \
        -DGGML_VULKAN="$VULKAN_FLAG" \
        -DGGML_CPU=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON
        
    JOBS=$(nproc 2>/dev/null || echo 4)
    cmake --build . --config Release -j"$JOBS"
    
    mkdir -p "$PROJECT_ROOT/llama/linux/bin"
    cp bin/llama-server "$PROJECT_ROOT/llama/linux/bin/"
    cp bin/llama-cli "$PROJECT_ROOT/llama/linux/bin/"
    # Copy shared libraries (.so) needed at runtime
    cp bin/*.so* "$PROJECT_ROOT/llama/linux/bin/" 2>/dev/null || true
    
    cd "$PROJECT_ROOT" || exit 1
    rm -rf "$PROJECT_ROOT/llama/CachyLLama/build_temp"
    echo "Build complete."
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
    if [ "$GGUF_COUNT" -eq 0 ]; then
        echo ""
        echo "No local GGUF models found in models/ directory."
        echo -n "Would you like to start the server and open the Web UI in your browser to download models? [Y/n]: "
        read -r choice
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
        if [ "$choice" = "y" ] || [ "$choice" = "" ]; then
            # Start server in router mode and auto-launch browser
            export AUTO_LAUNCH_BROWSER=false
            export PATH="$PROJECT_ROOT/llama/linux/python/bin:$PATH"
            export LD_LIBRARY_PATH="$PROJECT_ROOT/llama/linux/bin:${LD_LIBRARY_PATH:-}"
            export PROJECT_ROOT
            exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server
            exit 0
        else
            echo ""
            echo "To run hardware recommendation: sh linux.sh --recommend"
            echo "To run interactive model browser: sh linux.sh --fit-tui"
            echo "To list launcher options: sh linux.sh --help"
            exit 0
        fi
    else
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
            # Start server, prompting if multiple models are available
            MODEL_FILES=("$PROJECT_ROOT/models/"*.gguf)
            if [ "${#MODEL_FILES[@]}" -eq 0 ]; then
                echo "Error: No models found despite passing initial check."
                exit 1
            elif [ "${#MODEL_FILES[@]}" -eq 1 ]; then
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
fi

# 5. Launch with portable path setup
export PATH="$PROJECT_ROOT/llama/linux/python/bin:$PATH"
export LD_LIBRARY_PATH="$PROJECT_ROOT/llama/linux/bin:${LD_LIBRARY_PATH:-}"
export PROJECT_ROOT

echo "Running llama-run.sh..."
exec bash "$PROJECT_ROOT/scripts/llama-run.sh" "$@"
