"""The one model for 24 GB+ Macs: Inkling 2 Mini (3-bit g13 pack) served by g13 writes the notes and answers chat.

Chat streams the first word in about half a second on a 24 GB M4: the app opens Inkling's final-answer channel directly
(no hidden thinking) and the server reuses the cached thread. On 23 held-out calls its notes had fewer mistakes than our
fine-tuned Gemma E4B (60 vs 67, Grok judge), at ~106 s per call. Macs under 24 GB use Gemma E4B for everything.
Nothing leaves the Mac; the server's SSD prompt cache is off so no copy of the records is written outside the vault.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import signal
import subprocess
from collections.abc import Callable
from pathlib import Path

from . import notes

MIN_RAM_GB = 24
PORT = 8095
# g13 v0.3.1 (MIT), pinned to its commit.
G13_SOURCE = "git+https://gitlab.com/karulab/g13-engine.git@c91c0180f9ec099f67e09ff5a4645efbdcee53b5"
# Inkling 2 Mini, g13 3-bit BF16 pack (Apache-2.0 weights + Thinking Machines' acceptable-use policy), pinned revision.
PACK_REPO = "yonlyyone/Inkling-2-Mini-g13-q3-bf16"
PACK_REVISION = "7a7c673e159f18a6313ab9099e15f85b8e607193"
PACK_URL = f"https://huggingface.co/{PACK_REPO}/resolve/{PACK_REVISION}"
PACK_FILES = {  # file -> sha256
    "README.md": "1d667d2f11aa8a0db3b9201d0b3692d824e191f8756dec5765bb87f565326144",
    "chat_template.jinja": "53a9035f3255945704b5857657cfb00c1165090c0641c4f782a0cbf268cc16dc",
    "config.json": "e2bc953bb88cd286fbe41b7ac9bf9001e6bd494b67fd374e4674bc428f37de30",
    "generation_config.json": "a08737c07a65a8fdf69f7cf086576210e5aad4b241437090b26d7b0c4f7905f7",
    "model.safetensors.index.json": "5e741fa694a414f74cdca0c6bc0f7d64bcbca145cfa57632bed1ea0588144a33",
    "model-00001-of-00003.safetensors": "efe05e885d424213c22a26465f77f6a9f449206c11cf7612b591620158f235a7",
    "model-00002-of-00003.safetensors": "3cdebdb22609b4de2aa630f6bb9b1905098db2d80eeec6a1195c8de80dcfc76c",
    "model-00003-of-00003.safetensors": "8538ccf2b985e82753e2e54f9678f7b7e7eb627a9d440d22a7cbbc13020576c6",
    "mtp.safetensors": "7c3b651317f01f73bcf4e1dceba66ef8b7e1a1eac6bc171e882e690a4b10a1d2",
    "tokenizer.json": "7f332727f9a3f093dd452a39cc978e6757627e5dad1b0673aa4e75174f236dd6",
    "tokenizer_config.json": "2090107583ef1cd15a08cb644e3218dafe62f29dbadf5c8026839d13b8b24dde",
}
PACK_GB = 13.0


def root() -> Path:
    return notes.home() / "brain"


def config_path() -> Path:
    return notes.home() / "brain.json"


def installed() -> dict | None:
    try:
        return json.loads(config_path().read_text())
    except (OSError, ValueError):
        return None


def fit_line(memory: dict[str, float]) -> str:
    if memory.get("ram_gb", 0.0) >= MIN_RAM_GB - 0.5:
        return f"Inkling 2 Mini for notes and chat ({PACK_GB:.0f} GB download), first word in about half a second"
    return f"under {MIN_RAM_GB} GB: Gemma E4B does notes and chat"


def _python() -> str:
    for name in ("python3.13", "python3.12", "python3.11"):
        if exe := shutil.which(name):
            return exe
    return ""


def install(memory: dict[str, float], out: Callable[[str], None] = print,
            fetcher: Callable[[str, str, Path], Path] = notes.fetch, run: Callable[[list[str]], int] | None = None) -> int:
    """Install g13 and the Inkling pack, and write brain.json for the app. Returns 0 on success."""
    if platform.system() != "Darwin" and not os.environ.get("INFEROID_NOTES_ANY_OS"):
        out("Brain chat with Inkling runs on Apple silicon Macs only.")
        return 1
    ram = memory.get("ram_gb", 0.0)
    if ram < MIN_RAM_GB - 0.5:
        out(f"Inkling needs a Mac with at least {MIN_RAM_GB} GB of memory (this one has {ram:.0f} GB). "
            "Gemma E4B keeps doing notes and chat.")
        return 1
    if notes.installed() is None:
        out("Install the app first: inferoid add notes")
        return 1
    out(f"\nInstalling Inkling 2 Mini ({PACK_GB:.0f} GB) on g13.")
    if not install_model(out, fetcher, run):
        return 1
    out("\nInkling 2 Mini now writes your notes and answers chat on this Mac. Restart the Inferoid app to pick it up.")
    out("  It loads when needed and stops after 10 idle minutes. Licensed Apache-2.0 with Thinking Machines' acceptable-use policy.")
    return 0


def install_model(out: Callable[[str], None], fetcher: Callable[[str, str, Path], Path] = notes.fetch,
                  run: Callable[[list[str]], int] | None = None) -> bool:
    """g13 + the pinned Inkling pack + brain.json. Shared by `inferoid add brain` and `inferoid add notes` on 24 GB+."""
    run = run or (lambda cmd: subprocess.call(cmd))
    base = root()
    venv = base / "g13-venv"
    g13 = venv / "bin" / "g13"
    if not g13.exists():
        out("  Installing the g13 model server. This takes 1-2 minutes…")
        uv = shutil.which("uv")
        py = venv / "bin" / "python"
        if uv:
            ok = run([uv, "venv", "--python", "3.12", str(venv)]) == 0 and \
                run([uv, "pip", "install", "--python", str(py), "g13 @ " + G13_SOURCE]) == 0
        elif exe := _python():
            ok = run([exe, "-m", "venv", str(venv)]) == 0 and \
                run([str(py), "-m", "pip", "install", "--disable-pip-version-check", "g13 @ " + G13_SOURCE]) == 0
        else:
            out("g13 needs Python 3.11 or newer. Install uv (curl -LsSf https://astral.sh/uv/install.sh | sh), then run it again.")
            return False
        if not ok or not g13.exists():
            out("Installing g13 failed. Run the install again.")
            return False
    model_dir = base / "inkling-g13-q3-bf16"
    out(f"  Downloading Inkling 2 Mini from Hugging Face ({PACK_REPO}, pinned, {PACK_GB:.0f} GB)…")
    try:
        for name, digest in PACK_FILES.items():
            # A file from an older model version is replaced (fetch skips files that already exist).
            old = model_dir / name
            if old.exists() and notes._sha256(old) != digest:
                old.unlink()
            notes._checked_fetch(PACK_URL, name, model_dir, digest, fetcher)
    except (OSError, ValueError) as exc:
        out(f"Download failed ({exc}). Check your connection and run the install again.")
        return False
    config_path().write_text(json.dumps({"runtime": "g13", "g13": str(g13), "model_dir": str(model_dir), "port": PORT,
                                         "revision": PACK_REVISION}, indent=2) + "\n")
    return True


def uninstall(out: Callable[[str], None] = print, kill: Callable[[int, int], None] = os.kill) -> int:
    """Remove g13, the Inkling pack and brain.json (the app then needs a notes model: inferoid add notes)."""
    try:
        kill(int((notes.home() / "brain-server.pid").read_text().strip()), signal.SIGTERM)
        out("  Stopped the Brain model.")
    except (OSError, ValueError):
        pass
    shutil.rmtree(root(), ignore_errors=True)
    config_path().unlink(missing_ok=True)
    out(f"  Removed {root()} (Inkling and g13).")
    return 0
