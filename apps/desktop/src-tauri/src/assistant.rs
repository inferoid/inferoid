use serde::{Deserialize, Serialize};
use regex::Regex;
use std::fs;
use std::sync::OnceLock;

use super::support_root;

pub const THREAD_ID: &str = "A5510000-0000-4000-8000-000000000001";
pub const EMOJIS: [&str; 8] = ["✨", "🦉", "🌱", "🧭", "🪐", "🦊", "🌊", "🔭"];
pub const QUESTION_COUNT: u32 = 4;
pub const OPENING: &str = "Hey 👋 I just came online on your Windows PC. I'm your private assistant: I can read your meetings, people, books, media, trips and journal, and none of it leaves this computer.\n\nLet's make this yours. First: what would you like to call me?";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct AssistantProfile {
    #[serde(default)] pub assistantName: String,
    #[serde(default)] pub emoji: String,
    #[serde(default)] pub userName: String,
    #[serde(default)] pub callMe: String,
    #[serde(default)] pub aboutUser: String,
    #[serde(default)] pub style: String,
    #[serde(default)] pub useEmoji: Option<bool>,
    #[serde(default)] pub step: u32,
}

impl AssistantProfile {
    pub(crate) fn load() -> Self {
        fs::read_to_string(support_root().join("assistant.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub(crate) fn save(&self) -> Result<(), String> {
        fs::create_dir_all(support_root()).map_err(|e| e.to_string())?;
        let bytes = serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?;
        fs::write(support_root().join("assistant.json"), bytes).map_err(|e| e.to_string())
    }

    pub(crate) fn onboarded(&self) -> bool { self.step >= QUESTION_COUNT }
    pub(crate) fn display_name(&self) -> String { if self.assistantName.is_empty() { "Assistant".into() } else { self.assistantName.clone() } }
    pub(crate) fn display_emoji(&self) -> String { if self.emoji.is_empty() { "✨".into() } else { self.emoji.clone() } }

    pub(crate) fn system_prompt_section(&self) -> String {
        if !self.onboarded() { return String::new(); }
        let mut value = format!("\nYour name is {} {}.", self.display_name(), self.display_emoji());
        if !self.callMe.is_empty() { value.push_str(&format!(" Call the user {}.", self.callMe)); }
        if self.useEmoji.unwrap_or(true) { value.push_str(" Use an emoji now and then where it fits, like a friend texting. If the user asks you to stop, stop."); }
        else { value.push_str(" Never use emojis."); }
        if !self.aboutUser.is_empty() { value.push_str(&format!("\nWhat the user told you about themselves: {}", self.aboutUser)); }
        if !self.style.is_empty() { value.push_str(&format!("\nHow they want you to talk: {}", self.style)); }
        value.push('\n');
        value
    }

    pub(crate) fn about_section(&self) -> String {
        let mut lines = Vec::new();
        if !self.userName.is_empty() { lines.push(format!("Name: {}{}", self.userName, if self.callMe.is_empty() || self.callMe == self.userName { String::new() } else { format!(" (goes by {})", self.callMe) })); }
        if !self.aboutUser.is_empty() { lines.push(format!("In their words: {}", self.aboutUser)); }
        if !self.style.is_empty() { lines.push(format!("How they like answers: {}", self.style)); }
        lines.join("\n")
    }
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct AssistantState { pub profile: AssistantProfile, pub thread_id: String, pub opening: String }

pub(crate) fn state() -> AssistantState { AssistantState { profile: AssistantProfile::load(), thread_id: THREAD_ID.into(), opening: OPENING.into() } }

pub(crate) fn emoji_preference(text: &str) -> Option<bool> {
    // AssistantIntro.emojiPreference on the Mac: "stop using emojis" / "no emojis" -> false; "use emojis again" -> true.
    static OFF: OnceLock<Regex> = OnceLock::new();
    static ON: OnceLock<Regex> = OnceLock::new();
    if OFF.get_or_init(|| Regex::new(r"(?i)\b(stop|no|no more|don'?t|do not|quit|without)\b[^.?!]*\bemojis?\b").unwrap()).is_match(text) { return Some(false); }
    if ON.get_or_init(|| Regex::new(r"(?i)\b(use|bring back|start using)\b[^.?!]*\bemojis?\b").unwrap()).is_match(text) { return Some(true); }
    None
}

pub(crate) fn clean_name(text: &str) -> String {
    let prefixes = ["call you", "you are", "you're", "name you", "your name is", "i'll call you", "i will call you", "let's go with", "how about"];
    let mut value = text.trim().trim_matches(|c: char| " .!?\"'".contains(c)).to_string();
    let lower = value.to_lowercase();
    for prefix in prefixes { if lower.starts_with(&(prefix.to_string() + " ")) { value = value[prefix.len() + 1..].to_string(); break; } }
    let value = value.trim().trim_matches(|c: char| " .!?\"'".contains(c)).to_string();
    if value.is_empty() { return "Assistant".into(); }
    value.split_whitespace().take(3).collect::<Vec<_>>().join(" ")
}

pub(crate) fn call_name(text: &str) -> String {
    // AssistantIntro.callName on the Mac: "I'm Sara Lee, call me Sara" -> "Sara"; "Mehran" -> "Mehran".
    static CALL: OnceLock<Regex> = OnceLock::new();
    static SELF: OnceLock<Regex> = OnceLock::new();
    let patterns = [
        CALL.get_or_init(|| Regex::new(r"(?i)\bcall me\s+(\p{L}[\p{L}'\-]*)").unwrap()),
        SELF.get_or_init(|| Regex::new(r"(?i)\b(?:i am|i'm|im|my name is|name's|it's|this is)\s+(\p{L}[\p{L}'\-]*)").unwrap()),
    ];
    for re in patterns { if let Some(c) = re.captures(text) { return c[1].trim_matches(|ch: char| ch.is_ascii_punctuation()).to_string(); } }
    let first = text.split(|c: char| c == ' ' || c == ',' || c == '.').find(|w| !w.is_empty()).unwrap_or("");
    if first.is_empty() { "there".into() } else { first.into() }
}

pub(crate) fn first_emoji(text: &str) -> Option<String> { EMOJIS.iter().find(|emoji| text.contains(**emoji)).map(|emoji| (*emoji).into()) }

pub(crate) fn answer(raw: &str, profile: &mut AssistantProfile, saved: &[String]) -> String {
    let text = raw.trim();
    match profile.step {
        0 => { profile.assistantName = clean_name(text); let seed: usize = profile.assistantName.chars().map(|c| c as usize).sum(); profile.emoji = EMOJIS[seed % EMOJIS.len()].into(); profile.step = 1; format!("{} it is {} Now you: who are you, and what should I call you?", profile.assistantName, profile.emoji) }
        1 => { profile.userName = text.into(); profile.callMe = call_name(text); profile.step = 2; format!("Good to meet you, {}. Tell me a little about yourself: what you do, who matters most to you, what you're working on. A few lines is plenty.", profile.callMe) }
        2 => { profile.aboutUser = text.into(); profile.step = 3; "Thanks. Last one: how should I talk to you? Short and direct, or more detail? Anything I should never do?".into() }
        3 => { profile.style = text.into(); if emoji_preference(text) == Some(false) { profile.useEmoji = Some(false); } profile.step = QUESTION_COUNT; let mark = if profile.useEmoji.unwrap_or(true) { format!(" {}", profile.emoji) } else { String::new() }; if saved.is_empty() { format!("Got it, {}.{}\n\nYour Brain is empty so far. Drop a book, article or video link into Library, add a trip in Travels, or record a meeting. Then ask me what it all says about you.", profile.callMe, mark) } else { let named = saved.iter().take(2).map(|s| format!("“{}”", s)).collect::<Vec<_>>().join(" and "); let more = if saved.len() > 2 { format!(" and {} more", saved.len() - 2) } else { String::new() }; format!("Got it, {}.{}\n\nI see you've already added {}{}. Ask me about any of them, or ask what they say about you.", profile.callMe, mark, named, more) } }
        _ => String::new(),
    }
}

#[tauri::command]
pub fn assistant_profile() -> AssistantState { state() }

#[tauri::command]
pub fn assistant_action(action: String) -> Result<AssistantState, String> {
    let mut profile = AssistantProfile::load();
    if action == "reset" { profile = AssistantProfile::default(); profile.save()?; }
    if action == "restart" || action == "fresh" { let _ = fs::remove_file(support_root().join("Chats").join(format!("{}.json", THREAD_ID))); }
    Ok(AssistantState { profile, thread_id: THREAD_ID.into(), opening: OPENING.into() })
}

#[tauri::command]
pub fn update_assistant(name: String, emoji: String) -> Result<AssistantState, String> {
    let mut profile = AssistantProfile::load();
    let clean = name.trim();
    if !clean.is_empty() { profile.assistantName = clean.into(); }
    if let Some(picked) = first_emoji(&emoji) { profile.emoji = picked; }
    profile.save()?;
    Ok(AssistantState { profile, thread_id: THREAD_ID.into(), opening: OPENING.into() })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn intro_collects_name_and_user() { let mut p = AssistantProfile::default(); let next = answer("I'll call you Nova", &mut p, &[]); assert_eq!(p.assistantName, "Nova"); assert!(EMOJIS.contains(&p.emoji.as_str())); assert!(next.contains("who are you")); answer("I'm Sara, call me Sara", &mut p, &[]); assert_eq!(p.callMe, "Sara"); }
    #[test] fn emoji_and_fresh_profile_rules_match_mac() { assert_eq!(emoji_preference("please stop using emojis"), Some(false)); assert_eq!(emoji_preference("use emojis again"), Some(true)); let p = AssistantProfile { step: 4, assistantName: "Nova".into(), emoji: "✨".into(), ..Default::default() }; assert!(p.system_prompt_section().contains("Nova")); }

    #[test]
    fn names_and_emoji_match_mac() {
        assert_eq!(call_name("I'm Sara Lee, call me Sara"), "Sara");
        assert_eq!(call_name("I'm Sara Lee"), "Sara");
        assert_eq!(call_name("Mehran"), "Mehran");
        assert_eq!(emoji_preference("please stop using emojis"), Some(false));
        assert_eq!(emoji_preference("you can use emojis again"), Some(true));
        assert_eq!(emoji_preference("short answers please"), None);
    }
}
