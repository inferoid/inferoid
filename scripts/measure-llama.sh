#!/bin/bash
set -euo pipefail

CONFIG=${1:-"${HOME}/inferoid-notes/notes.json"}
CONFIG="$CONFIG" python3 - <<'PY'
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

config_path = os.environ["CONFIG"]
with open(config_path, encoding="utf-8") as f:
    config = json.load(f)
if config.get("runtime") != "llama":
    raise SystemExit(f"{config_path} is not a llama runtime config")

server = config["server"]
base = config["base"]
port = int(config.get("port", 8090))
adapters = config.get("adapters", [])
notes_id = next((i for i, a in enumerate(adapters) if a.get("name") == "notes"), None)
if notes_id is None:
    raise SystemExit("no adapter named notes is configured")

command = [server, "-m", base, "--host", "127.0.0.1", "--port", str(port), "-c", "32768", "-np", "1"]
for adapter in adapters:
    command += ["--lora", adapter["file"]]
command.append("--lora-init-without-apply")
log = open(os.devnull, "w")
process = subprocess.Popen(command, stdout=log, stderr=log)
endpoint = f"http://127.0.0.1:{port}"

def get(path):
    with urllib.request.urlopen(endpoint + path, timeout=1) as response:
        return response.read()

def rss_kb():
    value = subprocess.check_output(["ps", "-o", "rss=", "-p", str(process.pid)], text=True).strip()
    return int(value) if value else 0

try:
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            get("/v1/models")
            break
        except (OSError, urllib.error.URLError):
            if process.poll() is not None:
                raise SystemExit(f"llama-server exited with status {process.returncode}")
            time.sleep(1)
    else:
        raise SystemExit("llama-server did not become ready within 180 seconds")

    results = []
    peak_rss = rss_kb()
    for label, lora in (("base", None), ("notes", {"id": notes_id, "scale": adapters[notes_id].get("scale", 1.0)}), ("base", None)):
        body = {
            "model": base,
            "stream": False,
            "max_tokens": 8,
            "temperature": 0.2,
            "messages": [{"role": "user", "content": "Reply with one short word."}],
        }
        if lora is not None:
            body["lora"] = [lora]
        request = urllib.request.Request(endpoint + "/v1/chat/completions",
                                          data=json.dumps(body).encode(),
                                          headers={"Content-Type": "application/json"})
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=900) as response:
            response.read()
        latency = time.monotonic() - started
        current_rss = rss_kb()
        peak_rss = max(peak_rss, current_rss)
        results.append({"request": label, "latency_s": round(latency, 4), "rss_kb": current_rss})

    base_latency = (results[0]["latency_s"] + results[2]["latency_s"]) / 2
    print(json.dumps({
        "server": server,
        "base": base,
        "adapter": "notes",
        "requests": results,
        "server_rss_kb": peak_rss,
        "switch_extra_latency_s": round(results[1]["latency_s"] - base_latency, 4),
    }, indent=2))
finally:
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()
PY
