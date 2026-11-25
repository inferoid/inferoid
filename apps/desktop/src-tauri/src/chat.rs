use serde::{Deserialize, Serialize};
use std::{collections::{HashMap, HashSet}, fs, hash::{Hash, Hasher}, path::PathBuf};
use chrono::Utc;
use tauri::Emitter;

use super::{assistant, bm25_search, brain_context, ensure_engine, inkling_render, list_saved_meetings, needs_records, stream_json, AppState, ChatTurn, Meeting};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ChatMessage {
    #[serde(default)] pub id: String,
    pub role: String,
    pub text: String,
    #[serde(default)] pub sources: Vec<String>,
    #[serde(default)] pub action: Option<serde_json::Value>,
    #[serde(default)] pub date: String,
    #[serde(default)] pub prompt: Option<String>,
    #[serde(default)] pub sourceHashes: Option<HashMap<String, String>>,
}
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ChatThread {
    pub id: String,
    pub title: String,
    #[serde(default)] pub created: String,
    #[serde(default)] pub updated: String,
    pub messages: Vec<ChatMessage>,
}
#[derive(Debug, Clone, Serialize)]
pub(crate) struct ChatResult { pub answer: String, pub sources: Vec<String>, pub status: String }

pub(crate) fn chats_root() -> PathBuf { super::support_root().join("Chats") }
fn seen_path() -> PathBuf { super::support_root().join("chat-seen.json") }
fn now() -> String { Utc::now().to_rfc3339() }
fn new_id() -> String { uuid::Uuid::new_v4().to_string() }
fn ensure_thread(id: &str) -> ChatThread { ChatThread { id: id.into(), title: "New chat".into(), created: now(), updated: now(), messages: Vec::new() } }
fn load_thread(id: &str) -> Option<ChatThread> { fs::read_to_string(chats_root().join(format!("{}.json", id))).ok().and_then(|x| serde_json::from_str(&x).ok()) }
fn save_thread(thread: &ChatThread) -> Result<(), String> { if thread.messages.is_empty() { return Ok(()); } fs::create_dir_all(chats_root()).map_err(|e| e.to_string())?; fs::write(chats_root().join(format!("{}.json", thread.id)), serde_json::to_vec_pretty(thread).map_err(|e| e.to_string())?).map_err(|e| e.to_string()) }
fn assistant_thread() -> ChatThread { let mut thread = load_thread(assistant::THREAD_ID).unwrap_or_else(|| ensure_thread(assistant::THREAD_ID)); if thread.messages.is_empty() { thread.title = if assistant::AssistantProfile::load().onboarded() { assistant::AssistantProfile::load().display_name() } else { "Assistant".into() }; thread.messages.push(ChatMessage { id: new_id(), role: "assistant".into(), text: assistant::OPENING.into(), sources: Vec::new(), action: None, date: now(), prompt: None, sourceHashes: None }); let _ = save_thread(&thread); } thread }
fn all_threads() -> Vec<ChatThread> { let mut out = Vec::new(); if let Ok(entries) = fs::read_dir(chats_root()) { for entry in entries.flatten() { if entry.path().extension().and_then(|x| x.to_str()) == Some("json") { let entry_path = entry.path(); let id = entry_path.file_stem().and_then(|x| x.to_str()).unwrap_or(""); if super::brain_features::is_person_chat_id(id) { continue; } if let Ok(value) = fs::read_to_string(entry.path()).map_err(|_| ()) .and_then(|x| serde_json::from_str::<ChatThread>(&x).map_err(|_| ())) { if !value.messages.is_empty() { out.push(value); } } } } } if !out.iter().any(|x| x.id == assistant::THREAD_ID) { out.push(assistant_thread()); } out.sort_by(|a, b| b.updated.cmp(&a.updated)); out }
fn save_seen(values: &HashMap<String, usize>) { let _ = fs::create_dir_all(super::support_root()); if let Ok(bytes) = serde_json::to_vec_pretty(values) { let _ = fs::write(seen_path(), bytes); } }
fn load_seen() -> HashMap<String, usize> { fs::read_to_string(seen_path()).ok().and_then(|x| serde_json::from_str(&x).ok()).unwrap_or_default() }

