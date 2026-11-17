"""`inferoid uninstall`: remove everything inferoid installed. Saved meetings in ~/Documents stay."""
from __future__ import annotations

import os
import shutil
from collections.abc import Callable
from pathlib import Path

from . import claude, notes
from .setup import LAUNCHER, NEXT_LAUNCHER


def run(yes: bool = False, out: Callable[[str], None] = print, ask: Callable[[str], str] = input,
        bin_dir: Path | None = None) -> int:
    if not yes and not ask("Remove Inferoid Notes, its model, the Claude Code hooks and inferoid's settings? (y/n) ").lower().startswith("y"):
        out("Nothing removed.")
        return 1
    notes.uninstall(out)
    try:
        for line in claude.uninstall(Path.cwd(), global_=True):
            out("  " + line)
    except OSError as exc:
        out(f"  Could not remove the Claude Code hooks: {exc}")
    state = Path(os.environ.get("INFEROID_HOME", Path.home() / ".inferoid"))
    if state.exists():
        shutil.rmtree(state, ignore_errors=True)
        out(f"  Removed {state}")
    for name in (LAUNCHER, NEXT_LAUNCHER):
        launcher = (bin_dir or Path.home() / ".local" / "bin") / name
        if launcher.exists():
            launcher.unlink()
            out(f"  Removed {launcher}")
    out("\nLast step, removes the inferoid command itself:  uv tool uninstall inferoid")
    out("Projects where you ran `inferoid claude install` keep their hook: run `inferoid claude uninstall` there first.")
    out("Ollama and its models are shared with other tools and stay (ollama list / ollama rm <name>).")
    return 0
