import hashlib
import io
import json
import tarfile

from inferoid import models, notes, setup


def _source(tmp_path, model="inferoid-notes-e4b", bad_sum=False):
    src = tmp_path / "src"
    src.mkdir()
    (src / notes.APP_ZIP).write_bytes(b"zip")
    with tarfile.open(src / f"{model}.tar", "w") as tar:
        data = b"{}"
        info = tarfile.TarInfo(f"{model}/config.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    sums = {n: hashlib.sha256((src / n).read_bytes()).hexdigest() for n in (notes.APP_ZIP, f"{model}.tar")}
    if bad_sum:
        sums[notes.APP_ZIP] = "0" * 64
    (src / "SHA256SUMS").write_text("".join(f"{h}  {n}\n" for n, h in sums.items()))
    return src


def _env(tmp_path, monkeypatch):
    monkeypatch.setenv("INFEROID_NOTES_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("INFEROID_NOTES_ANY_OS", "1")


def test_pick_by_memory():
    assert notes.pick({"ram_gb": 24})[0] == "inferoid-notes-e4b"
    assert notes.pick({"ram_gb": 16})[0] == "inferoid-notes-e4b"
    assert notes.pick({"ram_gb": 8})[0] == "inferoid-notes-e2b"
    assert notes.pick({"ram_gb": 4}) is None


def test_install_from_folder(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch)
    monkeypatch.setenv("INFEROID_NOTES_SOURCE", str(_source(tmp_path)))
    cmds, lines = [], []
    rc = notes.install({"ram_gb": 24}, lines.append, run=lambda c: cmds.append(c) or 0, apps_dir=tmp_path, python="/usr/bin/python3")
    assert rc == 0, lines
    cfg = notes.installed()
    assert cfg["model"] == "inferoid-notes-e4b" and cfg["port"] == 8090
    assert (tmp_path / "home" / "inferoid-notes-e4b" / "config.json").exists()
    assert any(c[:2] == ["ditto", "-x"] for c in cmds) and any("mlx-lm" in c for c in cmds)


def test_install_rejects_bad_checksum_and_missing_source(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch)
    lines = []
    monkeypatch.setenv("INFEROID_NOTES_SOURCE", str(_source(tmp_path, bad_sum=True)))
    assert notes.install({"ram_gb": 24}, lines.append, run=lambda c: 0, apps_dir=tmp_path) == 1
    assert "checksum" in lines[-1]
    assert notes.install({"ram_gb": 4}, lines.append) == 1 and "at least 8 GB" in lines[-1]


def test_install_default_pulls_release_app_and_hf_model(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch)
    monkeypatch.delenv("INFEROID_NOTES_SOURCE", raising=False)
    rel = tmp_path / "release"
    rel.mkdir()
    (rel / notes.APP_ZIP).write_bytes(b"zip")
    (rel / (notes.APP_ZIP + ".sha256")).write_text(hashlib.sha256(b"zip").hexdigest() + "  InferoidNotes.zip\n")
    urls = []

    def fetcher(src, name, dest):
        urls.append(src)
        return notes.fetch(str(rel), name, dest)

    def run(cmd):
        if "snapshot_download" in " ".join(cmd):
            assert "Inferoid/inferoid-notes-e2b" in cmd[-1]
            d = tmp_path / "home" / "inferoid-notes-e2b"
            d.mkdir(parents=True)
            (d / "config.json").write_text("{}")
        return 0

    lines = []
    assert notes.install({"ram_gb": 8}, lines.append, fetcher=fetcher, run=run, apps_dir=tmp_path, python="/usr/bin/python3") == 0, lines
    assert set(urls) == {notes.APP_BASE} and notes.installed()["model"] == "inferoid-notes-e2b"
    assert any("Hugging Face" in x for x in lines)


def _setup_env(tmp_path, monkeypatch, ram=24.0):
    monkeypatch.setenv("INFEROID_HOME", str(tmp_path / "ihome"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "dotclaude"))
    monkeypatch.setenv("OLLAMA_CONTEXT_LENGTH", "65536")
    monkeypatch.setattr(setup, "machine_memory", lambda: {"ram_gb": ram, "wired_limit_gb": 0.0})
    monkeypatch.setattr(setup.shutil, "which", lambda name: "/usr/bin/" + name)
    monkeypatch.setattr(setup, "_ollama_models", lambda: set())


def test_setup_notes_only_skips_the_coding_steps(tmp_path, monkeypatch):
    _setup_env(tmp_path, monkeypatch, ram=8.0)
    called, lines = [], []
    rc = setup.run(tmp_path, answers={"workload": "1"}, out=lines.append,
                   notes_installer=lambda mem, out: called.append(mem["ram_gb"]) or 0)
    text = "\n".join(lines)
    assert rc == 0 and called == [8.0]
    assert "Which coding agent" not in text and "add a coding model" in text
    assert "under 24 GB" in text  # the coding option says what this 8 GB machine can do


def test_setup_notes_and_coding(tmp_path, monkeypatch):
    _setup_env(tmp_path, monkeypatch)
    called, lines = [], []
    rc = setup.run(tmp_path / "proj", answers={"workload": "2,1,3", "report": "n"}, out=lines.append, pull=lambda m: 0,
                   claude_version=lambda: "2.1.322", bin_dir=tmp_path / "bin", sandbox_checker=lambda: "verified",
                   notes_installer=lambda mem, out: called.append(1) or 0)
    text = "\n".join(lines)
    assert rc == 0 and called == [1]
    assert "run one at a time" in text and "Music is coming soon" in text
    assert "Inferoid app installed" in text and "Which coding agent" in text


def test_models_status_and_unload(tmp_path, monkeypatch):
    monkeypatch.setenv("INFEROID_NOTES_HOME", str(tmp_path))
    (tmp_path / "notes.json").write_text(json.dumps({"model": "inferoid-notes-e4b"}))
    (tmp_path / "server.pid").write_text("4242")

    def get(url):
        if url.endswith("/api/tags"):
            return {"models": [{"name": "ornith:20b", "size": 11e9}]}
        if url.endswith("/api/ps"):
            return {"models": [{"name": "ornith:20b", "size_vram": 12e9}]}
        return {"data": []}  # notes server answers

    text = "\n".join(models.status({"ram_gb": 24.0, "wired_limit_gb": 0.0}, get))
    assert "inferoid-notes-e4b" in text and "ornith:20b" in text and "Over budget" in text  # 6 + 12 GB > 16 GB
    posted, killed = [], []
    done = models.unload(get, post=lambda url, body: posted.append(body), kill=lambda pid, sig: killed.append(pid))
    assert posted == [{"model": "ornith:20b", "keep_alive": 0}] and killed == [4242]
    assert "stopped the notes model" in done and not (tmp_path / "server.pid").exists()


def test_catalog_jobs_and_add(tmp_path, monkeypatch):
    from inferoid import catalog
    _env(tmp_path, monkeypatch)
    assert list(catalog.JOBS) == setup.USES and "notes" in catalog.JOBS
    text = "\n".join(catalog.listing({"ram_gb": 8.0}))
    assert "inferoid-notes-e2b" in text and "coming soon" in text
    lines = []
    assert catalog.add("music", {"ram_gb": 24}, lines.append) == 1 and "coming soon" in lines[-1]
    assert catalog.add("coding", {"ram_gb": 24}, lines.append) == 1 and "inferoid setup" in lines[-1]
    assert catalog.add("nope", {"ram_gb": 24}, lines.append) == 2
    monkeypatch.setattr(notes, "install", lambda mem, out: 7)
    assert catalog.add("notes", {"ram_gb": 24}, lines.append) == 7  # routed to the notes installer


def test_remove_and_uninstall(tmp_path, monkeypatch):
    from inferoid import catalog, uninstall
    _env(tmp_path, monkeypatch)
    monkeypatch.setenv("INFEROID_HOME", str(tmp_path / "ihome"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "dotclaude"))
    (tmp_path / "ihome").mkdir()
    home = tmp_path / "home"
    home.mkdir()
    (home / "notes.json").write_text("{}")
    apps = tmp_path / "apps"
    (apps / notes.APP_NAME).mkdir(parents=True)
    ran, lines = [], []
    assert notes.uninstall(lines.append, run=lambda c: ran.append(c) or 0, apps_dirs=[apps]) == 0
    assert not home.exists() and not (apps / notes.APP_NAME).exists()
    assert ["defaults", "delete", "ai.inferoid.notes"] in ran and any(c[:2] == ["tccutil", "reset"] for c in ran)
    assert catalog.remove("music", lines.append) == 2
    monkeypatch.setattr(notes, "uninstall", lambda out: 0)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "claude-local").write_text("")
    assert uninstall.run(ask=lambda q: "n", out=lines.append) == 1
    assert uninstall.run(yes=True, out=lines.append, bin_dir=bin_dir) == 0
    assert not (tmp_path / "ihome").exists() and not (bin_dir / "claude-local").exists()
    assert "uv tool uninstall inferoid" in "\n".join(lines)


def test_setup_offers_coding_after_notes(tmp_path, monkeypatch):
    _setup_env(tmp_path, monkeypatch, ram=24.0)
    monkeypatch.setenv("INFEROID_NOTES_ANY_OS", "1")
    called, lines = [], []
    rc = setup.run(tmp_path, answers={"workload": "1", "add_coding": "n"}, out=lines.append,
                   notes_installer=lambda mem, out: called.append(1) or 0)
    text = "\n".join(lines)
    assert rc == 0 and called == [1] and "You're all set" in text and "Which coding agent" not in text
    assert setup.fitting_uses({"ram_gb": 24.0}) == ["notes", "coding"] and setup.fitting_uses({"ram_gb": 8.0}) == ["notes"]


def test_install_uses_uv_python_when_available(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch)
    monkeypatch.setenv("INFEROID_NOTES_SOURCE", str(_source(tmp_path)))
    monkeypatch.setattr(notes.shutil, "which", lambda name: "/opt/uv" if name == "uv" else None)
    cmds = []

    def run(cmd):
        cmds.append(cmd)
        if cmd[:2] == ["/opt/uv", "venv"]:
            (tmp_path / "home" / "venv" / "bin").mkdir(parents=True)
            (tmp_path / "home" / "venv" / "bin" / "python").write_text("")
        return 0

    assert notes.install({"ram_gb": 24}, lambda s: None, run=run, apps_dir=tmp_path) == 0
    assert cmds[0][:4] == ["/opt/uv", "venv", "--python", "3.12"] and cmds[1][:3] == ["/opt/uv", "pip", "install"]