#[tauri::command]
pub fn list_threads() -> Vec<ChatThread> { all_threads() }
#[tauri::command]
pub fn get_thread(id: String) -> Option<ChatThread> { if id == assistant::THREAD_ID { Some(assistant_thread()) } else { load_thread(&id) } }
#[tauri::command]
pub fn create_thread(id: Option<String>) -> ChatThread { let value = ensure_thread(&id.unwrap_or_else(new_id)); value }
#[tauri::command]
pub fn rename_thread(id: String, title: String) -> Result<(), String> { let mut thread = load_thread(&id).ok_or("Chat not found")?; let title = title.trim(); if title.is_empty() { return Err("Chat title cannot be empty".into()); } thread.title = title.into(); thread.updated = now(); save_thread(&thread) }
#[tauri::command]
pub fn delete_thread(id: String) -> Result<(), String> { if id == assistant::THREAD_ID { let _ = assistant::assistant_action("restart".into())?; let _ = fs::remove_file(chats_root().join(format!("{}.json", id))); let _ = assistant_thread(); return Ok(()); } fs::remove_file(chats_root().join(format!("{}.json", id))).map_err(|e| e.to_string()) }
#[tauri::command]
pub fn mark_seen(id: String, count: usize) { let mut values = load_seen(); values.insert(id, count); save_seen(&values); }

fn fingerprint(value: &str) -> String { let mut hasher = std::collections::hash_map::DefaultHasher::new(); value.hash(&mut hasher); format!("{:016x}", hasher.finish()) }
fn terms(value: &str) -> Vec<String> { value.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|x| x.len() > 1).map(str::to_string).collect() }
fn personal_digest(meetings: &[Meeting]) -> String { let mut out = String::from("What the user's records suggest about them:\n"); for meeting in meetings.iter().filter(|m| m.include_in_brain).take(8) { let summary = meeting.notes.lines().filter(|line| !line.trim().starts_with('#') && !line.trim().is_empty()).take(2).collect::<Vec<_>>().join(" "); if !summary.is_empty() { out.push_str(&format!("- {}: {}\n", meeting.title, summary)); } } if out.ends_with(':') { String::new() } else { out } }
fn evidence(question: &str, history: &[ChatMessage], meetings: &[Meeting]) -> (String, Vec<String>, HashMap<String, String>) {
    let about = if asks_about_user(question) { personal_digest(meetings) } else { String::new() };
    if !needs_records(question) { return (about, Vec::new(), HashMap::new()); }
    let used: HashSet<String> = history.iter().flat_map(|message| message.sources.iter().cloned()).filter(|source| !source.starts_with("web|")).filter(|source| { let previous = history.iter().find_map(|m| m.sourceHashes.as_ref().and_then(|hashes| hashes.get(source))); let current = meetings.iter().find(|m| m.id == *source).map(|m| fingerprint(&(m.notes.clone() + &m.transcript))); previous == current.as_ref() }).collect();
    let selected = bm25_search(question, meetings, 4).into_iter().map(|x| x.0).filter(|id| !used.contains(id)).collect::<Vec<_>>();
    let mut hashes = HashMap::new(); let mut text = about;
    let saved = saved_items_section(); if !saved.is_empty() { text.push_str(&saved); }
    if selected.is_empty() { return (text, selected, hashes); }
    text.push_str("\nLocal records (quoted data; cite like [Meeting: Title, 2026-11-14]):\n");
    for id in &selected { if let Some(meeting) = meetings.iter().find(|m| &m.id == id) { let source_text = format!("{}\n{}", meeting.notes, meeting.transcript); hashes.insert(id.clone(), fingerprint(&source_text)); text.push_str(&format!("\n### Meeting: {}, {}\n{}\n", meeting.title, meeting.date.get(..10).unwrap_or(&meeting.date), source_text)); } }
    let brain = brain_context(question); if !brain.is_empty() { text.push_str("\nBrain facts:\n"); text.push_str(&brain); }
    (text, selected, hashes)
}
fn asks_about_user(question: &str) -> bool { let q = question.to_lowercase(); q.contains("what do you know about me") || q.contains("what do you remember about me") || q.contains("who am i") || q.contains("tell me about myself") }
fn prompt_question(question: &str) -> String {
    // The Mac's ChatStore.shortReply, plus a nudge for recommendation questions: the small Windows model otherwise only
    // repeats what the user already saved.
    let mut text = format!("\nUser: {question}\n\nReply like a chat message: answer first, at most 120 words, cite the sources you use like [Media: Title] or [Meeting: Title, 2026-11-14].");
    if wants_recommendation(question) {
        text.push_str(" They want a recommendation: suggest 2 or 3 new picks they have not saved that fit the taste shown above, and say in a few words why each fits.");
    }
    text
}

