# Hermes Portable — Command Reference

## Portable Launcher Commands

These are the commands you type in your terminal / PowerShell.

### Windows (`launch.bat`)

| Command | What it does |
|---------|-------------|
| `launch.bat` | Start Hermes TUI (chat interface) |
| `launch.bat hermes` | Same as above |
| `launch.bat setup` | Run setup wizard |
| `launch.bat hermes setup` | Same as above |
| `launch.bat gateway` | Start messaging gateway (Telegram, etc.) |
| `launch.bat hermes gateway` | Same as above |
| `launch.bat hermes gateway restart` | Restart gateway |
| `launch.bat hermes gateway stop` | Stop gateway |
| `launch.bat hermes doctor` | Check for issues |
| `launch.bat hermes status` | Show current status |
| `launch.bat hermes config` | View current config |
| `launch.bat hermes config edit` | Edit config in default editor |
| `launch.bat hermes chat` | Start chat mode |
| `launch.bat hermes update` | Update Hermes to latest version |

### macOS / Linux (`launch.sh`)

| Command | What it does |
|---------|-------------|
| `./launch.sh` | Start Hermes TUI |
| `./launch.sh setup` | Run setup wizard |
| `./launch.sh gateway` | Start messaging gateway |
| `./launch.sh hermes doctor` | Check for issues |
| `./launch.sh hermes status` | Show status |
| `./launch.sh hermes config` | View config |
| `./launch.sh hermes update` | Update Hermes |

---

## Reset Scripts (for testing / fresh starts)

Located in `scripts/` folder.

### Windows
```powershell
cd scripts
.\reset-windows.ps1 -Mode soft     # Keep data (API keys, config)
.\reset-windows.ps1 -Mode full     # Delete everything
```

### macOS / Linux
```bash
cd scripts
bash reset-unix.sh soft             # Keep data
bash reset-unix.sh full             # Full wipe
```

---

## Hermes CLI Commands

These work inside `launch.bat` / `launch.sh` after `hermes`.

### Core
```bash
hermes                      # Start TUI chat
hermes chat                 # Same
hermes --version            # Show version
hermes -z "your prompt"     # One-shot prompt (no TUI)
```

### Setup & Config
```bash
hermes setup                # Full interactive wizard
hermes setup model          # Change model/provider only
hermes setup terminal       # Change terminal backend
hermes setup gateway        # Configure messaging platforms
hermes setup tools          # Configure tool providers
hermes setup agent          # Customize agent behavior
hermes config               # View current config
hermes config edit          # Open in editor
hermes config set <key> <value>   # Set a value
hermes config get <key>     # Get a value
```

### Gateway (Messaging)
```bash
hermes gateway              # Start gateway in foreground
hermes gateway run          # Same
hermes gateway run --replace # Replace existing instance
hermes gateway restart      # Stop + start
hermes gateway stop         # Stop running gateway
hermes gateway install      # Install as system service (auto-start on boot)
hermes gateway uninstall    # Remove system service
hermes gateway status       # Check if running
```

### Sessions
```bash
hermes sessions             # List sessions
hermes sessions --resume    # Resume last session
hermes --resume <name>      # Resume specific session
hermes --continue           # Continue last session
```

### Tools & Diagnostics
```bash
hermes doctor               # Run diagnostics
hermes dump                 # Dump debug info
hermes debug                # Debug mode
hermes logs                 # View logs
hermes backup               # Backup data
hermes checkpoints          # Manage checkpoints
```

### Skills & Memory
```bash
hermes skills               # List skills
hermes skills create        # Create new skill
hermes skills edit          # Edit skill
hermes memory               # Memory management
hermes curator              # Curator tools
```

### Other Commands
```bash
hermes model                # Model management
hermes fallback             # Fallback provider settings
hermes proxy                # Proxy settings
hermes lsp                  # LSP mode
hermes postinstall          # Post-install hooks
hermes whatsapp             # WhatsApp tools
hermes slack                # Slack tools
hermes send                 # Send message
hermes login                # Login to service
hermes logout               # Logout
hermes auth                 # Authentication
hermes cron                 # Cron jobs
hermes webhook              # Webhooks
hermes kanban               # Kanban board
hermes hooks                # Hooks management
hermes import               # Import data
hermes pairing              # Device pairing
hermes plugins              # Plugin management
hermes insights             # Analytics
hermes claw                 # OpenClaw import
hermes version              # Version info
hermes uninstall            # Uninstall
hermes acp                  # ACP tools
hermes profile              # Profile management
hermes completion           # Shell completion
hermes dashboard            # Dashboard
hermes mcp                  # MCP tools
hermes computer-use         # Computer use tools
```

---

## Telegram Bot Commands

Send these to your Hermes bot on Telegram.

| Command | What it does |
|---------|-------------|
| `/start` | Start chatting with Hermes |
| `/stop` | Cancel current task/agent turn |
| `/sethome` | Set this chat as your home channel (for cron/notifications) |
| Any text | Hermes processes it as a prompt |

---

## File Locations (Portable)

| File | Path | Purpose |
|------|------|---------|
| API Keys | `data/.env` | Secrets (DeepSeek, Telegram, etc.) |
| Settings | `data/config.yaml` | All Hermes configuration |
| Chat History | `data/sessions/` | Saved conversations |
| Logs | `data/logs/` | agent.log, errors.log, gateway.log |
| State DB | `data/state.db` | Gateway state & locks |
| Custom Prompt | `data/SOUL.md` | System prompt loaded on every launch |
