#!/bin/sh
# mac.sh - macOS Launcher for llama-ai portable setup
# Usage: sh mac.sh [args]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
mkdir -p "$PROJECT_ROOT/models"
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

# 2. Download precompiled CachyLLama (llama.cpp) if missing
if [ ! -f "$PROJECT_ROOT/llama/mac/bin/llama-server" ] || [ ! -f "$PROJECT_ROOT/llama/mac/bin/llama-cli" ]; then
    echo "Downloading precompiled CachyLLama Metal backend..."
    mkdir -p "$PROJECT_ROOT/llama/mac/bin"
    
    local_arch="$(uname -m)"
    if [ "$local_arch" = "arm64" ]; then
        llama_url="https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-macos-arm64.tar.gz"
    else
        llama_url="https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-macos-x64.tar.gz"
    fi
    
    if curl -L -s "$llama_url" -o "$PROJECT_ROOT/llama/mac/bin/llama_mac.tar.gz"; then
        tar -xzf "$PROJECT_ROOT/llama/mac/bin/llama_mac.tar.gz" -C "$PROJECT_ROOT/llama/mac/bin" --strip-components=1
        rm -f "$PROJECT_ROOT/llama/mac/bin/llama_mac.tar.gz"
        
        # Ensure executable
        chmod +x "$PROJECT_ROOT/llama/mac/bin/llama-server" "$PROJECT_ROOT/llama/mac/bin/llama-cli" 2>/dev/null || true
        
        # Add @loader_path to RPATH for macOS System Integrity Protection (SIP) compatibility
        echo "Configuring library search paths for macOS..."
        for f in "$PROJECT_ROOT/llama/mac/bin"/*; do
            if [ -f "$f" ]; then
                install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
            fi
        done
        echo "Download and setup complete."
    else
        echo "Error: Failed to download precompiled CachyLLama binaries."
        exit 1
    fi
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

## 4. Interactive menu when run with no arguments
if [ $# -eq 0 ]; then
    PYTHON_EXE="$PROJECT_ROOT/llama/mac/python/bin/python3"
    MODEL_SETUP="$PROJECT_ROOT/scripts/model_setup_server.py"
    GGUF_COUNT=$("$PYTHON_EXE" "$MODEL_SETUP" --find-models 2>/dev/null | wc -l | tr -d ' ')
    
    # ANSI Colors
    PURPLE='\033[1;35m'
    CYAN='\033[1;36m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    RED='\033[1;31m'
    BOLD='\033[1m'
    NC='\033[0m'

    echo -e ""
    echo -e "${PURPLE}=================================================${NC}"
    echo -e "${PURPLE}    Llama AI - Local Model Launcher & Setup       ${NC}"
    echo -e "${PURPLE}=================================================${NC}"
    echo -e ""
    echo -e "${BOLD}Choose an action:${NC}"
    echo -e "  ${CYAN}1)${NC} 🚀 Start Chat Server & Web UI ${GREEN}(default)${NC}"
    echo -e "  ${CYAN}2)${NC} 📊 Run Hardware Analysis & Model Fit (llmfit)"
    echo -e "  ${CYAN}3)${NC} 🤖 Start Hermes Agent"
    echo -e "  ${CYAN}4)${NC} 🚪 Quit"
    echo -e ""
    echo -e -n "👉 Select option [${CYAN}1${NC}]: "
    read -r choice
    choice=${choice:-1}
    
    if [ "$choice" = "1" ]; then
        if [ "$GGUF_COUNT" -eq 0 ]; then
            echo -e ""
            echo -e -n "${YELLOW}⚠️  No local model is installed. Download a recommended model now? [Y/n] ${NC}"
            read -r download_choice
            download_choice=${download_choice:-y}
            case "$download_choice" in
                n|N|no|NO|No)
                    echo -e "${RED}Model setup cancelled.${NC}"
                    exec bash "$PROJECT_ROOT/mac.sh"
                    ;;
            esac
            if ! "$PYTHON_EXE" "$MODEL_SETUP"; then
                echo -e "${RED}Model setup was not completed.${NC}"
                exec bash "$PROJECT_ROOT/mac.sh"
            fi
            DEFAULT_MODEL=$("$PYTHON_EXE" "$MODEL_SETUP" --selected-model 2>/dev/null)
            if [ -z "$DEFAULT_MODEL" ] || [ ! -f "$DEFAULT_MODEL" ]; then
                echo -e "${RED}Error: setup finished without a complete GGUF model.${NC}"
                exec bash "$PROJECT_ROOT/mac.sh"
            fi
            DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
            echo -e "${GREEN}Starting server with model: $DEFAULT_MODEL_NAME${NC}"
            export AUTO_LAUNCH_BROWSER=true
            export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
            export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
            export PROJECT_ROOT
            exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server -m "$DEFAULT_MODEL"
            exit 0
        fi
        
        # Prompt user whether to download a new one or select an existing one
        MODEL_FILES=()
        while IFS= read -r model_file; do
            [ -n "$model_file" ] && MODEL_FILES+=("$model_file")
        done < <("$PYTHON_EXE" "$MODEL_SETUP" --find-models)
        echo ""
        echo -e "${BOLD}Please choose a model option:${NC}"
        echo -e "  ${YELLOW}0)${NC} ✨ Download/setup a new model"
        i=1
        for m in "${MODEL_FILES[@]}"; do
            echo -e "  ${CYAN}$i)${NC} 📦 Start ${GREEN}$(basename "$m" .gguf)${NC}"
            i=$((i+1))
        done
        echo -e ""
        echo -e -n "👉 Select option [${CYAN}1${NC}]: "
        read -r mod_choice
        mod_choice=${mod_choice:-1}
        if [ "$mod_choice" = "0" ]; then
            if ! "$PYTHON_EXE" "$MODEL_SETUP"; then
                echo -e "${RED}Model setup was not completed.${NC}"
                exec bash "$PROJECT_ROOT/mac.sh"
            fi
            DEFAULT_MODEL=$("$PYTHON_EXE" "$MODEL_SETUP" --selected-model 2>/dev/null)
            if [ -z "$DEFAULT_MODEL" ] || [ ! -f "$DEFAULT_MODEL" ]; then
                echo -e "${RED}Error: setup finished without a complete GGUF model.${NC}"
                exec bash "$PROJECT_ROOT/mac.sh"
            fi
            DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
        else
            idx=$((mod_choice-1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MODEL_FILES[@]}" ]; then
                DEFAULT_MODEL="${MODEL_FILES[$idx]}"
                DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
            else
                echo -e "${YELLOW}Invalid choice. Defaulting to 1.${NC}"
                DEFAULT_MODEL="${MODEL_FILES[0]}"
                DEFAULT_MODEL_NAME=$(basename "$DEFAULT_MODEL" .gguf)
            fi
        fi
        echo ""
        echo -e "${GREEN}Starting server with model: $DEFAULT_MODEL_NAME${NC}"
        export AUTO_LAUNCH_BROWSER=true
        export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
        export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
        export PROJECT_ROOT
        exec bash "$PROJECT_ROOT/scripts/llama-run.sh" --server -m "$DEFAULT_MODEL"
        exit 0
    elif [ "$choice" = "2" ]; then
        if [ -f "$PROJECT_ROOT/llama/mac/bin/llmfit" ]; then
            exec "$PROJECT_ROOT/llama/mac/bin/llmfit"
        else
            echo -e "${RED}Error: llmfit binary is missing.${NC}"
        fi
        exit 0
    elif [ "$choice" = "3" ]; then
        if [ -f "$PROJECT_ROOT/hermes/launch.sh" ]; then
            cd "$PROJECT_ROOT/hermes" && exec bash launch.sh
        else
            echo -e "${RED}Error: Hermes not found in $PROJECT_ROOT/hermes${NC}"
            exit 1
        fi
    else
        exit 0
    fi
fi

# 5. Launch with portable path setup
export PATH="$PROJECT_ROOT/llama/mac/python/bin:$PATH"
export DYLD_LIBRARY_PATH="$PROJECT_ROOT/llama/mac/bin:${DYLD_LIBRARY_PATH:-}"
export PROJECT_ROOT

echo "Running llama-run.sh..."
exec bash "$PROJECT_ROOT/scripts/llama-run.sh" "$@"
