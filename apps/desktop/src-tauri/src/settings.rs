use serde::Serialize;
use std::{fs, process::Command};

use super::{support_root, AppState, EngineConfig};

#[derive(Debug, Clone, Serialize)]
pub(crate) struct EngineSettings { pub model_path: String, pub llama_server_path: Option<String>, pub whisper_model_path: Option<String>, pub whisper_path: Option<String>, pub style: String, pub server_args: Vec<String>, pub folder: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct ModelHealth { pub ready: bool, pub last_ok: Option<String>, pub last_error: Option<String> }

#[tauri::command]
pub fn research_preferences() -> super::research::ResearchPreferences { super::research::prefs() }
#[tauri::command]
pub fn save_research_preferences(enabled: bool, pages: usize, searxng_url: String, exa_key: String) -> Result<(), String> { super::research::save_prefs(&super::research::ResearchPreferences { enabled, pages: pages.clamp(1, 10), searxng_url, exa_key }) }
#[tauri::command]
pub fn engine_settings() -> EngineSettings { let config: EngineConfig = fs::read_to_string(support_root().join("engine.json")).ok().and_then(|x| serde_json::from_str(&x).ok()).unwrap_or_default(); EngineSettings { model_path: config.model_path, llama_server_path: config.llama_server_path, whisper_model_path: config.whisper_model_path, whisper_path: config.whisper_path, style: config.style, server_args: config.server_args, folder: support_root().to_string_lossy().into() } }
#[tauri::command]
pub fn open_settings_folder() -> Result<(), String> { Command::new("explorer").arg(support_root()).spawn().map(|_| ()).map_err(|e| e.to_string()) }
#[tauri::command]
pub fn model_health(state: tauri::State<'_, AppState>) -> ModelHealth { let last_ok = state.model_last_ok.lock().ok().and_then(|x| x.clone()); let last_error = state.model_last_error.lock().ok().and_then(|x| x.clone()); let engine_ready = state.engine.lock().ok().and_then(|engine| engine.port).map(super::health_check).unwrap_or(false); let ready = last_error.is_none() && (last_ok.is_some() || engine_ready); ModelHealth { ready, last_ok, last_error } }

