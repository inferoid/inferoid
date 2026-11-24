"""`inferoid models`: what is installed, what is loaded right now, and how much of the GPU memory budget it uses.

On a Mac every loaded model shares one GPU memory budget (about two thirds of RAM by default), so two large models at
once can crash the one that loads second. The Inferoid app starts its model only when needed and unloads Ollama
models first; `inferoid models unload` does the same by hand.
"""
from __future__ import annotations

import json
import os
import signal
import urllib.request
from collections.abc import Callable
from typing import Any

from . import claude, notes
from .night import machine_memory


def _get(url: str) -> Any:
    with urllib.request.urlopen(url, timeout=2) as resp:
        return json.loads(resp.read())


def ollama_installed(get: Callable[[str], Any] = _get) -> dict[str, float]:
    try:
        return {m["name"]: m.get("size", 0) / 1e9 for m in get(claude.OLLAMA + "/api/tags").get("models", [])}
    except (OSError, ValueError, KeyError):
        return {}


def ollama_loaded(get: Callable[[str], Any] = _get) -> dict[str, float]:
    try:
        return {m["name"]: (m.get("size_vram") or m.get("size", 0)) / 1e9 for m in get(claude.OLLAMA + "/api/ps").get("models", [])}
    except (OSError, ValueError, KeyError):
        return {}


def notes_running(get: Callable[[str], Any] = _get, port: int = notes.PORT) -> bool:
    try:
        get(f"http://127.0.0.1:{port}/v1/models")
        return True
    except (OSError, ValueError):
        return False


def status(memory: dict[str, float] | None = None, get: Callable[[str], Any] = _get) -> list[str]:
    memory = memory or machine_memory()
    budget = claude.gpu_budget(memory)
    lines = [f"This machine: {memory.get('ram_gb', 0):.0f} GB memory, about {budget:.0f} GB usable by models at once."]
    installed = ollama_installed(get)
    loaded = ollama_loaded(get)
    cfg = notes.installed()
    lines.append("\nInstalled:")
    if cfg:
        lines.append(f"  {cfg['model']:<44} notes + private brain (Inferoid app)")
    for name, gb in sorted(installed.items()):
        lines.append(f"  {name:<44} {gb:5.1f} GB  (Ollama)")
    if not cfg and not installed:
        lines.append("  nothing yet: run inferoid setup")
    lines.append("\nLoaded now:")
    used = 0.0
    if cfg and notes_running(get, 8095 if cfg.get("runtime") == "inkling" else notes.PORT):
        gb = 6.0 if "e4b" in cfg["model"] else 4.0  # weights + speech model + working memory for an hour-long call
        if cfg.get("runtime") == "inkling":
            gb = 14.0  # 12.3 GB pack + caches (g13 server on brain.PORT)
        used += gb
        lines.append(f"  {cfg['model']:<44} ~{gb:.0f} GB  (stops after 10 idle minutes)")
    for name, gb in loaded.items():
        used += gb
        lines.append(f"  {name:<44} {gb:5.1f} GB  (Ollama)")
    if used == 0:
        lines.append("  none")
    else:
        warn = "  Over budget: unload one (inferoid models unload)." if used > budget else ""
        lines.append(f"  total ~{used:.0f} of {budget:.0f} GB." + warn)
    return lines


def unload(get: Callable[[str], Any] = _get, post: Callable[[str, dict], Any] | None = None,
           kill: Callable[[int, int], None] = os.kill) -> list[str]:
    """Unload every Ollama model and stop the notes model server. They load again when next used."""
    def _post(url: str, body: dict) -> Any:
        req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()

    post = post or _post
    done = []
    for name in ollama_loaded(get):
        try:
            post(claude.OLLAMA + "/api/generate", {"model": name, "keep_alive": 0})
            done.append(f"unloaded {name}")
        except OSError as exc:
            done.append(f"could not unload {name}: {exc}")
    pid_file = notes.home() / "server.pid"
    try:
        pid = int(pid_file.read_text().strip())
        kill(pid, signal.SIGTERM)
        pid_file.unlink()
        done.append("stopped the notes model")
    except (OSError, ValueError):
        pass
    return done or ["nothing was loaded"]
