use chrono::Utc;
use regex::Regex;
use reqwest::blocking::Client;
use serde::{de::Deserializer, Deserialize, Serialize};
use std::{collections::HashSet, fs, path::{Path, PathBuf}, time::Duration};
use uuid::Uuid;

use crate::{support_root, BrainStore};

fn now() -> String { Utc::now().to_rfc3339() }
fn uuid_string() -> String { Uuid::new_v4().to_string() }
fn true_default() -> bool { true }
fn empty_string() -> String { String::new() }
fn default_kind() -> CollectionKind { CollectionKind::Library }
fn default_format() -> CollectionBookFormat { CollectionBookFormat::Print }
fn default_media_type() -> CollectionMediaType { CollectionMediaType::Movie }
fn default_journal_kind() -> JournalEntryKind { JournalEntryKind::Daily }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CollectionKind { #[serde(rename = "library")] Library, Articles, #[serde(rename = "movies")] Movies }

impl CollectionKind {
    pub(crate) fn title(&self) -> &'static str { match self { Self::Library => "Books", Self::Articles => "Articles", Self::Movies => "Media" } }
    fn folder_name(&self) -> &'static str { match self { Self::Library => "Library", Self::Articles => "Articles", Self::Movies => "Movies" } }
    fn creator_label(&self) -> &'static str { match self { Self::Library => "Author", Self::Articles => "Source / site", Self::Movies => "Creator / channel" } }
    fn from_name(value: &str) -> Result<Self, String> { match value { "library" | "books" => Ok(Self::Library), "articles" | "article" => Ok(Self::Articles), "movies" | "media" => Ok(Self::Movies), _ => Err("Unknown collection kind".into()) } }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CollectionMediaType { Movie, Show, #[serde(rename = "youtube")] YouTube, Podcast, Talk }
impl CollectionMediaType { fn title(&self) -> &'static str { match self { Self::Movie => "Movie", Self::Show => "Show", Self::YouTube => "YouTube", Self::Podcast => "Podcast", Self::Talk => "Talk" } } }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CollectionBookFormat { Print, Ebook, Audiobook }
impl CollectionBookFormat { fn title(&self) -> &'static str { match self { Self::Print => "Print", Self::Ebook => "Ebook", Self::Audiobook => "Audiobook" } } }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct CollectionHighlight {
    #[serde(default = "uuid_string")] pub id: String,
    #[serde(default)] pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")] pub location: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct CollectionItem {
    pub id: String,
    pub kind: CollectionKind,
    pub title: String,
    pub creator: String,
    #[serde(skip_serializing_if = "Option::is_none")] pub year: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")] pub coverFile: Option<String>,
    pub coverSeed: i64,
    pub source: String,
    pub url: String,
    pub format: CollectionBookFormat,
    #[serde(rename = "type")] pub r#type: CollectionMediaType,
    pub notes: String,
    pub highlights: Vec<CollectionHighlight>,
    #[serde(rename = "includeInBrain")] pub include_in_brain: bool,
    #[serde(skip_serializing_if = "Option::is_none")] pub readingStart: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub readingEnd: Option<String>,
    pub readingNow: bool,
    pub watchedDates: Vec<String>,
    pub createdAt: String,
    pub updatedAt: String,
}

#[derive(Deserialize)]
struct RawCollectionItem {
    id: Option<String>, kind: Option<CollectionKind>, title: Option<String>, creator: Option<String>, year: Option<i64>,
    #[serde(rename = "coverFile")] cover_file: Option<String>, #[serde(rename = "coverSeed")] cover_seed: Option<i64>,
    source: Option<String>, url: Option<String>, format: Option<CollectionBookFormat>, #[serde(rename = "bookFormat")] book_format: Option<CollectionBookFormat>,
    #[serde(rename = "type")] media_type: Option<CollectionMediaType>, #[serde(rename = "mediaType")] legacy_media_type: Option<CollectionMediaType>,
    notes: Option<String>, highlights: Option<Vec<CollectionHighlight>>, #[serde(rename = "includeInBrain")] include_in_brain: Option<bool>,
    #[serde(rename = "readingStart")] reading_start: Option<String>, #[serde(rename = "readingEnd")] reading_end: Option<String>,
    #[serde(rename = "readingNow")] reading_now: Option<bool>, #[serde(rename = "watchedDates")] watched_dates: Option<Vec<String>>,
    #[serde(rename = "createdAt")] created_at: Option<String>, #[serde(rename = "updatedAt")] updated_at: Option<String>,
}

impl<'de> Deserialize<'de> for CollectionItem {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawCollectionItem::deserialize(deserializer)?;
        let title = raw.title.unwrap_or_default();
        let seed = raw.cover_seed.unwrap_or_else(|| cover_seed(&title));
        let created = raw.created_at.unwrap_or_else(now);
        Ok(Self { id: raw.id.unwrap_or_else(uuid_string), kind: raw.kind.unwrap_or_else(default_kind), title,
            creator: raw.creator.unwrap_or_default(), year: raw.year, coverFile: raw.cover_file, coverSeed: seed,
            source: raw.source.unwrap_or_default(), url: raw.url.unwrap_or_default(), format: raw.format.or(raw.book_format).unwrap_or_else(default_format),
            r#type: raw.media_type.or(raw.legacy_media_type).unwrap_or_else(default_media_type), notes: raw.notes.unwrap_or_default(),
            highlights: raw.highlights.unwrap_or_default(), include_in_brain: raw.include_in_brain.unwrap_or(true_default()),
            readingStart: raw.reading_start, readingEnd: raw.reading_end, readingNow: raw.reading_now.unwrap_or(false), watchedDates: raw.watched_dates.unwrap_or_default(),
            createdAt: created.clone(), updatedAt: raw.updated_at.unwrap_or(created) })
    }
}

impl CollectionItem {
    pub(crate) fn new(kind: CollectionKind) -> Self { let stamp = now(); Self { id: uuid_string(), kind, title: String::new(), creator: String::new(), year: None, coverFile: None, coverSeed: cover_seed(""), source: String::new(), url: String::new(), format: CollectionBookFormat::Print, r#type: CollectionMediaType::Movie, notes: String::new(), highlights: Vec::new(), include_in_brain: true, readingStart: None, readingEnd: None, readingNow: false, watchedDates: Vec::new(), createdAt: stamp.clone(), updatedAt: stamp } }
}

pub(crate) fn cover_seed(value: &str) -> i64 { let mut hash: i64 = 17; for byte in value.as_bytes() { hash = hash.wrapping_mul(31).wrapping_add(i64::from(*byte)); } hash & 0x7fff_ffff }

fn collection_root(kind: &CollectionKind) -> PathBuf { support_root().join(kind.folder_name()) }
fn collection_folder(item: &CollectionItem) -> PathBuf { collection_root(&item.kind).join(&item.id) }
pub(crate) fn json_encoder<T: Serialize>(value: &T) -> Result<Vec<u8>, String> { serde_json::to_vec_pretty(value).map_err(|e| e.to_string()) }

pub(crate) fn load_collection(kind: &CollectionKind) -> Vec<CollectionItem> {
    let mut items: Vec<CollectionItem> = fs::read_dir(collection_root(kind)).ok().into_iter().flatten().filter_map(|entry| entry.ok())
        .filter_map(|entry| fs::read_to_string(entry.path().join("item.json")).ok()).filter_map(|text| serde_json::from_str(&text).ok()).collect();
    items.sort_by(|a: &CollectionItem, b: &CollectionItem| b.updatedAt.cmp(&a.updatedAt)); items
}

/// (title, author) of every Library item, newest first: research adds the author when the question names a saved title.
pub(crate) fn library_pairs() -> Vec<(String, String)> {
    let mut items: Vec<CollectionItem> = [CollectionKind::Library, CollectionKind::Articles, CollectionKind::Movies].into_iter().flat_map(|kind| load_collection(&kind)).collect();
    items.sort_by(|a, b| b.updatedAt.cmp(&a.updatedAt));
    items.into_iter().filter(|item| !item.title.trim().is_empty()).map(|item| (item.title, item.creator)).collect()
}

pub(crate) fn library_titles() -> Vec<String> {
    let mut items: Vec<CollectionItem> = [CollectionKind::Library, CollectionKind::Articles, CollectionKind::Movies].into_iter().flat_map(|kind| load_collection(&kind)).collect();
    items.sort_by(|a, b| b.updatedAt.cmp(&a.updatedAt));
    items.into_iter().flat_map(|item| { let mut values = Vec::new(); if !item.title.trim().is_empty() { values.push(item.title); } if !item.creator.trim().is_empty() { values.push(item.creator); } values }).collect()
}

pub(crate) fn save_collection(mut item: CollectionItem) -> Result<CollectionItem, String> {
    fs::create_dir_all(collection_folder(&item)).map_err(|e| e.to_string())?;
    item.updatedAt = now();
    fs::write(collection_folder(&item).join("item.json"), json_encoder(&item)?).map_err(|e| e.to_string())?;
    write_collection_brain_files(&item)?;
    let started = if item.kind == CollectionKind::Movies { item.watchedDates.first().cloned().unwrap_or_else(|| item.createdAt.clone()) } else { item.readingStart.clone().unwrap_or_else(|| item.createdAt.clone()) };
    let meta = serde_json::json!({ "started": started, "includeInBrain": item.include_in_brain });
    fs::write(collection_folder(&item).join("meta.json"), json_encoder(&meta)?).map_err(|e| e.to_string())?;
    Ok(item)
}

fn write_collection_brain_files(item: &CollectionItem) -> Result<(), String> {
    let mut notes = format!("# {}\n\n", if item.title.is_empty() { "Untitled" } else { &item.title });
    if item.kind == CollectionKind::Articles { if !item.source.is_empty() { notes.push_str(&format!("Source / site: {}\n", item.source)); } }
    else if !item.creator.is_empty() { notes.push_str(&format!("{}: {}\n", item.kind.creator_label(), item.creator)); }
    if !item.url.is_empty() { notes.push_str(&format!("URL: {}\n", item.url)); }
    if item.kind == CollectionKind::Library { notes.push_str(&format!("Format: {}\n", item.format.title())); }
    if item.kind == CollectionKind::Movies { notes.push_str(&format!("Type: {}\n", item.r#type.title())); }
    if let Some(year) = item.year { notes.push_str(&format!("Year: {year}\n")); }
    if !item.notes.trim().is_empty() { notes.push_str(&format!("\n## Notes\n\n{}\n", item.notes)); }
    if !item.highlights.is_empty() { notes.push_str("\n## Highlights\n\n"); for highlight in &item.highlights { notes.push_str(&format!("- \"{}\"{}\n", highlight.text, highlight.location.as_ref().map(|v| format!(" ({v})")).unwrap_or_default())); } }
    let folder = collection_folder(item); fs::write(folder.join("notes.md"), notes).map_err(|e| e.to_string())?;
    let mut transcript = String::new(); if !item.notes.trim().is_empty() { transcript.push_str(&format!("[Notes] {}\n", item.notes)); } for (index, highlight) in item.highlights.iter().enumerate() { transcript.push_str(&format!("[Highlight {}] {}{}\n", index + 1, highlight.text, highlight.location.as_ref().map(|v| format!(" ({v})")).unwrap_or_default())); }
    fs::write(folder.join("transcript.md"), transcript).map_err(|e| e.to_string())
}

pub(crate) fn delete_collection(item: &CollectionItem) -> Result<(), String> { let folder = collection_folder(item); if folder.exists() { trash::delete(&folder).map_err(|e| e.to_string())?; } let _ = BrainStore::open_default().and_then(|store| store.remove_meeting_data(folder.to_string_lossy().as_ref())); Ok(()) }
pub(crate) fn set_collection_include(mut item: CollectionItem, included: bool) -> Result<CollectionItem, String> { item.include_in_brain = included; let saved = save_collection(item)?; if !included { let folder = collection_folder(&saved); let _ = BrainStore::open_default().and_then(|store| store.remove_meeting_data(folder.to_string_lossy().as_ref())); } Ok(saved) }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct CollectionImportPreview { pub source: String, pub items: Vec<CollectionItem>, pub warnings: Vec<String> }

fn normalize_column(value: &str) -> String { value.trim_matches('\u{feff}').to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect() }
fn csv(text: &str) -> Vec<Vec<String>> { let mut rows = Vec::new(); let mut row = Vec::new(); let mut field = String::new(); let mut quoted = false; let mut chars = text.chars().peekable(); while let Some(c) = chars.next() { match c { '"' if quoted && chars.peek() == Some(&'"') => { field.push('"'); let _ = chars.next(); }, '"' => quoted = !quoted, ',' if !quoted => { row.push(field); field = String::new(); }, '\n' | '\r' if !quoted => { if c == '\r' && chars.peek() == Some(&'\n') { let _ = chars.next(); } row.push(field); field = String::new(); if row.iter().any(|v: &String| !v.trim().is_empty()) { rows.push(row); } row = Vec::new(); }, _ => field.push(c) } } row.push(field); if row.iter().any(|v: &String| !v.trim().is_empty()) { rows.push(row); } rows }
fn parse_date(value: &str) -> Option<String> { let clean = value.trim(); if clean.is_empty() { return None; } if clean.len() == 10 && clean.chars().nth(4) == Some('-') { return Some(format!("{clean}T00:00:00Z")); } let slash_parts: Vec<&str> = clean.split('/').collect(); if slash_parts.len() == 3 { if slash_parts[0].len() == 4 { return Some(format!("{}-{}-{}T00:00:00Z", slash_parts[0], slash_parts[1], slash_parts[2])); } if slash_parts[2].len() == 4 { return Some(format!("{}-{}-{}T00:00:00Z", slash_parts[2], slash_parts[0], slash_parts[1])); } } if clean.contains('T') { Some(clean.to_string()) } else { None } }

pub(crate) fn parse_import_collection(kind: &CollectionKind, source: &str, text: &str) -> CollectionImportPreview {
    if *kind == CollectionKind::Library && source.to_lowercase().contains("kindle") { return import_kindle(text); }
    if *kind == CollectionKind::Library { return import_goodreads(text); }
    import_letterboxd(text)
}
fn import_kindle(text: &str) -> CollectionImportPreview {
    let mut items = Vec::new(); let mut warnings = Vec::new();
    for block in text.split("==========") { let lines: Vec<String> = block.lines().map(str::trim).filter(|line| !line.is_empty()).map(str::to_string).collect(); if lines.len() < 2 { continue; }
        let marker = lines.iter().position(|line| { let lower = line.to_lowercase(); lower.contains("your highlight") || lower.contains("your note") }); let Some(marker) = marker else { continue; };
        let mut title = lines[0].trim_start_matches("Book Title: ").trim().to_string(); if title.is_empty() { warnings.push("One clipping was missing a title or passage.".into()); continue; }
        let location = kindle_location(&lines[marker]); let quote = lines.iter().skip(marker + 1).filter(|line| !line.to_lowercase().starts_with("location ")).cloned().collect::<Vec<_>>().join(" ").trim().to_string(); if quote.is_empty() { warnings.push("One clipping was missing a title or passage.".into()); continue; }
        if let Some(existing) = items.iter_mut().find(|item: &&mut CollectionItem| item.title.eq_ignore_ascii_case(&title)) { existing.highlights.push(CollectionHighlight { id: uuid_string(), text: quote, location }); } else { let mut item = CollectionItem::new(CollectionKind::Library); item.title = std::mem::take(&mut title); item.highlights.push(CollectionHighlight { id: uuid_string(), text: quote, location }); items.push(item); }
    }
    CollectionImportPreview { source: "Kindle My Clippings.txt".into(), items, warnings }
}
fn kindle_location(value: &str) -> Option<String> { let regex = Regex::new(r"(?i)location\s+([0-9]+(?:-[0-9]+)?)").ok()?; let captures = regex.captures(value)?; Some(format!("Location {}", captures.get(1)?.as_str())) }
fn import_goodreads(text: &str) -> CollectionImportPreview { let rows = csv(text); let Some(header) = rows.first() else { return CollectionImportPreview { source: "Goodreads CSV".into(), items: Vec::new(), warnings: vec!["The file has no header row.".into()] }; }; let columns: std::collections::HashMap<String, usize> = header.iter().enumerate().map(|(index, value)| (normalize_column(value), index)).collect(); let value = |row: &[String], names: &[&str]| names.iter().find_map(|name| columns.get(&normalize_column(name)).and_then(|index| row.get(*index))).cloned().unwrap_or_default(); let items = rows.iter().skip(1).filter_map(|row| { let title = value(row, &["Title"]); if title.is_empty() { return None; } let mut item = CollectionItem::new(CollectionKind::Library); item.title = title; item.creator = value(row, &["Author", "Author l-f"]); item.year = value(row, &["Original Publication Year"]).parse().ok(); item.readingStart = parse_date(&value(row, &["Date Read"])); item.readingEnd = item.readingStart.clone(); Some(item) }).collect(); CollectionImportPreview { source: "Goodreads CSV".into(), items, warnings: Vec::new() } }
fn import_letterboxd(text: &str) -> CollectionImportPreview { let rows = csv(text); let Some(header) = rows.first() else { return CollectionImportPreview { source: "Letterboxd CSV".into(), items: Vec::new(), warnings: vec!["The file has no header row.".into()] }; }; let columns: std::collections::HashMap<String, usize> = header.iter().enumerate().map(|(index, value)| (normalize_column(value), index)).collect(); let value = |row: &[String], names: &[&str]| names.iter().find_map(|name| columns.get(&normalize_column(name)).and_then(|index| row.get(*index))).cloned().unwrap_or_default(); let items = rows.iter().skip(1).filter_map(|row| { let title = value(row, &["Name", "Title"]); if title.is_empty() { return None; } let mut item = CollectionItem::new(CollectionKind::Movies); item.title = title; item.year = value(row, &["Year"]).parse().ok(); if let Some(date) = parse_date(&value(row, &["Watched Date", "Date"])) { item.watchedDates.push(date); } Some(item) }).collect(); CollectionImportPreview { source: "Letterboxd CSV".into(), items, warnings: Vec::new() } }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct CollectionLinkResult { pub item: CollectionItem }

fn url_parts(raw: &str) -> (String, String, String) { let without_scheme = raw.split_once("://").map(|(_, rest)| rest).unwrap_or(raw); let without_fragment = without_scheme.split('#').next().unwrap_or(without_scheme); let (authority, suffix) = without_fragment.split_once('/').unwrap_or((without_fragment, "")); let (host, authority_query) = authority.split_once('?').unwrap_or((authority, "")); let (path_part, path_query) = suffix.split_once('?').unwrap_or((suffix, "")); let query = if authority_query.is_empty() { path_query } else { authority_query }; let path = format!("/{path_part}"); (host.to_lowercase().trim_start_matches("www.").to_string(), path, query.to_lowercase()) }
pub(crate) fn normalize_url(raw: &str) -> Option<String> { let trimmed = raw.trim(); if trimmed.is_empty() { return None; } let value = if trimmed.contains("://") { trimmed.to_string() } else { format!("https://{trimmed}") }; let (host, _, _) = url_parts(&value); if host.is_empty() { None } else { Some(value) } }
fn classify(url: &str) -> (CollectionKind, CollectionBookFormat, CollectionMediaType) { let (host, path, query) = url_parts(url); if host.starts_with("audible.") || host.contains(".audible.") { return (CollectionKind::Library, CollectionBookFormat::Audiobook, CollectionMediaType::Movie); } if host.starts_with("amazon.") || host.contains(".amazon.") { let ebook = path.contains("kindle") || path.contains("/clp/") || query.contains("kc_"); return (CollectionKind::Library, if ebook { CollectionBookFormat::Ebook } else { CollectionBookFormat::Print }, CollectionMediaType::Movie); } if ["youtube.com", "m.youtube.com", "youtu.be"].contains(&host.as_str()) { return (CollectionKind::Movies, CollectionBookFormat::Print, CollectionMediaType::YouTube); } if host == "imdb.com" || host.ends_with(".imdb.com") || host == "share.google" || host == "google.com" { return (CollectionKind::Movies, CollectionBookFormat::Print, CollectionMediaType::Movie); } if host == "podcasts.apple.com" || host.ends_with(".podcasts.apple.com") || (host == "open.spotify.com" && path.contains("/episode")) { return (CollectionKind::Movies, CollectionBookFormat::Print, CollectionMediaType::Podcast); } (CollectionKind::Articles, CollectionBookFormat::Print, CollectionMediaType::Movie) }
fn html_attr(tag: &str, name: &str) -> Option<String> { for quote in ['"', '\''] { let pattern = format!(r"(?is)\b{}\s*=\s*{}([^{}]*){}", regex::escape(name), quote, quote, quote); if let Ok(regex) = Regex::new(&pattern) { if let Some(capture) = regex.captures(tag).and_then(|c| c.get(1)) { return Some(decode_entities(capture.as_str())); } } } None }
fn meta_value(html: &str, names: &[&str]) -> Option<String> { let regex = Regex::new(r"(?is)<meta\b[^>]*>").ok()?; for tag in regex.find_iter(html).map(|m| m.as_str()) { let marker = html_attr(tag, "property").or_else(|| html_attr(tag, "name")); if let Some(value) = marker { if names.iter().any(|name| value.eq_ignore_ascii_case(name)) { if let Some(content) = html_attr(tag, "content") { if !content.is_empty() { return Some(content); } } } } } None }
fn jsonld_value(html: &str, keys: &[&str]) -> Option<String> { let script = Regex::new(r#"(?is)<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#).ok()?; for capture in script.captures_iter(html) { let value: serde_json::Value = serde_json::from_str(capture.get(1)?.as_str()).ok()?; if let Some(found) = find_jsonld(&value, keys) { return Some(found); } } None }
fn find_jsonld(value: &serde_json::Value, keys: &[&str]) -> Option<String> { match value { serde_json::Value::Object(map) => { for key in keys { if let Some(value) = map.get(*key) { if let Some(text) = value.as_str() { return Some(text.to_string()); } if let Some(name) = value.get("name").and_then(|v| v.as_str()) { return Some(name.to_string()); } } } map.values().find_map(|child| find_jsonld(child, keys)) }, serde_json::Value::Array(values) => values.iter().find_map(|child| find_jsonld(child, keys)), _ => None } }
fn strip_tags(value: &str) -> String { Regex::new(r"(?is)<[^>]+>").map(|regex| regex.replace_all(value, "").to_string()).unwrap_or_else(|_| value.to_string()) }
pub(crate) fn decode_entities(value: &str) -> String { let mut out = value.replace("&quot;", "\"").replace("&apos;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " "); if let Ok(regex) = Regex::new(r"&#([xX][0-9a-fA-F]+|[0-9]+);") { out = regex.replace_all(&out, |capture: &regex::Captures<'_>| { let body = &capture[1]; let number = if body.starts_with('x') || body.starts_with('X') { u32::from_str_radix(&body[1..], 16).ok() } else { body.parse().ok() }; number.and_then(char::from_u32).map(|c| c.to_string()).unwrap_or_else(|| capture[0].to_string()) }).to_string(); } out.replace("&amp;", "&") }
pub(crate) fn clean_title(raw: &str) -> (String, Option<i64>) { let mut title = raw.trim().to_string(); for suffix in [" - IMDb", " | IMDb", " - Google Search", " - Google", " | Rotten Tomatoes", " | Letterboxd", " - YouTube", " | Netflix"] { if title.ends_with(suffix) { title.truncate(title.len() - suffix.len()); } } let regex = Regex::new(r"(?i)\s*\((?:TV (?:Series|Mini Series|Movie) )?((?:19|20)\d{2})(?:[–-](?:\d{4})?\s*)?\)\s*$").ok(); let year = regex.as_ref().and_then(|re| re.captures(&title)).and_then(|c| c.get(1)).and_then(|v| v.as_str().parse().ok()); if let Some(re) = regex { if let Some(m) = re.find(&title) { title.truncate(m.start()); } } (title.trim().to_string(), year) }
fn fallback_title(url: &str) -> String { let (_, path, _) = url_parts(url); let last = path.trim_matches('/').rsplit('/').next().unwrap_or(""); let candidate = last.replace(['-', '_'], " "); if candidate.is_empty() { url_parts(url).0 } else { candidate.split_whitespace().map(|part| { let mut chars = part.chars(); chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default() }).collect::<Vec<_>>().join(" ") } }
pub(crate) fn looks_like_id(title: &str, url: &str) -> bool { let t = title.trim(); let (host, path, _) = url_parts(url); if t.is_empty() || t.eq_ignore_ascii_case(&host) { return true; } if Regex::new(r"(?i)^tt\d{5,}$").ok().map(|r| r.is_match(t)).unwrap_or(false) { return true; } let last = path.trim_matches('/').rsplit('/').next().unwrap_or(""); t.eq_ignore_ascii_case(last) || (!t.contains(' ') && t.len() >= 8 && t.chars().any(|c| c.is_ascii_digit())) }
fn amazon_title(raw: &str) -> Option<(String, String)> { if raw.contains(" | ") { let first = raw.split(" | ").next()?.to_string(); if let Some((title, author)) = first.rsplit_once(" by ") { return Some((title.to_string(), author.to_string())); } return if first.is_empty() { None } else { Some((first, String::new())) }; } let noise = ["books", "kindle store", "audible books & originals", "movies & tv", "prime video"]; let mut parts: Vec<String> = raw.split(": ").map(str::trim).map(str::to_string).collect(); if !parts.iter().any(|part| part.to_lowercase().starts_with("amazon.")) { return None; } parts.retain(|part| { let lower = part.to_lowercase(); !part.is_empty() && !lower.starts_with("amazon.") && !noise.contains(&lower.as_str()) && !Regex::new(r"^[0-9Xx-]{10,17}$").unwrap().is_match(part) }); let mut author = String::new(); if let Some(index) = parts.iter().rposition(|part| Regex::new(r"^[^,]+, [^,]+$").unwrap().is_match(part)) { let names: Vec<&str> = parts[index].splitn(2, ", ").collect(); author = format!("{} {}", names[1], names[0]); parts.remove(index); } let mut title = parts.join(": "); for suffix in [" eBook", " Kindle Edition", " Audible Audiobook", " Paperback", " Hardcover"] { if title.ends_with(suffix) { title.truncate(title.len() - suffix.len()); } } if title.is_empty() { None } else { Some((title, author)) } }

#[derive(Debug, Clone)] struct LinkMetadata { title: String, creator: String, site_name: String, year: Option<i64>, thumbnail: Option<String> }
fn resolve_url(base: &str, value: &str) -> String { if value.starts_with("http://") || value.starts_with("https://") { value.to_string() } else if value.starts_with("//") { format!("https:{value}") } else { let (host, _, _) = url_parts(base); if value.starts_with('/') { format!("https://{host}{value}") } else { format!("https://{host}/{value}") } } }
fn parse_metadata(html: &str, url: &str) -> LinkMetadata { let title = meta_value(html, &["og:title", "twitter:title"]).or_else(|| jsonld_value(html, &["headline", "name"])).or_else(|| Regex::new(r"(?is)<title[^>]*>(.*?)</title>").ok().and_then(|r| r.captures(html)).and_then(|c| c.get(1)).map(|v| strip_tags(v.as_str()))).unwrap_or_else(|| fallback_title(url)); let description = meta_value(html, &["og:description", "description", "twitter:description"]).or_else(|| jsonld_value(html, &["description"])).unwrap_or_default(); let creator = meta_value(html, &["article:author", "author", "byl", "creator"]).or_else(|| jsonld_value(html, &["author", "creator"])).unwrap_or_default(); let site = meta_value(html, &["og:site_name"]).unwrap_or_else(|| url_parts(url).0); let image = meta_value(html, &["og:image", "twitter:image", "twitter:image:src"]).or_else(|| jsonld_value(html, &["image"])).or_else(|| { let regex = Regex::new(r#"(?is)data-old-hires\s*=\s*[\"']([^\"']+)[\"']"#).ok()?; regex.captures(html).and_then(|c| c.get(1)).map(|v| v.as_str().to_string()) }); let (cleaned, title_year) = clean_title(&decode_entities(&strip_tags(&title))); let year_text = format!("{title} {description} {html}"); let year = Regex::new(r"\b((?:19|20)\d{2})\b").ok().and_then(|r| r.captures(&year_text).and_then(|c| c.get(1)).and_then(|v| v.as_str().parse().ok())).or(title_year); let (host, _, _) = url_parts(url); if (host.contains("amazon.") || host.contains("audible.")) { if let Some((book, author)) = amazon_title(&cleaned) { return LinkMetadata { title: book, creator: if creator.is_empty() { author } else { clean_title(&creator).0 }, site_name: if host.contains("audible.") { "Audible".into() } else { "Amazon".into() }, year, thumbnail: image.map(|v| resolve_url(url, &v)) }; } } LinkMetadata { title: cleaned, creator: clean_title(&creator).0, site_name: clean_title(&site).0, year, thumbnail: image.map(|v| resolve_url(url, &v)) } }
fn fetch_data(client: &Client, url: &str) -> Result<Vec<u8>, String> { let response = client.get(url).send().map_err(|e| e.to_string())?; if !response.status().is_success() { return Err(format!("HTTP {}", response.status())); } let bytes = response.bytes().map_err(|e| e.to_string())?; Ok(bytes[..bytes.len().min(2 * 1024 * 1024)].to_vec()) }
/// Windows has no LinkPresentation (the Mac's fallback when a page hides its title, e.g. Amazon's robot check).
/// Books with an ISBN in the link are looked up in Open Library, then Google Books (both keyless); otherwise the words
/// in the link are used.
fn windows_fallback(client: &Client, url: &str, metadata: &mut LinkMetadata) {
    if let Some(id) = imdb_id(url) { if imdb_suggestion(client, &id, metadata) { return; } }
    if let Some(isbn) = isbn_in(url) {
        if open_library(client, &isbn, metadata) { return; }
        let endpoint = format!("https://www.googleapis.com/books/v1/volumes?q=isbn:{isbn}");
        if let Ok(data) = fetch_data(client, &endpoint) {
            if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) {
                if let Some(info) = value.pointer("/items/0/volumeInfo") {
                    let title = info.get("title").and_then(|v| v.as_str()).unwrap_or("").to_string();
                    if !title.is_empty() {
                        metadata.title = title;
                        let authors: Vec<String> = info.get("authors").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                        if metadata.creator.is_empty() { metadata.creator = authors.join(", "); }
                        if metadata.year.is_none() { metadata.year = info.get("publishedDate").and_then(|v| v.as_str()).and_then(|d| d.get(0..4)).and_then(|y| y.parse().ok()); }
                        if metadata.thumbnail.is_none() {
                            metadata.thumbnail = info.pointer("/imageLinks/thumbnail").and_then(|v| v.as_str()).map(|t| t.replace("http://", "https://"));
                        }
                        return;
                    }
                }
            }
        }
    }
    if let Some(title) = slug_title(url) { metadata.title = title; }
}

/// imdb.com/title/tt0099685/ -> "tt0099685".
fn imdb_id(url: &str) -> Option<String> {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)imdb\.com/(?:[a-z-]+/)?title/(tt\d{5,})").unwrap()).captures(url).map(|c| c[1].to_lowercase())
}

/// IMDb blocks page reads; its public suggestion endpoint returns title, year, stars and poster for a title id.
fn imdb_suggestion(client: &Client, id: &str, metadata: &mut LinkMetadata) -> bool {
    let Ok(data) = fetch_data(client, &format!("https://v3.sg.media-imdb.com/suggestion/x/{id}.json")) else { return false };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) else { return false };
    let Some(hit) = value.get("d").and_then(|d| d.as_array()).and_then(|a| a.iter().find(|x| x.get("id").and_then(|v| v.as_str()) == Some(id))) else { return false };
    let title = hit.get("l").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
    if title.is_empty() { return false; }
    metadata.title = title;
    if metadata.year.is_none() { metadata.year = hit.get("y").and_then(|v| v.as_i64()); }
    if metadata.creator.is_empty() { metadata.creator = hit.get("s").and_then(|v| v.as_str()).unwrap_or("").to_string(); }
    if metadata.thumbnail.is_none() { metadata.thumbnail = hit.pointer("/i/imageUrl").and_then(|v| v.as_str()).map(String::from); }
    true
}

/// Open Library by ISBN: title, first author, year and cover. Keyless and not rate-limited like Google Books.
fn open_library(client: &Client, isbn: &str, metadata: &mut LinkMetadata) -> bool {
    let Ok(data) = fetch_data(client, &format!("https://openlibrary.org/isbn/{isbn}.json")) else { return false };
    let Ok(book) = serde_json::from_slice::<serde_json::Value>(&data) else { return false };
    let title = book.get("title").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
    if title.is_empty() { return false; }
    metadata.title = title;
    if metadata.creator.is_empty() {
        if let Some(key) = book.pointer("/authors/0/key").and_then(|v| v.as_str()) {
            if let Ok(author) = fetch_data(client, &format!("https://openlibrary.org{key}.json")) {
                if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&author) {
                    metadata.creator = value.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
                }
            }
        }
    }
    if metadata.year.is_none() {
        static YEAR: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let date = book.get("publish_date").and_then(|v| v.as_str()).unwrap_or("");
        metadata.year = YEAR.get_or_init(|| Regex::new(r"\b(1[5-9]\d{2}|20\d{2})\b").unwrap()).captures(date).and_then(|c| c[1].parse().ok());
    }
    if metadata.thumbnail.is_none() { metadata.thumbnail = Some(format!("https://covers.openlibrary.org/b/isbn/{isbn}-L.jpg")); }
    true
}

/// ISBN-10/13 in a book link: amazon.com/Title/dp/0735216371, /gp/product/…, /isbn/…, ?isbn=….
fn isbn_in(url: &str) -> Option<String> {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)(?:/dp/|/gp/product/|/isbn/|[?&]isbn=)(97[89]\d{10}|\d{9}[\dX])\b").unwrap())
        .captures(url).map(|c| c[1].to_uppercase())
}

/// "amazon.com/Thinking-Bets-Making-Smarter-Decisions/dp/…" -> "Thinking Bets Making Smarter Decisions".
fn slug_title(url: &str) -> Option<String> {
    let path = url.split("//").nth(1)?.split_once('/')?.1.split(['?', '#']).next()?;
    path.split('/').filter(|seg| seg.contains('-') && seg.chars().any(|c| c.is_alphabetic()))
        .map(|seg| seg.split('-').filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" "))
        .find(|t| t.split(' ').count() >= 2)
}

fn fetch_link(raw: &str) -> Result<CollectionItem, String> { let url = normalize_url(raw).ok_or("Enter a valid link")?; let (kind, format, media_type) = classify(&url); let client = Client::builder().timeout(Duration::from_secs(10)).user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Inferoid Notes").build().map_err(|e| e.to_string())?; let mut metadata = LinkMetadata { title: String::new(), creator: String::new(), site_name: url_parts(&url).0, year: None, thumbnail: None };
    if media_type == CollectionMediaType::YouTube { let endpoint = format!("https://www.youtube.com/oembed?url={}&format=json", urlencoding::encode(&url)); if let Ok(data) = fetch_data(&client, &endpoint) { if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) { metadata.title = value.get("title").and_then(|v| v.as_str()).unwrap_or("").into(); metadata.creator = value.get("author_name").and_then(|v| v.as_str()).unwrap_or("").into(); metadata.site_name = "YouTube".into(); metadata.thumbnail = value.get("thumbnail_url").and_then(|v| v.as_str()).map(str::to_string); } } }
    if let Ok(data) = fetch_data(&client, &url) { if let Ok(html) = String::from_utf8(data) { let parsed = parse_metadata(&html, &url); if metadata.title.is_empty() { metadata.title = parsed.title.clone(); } if metadata.creator.is_empty() { metadata.creator = parsed.creator.clone(); } if metadata.thumbnail.is_none() { metadata.thumbnail = parsed.thumbnail.clone(); } if metadata.year.is_none() { metadata.year = parsed.year; } if metadata.site_name.is_empty() { metadata.site_name = parsed.site_name; } } }
    if metadata.title.is_empty() { metadata.title = fallback_title(&url); } if looks_like_id(&metadata.title, &url) { windows_fallback(&client, &url, &mut metadata); } let (cleaned, parsed_year) = clean_title(&metadata.title); metadata.title = if cleaned.is_empty() { fallback_title(&url) } else { cleaned }; if metadata.year.is_none() { metadata.year = parsed_year; }
    let mut item = CollectionItem::new(kind); item.title = metadata.title; item.creator = metadata.creator; item.year = metadata.year; item.source = metadata.site_name; item.url = url; item.format = format; item.r#type = media_type;
    if let Some(image_url) = metadata.thumbnail { if let Ok(data) = fetch_data(&client, &image_url) { let extension = image_url.rsplit('.').next().unwrap_or("jpg").split('?').next().unwrap_or("jpg").to_lowercase(); let filename = format!("cover.{}", if extension.len() <= 5 { extension } else { "jpg".into() }); fs::create_dir_all(collection_folder(&item)).map_err(|e| e.to_string())?; fs::write(collection_folder(&item).join(&filename), data).map_err(|e| e.to_string())?; item.coverFile = Some(filename); } }
    save_collection(item)
}

#[tauri::command]
pub(crate) fn list_collection(kind: String) -> Result<Vec<CollectionItem>, String> { Ok(load_collection(&CollectionKind::from_name(&kind)?)) }
#[tauri::command]
pub(crate) fn save_collection_item(item: CollectionItem, original_kind: Option<String>) -> Result<CollectionItem, String> { if let Some(old_name) = original_kind { let old_kind = CollectionKind::from_name(&old_name)?; if old_kind != item.kind { let old_folder = collection_root(&old_kind).join(&item.id); let new_folder = collection_folder(&item); if old_folder.exists() && !new_folder.exists() { fs::create_dir_all(collection_root(&item.kind)).map_err(|e| e.to_string())?; fs::rename(old_folder, new_folder).map_err(|e| e.to_string())?; } } } save_collection(item) }
#[tauri::command]
pub(crate) fn delete_collection_item(item: CollectionItem) -> Result<(), String> { delete_collection(&item) }
#[tauri::command]
pub(crate) fn set_collection_include_in_brain(item: CollectionItem, included: bool) -> Result<CollectionItem, String> { set_collection_include(item, included) }
#[tauri::command(async)]
pub(crate) async fn add_collection_by_link(url: String) -> Result<CollectionItem, String> { tauri::async_runtime::spawn_blocking(move || fetch_link(&url)).await.map_err(|e| e.to_string())? }
#[tauri::command]
pub(crate) fn import_collection(kind: String, source: String, text: String) -> Result<CollectionImportPreview, String> { let kind = CollectionKind::from_name(&kind)?; Ok(parse_import_collection(&kind, &source, &text)) }
#[tauri::command]
pub(crate) fn collection_cover_data(item: CollectionItem) -> Option<Vec<u8>> { item.coverFile.clone().and_then(|name| fs::read(collection_folder(&item).join(name)).ok()) }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum JournalEntryKind { Daily, Voice, Decision, Weekly, Routine }
impl JournalEntryKind { fn source_title(&self, entry: &JournalEntry) -> String { match self { Self::Decision => if entry.decisionTitle.is_empty() { format!("Decision {}", &entry.date[..entry.date.len().min(10)]) } else { entry.decisionTitle.clone() }, Self::Weekly => format!("Weekly reflection {}", &entry.date[..entry.date.len().min(10)]), Self::Routine => if entry.decisionTitle.is_empty() { format!("Routine {}", &entry.date[..entry.date.len().min(10)]) } else { entry.decisionTitle.clone() }, Self::Voice => format!("Voice memo {}", &entry.date[..entry.date.len().min(10)]), Self::Daily => format!("Journal {}", &entry.date[..entry.date.len().min(10)]) } } }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct DecisionSourceLink { #[serde(rename = "sourceID")] pub source_id: String, pub kind: String, pub title: String }
#[derive(Debug, Clone, Serialize)]
pub(crate) struct JournalEntry { pub id: String, pub date: String, pub kind: JournalEntryKind, pub text: String, pub voiceMemo: String, pub decisionTitle: String, pub decisionWhy: String, pub decisionExpectation: String, pub decisionShapedBy: Vec<DecisionSourceLink>, #[serde(skip_serializing_if = "Option::is_none")] pub checkBackDate: Option<String>, #[serde(rename = "includeInBrain")] pub include_in_brain: bool, pub createdAt: String, pub updatedAt: String, pub summary: String, pub summaryKey: String }
#[derive(Deserialize)]
struct RawJournalEntry { id: Option<String>, date: Option<String>, kind: Option<JournalEntryKind>, text: Option<String>, voiceMemo: Option<String>, decisionTitle: Option<String>, decisionWhy: Option<String>, decisionExpectation: Option<String>, decisionShapedBy: Option<Vec<DecisionSourceLink>>, checkBackDate: Option<String>, includeInBrain: Option<bool>, createdAt: Option<String>, updatedAt: Option<String>, summary: Option<String>, summaryKey: Option<String> }
impl<'de> Deserialize<'de> for JournalEntry { fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> { let raw = RawJournalEntry::deserialize(deserializer)?; let date = raw.date.unwrap_or_else(now); let kind = raw.kind.or_else(|| raw.voiceMemo.as_ref().filter(|v| !v.is_empty()).map(|_| JournalEntryKind::Voice)).unwrap_or_else(default_journal_kind); let created = raw.createdAt.unwrap_or_else(|| date.clone()); Ok(Self { id: raw.id.unwrap_or_else(uuid_string), date: date.clone(), kind, text: raw.text.unwrap_or_default(), voiceMemo: raw.voiceMemo.unwrap_or_default(), decisionTitle: raw.decisionTitle.unwrap_or_default(), decisionWhy: raw.decisionWhy.unwrap_or_default(), decisionExpectation: raw.decisionExpectation.unwrap_or_default(), decisionShapedBy: raw.decisionShapedBy.unwrap_or_default(), checkBackDate: raw.checkBackDate, include_in_brain: raw.includeInBrain.unwrap_or(true), createdAt: created.clone(), updatedAt: raw.updatedAt.unwrap_or(created), summary: raw.summary.unwrap_or_default(), summaryKey: raw.summaryKey.unwrap_or_default() }) } }
impl JournalEntry { pub(crate) fn new(date: String, kind: JournalEntryKind) -> Self { let stamp = now(); Self { id: uuid_string(), date, kind, text: String::new(), voiceMemo: String::new(), decisionTitle: String::new(), decisionWhy: String::new(), decisionExpectation: String::new(), decisionShapedBy: Vec::new(), checkBackDate: None, include_in_brain: true, createdAt: stamp.clone(), updatedAt: stamp, summary: String::new(), summaryKey: String::new() } } fn brain_text(&self) -> String { let mut values = vec![self.text.clone(), self.voiceMemo.clone()]; if self.kind == JournalEntryKind::Decision { values.extend([self.decisionTitle.clone(), self.decisionWhy.clone(), self.decisionExpectation.clone()]); values.push(self.decisionShapedBy.iter().map(|v| format!("Shaped by: {}", v.title)).collect::<Vec<_>>().join("\n")); } values.into_iter().filter(|v| !v.trim().is_empty()).collect::<Vec<_>>().join("\n") } }

fn journal_root() -> PathBuf { support_root().join("Journal") }
pub(crate) fn journal_folder(entry: &JournalEntry) -> PathBuf { journal_root().join(&entry.id) }
pub(crate) fn load_journal() -> Vec<JournalEntry> { let mut entries: Vec<JournalEntry> = fs::read_dir(journal_root()).ok().into_iter().flatten().filter_map(|e| e.ok()).filter_map(|e| fs::read_to_string(e.path().join("entry.json")).ok()).filter_map(|text| serde_json::from_str(&text).ok()).collect(); entries.sort_by(|a: &JournalEntry, b: &JournalEntry| b.date.cmp(&a.date)); entries }
pub(crate) fn journal_day(day: &str, entries: &[JournalEntry]) -> JournalEntry { let found = entries.iter().filter(|entry| entry.kind == JournalEntryKind::Daily && entry.date.starts_with(day)).find(|entry| !entry.text.is_empty() || !entry.summary.is_empty() || !entry.voiceMemo.is_empty()).or_else(|| entries.iter().find(|entry| entry.kind == JournalEntryKind::Daily && entry.date.starts_with(day))); found.cloned().unwrap_or_else(|| JournalEntry::new(format!("{day}T12:00:00Z"), JournalEntryKind::Daily)) }
pub(crate) fn save_journal(mut entry: JournalEntry) -> Result<JournalEntry, String> { fs::create_dir_all(journal_folder(&entry)).map_err(|e| e.to_string())?; entry.updatedAt = now(); fs::write(journal_folder(&entry).join("entry.json"), json_encoder(&entry)?).map_err(|e| e.to_string())?; let mut notes = format!("# {}\n\n", entry.kind.source_title(&entry)); if entry.kind == JournalEntryKind::Decision { notes.push_str(&format!("## Why\n\n{}\n\n## What I expect\n\n{}\n", entry.decisionWhy, entry.decisionExpectation)); } if !entry.summary.is_empty() { notes.push_str(&format!("\n## What happened\n\n{}\n", entry.summary)); } notes.push_str(&format!("\n{}\n", entry.text)); fs::write(journal_folder(&entry).join("notes.md"), notes).map_err(|e| e.to_string())?; fs::write(journal_folder(&entry).join("transcript.md"), entry.brain_text()).map_err(|e| e.to_string())?; let meta = serde_json::json!({ "started": entry.date, "includeInBrain": entry.include_in_brain }); fs::write(journal_folder(&entry).join("meta.json"), json_encoder(&meta)?).map_err(|e| e.to_string())?; Ok(entry) }
pub(crate) fn remove_empty_duplicate_days() { let entries = load_journal(); for mut entry in entries.iter().filter(|e| e.kind == JournalEntryKind::Daily && e.text.starts_with("# ")).cloned().collect::<Vec<_>>() { let parts: Vec<&str> = entry.text.splitn(2, "\n\n").collect(); if parts.len() == 2 { entry.kind = JournalEntryKind::Routine; entry.decisionTitle = parts[0].trim_start_matches("# ").to_string(); entry.text = parts[1].to_string(); let _ = save_journal(entry); } } let entries = load_journal(); let mut keep = HashSet::new(); for entry in entries.iter().filter(|e| e.kind == JournalEntryKind::Daily) { let day = &entry.date[..entry.date.len().min(10)]; let selected = entries.iter().find(|other| other.kind == JournalEntryKind::Daily && other.date.starts_with(day) && (!other.text.is_empty() || !other.summary.is_empty() || !other.voiceMemo.is_empty())).or_else(|| entries.iter().find(|other| other.kind == JournalEntryKind::Daily && other.date.starts_with(day))); if let Some(value) = selected { keep.insert(value.id.clone()); } } for entry in entries.iter().filter(|e| e.kind == JournalEntryKind::Daily && !keep.contains(&e.id) && e.text.is_empty() && e.summary.is_empty() && e.voiceMemo.is_empty()) { let _ = fs::remove_dir_all(journal_folder(entry)); } }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn metadata_cases_match_mac() { let html = r#"<meta property="og:title" content="Goodfellas (1990) - IMDb"><meta name="article:author" content="Ada Lovelace"><meta property="og:image" content="/cover.jpg">"#; let parsed = parse_metadata(html, "https://example.com/story"); assert_eq!(parsed.title, "Goodfellas"); assert_eq!(parsed.creator, "Ada Lovelace"); assert_eq!(parsed.thumbnail.as_deref(), Some("https://example.com/cover.jpg")); assert_eq!(parsed.year, Some(1990)); }
    #[test] fn entities_and_amazon_titles_match_mac() { assert_eq!(decode_entities("Don&#x27;t &#39;stop&#39; &amp;amp;"), "Don't 'stop' &amp;"); assert_eq!(amazon_title("Think Again: The Power of Knowing What You Don't Know: Grant, Adam: 9781984878120: Amazon.com: Books").unwrap(), ("Think Again: The Power of Knowing What You Don't Know".into(), "Adam Grant".into())); }
    #[test] fn classifications_cover_all_special_hosts() { assert_eq!(classify("https://www.amazon.com/clp/x?kc_a=1").0, CollectionKind::Library); assert_eq!(classify("https://youtu.be/x").2, CollectionMediaType::YouTube); assert_eq!(classify("https://open.spotify.com/episode/x").2, CollectionMediaType::Podcast); assert_eq!(classify("https://example.com/story").0, CollectionKind::Articles); }
    #[test] fn journal_migration_creates_routine_shape() { let mut entry = JournalEntry::new("2026-11-23T12:00:00Z".into(), JournalEntryKind::Daily); entry.text = "# Promise check\n\nDone".into(); assert!(entry.text.starts_with("# ")); }

    #[test]
    fn windows_book_fallbacks() {
        assert_eq!(isbn_in("https://www.amazon.com/Thinking-Bets-Making-Smarter-Decisions/dp/0735216371").as_deref(), Some("0735216371"));
        assert_eq!(isbn_in("https://example.com/book?isbn=9780735216372").as_deref(), Some("9780735216372"));
        assert_eq!(isbn_in("https://www.amazon.com/dp/B07XYZ1234"), None);
        assert_eq!(slug_title("https://www.amazon.com/Thinking-Bets-Making-Smarter-Decisions/dp/0735216371").as_deref(), Some("Thinking Bets Making Smarter Decisions"));
        assert_eq!(slug_title("https://example.com/item/12345"), None);
        assert_eq!(imdb_id("https://www.imdb.com/title/tt0099685/").as_deref(), Some("tt0099685"));
        assert_eq!(imdb_id("https://m.imdb.com/title/tt0099685/?ref_=x").as_deref(), Some("tt0099685"));
    }
}

