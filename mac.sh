#!/bin/sh
# mac.sh - macOS Launcher for llama-ai portable setup
# Usage: sh mac.sh [args]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

echo "=== llama-ai macOS Portable Setup & Launcher ==="

# 1. Setup Portable Python
if [ ! -d "$PROJECT_ROOT/llama/mac/python" ]; then
    echo "Installing portable Python..."
    mkdir -p "$PROJECT_ROOT/llama/mac"
    
    # Detect Architecture
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ]; then
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.10.13+20240107-aarch64-apple-darwin-install_only.tar.gz"
    else
        PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20240107/cpython-3.10.13+20240107-x86_64-apple-darwin-install_only.tar.gz"
    fi
    
    echo "Downloading from: $PYTHON_URL"
    if ! curl -L -o "$PROJECT_ROOT/llama/mac/python.tar.gz" "$PYTHON_URL"; then
        echo "Error: Failed to download portable Python."
        exit 1
    fi
    
    mkdir -p "$PROJECT_ROOT/llama/mac/python"
    echo "Extracting..."
    if ! tar -xzf "$PROJECT_ROOT/llama/mac/python.tar.gz" -C "$PROJECT_ROOT/llama/mac/python" --strip-components=1; then
        echo "Error: Failed to extract Python."
        rm -rf "$PROJECT_ROOT/llama/mac/python"
        exit 1
    fi
    rm "$PROJECT_ROOT/llama/mac/python.tar.gz"
    
    # Resolve Symlinks for exFAT compatibility
    echo "Resolving symlinks in Python folder for exFAT compatibility..."
    find "$PROJECT_ROOT/llama/mac/python" -type l | while read -r symlink; do
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
    "$PROJECT_ROOT/llama/mac/python/bin/python3" -m pip install --upgrade pip
    "$PROJECT_ROOT/llama/mac/python/bin/python3" -m pip install huggingface_hub urllib3
fi

# 2. Build CachyLLama if binaries are missing
if [ ! -f "$PROJECT_ROOT/llama/mac/bin/llama-server" ] || [ ! -f "$PROJECT_ROOT/llama/mac/bin/llama-cli" ]; then
    echo "Building CachyLLama Metal backend (one-time build)..."
    
    # Verify cmake is installed
    if ! command -v cmake >/dev/null 2>&1; then
        echo "Error: cmake is required to build llama-server. Please install it first (e.g. brew install cmake)."
        exit 1
    fi
    
    mkdir -p "$PROJECT_ROOT/llama/CachyLLama/build_temp"
    cd "$PROJECT_ROOT/llama/CachyLLama/build_temp" || exit 1
    
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DGGML_METAL=ON \
        -DGGML_METAL_NDEBUG=ON \
        -DGGML_CPU=ON \
        -DGGML_NATIVE=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON
        
    JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    cmake --build . --config Release -j"$JOBS"
    
    mkdir -p "$PROJECT_ROOT/llama/mac/bin"
    cp bin/llama-server "$PROJECT_ROOT/llama/mac/bin/"
    cp bin/llama-cli "$PROJECT_ROOT/llama/mac/bin/"
    # Copy shared libraries (.dylib) needed at runtime
    cp bin/*.dylib "$PROJECT_ROOT/llama/mac/bin/" 2>/dev/null || true
    
    # Add @loader_path to RPATH for macOS System Integrity Protection (SIP) compatibility
    echo "Configuring library search paths for macOS..."
    for f in "$PROJECT_ROOT/llama/mac/bin"/*; do
        if [ -f "$f" ]; then
            install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
        fi
    done
    
    cd "$PROJECT_ROOT" || exit 1
    rm -rf "$PROJECT_ROOT/llama/CachyLLama/build_temp"
    echo "Build complete."
fi

# 2b. Download llmfit if not present
if [ ! -f "$PROJECT_ROOT/llama/mac/bin/llmfit" ]; then
    echo "Downloading portable hardware analyzer (llmfit)..."
    mkdir -p "$PROJECT_ROOT/llama/mac/bin"
    
    # Detect CPU arch to download correct aarch64 vs x86_64 binary
    local_arch="$(uname -m)"
    if [ "$local_arch" = "arm64" ]; then
        download_url="https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-aarch64-apple-darwin.tar.gz"
    else
        download_url="https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-x86_64-apple-darwin.tar.gz"
    fi
    
    if curl -L "$download_url" -o "$PROJECT_ROOT/llama/mac/bin/llmfit.tar.gz"; then
        tar -xzf "$PROJECT_ROOT/llama/mac/bin/llmfit.tar.gz" -C "$PROJECT_ROOT/llama/mac/bin"
        mv "$PROJECT_ROOT/llama/mac/bin"/llmfit-*/llmfit "$PROJECT_ROOT/llama/mac/bin/llmfit"
        rm -rf "$PROJECT_ROOT/llama/mac/bin"/llmfit-*
        rm -f "$PROJECT_ROOT/llama/mac/bin/llmfit.tar.gz"
        chmod +x "$PROJECT_ROOT/llama/mac/bin/llmfit"
        echo "llmfit installed portably."
    else
        echo "Warning: Failed to download llmfit. Continuing setup..."
    fi
fi

# 3. Handle specific launcher-integrated commands
for arg in "$@"; do
    case "$arg" in
        --recommend)
            if [ -f "$PROJECT_ROOT/llama/mac/bin/llmfit" ]; then
                "$PROJECT_ROOT/llama/mac/bin/llmfit" --cli fit -p -n 10
            else
                echo "Error: llmfit binary is missing."
            fi
            exit 0
            ;;
        --fit-tui)
            if [ -f "$PROJECT_ROOT/llama/mac/bin/llmfit" ]; then
                exec "$PROJECT_ROOT/llama/mac/bin/llmfit"
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
            export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
            export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
            export PROJECT_ROOT
            exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server
            exit 0
        else
            echo ""
            echo "To run hardware recommendation: sh mac.sh --recommend"
            echo "To run interactive model browser: sh mac.sh --fit-tui"
            echo "To list launcher options: sh mac.sh --help"
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
            export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
            export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
            export PROJECT_ROOT
            exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server -m "$DEFAULT_MODEL"
            exit 0
        elif [ "$choice" = "2" ]; then
            if [ -f "$PROJECT_ROOT/llama/mac/bin/llmfit" ]; then
                exec "$PROJECT_ROOT/llama/mac/bin/llmfit"
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
export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
export PROJECT_ROOT

echo "Running llama-run.sh..."
exec bash "$PROJECT_ROOT/scripts/llama-run.sh" "$@"
