@echo off
rem windows.bat - Windows Launcher for llama-ai portable setup
rem Usage: windows.bat [args]

if not defined AUTO_LAUNCH_BROWSER set AUTO_LAUNCH_BROWSER=false
if not defined LLAMA_CTX_SIZE set LLAMA_CTX_SIZE=65536
if not defined LLAMA_SLOTS set LLAMA_SLOTS=1
if not defined LLAMA_GPU_LAYERS set LLAMA_GPU_LAYERS=99

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%
if "%PROJECT_ROOT:~-1%"=="\" set PROJECT_ROOT=%PROJECT_ROOT:~0,-1%
if not exist "%PROJECT_ROOT%\models" mkdir "%PROJECT_ROOT%\models"
echo === llama-ai Windows Portable Setup ^& Launcher ===

rem 1. Setup Portable Python
if exist "%PROJECT_ROOT%\llama\windows\python" goto :skip_python_setup

echo Installing portable Python...
if not exist "%PROJECT_ROOT%\llama\windows" mkdir "%PROJECT_ROOT%\llama\windows"

echo Downloading Python embeddable zip...
ver >nul
curl -L -o "%PROJECT_ROOT%\llama\windows\python.zip" https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip
if %ERRORLEVEL% neq 0 (
    echo Error: Failed to download portable Python.
    exit /b 1
)

if not exist "%PROJECT_ROOT%\llama\windows\python" mkdir "%PROJECT_ROOT%\llama\windows\python"
echo Extracting Python...
tar -xf "%PROJECT_ROOT%\llama\windows\python.zip" -C "%PROJECT_ROOT%\llama\windows\python"
del "%PROJECT_ROOT%\llama\windows\python.zip"

rem Enable site-packages in embeddable python
echo Configuring Python path...
powershell -Command "(gc '%PROJECT_ROOT%\llama\windows\python\python310._pth') -replace '#import site', 'import site' | Out-File -encoding ASCII '%PROJECT_ROOT%\llama\windows\python\python310._pth'"

rem Bootstrap pip
echo Bootstrapping pip...
curl -L -o "%PROJECT_ROOT%\llama\windows\python\get-pip.py" https://bootstrap.pypa.io/get-pip.py
"%PROJECT_ROOT%\llama\windows\python\python.exe" "%PROJECT_ROOT%\llama\windows\python\get-pip.py" --no-warn-script-location
del "%PROJECT_ROOT%\llama\windows\python\get-pip.py"

rem Install dependencies
echo Installing packages...
"%PROJECT_ROOT%\llama\windows\python\python.exe" -m pip install huggingface_hub urllib3 --no-warn-script-location

:skip_python_setup


rem 1b. Check and install VC++ Redistributable if missing
set VC_REDIST_URL=https://aka.ms/vs/17/release/vc_redist.x64.exe
set VC_REDIST_NAME=vc_redist.x64.exe
if defined ProgramFiles(Arm) (
    set VC_REDIST_URL=https://aka.ms/vs/17/release/vc_redist.arm64.exe
    set VC_REDIST_NAME=vc_redist.arm64.exe
)

if exist "%SystemRoot%\System32\vcruntime140.dll" goto :skip_vc_install

echo.
echo =======================================================================
echo WARNING: Microsoft Visual C++ Redistributable is missing!
echo This is required to run the local LLM server and hardware tools.
echo =======================================================================
echo.
set /p install_vc="Would you like to download and install the official Microsoft VC++ Redistributable? [Y/n]: "
if "%install_vc%"=="" set install_vc=y
if /i not "%install_vc%"=="y" goto :skip_vc_install

echo Downloading installer from Microsoft...
if not exist "%PROJECT_ROOT%\llama\windows" mkdir "%PROJECT_ROOT%\llama\windows"
powershell -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\llama\windows\download.ps1" "%VC_REDIST_URL%" "%PROJECT_ROOT%\llama\windows\%VC_REDIST_NAME%"
if not exist "%PROJECT_ROOT%\llama\windows\%VC_REDIST_NAME%" (
    echo Error: Failed to download VC++ Redistributable.
    goto :skip_vc_install
)

