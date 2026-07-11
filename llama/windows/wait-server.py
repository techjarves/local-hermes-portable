import socket
import time
import webbrowser
import sys
import os
import re
import urllib.parse

if len(sys.argv) < 3:
    sys.exit(1)

port = int(sys.argv[1])
auto_launch = sys.argv[2].lower() == 'true'
model_path = sys.argv[3] if len(sys.argv) > 3 else None
script_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))

# Auto-sync model path to Hermes config if provided
if model_path:
    # Resolve project root from wait-server.py's location:
    # wait-server.py is in project_root/llama/windows/wait-server.py
    hermes_config = os.path.join(project_root, "hermes", "data", "config.yaml")
    
    # Replace backslashes with forward slashes for cross-platform compatibility in YAML
    normalized_model_path = model_path.replace("\\", "/")
    
    try:
        if not os.path.exists(hermes_config):
            os.makedirs(os.path.dirname(hermes_config), exist_ok=True)
            with open(hermes_config, 'w', encoding='utf-8') as f:
                f.write(f'model:\n  provider: llamacpp\n  base_url: "http://localhost:9090/v1"\n  api_key: "dummy"\n  default: {normalized_model_path}\n')
                f.write('\ncontext_file_max_chars: 5000\n')
                f.write('\nproviders:\n  llamacpp:\n    request_timeout_seconds: 600\n    stale_timeout_seconds: 600\n')
        else:
            with open(hermes_config, 'r', encoding='utf-8') as f:
                content = f.read()
            
            provider_match = re.search(r'(?m)^[ \t]*provider:[ \t]*([^\s]+)', content)
            is_local = False
            if provider_match and provider_match.group(1).lower() in ['local', 'openai', 'custom', 'llamacpp', 'ollama']:
                is_local = True
                
            if is_local or not provider_match:
                if "model:" not in content:
                    # Append a fresh model config block if not present at all
                    if not content.endswith('\n'):
                        content += '\n'
                    content += f'model:\n  provider: llamacpp\n  base_url: "http://localhost:9090/v1"\n  api_key: "dummy"\n  default: {normalized_model_path}\n'
                else:
                    if re.search(r'(?m)^[ \t]*default:[ \t]*', content):
                        content = re.sub(r'(?m)^([ \t]*default:[ \t]*).*', r'\g<1>' + normalized_model_path, content)
                    elif re.search(r'(?m)^model:[ \t]*\n', content):
                        content = re.sub(r'(?m)^(model:[ \t]*\n)', r'\g<1>  default: ' + normalized_model_path + '\n', content)
                    
                    content = re.sub(r'(?m)^([ \t]*model:[ \t]*)(?![\n\r]).*\.gguf', r'\g<1>' + normalized_model_path, content)
                
                # Ensure context_file_max_chars is set to 5000
                if "context_file_max_chars:" not in content:
                    if not content.endswith('\n'):
                        content += '\n'
                    content += 'context_file_max_chars: 5000\n'
                else:
                    content = re.sub(r'(?m)^([ \t]*context_file_max_chars:[ \t]*).*', r'\g<1>5000', content)
                    
                # Ensure llamacpp timeouts are configured
                if "providers:" not in content:
                    if not content.endswith('\n'):
                        content += '\n'
                    content += 'providers:\n  llamacpp:\n    request_timeout_seconds: 600\n    stale_timeout_seconds: 600\n'
                elif "llamacpp:" not in content:
                    content = re.sub(r'(?m)^(providers:[ \t]*\n)', r'\g<1>  llamacpp:\n    request_timeout_seconds: 600\n    stale_timeout_seconds: 600\n', content)
                
                with open(hermes_config, 'w', encoding='utf-8') as f:
                    f.write(content)
    except Exception as e:
        print(f"Error syncing Hermes config: {e}")

# Poll the port until it is open (up to 60 seconds)
count = 0
while count < 120:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(('127.0.0.1', port))
        s.close()
        break
    except Exception:
        pass
    time.sleep(0.5)
    count += 1

if auto_launch:
    browser_url = f"http://localhost:{port}"
    startup_prompt = os.path.join(project_root, "models", ".startup-prompt")
    if os.path.isfile(startup_prompt) and os.path.getsize(startup_prompt) > 0:
        try:
            with open(startup_prompt, "r", encoding="utf-8") as stream:
                prompt = stream.read()
            browser_url = f"{browser_url}/?q={urllib.parse.quote(prompt)}#/"
            os.remove(startup_prompt)
        except Exception as exc:
            print(f"Warning: could not attach first chat prompt: {exc}")
    print(f"\nOpening Chat & Model Manager in your browser at {browser_url}...")
    webbrowser.open(browser_url)
else:
    print(f"\n====================================================\n  Server is ready!\n  Open http://localhost:{port} in your browser to use the Web UI\n====================================================\n")
