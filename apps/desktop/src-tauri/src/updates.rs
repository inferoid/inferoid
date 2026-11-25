//! Updates on Windows, like the Mac's Home cards: the app (latest GitHub release's Inferoid-Setup.exe, checked against its
//! .sha256, installed silently after the app quits, then relaunched) and the model (models.json in the public repo).

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::time::Duration;
use tauri::AppHandle;

const RELEASES_API: &str = "https://api.github.com/repos/inferoid/inferoid/releases/latest";
const MODELS_MANIFEST: &str = "https://raw.githubusercontent.com/inferoid/inferoid/main/models.json";
const MODEL_KEY: &str = "inkling-2-mini-gguf-q2kxl";
const SETUP_ASSET: &str = "Inferoid-Setup.exe";

#[derive(Serialize)]
pub(crate) struct AppUpdate {
    current: String,
    latest: Option<String>,
    available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
pub(crate) struct ModelUpdate {
    installed: Option<String>,
    available: bool,
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .user_agent("Inferoid-Windows")
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(600))
        .build()
        .map_err(|e| e.to_string())
}

/// "0.7.10" is newer than "0.7.9"; missing parts count as 0.
pub(crate) fn is_newer(candidate: &str, current: &str) -> bool {
    let parse = |v: &str| v.split('.').map(|p| p.trim().parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (a, b) = (parse(candidate), parse(current));
    for index in 0..a.len().max(b.len()) {
        let x = a.get(index).copied().unwrap_or(0);
        let y = b.get(index).copied().unwrap_or(0);
        if x != y { return x > y; }
    }
    false
}

fn latest_release() -> Result<(String, Option<String>, Option<String>), String> {
    let value: serde_json::Value = client()?.get(RELEASES_API).header("Accept", "application/vnd.github+json")
        .send().map_err(|e| e.to_string())?.json().map_err(|e| e.to_string())?;
    let tag = value.get("tag_name").and_then(|v| v.as_str()).ok_or("No release found")?;
    let asset = |name: &str| value.get("assets").and_then(|a| a.as_array()).and_then(|list| list.iter()
        .find(|x| x.get("name").and_then(|n| n.as_str()) == Some(name))
        .and_then(|x| x.get("browser_download_url")).and_then(|u| u.as_str()).map(String::from));
    Ok((tag.trim_start_matches("notes-v").to_string(), asset(SETUP_ASSET), asset(format!("{SETUP_ASSET}.sha256").as_str())))
}

#[tauri::command(async)]
pub(crate) fn check_app_update(app: AppHandle) -> AppUpdate {
    let current = app.package_info().version.to_string();
    match latest_release() {
        Ok((latest, installer, _)) => AppUpdate { available: installer.is_some() && is_newer(&latest, &current), latest: Some(latest), current, error: None },
        Err(error) => AppUpdate { current, latest: None, available: false, error: Some(format!("Couldn't check for updates ({error}).")) },
    }
}

/// Download the installer, check its SHA-256, then run it silently after this app exits and start the new version.
#[tauri::command(async)]
pub(crate) fn install_app_update(app: AppHandle) -> Result<(), String> {
    let (_, installer, checksum) = latest_release()?;
    let installer = installer.ok_or("The latest release has no Windows installer yet.")?;
    let checksum = checksum.ok_or("The latest release has no checksum, so it wasn't installed.")?;
    let client = client()?;
    let bytes = client.get(&installer).send().map_err(|e| e.to_string())?.bytes().map_err(|e| e.to_string())?;
    let expected = client.get(&checksum).send().map_err(|e| e.to_string())?.text().map_err(|e| e.to_string())?;
    let expected = expected.split_whitespace().next().unwrap_or("").to_lowercase();
    let actual: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    if expected.is_empty() || expected != actual { return Err("The download didn't match its checksum, so it wasn't installed.".into()); }
    let dir = std::env::temp_dir().join(format!("inferoid-update-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let setup = dir.join(SETUP_ASSET);
    std::fs::write(&setup, &bytes).map_err(|e| e.to_string())?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let pid = std::process::id();
    // Wait for this app to exit, install silently (NSIS /S, per-user), start the new version.
    let script = format!(
        "$p = Get-Process -Id {pid} -ErrorAction SilentlyContinue; if ($p) {{ $p.WaitForExit(30000) | Out-Null }}; \
         Start-Process -FilePath '{}' -ArgumentList '/S' -Wait; Start-Process -FilePath '{}'",
        setup.display().to_string().replace('\'', "''"), exe.display().to_string().replace('\'', "''"));
    let mut command = std::process::Command::new("powershell.exe");
    command.args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0000_0008 | 0x0800_0000); // DETACHED_PROCESS | CREATE_NO_WINDOW
    }
    command.spawn().map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}

#[tauri::command(async)]
pub(crate) fn check_model_update() -> ModelUpdate {
    let installed: Option<String> = std::fs::read_to_string(super::support_root().join("engine.json")).ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .map(|v| v.get("model_revision").and_then(|r| r.as_str()).unwrap_or(super::setup::MODEL_REVISION).to_string());
    let Some(installed) = installed else { return ModelUpdate { installed: None, available: false, name: None, error: None } };
    let manifest = client().and_then(|c| c.get(MODELS_MANIFEST).send().map_err(|e| e.to_string()));
    // No manifest yet, or no Windows entry in it: nothing newer is published.
    let entry = manifest.ok().filter(|r| r.status().is_success())
        .and_then(|r| r.json::<serde_json::Value>().ok())
        .and_then(|v| v.get("models").and_then(|m| m.get(MODEL_KEY)).cloned());
    match entry.as_ref().and_then(|e| e.get("revision")).and_then(|r| r.as_str()) {
        Some(revision) if revision != installed => ModelUpdate {
            installed: Some(installed), available: true,
            name: entry.as_ref().and_then(|e| e.get("name")).and_then(|n| n.as_str()).map(String::from), error: None },
        _ => ModelUpdate { installed: Some(installed), available: false, name: None, error: None },
    }
}

/// A new model ships in a new app release (its pinned download list); update the app first, then this re-downloads
/// only the model files whose checksum changed and restarts the engine.
#[tauri::command(async)]
pub(crate) fn update_model(app: AppHandle, state: tauri::State<'_, super::AppState>) -> Result<(), String> {
    super::setup::install(&app, Some(&["model", "whisper-model"]))?;
    if let Ok(mut engine) = state.engine.lock() { engine.stop(); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_numerically() {
        assert!(is_newer("0.7.10", "0.7.9"));
        assert!(is_newer("1.0", "0.9.9"));
        assert!(!is_newer("0.7.2", "0.7.2"));
        assert!(!is_newer("0.7", "0.7.0"));
    }
}
