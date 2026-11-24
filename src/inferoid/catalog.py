"""The jobs Inferoid can do on this machine. A job = a model picked (or fine-tuned) for one purpose + how to install it,
plus an app only when the job needs one. `inferoid setup` offers these; `inferoid add <job>` installs one later.

Adding a job: add an entry here. Ollama jobs reuse the setup flow; app jobs bring their own installer module.
"""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from . import notes


@dataclass(frozen=True)
class Job:
    key: str
    label: str
    kind: str  # "ollama": a model wired to your agent by `inferoid setup`; "app": installs an app + its model; "soon"
    fit: Callable[[dict[str, float]], str]
    install: Callable[[dict[str, float], Callable[[str], None]], int] | None = None
    remove: Callable[[Callable[[str], None]], int] | None = None
    models: tuple[str, ...] = field(default=())


def _ram(mem: dict[str, float]) -> float:
    return mem.get("vram_gb") or mem.get("ram_gb", 0.0)


JOBS: dict[str, Job] = {j.key: j for j in (
    Job("notes", "Meeting notes + private brain: records your calls, writes the notes, answers questions across all your meetings",
        "app", notes.fit_line, lambda m, out: notes.install(m, out), lambda out: notes.uninstall(out),
        tuple(n for n, *_ in notes.MODELS)),
    Job("coding", "Coding: a local model your coding agent hands chores to", "ollama",
        lambda m: "a local model fits" if _ram(m) >= 24 else "under 24 GB: a cloud model takes over, or a weaker local one"),
    Job("music", "Music: mixing and transitions (coming soon)", "soon", lambda m: "not available yet"),
    Job("general", "General: chat, writing and documents with a local model", "ollama", lambda m: "fits"),
)}


def listing(mem: dict[str, float]) -> list[str]:
    lines = ["Jobs Inferoid can do on this machine:"]
    for j in JOBS.values():
        lines.append(f"  {j.key:<8} {j.label}\n           on this machine: {j.fit(mem)}")
    lines.append("\nAdd one with: inferoid add <job>   (coding and general: inferoid setup)")
    return lines


def add(key: str, mem: dict[str, float], out: Callable[[str], None] = print, runtime: str = "mlx") -> int:
    job = JOBS.get(key)
    if not job:
        out(f"Unknown job {key!r}. Jobs: {', '.join(JOBS)}")
        return 2
    if job.kind == "soon":
        out(f"{job.label.split(':')[0]} is coming soon.")
        return 1
    if job.kind == "ollama":
        out(f"{key} picks a model and connects it to your coding agent: run inferoid setup and choose {key}.")
        return 1
    assert job.install is not None
    if key == "notes" and runtime != "mlx":
        return notes.install(mem, out, runtime=runtime)
    return job.install(mem, out)


def remove(key: str, out: Callable[[str], None] = print) -> int:
    job = JOBS.get(key)
    if not job or not job.remove:
        out(f"Nothing to remove for {key!r}. Removable: {', '.join(k for k, j in JOBS.items() if j.remove)}. "
            "To remove everything: inferoid uninstall")
        return 2
    out(f"Removing {key}…")
    return job.remove(out)