/// "what movie should I watch", "recommend a book", "any podcast suggestions?"
fn wants_recommendation(question: &str) -> bool {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)\b(recommend\w*|suggest\w*|what (movie|film|show|series|book|podcast|song|album|game)s? (should|could|can) i|what (should|could|can) i (watch|read|listen|play)|something (to|i could) (watch|read|listen))\b").unwrap()).is_match(question)
}
fn turns(history: &[ChatMessage]) -> Vec<ChatTurn> { history.iter().filter_map(|m| { let text = m.prompt.clone().unwrap_or_else(|| m.text.clone()); if text.trim().is_empty() || text == "Thinking…" { return None; } Some(ChatTurn { role: if m.role == "assistant" { "assistant".into() } else { "user".into() }, text }) }).collect() }
fn model_reply(app: &tauri::AppHandle, state: &tauri::State<'_, AppState>, thread_id: &str, system: &str, turns: &[ChatTurn]) -> Result<String, String> {
    let _gate = state.model_gate.lock().map_err(|_| "Model gate lock failed".to_string())?; ensure_engine(&state.engine)?; let (port, style) = { let engine = state.engine.lock().map_err(|_| "Engine lock failed".to_string())?; (engine.port.ok_or("The local model is not running")?, engine.style.clone()) };
    let app = app.clone(); let id = thread_id.to_string(); let answer = if style.eq_ignore_ascii_case("inkling") { stream_json(port, "/completion", &serde_json::json!({"prompt": inkling_render(system, turns), "n_predict": 500, "temperature": 0.2, "seed": 7, "stream": true, "stop": ["<|end_message|>", "<|content_model_end_sampling|>"]}), |piece| { let _ = app.emit("chat-delta", serde_json::json!({"threadId": id, "text": piece})); })? } else { stream_json(port, "/v1/chat/completions", &serde_json::json!({"messages": turns.iter().map(|turn| serde_json::json!({"role": turn.role, "content": turn.text})).collect::<Vec<_>>(), "max_tokens": 500, "temperature": 0.2, "seed": 7, "stream": true, "cache_prompt": true, "chat_template_kwargs": {"enable_thinking": false}}), |piece| { let _ = app.emit("chat-delta", serde_json::json!({"threadId": id, "text": piece})); })? }; Ok(answer)
}