echo Launching installer... Please approve the User Account Control (UAC) prompt if it appears.
start /wait "" "%PROJECT_ROOT%\llama\windows\%VC_REDIST_NAME%" /install /passive /norestart
del "%PROJECT_ROOT%\llama\windows\%VC_REDIST_NAME%" 2>nul
echo VC++ Redistributable installed.

:skip_vc_install


rem 2. Download precompiled CachyLLama if missing
if exist "%PROJECT_ROOT%\llama\windows\bin\llama-server.exe" goto :skip_cachy_build

echo Downloading precompiled CachyLLama backend...

if not exist "%PROJECT_ROOT%\llama\windows\bin" mkdir "%PROJECT_ROOT%\llama\windows\bin"

set LLAMA_ZIP_URL=https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-win-vulkan-x64.zip
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set LLAMA_ZIP_URL=https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-bin-win-cpu-arm64.zip
)

powershell -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\llama\windows\download.ps1" "%LLAMA_ZIP_URL%" "%PROJECT_ROOT%\llama\windows\bin\llama_win.zip"
if exist "%PROJECT_ROOT%\llama\windows\bin\llama_win.zip" (
    powershell -Command "Expand-Archive -Path '%PROJECT_ROOT%\llama\windows\bin\llama_win.zip' -DestinationPath '%PROJECT_ROOT%\llama\windows\bin' -Force"
    del "%PROJECT_ROOT%\llama\windows\bin\llama_win.zip" 2>nul
    echo Precompiled binaries installed portably.
) else (
    echo Error: Failed to download precompiled CachyLLama binaries.
    exit /b 1
)

:skip_cachy_build


rem 2b. Download/Update llmfit based on architecture
set LLMFIT_ARCH=x64
set LLMFIT_ZIP_URL=https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-x86_64-pc-windows-msvc.zip

if defined ProgramFiles(Arm) (
    set LLMFIT_ARCH=arm64
    set LLMFIT_ZIP_URL=https://github.com/AlexsJones/llmfit/releases/download/v0.9.34/llmfit-v0.9.34-aarch64-pc-windows-msvc.zip
)

if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
    if not exist "%PROJECT_ROOT%\llama\windows\bin\llmfit_%LLMFIT_ARCH%.txt" (
        echo Detected architecture change or incorrect llmfit version. Reinstalling...
        del "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" 2>nul
        del "%PROJECT_ROOT%\llama\windows\bin\llmfit_x64.txt" 2>nul
        del "%PROJECT_ROOT%\llama\windows\bin\llmfit_arm64.txt" 2>nul
    )
)

if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" goto :skip_llmfit_download

echo Downloading portable hardware analyzer (llmfit) for %LLMFIT_ARCH%...
if not exist "%PROJECT_ROOT%\llama\windows\bin" mkdir "%PROJECT_ROOT%\llama\windows\bin"

powershell -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\llama\windows\download.ps1" "%LLMFIT_ZIP_URL%" "%PROJECT_ROOT%\llama\windows\bin\llmfit.zip"
if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.zip" (
    powershell -Command "Expand-Archive -Path '%PROJECT_ROOT%\llama\windows\bin\llmfit.zip' -DestinationPath '%PROJECT_ROOT%\llama\windows\bin' -Force; Move-Item -Path '%PROJECT_ROOT%\llama\windows\bin\llmfit-*\llmfit.exe' -Destination '%PROJECT_ROOT%\llama\windows\bin\llmfit.exe' -Force; Remove-Item -Path '%PROJECT_ROOT%\llama\windows\bin\llmfit-*' -Recurse -Force"
    del "%PROJECT_ROOT%\llama\windows\bin\llmfit.zip" 2>nul
    echo. > "%PROJECT_ROOT%\llama\windows\bin\llmfit_%LLMFIT_ARCH%.txt"
    echo llmfit installed portably.
) else (
    echo Warning: Failed to download llmfit.
)

:skip_llmfit_download

rem 2c. Check if llama-server supports --cache-ssd option
set "CACHE_ARG="
if not exist "%PROJECT_ROOT%\llama\windows\bin\llama-server.exe" goto :skip_cache_check
"%PROJECT_ROOT%\llama\windows\bin\llama-server.exe" --help 2>&1 | findstr /C:"--cache-ssd" >nul
if %ERRORLEVEL% equ 0 (
    set CACHE_ARG=--cache-ssd "%PROJECT_ROOT%\llama\kv-cache"
)
:skip_cache_check



