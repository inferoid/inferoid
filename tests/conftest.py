import pytest

from inferoid import notes


@pytest.fixture(autouse=True)
def _never_install_notes_for_real(request, monkeypatch):
    """A setup test that reaches the real notes installer would download the app and a 4 GB model.
    The installer's own tests (test_install_*) call it on purpose with fake downloads."""
    if request.node.name.startswith("test_install"):
        return

    def refuse(*args, **kwargs):
        raise AssertionError("test reached the real notes installer: pass notes_installer= or a workload answer")
    monkeypatch.setattr(notes, "install", refuse)
