use chrono::{Duration, Local};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, fs};

use crate::{chat, ensure_engine, inkling_render, library::{journal_day, load_collection, load_journal, remove_empty_duplicate_days, save_journal, CollectionItem, CollectionKind, JournalEntry, JournalEntryKind}, list_saved_meetings, stream_json, AppState, ChatTurn, Meeting};

#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalActivityMeeting { pub title: String, pub notes: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalActivityChat { pub questions: Vec<String> }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalActivityItem { pub kind: String, pub title: String, pub creator: String, pub notes: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalActivityTrip { pub title: String, pub place: String, pub notes: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalActivity { pub day: String, pub meetings: Vec<JournalActivityMeeting>, pub chats: Vec<JournalActivityChat>, pub items: Vec<JournalActivityItem>, pub trips: Vec<JournalActivityTrip>, pub is_empty: bool, pub headline: String, pub key: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalDaySummary { pub day: String, pub entry: JournalEntry }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalDayData { pub day: String, pub entry: JournalEntry, pub others: Vec<JournalEntry>, pub activity: JournalActivity }

fn day_stamp(value: &str) -> String { value.chars().take(10).collect() }
fn clip(value: &str, max: usize) -> String { let flat = value.replace('\n', " ").split_whitespace().collect::<Vec<_>>().join(" "); flat.chars().take(max).collect() }
fn within(day: &str, start: &str, end: &str) -> bool { let stamp = day_stamp(day); stamp >= day_stamp(start) && stamp <= day_stamp(end) }
fn chat_activity(day: &str) -> Vec<JournalActivityChat> { let mut out = Vec::new(); if let Ok(entries) = fs::read_dir(chat::chats_root()) { for file in entries.flatten() { if file.path().extension().and_then(|v| v.to_str()) != Some("json") { continue; } let Ok(text) = fs::read_to_string(file.path()) else { continue; }; let Ok(thread) = serde_json::from_str::<chat::ChatThread>(&text) else { continue; }; let questions: Vec<String> = thread.messages.iter().filter(|message| message.role == "user" && day_stamp(&message.date) == day).map(|message| clip(&message.text, 140)).filter(|value| !value.is_empty()).take(4).collect(); if !questions.is_empty() { out.push(JournalActivityChat { questions }); } } } out }
fn activity_for_day(day: &str, meetings: &[Meeting]) -> JournalActivity { let meetings: Vec<JournalActivityMeeting> = meetings.iter().filter(|meeting| day_stamp(&meeting.date) == day).map(|meeting| JournalActivityMeeting { title: meeting.title.clone(), notes: clip(&meeting.notes, 500) }).collect(); let chats = chat_activity(day); let items: Vec<JournalActivityItem> = [CollectionKind::Library, CollectionKind::Articles, CollectionKind::Movies].into_iter().flat_map(|kind| load_collection(&kind)).filter(|item| day_stamp(&item.createdAt) == day).map(|item: CollectionItem| JournalActivityItem { kind: item.kind.title().into(), title: item.title, creator: item.creator, notes: clip(&item.notes, 200) }).collect(); let trips: Vec<JournalActivityTrip> = crate::travels::load_trips().into_iter().filter(|trip| day_stamp(&trip.createdAt) == day || within(day, &trip.startDate, &trip.endDate)).map(|trip| JournalActivityTrip { title: trip.title, place: trip.place, notes: clip(&trip.notes, 200) }).collect(); let mut parts = Vec::new(); if !meetings.is_empty() { parts.push(format!("{} meeting{}", meetings.len(), if meetings.len() == 1 { "" } else { "s" })); } if !chats.is_empty() { parts.push(format!("{} chat{}", chats.len(), if chats.len() == 1 { "" } else { "s" })); } if !items.is_empty() { parts.push(format!("{} item{} added", items.len(), if items.len() == 1 { "" } else { "s" })); } if !trips.is_empty() { parts.push(format!("{} trip{}", trips.len(), if trips.len() == 1 { "" } else { "s" })); } let key = format!("{}|m{}|c{}|i{}|t{}", day, meetings.len(), chats.iter().map(|c| c.questions.len()).sum::<usize>(), items.iter().map(|i| i.notes.len()).sum::<usize>(), trips.iter().map(|t| t.notes.len()).sum::<usize>()); JournalActivity { day: day.into(), meetings, chats, items, trips, is_empty: parts.is_empty(), headline: if parts.is_empty() { String::new() } else { format!("From {}", parts.join(", ")) }, key } }
fn prompt(activity: &JournalActivity) -> String { let mut value = format!("Activity on {}:\n", activity.day); for meeting in &activity.meetings { value.push_str(&format!("- Meeting \"{}\": {}\n", meeting.title, meeting.notes)); } for chat in &activity.chats { value.push_str(&format!("- Conversation with your assistant; you asked: {}\n", chat.questions.join(" / "))); } for item in &activity.items { value.push_str(&format!("- Added to Library ({}): {}{}{}\n", item.kind, item.title, if item.creator.is_empty() { String::new() } else { format!(" by {}", item.creator) }, if item.notes.is_empty() { String::new() } else { format!(". Your notes: {}", item.notes) })); } for trip in &activity.trips { value.push_str(&format!("- Trip: {}{}\n", if trip.title.is_empty() { &trip.place } else { &trip.title }, if trip.notes.is_empty() { String::new() } else { format!(". Your notes: {}", trip.notes) })); } value.chars().take(6_000).collect() }
fn system_prompt() -> &'static str { "You write the user's private daily journal from what happened that day. Write 2 to 5 sentences in the second person (\"You met…\", \"You read…\"), warm and plain. Use only the activity given. No headings, no lists, no advice. Chats are conversations with the user's AI assistant: write \"you asked your assistant…\" or \"you talked with your assistant about…\". Never treat a chat's title or the assistant's name as a person." }

