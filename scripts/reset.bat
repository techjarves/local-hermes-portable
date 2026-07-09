@echo off
:: reset.bat - Resets the portable environment for Windows, Linux, and Mac
:: Keeps only the models/ directory at the root intact.

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..
set LLAMA_ROOT=%PROJECT_ROOT%\llama

echo === Resets llama-ai portable setup ===
echo Keeping models/ directory...

if exist "%LLAMA_ROOT%\windows" (
    echo Removing llama\windows\ runtime directory...
    rmdir /s /q "%LLAMA_ROOT%\windows"
)

if exist "%LLAMA_ROOT%\linux" (
    echo Removing llama\linux\ runtime directory...
    rmdir /s /q "%LLAMA_ROOT%\linux"
)

if exist "%LLAMA_ROOT%\mac" (
    echo Removing llama\mac\ runtime directory...
    rmdir /s /q "%LLAMA_ROOT%\mac"
)

if exist "%LLAMA_ROOT%\kv-cache" (
    echo Removing llama\kv-cache\ directory...
    rmdir /s /q "%LLAMA_ROOT%\kv-cache"
)

echo Reset complete.
