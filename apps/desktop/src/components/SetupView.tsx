import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, SetupProgress, SetupStatus } from "../api";

const gb = (bytes: number) => `${(bytes / 1e9).toFixed(1)} GB`;

/** First run: check the GPU, then download the engine and model (about 10 GB), with progress per file. */
export function SetupView({ onDone }: { onDone: () => void }) {
  const [status, setStatus] = useState<SetupStatus>();
  const [items, setItems] = useState<Record<string, SetupProgress>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    void api.setupStatus().then(setStatus).catch((e) => setError(String(e)));
    let stop: (() => void) | undefined;
    void listen<SetupProgress>("setup-progress", (event) => setItems((current) => ({ ...current, [event.payload.key]: event.payload }))).then((fn) => { stop = fn; });
    return () => stop?.();
  }, []);

  async function start() {
    setBusy(true); setError("");
    try { await api.runSetup(); onDone(); } catch (e) { setError(String(e)); } finally { setBusy(false); }
  }

  return <div className="setup-page">
    <div className="setup-card">
      <div className="brand-mark">i</div>
      <h1>Set up Inferoid</h1>
      <p className="muted">Inferoid runs its AI on this computer. The first time, it downloads the AI engine and model (about {status ? gb(status.totalBytes) : "10 GB"}). Nothing you do in Inferoid leaves this PC.</p>
      {status && <p className={status.supported ? "setup-gpu ok" : "setup-gpu bad"}>{status.gpu ? `${status.gpu} · ${Math.round((status.vramMb ?? 0) / 1024)} GB` : "No NVIDIA GPU found"}{!status.supported && <><br />{status.reason}</>}</p>}
      {Object.values(items).length > 0 && <ul className="setup-list">{Object.values(items).map((item) => <li key={item.key}>
        <div className="setup-row"><span>{item.label}</span><small>{item.phase}{item.phase === "Downloading" || item.phase === "Checking" ? ` · ${gb(item.done)} of ${gb(item.total)}` : ""}</small></div>
        <div className="setup-bar"><i style={{ width: `${item.total ? Math.min(100, (100 * item.done) / item.total) : 0}%` }} /></div>
      </li>)}</ul>}
      {error && <p className="setup-error">{error}</p>}
      <button className="primary-button" disabled={busy || !status?.supported} onClick={() => void start()}>{busy ? "Setting up… keep Inferoid open" : error ? "Try again" : "Download and set up"}</button>
      <p className="muted small">Downloads resume where they stopped if the connection drops. Every file is checked against its checksum.</p>
    </div>
  </div>;
}
