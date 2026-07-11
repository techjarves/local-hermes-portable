#!/usr/bin/env python3
"""Cross-platform localhost GUI for choosing and downloading a GGUF with llmfit."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "models"
WEB_DIR = Path(__file__).resolve().parent / "model-setup-web"
SELECTION_FILE = MODELS_DIR / ".last-selected-model"
STARTUP_PROMPT_FILE = MODELS_DIR / ".startup-prompt"
SHARD_RE = re.compile(r"^(?P<base>.+)-(?P<part>\d{5})-of-(?P<total>\d{5})\.gguf$", re.I)


class DownloadCancelled(Exception):
    pass


def platform_name() -> str:
    value = platform.system().lower()
    return "mac" if value == "darwin" else "windows" if value == "windows" else "linux"


def llmfit_path() -> Path:
    name = platform_name()
    return ROOT / "llama" / name / "bin" / ("llmfit.exe" if name == "windows" else "llmfit")


def complete_models() -> list[Path]:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    files = [p.resolve() for p in MODELS_DIR.glob("*.gguf") if p.is_file() and p.stat().st_size > 0]
    standalone: list[Path] = []
    groups: dict[tuple[str, int], dict[int, Path]] = {}
    for path in files:
        match = SHARD_RE.match(path.name)
        if not match:
            standalone.append(path)
            continue
        total = int(match.group("total"))
        groups.setdefault((match.group("base").lower(), total), {})[int(match.group("part"))] = path
    result = list(standalone)
    for (_, total), parts in groups.items():
        if set(parts) == set(range(1, total + 1)):
            result.append(parts[1])
    return sorted(result, key=lambda p: p.name.lower())


def selected_model() -> Path | None:
    models = complete_models()
    if SELECTION_FILE.is_file():
        wanted = SELECTION_FILE.read_text(encoding="utf-8").strip()
        match = next((p for p in models if p.name == wanted), None)
        if match:
            return match
    return models[0] if models else None


def normalize_system(raw: dict) -> dict:
    return {
        "platform": platform.system(),
        "cpu_name": raw.get("cpu_name", "Unknown CPU"),
        "cpu_cores": raw.get("cpu_cores", 0),
        "total_ram_gb": raw.get("total_ram_gb", 0),
        "available_ram_gb": raw.get("available_ram_gb", raw.get("total_ram_gb", 0)),
        "has_gpu": bool(raw.get("has_gpu")),
        "gpu_name": raw.get("gpu_name", "CPU inference"),
        "gpu_vram_gb": raw.get("gpu_vram_gb", 0),
        "backend": raw.get("backend", "CPU"),
    }


def normalized_recommendation(model: dict, index: int) -> dict | None:
    sources = model.get("gguf_sources") or []
    repo = next((s.get("repo") for s in sources if isinstance(s, dict) and s.get("repo")), None)
    if not repo:
        return None
    quant = model.get("best_quant") or "Q4_K_M"
    rec_id = hashlib.sha256(f"{repo}|{quant}|{index}".encode()).hexdigest()[:16]
    return {
        "id": rec_id,
        "name": model.get("name") or repo,
        "repo": repo,
        "quant": quant,
        "fit_level": str(model.get("fit_level", "good")).lower(),
        "run_mode": str(model.get("run_mode", "CPU")),
        "disk_size_gb": float(model.get("disk_size_gb") or 0),
        "memory_required_gb": float(model.get("memory_required_gb") or model.get("total_memory_gb") or 0),
        "speed_tps": float(model.get("estimated_tps") or 0),
        "context": int(model.get("effective_context_length") or 8192),
        "score": float(model.get("score") or 0),
        "score_components": model.get("score_components") or {},
        "best": index == 0,
    }


def recommendations() -> tuple[dict, list[dict]]:
    binary = llmfit_path()
    if not binary.is_file():
        raise RuntimeError(f"llmfit is missing: {binary}")
    
    # Try 1: Strict recommendation with tool_use and good fit
    command_strict = [
        str(binary), "--max-context", "32768", "recommend", "--json",
        "--force-runtime", "llamacpp", "--use-case", "general",
        "--capability", "tool_use", "--min-fit", "good",
        "--output-llamacpp", "--limit", "40", "--no-dashboard",
    ]
    
    payload = {}
    try:
        completed = subprocess.run(command_strict, capture_output=True, text=True, timeout=60)
        if completed.returncode == 0:
            payload = json.loads(completed.stdout)
    except Exception:
        pass

    result: list[dict] = []
    excluded = ("nsfw", "sex", "roleplay", "abliterated", "uncensored", "huihui")
    
    if payload.get("models"):
        for model in payload.get("models", []):
            searchable = str(model.get("name", "")).lower()
            if any(term in searchable for term in excluded) or re.search(r"(?:^|[-_/])base(?:$|[-_/])", searchable):
                continue
            item = normalized_recommendation(model, len(result))
            if item:
                result.append(item)
            if len(result) == 3:
                break

    # Try 2: Relaxed recommendation (drop tool_use capability, allow marginal fits)
    if not result:
        command_relaxed = [
            str(binary), "--max-context", "32768", "recommend", "--json",
            "--force-runtime", "llamacpp", "--min-fit", "marginal",
            "--output-llamacpp", "--limit", "40", "--no-dashboard",
        ]
        try:
            completed = subprocess.run(command_relaxed, capture_output=True, text=True, timeout=60)
            if completed.returncode == 0:
                payload = json.loads(completed.stdout)
        except Exception:
            pass
            
        if payload.get("models"):
            for model in payload.get("models", []):
                searchable = str(model.get("name", "")).lower()
                if any(term in searchable for term in excluded) or re.search(r"(?:^|[-_/])base(?:$|[-_/])", searchable):
                    continue
                item = normalized_recommendation(model, len(result))
                if item:
                    result.append(item)
                if len(result) == 3:
                    break

    # Try 3: Static, reliable lightweight fallbacks if llmfit or the system is offline/extremely low RAM
    if not result:
        static_models = [
            {
                "name": "Qwen2.5-3B-Instruct",
                "gguf_sources": [{"repo": "Qwen/Qwen2.5-3B-Instruct-GGUF"}],
                "best_quant": "Q4_K_M",
                "fit_level": "Perfect",
                "run_mode": "CPU/GPU",
                "disk_size_gb": 2.2,
                "total_memory_gb": 3.2,
                "estimated_tps": 15.0,
                "effective_context_length": 32768,
                "score": 80.0,
                "score_components": {},
                "notes": ["Static fallback model - perfect balance for low memory systems."]
            },
            {
                "name": "Qwen2.5-1.5B-Instruct",
                "gguf_sources": [{"repo": "Qwen/Qwen2.5-1.5B-Instruct-GGUF"}],
                "best_quant": "Q4_K_M",
                "fit_level": "Perfect",
                "run_mode": "CPU/GPU",
                "disk_size_gb": 1.2,
                "total_memory_gb": 2.0,
                "estimated_tps": 25.0,
                "effective_context_length": 32768,
                "score": 75.0,
                "score_components": {},
                "notes": ["Static fallback model - ultra-lightweight option."]
            },
            {
                "name": "Llama-3.2-3B-Instruct",
                "gguf_sources": [{"repo": "bartowski/Llama-3.2-3B-Instruct-GGUF"}],
                "best_quant": "Q4_K_M",
                "fit_level": "Perfect",
                "run_mode": "CPU/GPU",
                "disk_size_gb": 2.0,
                "total_memory_gb": 3.0,
                "estimated_tps": 18.0,
                "effective_context_length": 8192,
                "score": 78.0,
                "score_components": {},
                "notes": ["Static fallback model - highly capable small language model."]
            }
        ]
        for model in static_models:
            item = normalized_recommendation(model, len(result))
            if item:
                result.append(item)
            if len(result) == 3:
                break

    return normalize_system(payload.get("system") or {}), result


def searchable_recommendations(query: str) -> tuple[dict, list[dict]]:
    """Return hardware-scored llama.cpp/GGUF results matching a user query."""
    binary = llmfit_path()
    command = [
        str(binary), "--max-context", "32768", "recommend", "--json",
        "--force-runtime", "llamacpp", "--min-fit", "marginal",
        "--output-llamacpp", "--limit", "1000", "--no-dashboard",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout).strip() or "llmfit search failed")
    payload = json.loads(completed.stdout)
    query_lc = query.lower()
    excluded = ("nsfw", "sex", "roleplay", "abliterated", "uncensored", "huihui")
    result: list[dict] = []
    for model in payload.get("models", []):
        sources = model.get("gguf_sources") or []
        searchable = " ".join([
            str(model.get("name", "")), str(model.get("provider", "")),
            " ".join(str(source.get("repo", "")) for source in sources if isinstance(source, dict)),
        ]).lower()
        if query_lc not in searchable or any(term in searchable for term in excluded):
            continue
        if re.search(r"(?:^|[-_/])base(?:$|[-_/])", str(model.get("name", "")).lower()):
            continue
        item = normalized_recommendation(model, len(result))
        if item:
            item["best"] = False
            result.append(item)
        if len(result) == 6:
            break
    return normalize_system(payload.get("system") or {}), result


def repo_files(repo: str, quant: str) -> list[dict]:
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
        raise RuntimeError("Invalid Hugging Face repository")
    headers = {"User-Agent": "llama-ai-portable"}
    request = urllib.request.Request(f"https://huggingface.co/api/models/{repo}", headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    names = [s.get("rfilename") for s in payload.get("siblings", []) if s.get("rfilename")]
    pattern = f"*{quant.lower()}*.gguf"
    auxiliary_markers = ("mmproj", "mtp/", "mtp-", "projector")
    matched = [
        name for name in names
        if fnmatch.fnmatch(name.lower(), pattern)
        and not any(marker in name.lower() for marker in auxiliary_markers)
    ]
    if not matched:
        raise RuntimeError(f"No {quant} GGUF files found in {repo}")
    # Keep one single-file quant or every shard from one split set.
    first = sorted(matched)[0]
    shard = SHARD_RE.match(Path(first).name)
    if shard:
        base = shard.group("base").lower()
        matched = [name for name in matched if (m := SHARD_RE.match(Path(name).name)) and m.group("base").lower() == base]
    elif len(matched) > 1:
        exact = [name for name in matched if re.search(rf"[-_]{re.escape(quant)}\.gguf$", Path(name).name, re.I)]
        matched = exact[:1] or [first]
    return [{
        "name": Path(name).name,
        "url": f"https://huggingface.co/{repo}/resolve/main/{urllib.parse.quote(name)}",
    } for name in sorted(matched)]


def remote_size(url: str) -> int:
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "llama-ai-portable"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return int(response.headers.get("content-length", 0))


def partial_models() -> list[str]:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    files = [p.resolve() for p in MODELS_DIR.glob("*.gguf.downloading") if p.is_file() and p.stat().st_size > 0]
    return sorted(list({p.name[:-12] for p in files}), key=lambda s: s.lower())


class Application:
    def __init__(self):
        self.lock = threading.Lock()
        self.system: dict | None = None
        self.recs: dict[str, dict] = {}
        self.search_cache: dict[str, list[dict]] = {}
        self.cancel_event = threading.Event()
        self.httpd: ThreadingHTTPServer | None = None
        self.finished = False
        self.status = self.blank_status()
        self.session_downloaded = 0
        self.session_started = 0.0

    @staticmethod
    def blank_status() -> dict:
        return {
            "active": False, "complete": False, "stage": "idle", "filename": "",
            "downloaded_bytes": 0, "total_bytes": 0, "remaining_bytes": 0,
            "percent": 0.0, "speed_mb": 0.0, "error": None, "message": "Ready",
            "selected_id": "", "primary_model": "", "download_url": "",
        }

    def bootstrap(self) -> dict:
        if self.system is None:
            self.system, items = recommendations()
            self.recs = {item["id"]: item for item in items}
        return {
            "system": self.system,
            "recommendations": list(self.recs.values()),
            "installed_models": [p.name for p in complete_models()],
            "partial_models": partial_models(),
            "source": "llmfit",
        }

    def search(self, query: str) -> list[dict]:
        query = query.strip()
        if len(query) < 2:
            raise ValueError("Enter at least 2 characters")
        if len(query) > 80:
            raise ValueError("Search is limited to 80 characters")
        cache_key = query.lower()
        if cache_key not in self.search_cache:
            _, items = searchable_recommendations(query)
            self.search_cache[cache_key] = items
            self.recs.update({item["id"]: item for item in items})
        return self.search_cache[cache_key]

    def update(self, **values) -> None:
        with self.lock:
            self.status.update(values)

    def disk_check(self, rec: dict) -> None:
        free = shutil.disk_usage(MODELS_DIR).free
        needed = int(max(rec.get("disk_size_gb", 0), 0.5) * 1024**3) + 1024**3
        if free < needed:
            raise RuntimeError(f"Not enough free space: need about {needed / 1024**3:.1f} GB, have {free / 1024**3:.1f} GB")

    def download_file(self, item: dict, base: int, total: int, started: float) -> int:
        destination = (MODELS_DIR / item["name"]).resolve()
        destination.relative_to(MODELS_DIR.resolve())
        partial = destination.with_name(destination.name + ".downloading")
        existing = partial.stat().st_size if partial.exists() else 0
        headers = {"User-Agent": "llama-ai-portable"}
        if existing:
            headers["Range"] = f"bytes={existing}-"
        request = urllib.request.Request(item["url"], headers=headers)
        response = urllib.request.urlopen(request, timeout=45)
        append = existing > 0 and getattr(response, "status", 200) == 206
        if not append:
            existing = 0
        downloaded = existing
        with response, partial.open("ab" if append else "wb") as output:
            while True:
                if self.cancel_event.is_set():
                    raise DownloadCancelled()
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                downloaded += len(chunk)
                self.session_downloaded += len(chunk)
                overall = base + downloaded
                elapsed = max(time.time() - self.session_started, .01)
                self.update(
                    stage="download", filename=item["name"], downloaded_bytes=overall,
                    total_bytes=total, remaining_bytes=max(total - overall, 0),
                    percent=round(overall / total * 100, 1) if total else 0,
                    speed_mb=round(self.session_downloaded / 1024**2 / elapsed, 2),
                    message=f"Downloading {item['name']}",
                    download_url=item["url"],
                )
        if downloaded <= 0:
            raise RuntimeError(f"Empty download: {item['name']}")
        os.replace(partial, destination)
        return downloaded

    def install(self, rec: dict) -> None:
        try:
            self.disk_check(rec)
            self.update(stage="metadata", message="Finding the recommended GGUF files…")
            files = repo_files(rec["repo"], rec["quant"])
            for item in files:
                try:
                    item["size"] = remote_size(item["url"])
                except Exception:
                    item["size"] = 0
            total = sum(item["size"] for item in files)
            started = time.time()
            self.session_downloaded = 0
            self.session_started = time.time()
            completed = 0
            for item in files:
                if self.cancel_event.is_set():
                    raise DownloadCancelled()
                destination = MODELS_DIR / item["name"]
                if destination.is_file() and destination.stat().st_size > 0 and (not item["size"] or destination.stat().st_size == item["size"]):
                    completed += destination.stat().st_size
                else:
                    completed += self.download_file(item, completed, total, started)
            candidates = complete_models()
            names = {item["name"] for item in files}
            primary = next((p for p in candidates if p.name in names), None)
            if not primary:
                raise RuntimeError("Download finished, but the GGUF shard set is incomplete")
            SELECTION_FILE.write_text(primary.name + "\n", encoding="utf-8")
            self.update(
                active=False, complete=True, stage="complete", percent=100.0,
                remaining_bytes=0, primary_model=str(primary), message="Model is ready",
            )
        except DownloadCancelled:
            self.update(
                active=False, complete=False, stage="canceled", error=None,
                message="Download canceled. Partial progress was saved and can be resumed.",
            )
        except Exception as exc:
            self.update(active=False, complete=False, stage="error", error=str(exc), message="Download failed")

    def start(self, rec_id: str) -> None:
        rec = self.recs.get(rec_id)
        if not rec:
            raise ValueError("Unknown recommendation")
        with self.lock:
            if self.status.get("active"):
                raise RuntimeError("A download is already active")
            self.status = self.blank_status()
            self.status.update(active=True, stage="preflight", selected_id=rec_id, message="Checking free space…")
            self.cancel_event.clear()
        threading.Thread(target=self.install, args=(rec,), daemon=True).start()

    def cancel(self) -> None:
        if not self.status.get("active"):
            raise RuntimeError("No download is active")
        self.cancel_event.set()
        self.update(stage="canceling", message="Canceling download…")

    def finish(self, prompt: str = "") -> None:
        if not self.status.get("complete") or not selected_model():
            raise RuntimeError("The model download is not complete")
        prompt = prompt.strip()
        if len(prompt) > 8000:
            raise ValueError("The first chat prompt is limited to 8,000 characters")
        if prompt:
            STARTUP_PROMPT_FILE.write_text(prompt, encoding="utf-8")
        elif STARTUP_PROMPT_FILE.exists():
            STARTUP_PROMPT_FILE.unlink()
        self.finished = True
        if self.httpd:
            threading.Thread(target=self.httpd.shutdown, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalModelSetup/1"

    @property
    def app(self) -> Application:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, _format, *_args):
        pass

    def local_request(self) -> bool:
        port = self.server.server_address[1]
        hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        origins = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}
        return self.headers.get("Host", "") in hosts and (not self.headers.get("Origin") or self.headers.get("Origin") in origins)

    def headers_common(self, content_type: str, length: int) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:")

    def json(self, data: dict, code: int = 200) -> None:
        content = json.dumps(data).encode()
        self.send_response(code)
        self.headers_common("application/json; charset=utf-8", len(content))
        self.end_headers()
        self.wfile.write(content)

    def asset(self, name: str, content_type: str) -> None:
        path = WEB_DIR / name
        if not path.is_file():
            self.send_error(404)
            return
        content = path.read_bytes()
        self.send_response(200)
        self.headers_common(content_type, len(content))
        self.end_headers()
        self.wfile.write(content)

    def body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length > 65536:
            raise ValueError("Request too large")
        return json.loads(self.rfile.read(length).decode()) if length else {}

    def do_GET(self):
        if not self.local_request():
            self.send_error(403); return
        path = urllib.parse.urlparse(self.path).path
        if path in {"/", "/index.html"}:
            self.asset("index.html", "text/html; charset=utf-8")
        elif path == "/style.css":
            self.asset("style.css", "text/css; charset=utf-8")
        elif path == "/enhancements.css":
            self.asset("enhancements.css", "text/css; charset=utf-8")
        elif path == "/app.js":
            self.asset("app.js", "application/javascript; charset=utf-8")
        elif path == "/api/bootstrap":
            try: self.json(self.app.bootstrap())
            except Exception as exc: self.json({"error": str(exc)}, 500)
        elif path == "/api/status":
            with self.app.lock: self.json(dict(self.app.status))
        elif path == "/api/resolve-url":
            try:
                rec_id = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("id", [""])[0]
                rec = self.app.recs.get(rec_id)
                if not rec:
                    raise ValueError("Unknown recommendation")
                files = repo_files(rec["repo"], rec["quant"])
                if not files:
                    raise RuntimeError("No files found")
                self.json({"url": files[0]["url"], "filename": files[0]["name"]})
            except Exception as exc:
                self.json({"error": str(exc)}, 500)
        elif path == "/api/search":
            try:
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("q", [""])[0]
                self.json({"results": self.app.search(query), "query": query})
            except ValueError as exc:
                self.json({"error": str(exc)}, 400)
            except Exception as exc:
                self.json({"error": str(exc)}, 500)
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.local_request():
            self.send_error(403); return
        try:
            path = urllib.parse.urlparse(self.path).path
            body = self.body()
            if path == "/api/download":
                self.app.start(str(body.get("recommendation_id", "")))
                self.json({"status": "started"}, 202)
            elif path == "/api/cancel":
                self.app.cancel()
                self.json({"status": "canceling"}, 202)
            elif path == "/api/finish":
                self.app.finish(str(body.get("prompt", "")))
                self.json({"status": "finished"})
            else:
                self.send_error(404)
        except ValueError as exc:
            self.json({"error": str(exc)}, 400)
        except RuntimeError as exc:
            self.json({"error": str(exc)}, 409)
        except Exception as exc:
            self.json({"error": str(exc)}, 500)


def free_port(start: int = 5080, end: int = 5130) -> int:
    import socket
    for port in range(start, end):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                pass
    raise RuntimeError("No free port is available for model setup")


def run_server(no_browser: bool = False) -> int:
    app = Application()
    port = free_port()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.app = app  # type: ignore[attr-defined]
    app.httpd = server
    url = f"http://127.0.0.1:{port}/"
    print(f"Opening model setup at {url}")
    if not no_browser:
        threading.Timer(.5, lambda: webbrowser.open_new_tab(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0 if app.finished else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--find-models", action="store_true")
    parser.add_argument("--selected-model", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    if args.find_models:
        for model in complete_models():
            print(model)
        return 0 if complete_models() else 1
    if args.selected_model:
        model = selected_model()
        if model:
            print(model)
            return 0
        return 1
    return run_server(args.no_browser)


if __name__ == "__main__":
    raise SystemExit(main())
