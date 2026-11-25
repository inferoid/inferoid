use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};
use tauri::Emitter;
fn default_file_type() -> String { "text".into() }

use crate::{chat, ensure_engine, inkling_render, list_saved_meetings, stream_json, AppState, ChatTurn};

fn id() -> String { uuid::Uuid::new_v4().to_string() }
fn now() -> String { Utc::now().to_rfc3339() }
fn root() -> PathBuf { crate::support_root().join("Projects") }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectFile { #[serde(default = "id")] pub id: String, pub name: String, #[serde(default)] pub size: i64, #[serde(rename = "type", default = "default_file_type")] pub file_type: String, #[serde(rename = "relativePath", default)] pub relative_path: String, #[serde(default)] pub text: String, #[serde(rename = "includeInBrain", default = "default_true")] pub include_in_brain: bool }
fn default_true() -> bool { true }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project { #[serde(default = "id")] pub id: String, pub name: String, #[serde(default)] pub instructions: String, #[serde(default)] pub files: Vec<ProjectFile>, #[serde(rename = "includeInBrain", default)] pub include_in_brain: bool, #[serde(rename = "createdAt", default = "now")] pub created_at: String, #[serde(rename = "updatedAt", default = "now")] pub updated_at: String, #[serde(rename = "chatIDs", default)] pub chat_ids: Vec<String>, #[serde(rename = "chatID", default, skip_serializing)] pub old_chat_id: Option<String> }
impl Project { fn normalize(mut self) -> Self { if self.chat_ids.is_empty() { if let Some(id) = self.old_chat_id.take() { self.chat_ids.push(id); } } for file in &mut self.files { if file.relative_path.is_empty() { file.relative_path = file.name.clone(); } } self } }

fn load_all() -> Vec<Project> { let mut values = fs::read_dir(root()).ok().into_iter().flatten().filter_map(|entry| entry.ok()).filter_map(|entry| fs::read_to_string(entry.path().join("project.json")).ok()).filter_map(|text| serde_json::from_str::<Project>(&text).ok().map(Project::normalize)).collect::<Vec<_>>(); values.sort_by(|a,b| b.updated_at.cmp(&a.updated_at)); values }
fn save(project: &Project) -> Result<(), String> { let folder = root().join(&project.id); fs::create_dir_all(folder.join("files")).map_err(|e| e.to_string())?; fs::write(folder.join("project.json"),serde_json::to_vec_pretty(project).map_err(|e| e.to_string())?).map_err(|e| e.to_string()) }
fn get(project_id: &str) -> Result<Project, String> { load_all().into_iter().find(|p| p.id == project_id).ok_or_else(|| "The project is no longer available.".into()) }

#[tauri::command]
pub fn projects_list() -> Vec<Project> { load_all() }
#[tauri::command]
pub fn project_create(name: String, instructions: String) -> Result<Project, String> { let clean = name.trim(); if clean.is_empty() { return Err("A project needs a name.".into()) } let project = Project { id:id(),name:clean.into(),instructions,files:vec![],include_in_brain:false,created_at:now(),updated_at:now(),chat_ids:vec![],old_chat_id:None }; save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_update_instructions(project_id: String, instructions: String) -> Result<Project, String> { let mut project = get(&project_id)?; project.instructions = instructions; project.updated_at=now(); save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_set_include(project_id: String, included: bool) -> Result<Project, String> { let mut project = get(&project_id)?; project.include_in_brain=included; project.updated_at=now(); save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_set_file_include(project_id: String, file_id: String, included: bool) -> Result<Project, String> { let mut project=get(&project_id)?; let file=project.files.iter_mut().find(|v| v.id==file_id).ok_or("The file is no longer available.")?; file.include_in_brain=included; project.updated_at=now(); save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_add_file(project_id: String, name: String, size: i64, file_type: String, text: String) -> Result<Project, String> { let mut project=get(&project_id)?; let file_id=id(); let clean=name.trim(); if clean.is_empty() { return Err("A file needs a name.".into()) } let relative=format!("files/{}-{}",file_id,clean); let folder=root().join(&project.id); fs::create_dir_all(folder.join("files")).map_err(|e| e.to_string())?; fs::write(folder.join(&relative),text.as_bytes()).map_err(|e| e.to_string())?; project.files.push(ProjectFile{id:file_id,name:clean.into(),size,file_type,relative_path:relative,text,include_in_brain:true}); project.updated_at=now(); save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_remove_file(project_id: String, file_id: String) -> Result<Project, String> { let mut project=get(&project_id)?; let index=project.files.iter().position(|v| v.id==file_id).ok_or("The file is no longer available.")?; let file=project.files.remove(index); let _=fs::remove_file(root().join(&project.id).join(&file.relative_path)); project.updated_at=now(); save(&project)?; Ok(project) }
#[tauri::command]
pub fn project_delete(project_id: String) -> Result<(), String> { let project=get(&project_id)?; for thread in &project.chat_ids { let _=chat::delete_thread(thread.clone()); } trash::delete(root().join(project.id)).map_err(|e| e.to_string()) }
#[tauri::command]
pub fn project_create_chat(project_id: String) -> Result<String, String> { let mut project=get(&project_id)?; let thread=id(); project.chat_ids.push(thread.clone()); project.updated_at=now(); save(&project)?; Ok(thread) }
#[tauri::command]
pub fn project_delete_chat(project_id: String, thread_id: String) -> Result<(), String> { let mut project=get(&project_id)?; project.chat_ids.retain(|v| v!=&thread_id); project.updated_at=now(); save(&project)?; chat::delete_thread(thread_id) }

fn project_context(project: &Project) -> String { let mut context=String::new(); if !project.instructions.trim().is_empty() { context.push_str("Project instructions:\n"); context.push_str(&project.instructions); context.push('\n'); } for file in project.files.iter().filter(|v| v.include_in_brain) { context.push_str(&format!("\n### {}\n{}\n",file.name,file.text)); } context }
fn model_reply(app:&tauri::AppHandle,state:&tauri::State<'_,AppState>,thread_id:&str,system:String,user:String)->Result<String,String> { let _gate=state.model_gate.lock().map_err(|_|"Model gate lock failed".to_string())?; ensure_engine(&state.engine)?; let (port,style)={let engine=state.engine.lock().map_err(|_|"Engine lock failed".to_string())?;(engine.port.ok_or("The local model is not running")?,engine.style.clone())}; let app=app.clone(); let id=thread_id.to_string(); if style.eq_ignore_ascii_case("inkling") { stream_json(port,"/completion",&serde_json::json!({"prompt":inkling_render(&system,&[ChatTurn{role:"user".into(),text:user}]),"n_predict":600,"temperature":0.2,"seed":7,"stream":true,"stop":["<|end_message|>","<|content_model_end_sampling|>"]}),|piece|{let _=app.emit("chat-delta",serde_json::json!({"threadId":id,"text":piece}));}) } else { stream_json(port,"/v1/chat/completions",&serde_json::json!({"messages":[{"role":"system","content":system},{"role":"user","content":user}],"max_tokens":600,"temperature":0.2,"seed":7,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}),|piece|{let _=app.emit("chat-delta",serde_json::json!({"threadId":id,"text":piece}));}) } }

#[tauri::command(async)]
pub async fn send_project_chat(app: tauri::AppHandle, thread_id:String, project_id:String, question:String, state:tauri::State<'_,AppState>)->Result<chat::ChatResult,String> { let project=get(&project_id)?; let question=question.trim().to_string(); let meetings=list_saved_meetings(); let mut local=project_context(&project); for meeting in meetings.iter().filter(|v|v.include_in_brain).take(4) { if question.to_lowercase().split_whitespace().any(|term| meeting.notes.to_lowercase().contains(term)) { local.push_str(&format!("\n### Meeting {} ({})\n{}\n",meeting.title,meeting.date,meeting.notes)); } } let system=format!("You are a private assistant on the user's computer for a focused project. Nothing leaves this computer. Be direct and brief. Use project instructions and files as context, never invent details. Cite meetings like [Meeting: Title, date].\nYou are in the project \"{}\".\n{}",project.name,project.instructions); let answer=model_reply(&app,&state,&thread_id,system,format!("Local project context:\n{}\n\nUser question: {}\nAnswer first, at most 120 words. Say when the records do not answer it.",local,question))?; let mut thread=chat::get_thread(thread_id.clone()).unwrap_or_default(); thread.id=thread_id.clone(); if thread.title.is_empty(){thread.title=question.chars().take(50).collect();} thread.messages.push(chat::ChatMessage{id:id(),role:"user".into(),text:question.clone(),sources:vec![],action:None,date:now(),prompt:None,sourceHashes:None}); thread.messages.push(chat::ChatMessage{id:id(),role:"assistant".into(),text:answer.clone(),sources:vec![],action:None,date:now(),prompt:None,sourceHashes:None}); thread.updated=now(); fs::create_dir_all(chat::chats_root()).map_err(|e|e.to_string())?; fs::write(chat::chats_root().join(format!("{}.json",thread_id)),serde_json::to_vec_pretty(&thread).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?; Ok(chat::ChatResult{answer,sources:vec![],status:String::new()}) }

#[cfg(test)] mod tests { use super::*; #[test] fn old_project_chat_id_is_migrated(){ let value:Project=serde_json::from_str(r#"{"name":"Old","chatID":"abc"}"#).unwrap(); assert_eq!(value.normalize().chat_ids,vec!["abc"]); } #[test] fn project_file_defaults_to_brain(){ let value:ProjectFile=serde_json::from_str(r#"{"name":"notes.md","text":"hello"}"#).unwrap(); assert!(value.include_in_brain); } }