#[tauri::command]
pub(crate) fn list_journal_days() -> Vec<JournalDaySummary> { remove_empty_duplicate_days(); let entries = load_journal(); let meetings = list_saved_meetings(); let mut days = BTreeSet::new(); days.insert(Local::now().format("%Y-%m-%d").to_string()); for entry in &entries { if entry.kind == JournalEntryKind::Daily && (!entry.text.is_empty() || !entry.summary.is_empty()) { days.insert(day_stamp(&entry.date)); } } for index in 0..60 { let date = Local::now() - Duration::days(index); let stamp = date.format("%Y-%m-%d").to_string(); if !activity_for_day(&stamp, &meetings).is_empty { days.insert(stamp); } } days.into_iter().rev().map(|day| JournalDaySummary { entry: journal_day(&day, &entries), day }).collect()
}

#[tauri::command]
pub(crate) fn get_journal_day(day: String) -> JournalDayData { let entries = load_journal(); let entry = journal_day(&day, &entries); let others = entries.into_iter().filter(|value| value.kind != JournalEntryKind::Daily && day_stamp(&value.date) == day_stamp(&day)).collect(); JournalDayData { day: day_stamp(&day), entry, others, activity: activity_for_day(&day_stamp(&day), &list_saved_meetings()) } }

#[tauri::command]
pub(crate) fn save_journal_entry(entry: JournalEntry) -> Result<JournalEntry, String> { save_journal(entry) }

#[tauri::command(async)]
pub(crate) async fn rewrite_journal(day: String, force: bool, state: tauri::State<'_, AppState>) -> Result<JournalEntry, String> {
    let normalized_day = day_stamp(&day); let activity = activity_for_day(&normalized_day, &list_saved_meetings()); if activity.is_empty { return Ok(journal_day(&normalized_day, &load_journal())); }
    let current = journal_day(&normalized_day, &load_journal()); if !force && !current.summary.is_empty() { return Ok(current); }
    let _gate = state.model_gate.lock().map_err(|_| "Model gate lock failed".to_string())?; ensure_engine(&state.engine)?; let (port, style) = { let engine = state.engine.lock().map_err(|_| "Engine lock failed".to_string())?; (engine.port.ok_or("The local model is not running")?, engine.style.clone()) }; let user = prompt(&activity);
    let answer = if style.eq_ignore_ascii_case("inkling") { stream_json(port, "/completion", &serde_json::json!({ "prompt": inkling_render(system_prompt(), &[ChatTurn { role: "user".into(), text: user }]), "n_predict": 260, "temperature": 0.2, "seed": 7, "stream": true, "stop": ["<|end_message|>", "<|content_model_end_sampling|>"] }), |_| {})? } else { stream_json(port, "/v1/chat/completions", &serde_json::json!({ "messages": [{ "role": "system", "content": system_prompt() }, { "role": "user", "content": user }], "max_tokens": 260, "temperature": 0.2, "seed": 7, "stream": true, "chat_template_kwargs": { "enable_thinking": false } }), |_| {})? };
    let written = answer.trim().to_string(); if written.is_empty() { return Err("The model returned an empty journal entry.".into()); } let mut entry = current; if force || entry.text.is_empty() || entry.text == entry.summary { entry.text = written.clone(); } entry.summary = written; entry.summaryKey = activity.key; save_journal(entry)
}

#[tauri::command]
pub(crate) fn save_routine_result(name: String, result: String, date: Option<String>) -> Result<JournalEntry, String> { let mut entry = JournalEntry::new(date.unwrap_or_else(|| chrono::Utc::now().to_rfc3339()), JournalEntryKind::Routine); entry.decisionTitle = name; entry.text = result; save_journal(entry) }

#[cfg(test)]
mod tests { use super::*; #[test] fn assistant_is_never_named_as_a_person() { let activity = JournalActivity { day: "2026-11-23".into(), meetings: Vec::new(), chats: vec![JournalActivityChat { questions: vec!["What did I finish?".into()] }], items: Vec::new(), trips: Vec::new(), is_empty: false, headline: "From 1 chat".into(), key: "x".into() }; let text = prompt(&activity); assert!(text.contains("Conversation with your assistant")); assert!(!text.contains("AssistantName")); } }