rem 3. Handle specific launcher-integrated commands
if "%~1"=="--recommend" goto :action_recommend
if "%~1"=="--fit-tui" goto :action_fit_tui
goto :skip_launcher_commands

:action_recommend
if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
    "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" --cli fit -p -n 10
) else (
    echo Error: llmfit.exe is missing.
)
exit /b 0

:action_fit_tui
if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
    "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe"
) else (
    echo Error: llmfit.exe is missing.
)
exit /b 0

:skip_launcher_commands


rem 4. Interactive menu when run with no arguments
if not "%~1"=="" goto :skip_interactive_menu

:interactive_menu
set "PYTHON_EXE=%PROJECT_ROOT%\llama\windows\python\python.exe"
set "MODEL_SETUP=%PROJECT_ROOT%\scripts\model_setup_server.py"
set "MODEL_LIST_FILE=%TEMP%\llama-ai-portable-models.txt"
"%PYTHON_EXE%" "%MODEL_SETUP%" --find-models > "%MODEL_LIST_FILE%" 2>nul
set GGUF_COUNT=0
for /f "usebackq delims=" %%f in ("%MODEL_LIST_FILE%") do (
    set /a GGUF_COUNT+=1
)

echo.
echo Choose an action:
echo 1] Start Chat Server and Web UI [default]
echo 2] Run Hardware Analysis and Model Fit [llmfit]
echo 3] Start Hermes Agent
echo 4] Quit
set /p choice="Select option [1]: "
if "%choice%"=="" set choice=1
if "%choice%"=="1" (
    if "%GGUF_COUNT%"=="0" (
        goto action_prompt_downloader
    ) else (
        goto action_start_default
    )
)
if "%choice%"=="2" goto action_llmfit
if "%choice%"=="3" goto action_hermes
exit /b 0

:action_prompt_downloader
echo.
set "DOWNLOAD_CHOICE="
set /p DOWNLOAD_CHOICE="No local model is installed. Download a recommended model now? [Y/n] "
if /I "%DOWNLOAD_CHOICE%"=="n" goto :interactive_menu
if /I "%DOWNLOAD_CHOICE%"=="no" goto :interactive_menu

:action_prompt_downloader_force
"%PYTHON_EXE%" "%MODEL_SETUP%"
if errorlevel 1 (
    echo Model setup was not completed.
    goto :interactive_menu
)
set "DEFAULT_MODEL="
set "SELECTED_MODEL_FILE=%TEMP%\llama-ai-portable-selected-model.txt"
"%PYTHON_EXE%" "%MODEL_SETUP%" --selected-model > "%SELECTED_MODEL_FILE%" 2>nul
for /f "usebackq delims=" %%f in ("%SELECTED_MODEL_FILE%") do set "DEFAULT_MODEL=%%f"
if not defined DEFAULT_MODEL (
    echo Error: setup finished without a complete GGUF model.
    goto :interactive_menu
)
for %%F in ("%DEFAULT_MODEL%") do set "DEFAULT_MODEL_NAME=%%~nF"
set AUTO_LAUNCH_BROWSER=true
goto :launch_selected_model

:action_start_default
set AUTO_LAUNCH_BROWSER=true
setlocal EnableDelayedExpansion
set model_count=0
for /f "usebackq delims=" %%F in ("%MODEL_LIST_FILE%") do (
    set /a model_count+=1
    set "MODEL_!model_count!=%%F"
    set "MODEL_NAME_!model_count!=%%~nF"
)

if !model_count! equ 0 (
    echo Error: No models found despite passing initial check.
    endlocal
    exit /b 1
)

echo.
echo Please choose a model option:
echo   0] Download/setup a new model
for /L %%I in (1,1,!model_count!) do (
    echo   %%I] Start !MODEL_NAME_%%I!
)
set /p mod_choice="Select option [1]: "
if "!mod_choice!"=="" set mod_choice=1

if "!mod_choice!"=="0" (
    endlocal
    goto action_prompt_downloader_force
)