#[tauri::command(async)]
pub fn send_thread_message(app: tauri::AppHandle, thread_id: String, question: String, state: tauri::State<'_, AppState>) -> Result<ChatResult, String> {
    let question = question.trim().to_string(); if question.is_empty() { return Err("Question is empty".into()); }
    let mut thread = if thread_id == assistant::THREAD_ID { assistant_thread() } else { load_thread(&thread_id).unwrap_or_else(|| ensure_thread(&thread_id)) };
    let profile = assistant::AssistantProfile::load();
    if thread_id == assistant::THREAD_ID && !profile.onboarded() { let mut profile = profile.clone(); let reply = assistant::answer(&question, &mut profile, &list_saved_meetings().iter().map(|m| m.title.clone()).collect::<Vec<_>>()); profile.save()?; thread.messages.push(ChatMessage { id: new_id(), role: "user".into(), text: question.clone(), sources: Vec::new(), action: None, date: now(), prompt: None, sourceHashes: None }); thread.messages.push(ChatMessage { id: new_id(), role: "assistant".into(), text: reply.clone(), sources: Vec::new(), action: None, date: now(), prompt: None, sourceHashes: None }); thread.title = profile.display_name(); thread.updated = now(); save_thread(&thread)?; return Ok(ChatResult { answer: reply, sources: Vec::new(), status: "".into() }); }
    if let Some(value) = assistant::emoji_preference(&question) { let mut profile = profile.clone(); profile.useEmoji = Some(value); profile.save()?; }
    if !needs_records(&question) { let answer = "Hello — I’m Inferoid, your private assistant.".to_string(); append_turn(&mut thread, &question, &answer, Vec::new(), None); save_thread(&thread)?; return Ok(ChatResult { answer, sources: Vec::new(), status: "".into() }); }
    let meetings = list_saved_meetings(); let history = thread.messages.clone(); let (local_text, sources, hashes) = evidence(&question, &history, &meetings); let mut system = SYSTEM_PROMPT.to_string(); system.push_str(&profile.system_prompt_section()); if asks_about_user(&question) { let about = profile.about_section(); if !about.is_empty() { system.push_str("\nUser profile:\n"); system.push_str(&about); } }
    let turn_prompt = local_text + &prompt_question(&question); let mut model_turns = turns(&history); model_turns.push(ChatTurn { role: "user".into(), text: turn_prompt.clone() }); let answer = match model_reply(&app, &state, &thread_id, &system, &model_turns) { Ok(value) => value, Err(error) => { *state.model_last_error.lock().map_err(|_| "Model health lock failed".to_string())? = Some(error.clone()); return Err(error); } };
    *state.model_last_ok.lock().map_err(|_| "Model health lock failed".to_string())? = Some(now()); *state.model_last_error.lock().map_err(|_| "Model health lock failed".to_string())? = None;
    let mut final_answer = answer.clone(); let mut final_sources = sources.clone(); let mut status = String::new();
    let query = if let Some(query) = super::research::search_request(&answer) { Some(query) } else if super::research::wants_world_facts(&question) && (super::research::declined(&answer) || super::research::cites_web(&answer)) { Some(super::research::enrich(&super::research::query(&question), &question, &super::library::library_pairs())) } else { None };
    if let Some(query) = query.filter(|x| !x.is_empty()) { status = "Good question, let me check online…".into(); let _ = app.emit("chat-status", serde_json::json!({"threadId": thread_id, "text": "Good question, let me check online…"})); let pages = super::research::search_sync(&query, super::research::prefs().pages, &[]); if !pages.is_empty() { let web_text = super::research::evidence_text(&pages, &query); final_sources = pages.iter().map(|p| p.source_id()).collect(); let mut web_turns = turns(&history); web_turns.push(ChatTurn { role: "user".into(), text: format!("{}\n\n{}\nAnswer the user's question in one short paragraph, citing pages inline as [Web: page title].", turn_prompt, web_text) }); final_answer = model_reply(&app, &state, &thread_id, &system, &web_turns)?; super::research::log(serde_json::json!({"question": question, "query": query, "engine": pages.first().map(|x| x.engine.clone()).unwrap_or_default(), "pages": pages.iter().map(|x| serde_json::json!({"title":x.title,"url":x.url,"chars":x.text.len()})).collect::<Vec<_>>() })); } }
    append_turn(&mut thread, &question, &final_answer, final_sources.clone(), Some(hashes)); save_thread(&thread)?; Ok(ChatResult { answer: final_answer, sources: final_sources, status })
}
fn append_turn(thread: &mut ChatThread, question: &str, answer: &str, sources: Vec<String>, hashes: Option<HashMap<String, String>>) { if thread.messages.is_empty() { thread.title = question.chars().take(50).collect(); } thread.messages.push(ChatMessage { id: new_id(), role: "user".into(), text: question.into(), sources: Vec::new(), action: None, date: now(), prompt: Some(question.into()), sourceHashes: None }); thread.messages.push(ChatMessage { id: new_id(), role: "assistant".into(), text: answer.into(), sources, action: None, date: now(), prompt: None, sourceHashes: hashes }); thread.updated = now(); }

pub(crate) fn unread(id: &str, thread: &ChatThread) -> usize { let seen = load_seen().get(id).copied().unwrap_or(0).min(thread.messages.len()); thread.messages.iter().skip(seen).filter(|m| m.role == "assistant" && !m.text.is_empty()).count() }

