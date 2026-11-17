"""Small Business activation and local workflow runtime helpers.

The activation token is sent only in a POST body. The local cache contains the
entitlement response and timing data, never the token itself.
"""
from __future__ import annotations

import json
import os
import platform
import secrets
import shutil
import stat
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

NODE_RED_VERSION = "4.0.9"
NODE_RED_PORT = 1880
OFFLINE_GRACE_DAYS = 7
FLOW_DIR = Path(__file__).with_name("data") / "flows"


def state_dir() -> Path:
    override = os.environ.get("INFEROID_BUSINESS_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Inferoid"


def entitlement_path() -> Path:
    return state_dir() / "entitlement.json"


def _sysctl(name: str) -> str:
    try:
        return subprocess.run(["sysctl", "-n", name], check=False, capture_output=True, text=True, timeout=2).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def machine_info() -> dict[str, Any]:
    memory = 0
    try:
        memory = int(_sysctl("hw.memsize") or 0) // (1024**3)
    except ValueError:
        pass
    usage = shutil.disk_usage(Path.home())
    return {
        "os": platform.platform(),
        "macos": platform.mac_ver()[0],
        "chip": _sysctl("machdep.cpu.brand_string") or platform.machine(),
        "ram_gb": memory,
        "free_disk_gb": round(usage.free / (1024**3), 1),
    }


def _write_private(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    temp.chmod(stat.S_IRUSR | stat.S_IWUSR)
    temp.replace(path)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def activate(token: str, endpoint: str | None = None, opener: Callable[..., Any] = urllib.request.urlopen) -> dict[str, Any]:
    """Activate against the hub and cache only the returned entitlement."""
    token = token.strip()
    if not token or len(token) > 256:
        raise ValueError("activation token is required")
    url = (endpoint or os.environ.get("INFEROID_HUB_URL", "https://app.inferoid.com")).rstrip("/") + "/api/activate"
    payload = json.dumps({"token": token, "machine": machine_info()}).encode()
    request = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    try:
        with opener(request, timeout=30) as response:
            if getattr(response, "status", 200) != 200:
                raise ValueError("activation was rejected")
            result = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        raise ValueError("activation was rejected") from exc
    if not isinstance(result, dict) or not result.get("plan"):
        raise ValueError("hub returned an invalid entitlement")
    now = int(time.time())
    result["activated_at"] = now
    result["grace_until"] = now + int(result.get("offline_grace_days", OFFLINE_GRACE_DAYS)) * 86400
    _write_private(entitlement_path(), result)
    return result


def cached_entitlement(now: int | None = None) -> dict[str, Any] | None:
    try:
        result = json.loads(entitlement_path().read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(result, dict) or not result.get("plan"):
        return None
    if now is not None and now > int(result.get("grace_until", 0)):
        return None
    return result


def node_red_dir() -> Path:
    return state_dir() / "node-red"


def node_red_command() -> list[str]:
    return ["npx", "--yes", f"node-red@{NODE_RED_VERSION}", "--userDir", str(node_red_dir()), "--settings", str(node_red_dir() / "settings.js"), "--port", str(NODE_RED_PORT)]


def _keychain_secret(service: str, account: str = "inferoid") -> str:
    if platform.system() != "Darwin" or not shutil.which("security"):
        raise RuntimeError("macOS Keychain is required for Node-RED credentials")
    found = subprocess.run(["security", "find-generic-password", "-a", account, "-s", service, "-w"], check=False, capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    value = secrets.token_urlsafe(32)
    stored = subprocess.run(["security", "add-generic-password", "-a", account, "-s", service, "-w", value, "-U"], check=False, capture_output=True, text=True)
    if stored.returncode != 0:
        raise RuntimeError("unable to store Node-RED credentials in Keychain")
    return value


def write_node_red_settings(password_hash: str, credential_secret: str | None = None) -> Path:
    """Write a loopback-only Node-RED configuration with adminAuth enabled."""
    root = node_red_dir()
    root.mkdir(parents=True, exist_ok=True)
    credential_secret = credential_secret or _keychain_secret("ai.inferoid.node-red.credential")
    settings = """module.exports = {\n  uiPort: %d,\n  uiHost: '127.0.0.1',\n  httpAdminRoot: '/red',\n  credentialSecret: %r,\n  adminAuth: { type: 'credentials', users: [{ username: 'inferoid', password: %r, permissions: '*' }] },\n  httpAdminMiddleware: function(req, res, next) {\n    const host = (req.headers.host || '').split(':')[0];\n    if (host !== '127.0.0.1' && host !== 'localhost' && host !== '::1') return res.status(403).send('loopback only');\n    next();\n  },\n  editorTheme: { projects: { enabled: false } }\n};\n""" % (NODE_RED_PORT, credential_secret, password_hash)
    path = root / "settings.js"
    path.write_text(settings)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    return path


def install_node_red(run: Callable[..., Any] = subprocess.run) -> Path:
    """Install the pinned Node-RED package into an isolated local user dir.

    The pilot intentionally does not use a system-wide npm install. The host's
    existing Node.js runtime is used by npx; a packaged Node runtime is the
    next release artifact once its notarized binary is selected.
    """
    root = node_red_dir()
    root.mkdir(parents=True, exist_ok=True)
    result = run(node_red_command() + ["--help"], check=False, capture_output=True, text=True)
    if getattr(result, "returncode", 1) != 0:
        raise RuntimeError("Node.js/npm is required to install the pinned Node-RED runtime")
    admin_password = _keychain_secret("ai.inferoid.node-red.admin")
    hashed = run(["npx", "--yes", f"node-red@{NODE_RED_VERSION}", "admin", "hash-pw"], input=admin_password + "\n", check=False, capture_output=True, text=True)
    password_hash = next((line.strip() for line in getattr(hashed, "stdout", "").splitlines() if line.strip().startswith("$2")), "")
    if getattr(hashed, "returncode", 1) != 0 or not password_hash:
        raise RuntimeError("unable to create Node-RED adminAuth credentials")
    write_node_red_settings(password_hash)
    return root


def starter_flows() -> list[Path]:
    return sorted(FLOW_DIR.glob("*.json"))
