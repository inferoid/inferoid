import { useEffect, useState } from "react";
import { api, AppUpdate, ModelUpdate } from "../api";

/** Home: the AI model and the Inferoid app, each with "Update available" and an Update button, like the Mac. */
export function UpdateCards() {
  const [app, setApp] = useState<AppUpdate>();
  const [model, setModel] = useState<ModelUpdate>();
  const [appBusy, setAppBusy] = useState(""); const [modelBusy, setModelBusy] = useState("");
  const check = () => { void api.checkAppUpdate().then(setApp).catch(() => undefined); void api.checkModelUpdate().then(setModel).catch(() => undefined); };
  useEffect(check, []);

  async function updateApp() { setAppBusy("Downloading the update… Inferoid restarts when it's installed."); try { await api.installAppUpdate(); } catch (e) { setAppBusy(""); setApp((a) => a && { ...a, error: String(e) }); } }
  async function updateModel() { setModelBusy("Updating the model…"); try { await api.updateModel(); setModelBusy("Model updated."); check(); } catch (e) { setModelBusy(String(e)); } }

  return <>
    <section className="home-card update-card"><div><h3>AI model</h3><p className="muted">Inkling 2 Mini · runs on this PC</p>
      {modelBusy ? <p className="muted">{modelBusy}</p> : model?.available ? <p className="update-note">Update available{model.name ? `: ${model.name}` : ""}</p> : model?.installed ? <p className="muted">Model up to date</p> : null}</div>
      {model?.available && !modelBusy && <button className="primary-button" onClick={() => void updateModel()}>Update model</button>}</section>
    <section className="home-card update-card"><div><h3>Inferoid</h3><p className="muted">Version {app?.current ?? "…"}</p>
      {appBusy ? <p className="muted">{appBusy}</p> : app?.error ? <p className="update-note">{app.error}</p> : app?.available ? <p className="update-note">Update available: version {app.latest}</p> : app ? <p className="muted">You're up to date.</p> : null}</div>
      {app?.available && !appBusy ? <button className="primary-button" onClick={() => void updateApp()}>Update</button> : !appBusy && <button className="secondary-button" onClick={check}>Check for updates</button>}</section>
  </>;
}