REM Validate choice
set "DEFAULT_MODEL=!MODEL_%mod_choice%!"
if not defined DEFAULT_MODEL (
    echo Invalid choice. Defaulting to 1.
    set mod_choice=1
    set "DEFAULT_MODEL=!MODEL_1!"
)
set "DEFAULT_MODEL_NAME=!MODEL_NAME_%mod_choice%!"

:exec_start_default
endlocal & set "DEFAULT_MODEL=%DEFAULT_MODEL%" & set "DEFAULT_MODEL_NAME=%DEFAULT_MODEL_NAME%"

:launch_selected_model
echo.
echo Starting server with model: %DEFAULT_MODEL_NAME%

if not defined AUTO_LAUNCH_BROWSER set AUTO_LAUNCH_BROWSER=false
set PATH=%PROJECT_ROOT%\llama\windows\python;%PROJECT_ROOT%\llama\windows\python\Scripts;%PATH%
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%PROJECT_ROOT%\scripts\llama-run.sh" --server -m "%DEFAULT_MODEL%"
) else (
    taskkill /F /IM llama-server.exe 2>nul
    taskkill /F /IM llmfit.exe 2>nul
    if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
        start "" /B "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" serve --port 8787
    )
    start /B "" "%PROJECT_ROOT%\llama\windows\python\python.exe" "%PROJECT_ROOT%\llama\windows\wait-server.py" 9090 %AUTO_LAUNCH_BROWSER% "%DEFAULT_MODEL%"
    echo Starting server on http://localhost:9090...
    "%PROJECT_ROOT%\llama\windows\bin\llama-server.exe" -m "%DEFAULT_MODEL%" -c %LLAMA_CTX_SIZE% -np %LLAMA_SLOTS% -ngl %LLAMA_GPU_LAYERS% --cache-type-k q8_0 --cache-type-v q8_0 --host 0.0.0.0 --port 9090 --ui-mcp-proxy %CACHE_ARG%
)
exit /b 0

:action_llmfit
if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
    "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe"
) else (
    echo Error: llmfit.exe is missing.
)
exit /b 0


:action_hermes
if exist "%PROJECT_ROOT%\hermes\launch.bat" (
    cd /d "%PROJECT_ROOT%\hermes"
    call launch.bat
) else (
    echo Error: Hermes not found in %PROJECT_ROOT%\hermes
)
exit /b 0


:skip_interactive_menu
rem 5. Launching
set PATH=%PROJECT_ROOT%\llama\windows\python;%PROJECT_ROOT%\llama\windows\python\Scripts;%PATH%

where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo Found bash shell. Launching via llama-run.sh...
    bash "%PROJECT_ROOT%\scripts\llama-run.sh" %*
) else (
    echo Bash shell not found. Launching llama-server natively...
    rem Extract model name if provided
    set MODEL_NAME=
    if "%~1"=="--server" (
        set MODEL_NAME=%~2
    )

    if "%MODEL_NAME%"=="" (
        echo Usage: windows.bat --server [model_name]
        echo Please specify a model name. Available models:
        "%PROJECT_ROOT%\llama\windows\python\python.exe" -c "import os; print('\n'.join([f for f in os.listdir('models') if f.endswith('.gguf')]))"
        exit /b 1
    )

    taskkill /F /IM llama-server.exe 2>nul
    taskkill /F /IM llmfit.exe 2>nul
    if exist "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" (
        start "" /B "%PROJECT_ROOT%\llama\windows\bin\llmfit.exe" serve --port 8787
    )
    start /B "" "%PROJECT_ROOT%\llama\windows\python\python.exe" "%PROJECT_ROOT%\llama\windows\wait-server.py" 9090 %AUTO_LAUNCH_BROWSER% "%PROJECT_ROOT%\models\%MODEL_NAME%.gguf"
    echo Starting server on http://localhost:9090...
    "%PROJECT_ROOT%\llama\windows\bin\llama-server.exe" -m "models\%MODEL_NAME%.gguf" -c %LLAMA_CTX_SIZE% -np %LLAMA_SLOTS% -ngl %LLAMA_GPU_LAYERS% --cache-type-k q8_0 --cache-type-v q8_0 --host 0.0.0.0 --port 9090 --ui-mcp-proxy %CACHE_ARG%
)
