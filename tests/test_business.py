import json
from types import SimpleNamespace

from inferoid import business


class _Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps({"plan": "small-business", "features": ["chat", "workflows"], "offline_grace_days": 7}).encode()


def test_activate_caches_entitlement_without_token_in_cache(tmp_path, monkeypatch):
    monkeypatch.setenv("INFEROID_BUSINESS_HOME", str(tmp_path))
    monkeypatch.setattr(business, "machine_info", lambda: {"chip": "Apple M4", "ram_gb": 24})
    seen = {}

    def opener(request, timeout):
        seen["url"] = request.full_url
        seen["body"] = request.data
        return _Response()

    result = business.activate("ifd_secret", endpoint="https://app.example.test", opener=opener)
    cached = business.entitlement_path().read_text()
    assert result["plan"] == "small-business"
    assert seen["url"] == "https://app.example.test/api/activate"
    assert "ifd_secret" not in cached
    assert json.loads(cached)["features"] == ["chat", "workflows"]


def test_expired_entitlement_is_not_available(tmp_path, monkeypatch):
    monkeypatch.setenv("INFEROID_BUSINESS_HOME", str(tmp_path))
    business.entitlement_path().write_text(json.dumps({"plan": "small-business", "grace_until": 10}))
    assert business.cached_entitlement(now=11) is None


def test_node_red_is_pinned_and_flows_are_packaged():
    command = business.node_red_command()
    assert f"node-red@{business.NODE_RED_VERSION}" in command
    names = {path.stem for path in business.starter_flows()}
    assert names == {"meeting-to-local-notes", "notes-to-follow-up-draft"}


def test_node_red_settings_are_loopback_only_and_authenticated(tmp_path, monkeypatch):
    monkeypatch.setenv("INFEROID_BUSINESS_HOME", str(tmp_path))
    path = business.write_node_red_settings("$2b$12$test", credential_secret="credential-secret")
    text = path.read_text()
    assert "uiHost: '127.0.0.1'" in text
    assert "adminAuth" in text
    assert "credential-secret" in text
    assert "loopback only" in text