#[cfg(test)]
mod tests { use super::*; #[test] fn profile_questions_are_detected() { assert!(asks_about_user("What do you know about me so far?")); assert!(asks_about_user("Who am I?")); assert!(!asks_about_user("What happened with the budget?")); } #[test] fn thread_title_is_first_question() { let mut thread = ensure_thread("x"); append_turn(&mut thread, "What happened?", "Nothing", Vec::new(), None); assert_eq!(thread.title, "What happened?"); } }


/// Same rules as the Mac's ChatStore.systemPrompt: records-grounded answers, but advice and recommendations come from
/// what the assistant knows about the user and the world.
const SYSTEM_PROMPT: &str = "You are a private assistant on the user's computer for notes and questions about their own records. Nothing they type leaves it.
Be direct, helpful and brief. Use local excerpts only when they answer the user's question. Cite a source like [Meeting: Title, 2026-11-14], [Media: Title] or [Trip: Place].
Never invent record details. When the user asks what happened in their life, who said what, or for a name, date or number from their records, and the excerpts do not contain it, say it is not in their records instead of guessing.
When they ask for advice, ideas, recommendations or an opinion, answer directly from what you know about them and the world. Never add notes like \"this is a recommendation, not a record lookup\".
When they ask what to watch, read, listen to, buy, try or do next, treat their saved items and notes as signals of their taste and suggest new picks that fit it, naming why. Only point back to something they already saved when they ask to revisit it.";

/// What the user saved (Library, Media, Articles, Trips), included in Brain, as short cited lines: the taste signals
/// recommendations need. Mirrors the item lines the Mac adds for "what do you know about me".
fn saved_items_section() -> String {
    fn clip(text: &str, limit: usize) -> String {
        let flat = text.replace('\n', " ");
        let flat = flat.trim();
        if flat.chars().count() > limit { format!("{}…", flat.chars().take(limit).collect::<String>()) } else { flat.to_string() }
    }
    use super::library::{load_collection, CollectionKind};
    let mut out = String::new();
    for (kind, label, heading) in [(CollectionKind::Library, "Library", "Books they read"), (CollectionKind::Articles, "Article", "Articles they saved"),
                                   (CollectionKind::Movies, "Media", "Movies, shows and videos they watched")] {
        let items: Vec<_> = load_collection(&kind).into_iter().filter(|i| i.include_in_brain && !i.title.trim().is_empty()).take(15).collect();
        if !items.is_empty() { out.push_str(&format!("{heading}:\n")); }
        for item in items {
            let mut line = format!("- [{label}: {}]", item.title.trim());
            if !item.creator.trim().is_empty() { line.push_str(&format!(" by {}", item.creator.trim())); }
            if !item.notes.trim().is_empty() { line.push_str(&format!(". Their notes: {}", clip(&item.notes, 240))); }
            out.push_str(&line); out.push('\n');
        }
    }
    let trips: Vec<_> = super::travels::load_trips().into_iter().filter(|t| t.include_in_brain).take(10).collect();
    if !trips.is_empty() { out.push_str("Trips they took:\n"); }
    for trip in trips {
        let name = if trip.title.trim().is_empty() { trip.place.clone() } else { trip.title.clone() };
        let mut line = format!("- [Trip: {}, {}]", name.trim(), trip.startDate.get(..10).unwrap_or(&trip.startDate));
        if !trip.notes.trim().is_empty() { line.push_str(&format!(". Their notes: {}", clip(&trip.notes, 240))); }
        out.push_str(&line); out.push('\n');
    }
    if out.is_empty() { out } else { format!("\nWhat the user read, watched and did (their taste; cite like [Media: Title]):\n{out}") }

}

#[cfg(test)]
mod recommend_tests {
    use super::*;
    #[test]
    fn recommendation_questions() {
        assert!(wants_recommendation("Based on the movies I watched, what movie should I watch today?"));
        assert!(wants_recommendation("Can you recommend a book?"));
        assert!(!wants_recommendation("What did David say about the budget?"));
    }
}
