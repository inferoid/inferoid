"""Meeting notes + private brain: installs the Inferoid Notes Mac app and the notes model that fits this Mac.

The app records the call, transcribes it on the Mac, writes the notes with our fine-tuned model, and answers questions
across all saved meetings (its Ask tab). Nothing leaves the Mac.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any

APP_ZIP = "InferoidNotes.zip"
APP_VERSION = "0.5.0"
# Default downloads: the app from this repo's GitHub release, the model from Hugging Face (pinned revision).
APP_BASE = f"https://github.com/inferoid/inferoid/releases/download/notes-v{APP_VERSION}"
HF_REPOS = {  # model -> (Hugging Face repo, pinned revision)
    "inferoid-notes-e4b": ("Inferoid/inferoid-notes-e4b", "ad96d9b87a0220a7c97b89e2b6d86207c0b4689d"),
    "inferoid-notes-e2b": ("Inferoid/inferoid-notes-e2b", "3b23ac154774fa26d62a104cce168a033cdce475"),
}
APP_NAME = "Inferoid Notes.app"
PORT = 8090
# (model, minimum RAM GB, download GB, what to expect). Measured on 23 held-out calls, judged by two independent models.
MODELS = [
    ("inferoid-notes-e4b", 16, 3.9, "our best notes model: about as few mistakes as a frontier cloud model, ~40 s per call on a 24 GB M4"),
    ("inferoid-notes-e2b", 8, 2.5, "lighter model for 8 GB Macs: twice as fast, but about twice the mistakes of the E4B"),
]
MIN_RAM = MODELS[-1][1]


def home() -> Path:
    return Path(os.environ.get("INFEROID_NOTES_HOME", Path.home() / "inferoid-notes"))


def pick(memory: dict[str, float]) -> tuple[str, int, float, str] | None:
    """The notes model for this much memory, or None under 8 GB."""
    ram = memory.get("ram_gb", 0.0)
    return next((m for m in MODELS if ram >= m[1] - 0.5), None)


def fit_line(memory: dict[str, float]) -> str:
    """One line for the setup menu: what notes would install on this machine."""
    if platform.system() != "Darwin" and not os.environ.get("INFEROID_NOTES_ANY_OS"):
        return "Mac only for now"
    m = pick(memory)
    if not m:
        return f"needs {MIN_RAM} GB of memory"
    return f"{m[0]} ({m[2]:.1f} GB download)"


def source(cfg: dict[str, Any] | None = None) -> str:
    """Override for where the app and model tars come from: a folder or an https:// base URL. Empty = the defaults
    (GitHub release + Hugging Face)."""
    return os.environ.get("INFEROID_NOTES_SOURCE") or (cfg or {}).get("notes_source", "")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(src: str, name: str, dest: Path) -> Path:
    """Copy `name` from a folder, or download it from a base URL, into `dest` (skips a file already there)."""
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / name
    if target.exists():
        return target
    tmp = target.with_suffix(target.suffix + ".part")
    if src.startswith(("http://", "https://")):
        with urllib.request.urlopen(src.rstrip("/") + "/" + name, timeout=60) as resp, tmp.open("wb") as f:
            total, done, shown = int(resp.headers.get("Content-Length") or 0), 0, -1
            while block := resp.read(1 << 20):
                f.write(block)
                done += len(block)
                if total > (5 << 20) and sys.stderr.isatty() and (pct := done * 100 // total) != shown:
                    shown = pct
                    sys.stderr.write(f"\r    {done / 1e6:.0f} of {total / 1e6:.0f} MB ({pct}%)")
            if shown >= 0:
                sys.stderr.write("\n")
    else:
        shutil.copyfile(Path(src).expanduser() / name, tmp)
    tmp.rename(target)
    return target


def _sums(src: str, dest: Path, fetcher: Callable[[str, str, Path], Path]) -> dict[str, str]:
    try:
        text = fetcher(src, "SHA256SUMS", dest).read_text()
    except (OSError, ValueError):
        return {}
    return {parts[1].lstrip("*"): parts[0] for parts in (line.split() for line in text.splitlines()) if len(parts) == 2}


def _python() -> str:
    for name in ("python3.12", "python3.13", "python3.11", "python3"):
        exe = shutil.which(name)
        if exe:
            out = subprocess.run([exe, "-c", "import sys; print(sys.version_info >= (3, 10))"], check=False, capture_output=True, text=True).stdout
            if out.strip() == "True":
                return exe
    return ""


def _app_sum(fetcher: Callable[[str, str, Path], Path], dest: Path) -> dict[str, str]:
    """The release publishes InferoidNotes.zip.sha256 next to the zip."""
    text = fetcher(APP_BASE, APP_ZIP + ".sha256", dest).read_text().split()
    return {APP_ZIP: text[0]} if text else {}


def config_path() -> Path:
    return home() / "notes.json"


def installed() -> dict[str, Any] | None:
    try:
        return json.loads(config_path().read_text())
    except (OSError, ValueError):
        return None


def install(memory: dict[str, float], out: Callable[[str], None] = print, cfg: dict[str, Any] | None = None,
            fetcher: Callable[[str, str, Path], Path] = fetch, run: Callable[[list[str]], int] | None = None,
            apps_dir: Path | None = None, python: str | None = None) -> int:
    """Download and install the app and the notes model. Returns 0 on success."""
    run = run or (lambda cmd: subprocess.call(cmd))
    if platform.system() != "Darwin" and not os.environ.get("INFEROID_NOTES_ANY_OS"):
        out("Inferoid Notes is a Mac app (Apple silicon). Windows and Linux are not supported yet.")
        return 1
    choice = pick(memory)
    if not choice:
        out(f"Inferoid Notes needs at least {MIN_RAM} GB of memory; this machine has {memory.get('ram_gb', 0):.0f} GB.")
        return 1
    model, _, size, why = choice
    src = source(cfg)
    root = home()
    downloads = root / "downloads"
    model_dir = root / model
    out(f"\nInstalling Inferoid Notes with {model} ({size:.1f} GB): {why}.")
    try:
        if src:
            sums = _sums(src, downloads, fetcher)
            names = (APP_ZIP, f"{model}.tar")
        else:
            sums = _app_sum(fetcher, downloads)
            names = (APP_ZIP,)
        files = {}
        for name in names:
            out(f"  Downloading {name}…")
            files[name] = fetcher(src or APP_BASE, name, downloads)
            if name in sums and _sha256(files[name]) != sums[name]:
                files[name].unlink()
                out(f"  {name} did not match its checksum; deleted. Run the install again.")
                return 1
    except (OSError, ValueError) as exc:
        out(f"Download failed ({exc}). Check your connection and run: inferoid add notes")
        return 1

    if src and not (model_dir / "config.json").exists():
        out("  Unpacking the model…")
        with tarfile.open(files[f"{model}.tar"]) as tar:
            tar.extractall(root, filter="data")

    venv = root / "venv"
    py = venv / "bin" / "python"
    if not py.exists():
        uv = None if python else shutil.which("uv")
        out("  Installing the model server (mlx-lm). This takes 1-2 minutes…")
        if uv:  # uv brings its own Python: no Homebrew or system Python needed (macOS ships 3.9)
            ok = run([uv, "venv", "--python", "3.12", str(venv)]) == 0 and \
                run([uv, "pip", "install", "--python", str(py), "mlx-lm"]) == 0
        else:
            base = python or _python()
            if not base:
                out("Python 3.10 or newer is needed for the model server. Install uv (curl -LsSf https://astral.sh/uv/install.sh | sh) "
                    "or Python (brew install python@3.12), then run: inferoid add notes")
                return 1
            ok = run([base, "-m", "venv", str(venv)]) == 0 and run(
                [str(py), "-m", "pip", "install", "--disable-pip-version-check", "--progress-bar", "on", "mlx-lm"]) == 0
        if not ok:
            out(f"Installing mlx-lm failed. Try: {py} -m pip install mlx-lm")
            return 1
        if not (venv / "bin" / "python").exists() and uv:
            out(f"The model server environment was not created in {venv}.")
            return 1

    if not (model_dir / "config.json").exists():
        repo, rev = HF_REPOS[model]
        out(f"  Downloading the model from Hugging Face ({repo})…")
        code = f"from huggingface_hub import snapshot_download; snapshot_download({repo!r}, revision={rev!r}, local_dir={str(model_dir)!r})"
        if run([str(py), "-c", code]) != 0:
            out(f"Downloading {repo} failed. Check your connection and run: inferoid add notes")
            return 1
    if not (model_dir / "config.json").exists():
        out(f"  The model download did not contain {model}/config.json.")
        return 1

    apps = apps_dir or Path("/Applications")
    if not os.access(apps, os.W_OK):
        apps = Path.home() / "Applications"
        apps.mkdir(exist_ok=True)
    out(f"  Installing the app in {apps}…")
    if run(["ditto", "-x", "-k", str(files[APP_ZIP]), str(apps)]) != 0:
        out("Unzipping the app failed.")
        return 1

    config_path().write_text(json.dumps({"model": model, "model_dir": str(model_dir), "python": str(py), "port": PORT,
                                         "app": str(apps / APP_NAME)}, indent=2) + "\n")
    out(f"\nInferoid Notes is installed ({apps / APP_NAME}).")
    out("  Open it, click Start meeting, and allow Microphone and System Audio Recording when macOS asks.")
    out("  The notes model starts by itself when a meeting starts and stops after 10 idle minutes.")
    out("  Ask tab: search all your meetings or ask a question; answers cite the meeting.")
    out("  Your notes are plain files in ~/Documents/Inferoid Notes. Nothing leaves this Mac.")
    return 0


def uninstall(out: Callable[[str], None] = print, run: Callable[[list[str]], int] | None = None,
              apps_dirs: list[Path] | None = None, kill: Callable[[int, int], None] = os.kill) -> int:
    """Remove the app, the notes model, its Python env and settings. Saved meetings in ~/Documents stay."""
    import signal

    def quiet(cmd: list[str]) -> int:
        return subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    run = run or quiet
    try:
        kill(int((home() / "server.pid").read_text().strip()), signal.SIGTERM)
        out("  Stopped the notes model.")
    except (OSError, ValueError):
        pass
    run(["pkill", "-x", "InferoidNotes"])
    for apps in apps_dirs or [Path("/Applications"), Path.home() / "Applications"]:
        app = apps / APP_NAME
        if app.exists():
            shutil.rmtree(app, ignore_errors=True)
            out(f"  Removed {app}")
    if home().exists():
        shutil.rmtree(home(), ignore_errors=True)
        out(f"  Removed {home()} (notes model, model server, settings)")
    run(["defaults", "delete", "ai.inferoid.notes"])
    for service in ("Microphone", "AudioCapture", "ScreenCapture"):
        run(["tccutil", "reset", service, "ai.inferoid.notes"])
    out("  Reset its Microphone and System Audio permissions.")
    out("  Your saved meetings are still in ~/Documents/Inferoid Notes (delete that folder to remove them).")
    return 0
