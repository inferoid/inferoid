use chrono::Utc;
use serde::{de::Deserializer, Deserialize, Serialize};
use std::{fs, path::PathBuf};
use uuid::Uuid;

use crate::{library::json_encoder, support_root, BrainStore};

fn now() -> String { Utc::now().to_rfc3339() }
fn uuid_string() -> String { Uuid::new_v4().to_string() }

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Trip {
    pub id: String,
    pub title: String,
    pub place: String,
    pub startDate: String,
    pub endDate: String,
    pub coverColor: String,
    #[serde(skip_serializing_if = "Option::is_none")] pub coverFile: Option<String>,
    pub places: Vec<String>,
    pub peopleMet: Vec<String>,
    pub notes: String,
    pub photos: Vec<String>,
    #[serde(rename = "includeInBrain")] pub include_in_brain: bool,
    pub createdAt: String,
    pub updatedAt: String,
}

#[derive(Deserialize)]
struct RawTrip { id: Option<String>, title: Option<String>, place: Option<String>, startDate: Option<String>, endDate: Option<String>, coverColor: Option<String>, coverFile: Option<String>, places: Option<Vec<String>>, peopleMet: Option<Vec<String>>, notes: Option<String>, photos: Option<Vec<String>>, includeInBrain: Option<bool>, createdAt: Option<String>, updatedAt: Option<String> }
impl<'de> Deserialize<'de> for Trip {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> { let raw = RawTrip::deserialize(deserializer)?; let stamp = now(); let start = raw.startDate.unwrap_or_else(|| stamp.clone()); let created = raw.createdAt.unwrap_or_else(|| start.clone()); Ok(Self { id: raw.id.unwrap_or_else(uuid_string), title: raw.title.unwrap_or_default(), place: raw.place.unwrap_or_default(), startDate: start.clone(), endDate: raw.endDate.unwrap_or(start), coverColor: raw.coverColor.unwrap_or_else(|| "blue".into()), coverFile: raw.coverFile, places: raw.places.unwrap_or_default(), peopleMet: raw.peopleMet.unwrap_or_default(), notes: raw.notes.unwrap_or_default(), photos: raw.photos.unwrap_or_default(), include_in_brain: raw.includeInBrain.unwrap_or(true), createdAt: created.clone(), updatedAt: raw.updatedAt.unwrap_or(created) }) }
}
impl Trip { pub(crate) fn new() -> Self { let stamp = now(); Self { id: uuid_string(), title: String::new(), place: String::new(), startDate: stamp.clone(), endDate: stamp.clone(), coverColor: "blue".into(), coverFile: None, places: Vec::new(), peopleMet: Vec::new(), notes: String::new(), photos: Vec::new(), include_in_brain: true, createdAt: stamp.clone(), updatedAt: stamp } } }

fn root() -> PathBuf { support_root().join("Travels") }
fn folder(trip: &Trip) -> PathBuf { root().join(&trip.id) }
pub(crate) fn load_trips() -> Vec<Trip> { let mut trips: Vec<Trip> = fs::read_dir(root()).ok().into_iter().flatten().filter_map(|e| e.ok()).filter_map(|e| fs::read_to_string(e.path().join("trip.json")).ok()).filter_map(|text| serde_json::from_str(&text).ok()).collect(); trips.sort_by(|a: &Trip, b: &Trip| b.startDate.cmp(&a.startDate)); trips }
pub(crate) fn save_trip(mut trip: Trip) -> Result<Trip, String> { fs::create_dir_all(folder(&trip)).map_err(|e| e.to_string())?; trip.updatedAt = now(); fs::write(folder(&trip).join("trip.json"), json_encoder(&trip)?).map_err(|e| e.to_string())?; let mut text = format!("# {}\n\nPlace: {}\n", if trip.title.is_empty() { &trip.place } else { &trip.title }, trip.place); if !trip.places.is_empty() { text.push_str(&format!("Places: {}\n", trip.places.join(", "))); } if !trip.peopleMet.is_empty() { text.push_str(&format!("People met: {}\n", trip.peopleMet.join(", "))); } if !trip.notes.trim().is_empty() { text.push_str(&format!("\n## Notes\n\n{}\n", trip.notes)); } fs::write(folder(&trip).join("notes.md"), &text).map_err(|e| e.to_string())?; fs::write(folder(&trip).join("transcript.md"), text).map_err(|e| e.to_string())?; let meta = serde_json::json!({ "started": trip.startDate, "includeInBrain": trip.include_in_brain }); fs::write(folder(&trip).join("meta.json"), json_encoder(&meta)?).map_err(|e| e.to_string())?; Ok(trip) }
pub(crate) fn delete_trip(trip: &Trip) -> Result<(), String> { let value = folder(trip); if value.exists() { trash::delete(&value).map_err(|e| e.to_string())?; } let _ = BrainStore::open_default().and_then(|store| store.remove_meeting_data(value.to_string_lossy().as_ref())); Ok(()) }

#[tauri::command]
pub(crate) fn list_trips() -> Vec<Trip> { load_trips() }
#[tauri::command]
pub(crate) fn save_trip_command(trip: Trip) -> Result<Trip, String> { save_trip(trip) }
#[tauri::command]
pub(crate) fn delete_trip_command(trip: Trip) -> Result<(), String> { delete_trip(&trip) }
#[tauri::command]
pub(crate) fn set_trip_include_in_brain(mut trip: Trip, included: bool) -> Result<Trip, String> { trip.include_in_brain = included; save_trip(trip) }
#[tauri::command]
pub(crate) fn trip_photo_data(trip: Trip, name: String) -> Option<Vec<u8>> { fs::read(folder(&trip).join("photos").join(name)).ok() }
#[tauri::command]
pub(crate) fn add_trip_photo(mut trip: Trip, name: String, data: Vec<u8>, extension: String) -> Result<Trip, String> { let photos = folder(&trip).join("photos"); fs::create_dir_all(&photos).map_err(|e| e.to_string())?; let safe_ext = if extension.len() <= 5 { extension.to_lowercase() } else { "jpg".into() }; let filename = if name.trim().is_empty() { format!("photo-{}.{}", uuid_string(), safe_ext) } else { format!("photo-{}.{}", uuid_string(), safe_ext) }; fs::write(photos.join(&filename), data).map_err(|e| e.to_string())?; trip.photos.push(filename.clone()); if trip.coverFile.is_none() { trip.coverFile = Some(filename); } save_trip(trip) }

#[cfg(test)]
mod tests { use super::*; #[test] fn old_trip_defaults_round_trip() { let value: Trip = serde_json::from_str(r#"{"title":"A trip","place":"Oslo"}"#).unwrap(); assert_eq!(value.coverColor, "blue"); assert!(value.include_in_brain); assert_eq!(value.endDate, value.startDate); } }
