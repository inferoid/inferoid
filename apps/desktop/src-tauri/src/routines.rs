use chrono::{Datelike, Duration, Local, NaiveDate, TimeZone, Utc, Weekday};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::{fs, path::PathBuf, sync::{Arc, Mutex}, thread, time::Duration as StdDuration};
use tauri::{AppHandle, Emitter};

use crate::{ensure_engine, inkling_render, list_saved_meetings, stream_json, AppState, ChatTurn};

#[derive(Debug, Clone, PartialEq)]
pub enum RoutineSchedule { EveryDay, Weekdays, Weekly { weekday: u32 }, Monthly { day: u32 }, Once }
impl Serialize for RoutineSchedule { fn serialize<S>(&self,s:S)->Result<S::Ok,S::Error> where S:Serializer { let value=match self { Self::EveryDay=>serde_json::json!({"everyDay":{}}),Self::Weekdays=>serde_json::json!({"weekdays":{}}),Self::Weekly{weekday}=>serde_json::json!({"weekly":{"weekday":weekday}}),Self::Monthly{day}=>serde_json::json!({"monthly":{"day":day}}),Self::Once=>serde_json::json!({"once":{}})}; value.serialize(s) } }
impl<'de> Deserialize<'de> for RoutineSchedule { fn deserialize<D>(d:D)->Result<Self,D::Error> where D:Deserializer<'de> { let value=serde_json::Value::deserialize(d)?; if let Some(name)=value.as_str(){return Ok(match name {"everyDay"=>Self::EveryDay,"weekdays"=>Self::Weekdays,"once"=>Self::Once,_=>Self::EveryDay})} let object=value.as_object().ok_or_else(||serde::de::Error::custom("invalid routine schedule"))?; if object.contains_key("everyDay"){Ok(Self::EveryDay)}else if object.contains_key("weekdays"){Ok(Self::Weekdays)}else if object.contains_key("once"){Ok(Self::Once)}else if let Some(v)=object.get("weekly"){Ok(Self::Weekly{weekday:v.get("weekday").and_then(|x|x.as_u64()).unwrap_or(2) as u32})}else if let Some(v)=object.get("monthly"){Ok(Self::Monthly{day:v.get("day").and_then(|x|x.as_u64()).unwrap_or(1) as u32})}else{Err(serde::de::Error::custom("unknown routine schedule"))} } }

#[derive(Debug, Clone, PartialEq)]
pub enum RoutineScope { WholeBrain, Project(String), LibraryOnly }
impl Serialize for RoutineScope { fn serialize<S>(&self,s:S)->Result<S::Ok,S::Error> where S:Serializer { let value=match self { Self::WholeBrain=>serde_json::json!({"wholeBrain":{}}),Self::Project(id)=>serde_json::json!({"project":{"_0":id}}),Self::LibraryOnly=>serde_json::json!({"libraryOnly":{}})}; value.serialize(s) } }
impl<'de> Deserialize<'de> for RoutineScope { fn deserialize<D>(d:D)->Result<Self,D::Error> where D:Deserializer<'de> { let value=serde_json::Value::deserialize(d)?; if let Some(name)=value.as_str(){return Ok(match name {"libraryOnly"=>Self::LibraryOnly,_=>Self::WholeBrain})} let object=value.as_object().ok_or_else(||serde::de::Error::custom("invalid routine scope"))?; if object.contains_key("wholeBrain"){Ok(Self::WholeBrain)}else if object.contains_key("libraryOnly"){Ok(Self::LibraryOnly)}else if let Some(v)=object.get("project"){let id=v.get("_0").and_then(|x|x.as_str()).or_else(||v.as_str()).unwrap_or_default().to_string();Ok(Self::Project(id))}else{Err(serde::de::Error::custom("unknown routine scope"))} } }
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum RoutineDelivery { #[serde(rename="notificationAndJournal")] NotificationAndJournal, #[serde(rename="notificationOnly")] NotificationOnly, #[serde(rename="journalOnly")] JournalOnly }
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutineRun { #[serde(default = "new_id")] pub id:String, pub date:String, pub success:bool, pub result:String }
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Routine { #[serde(default = "new_id")] pub id:String, pub name:String, pub prompt:String, pub schedule:RoutineSchedule, pub hour:u32, pub minute:u32, #[serde(rename="onceDate",default)] pub once_date:Option<String>, pub scope:RoutineScope, pub delivery:RoutineDelivery, pub enabled:bool, #[serde(rename="lastRun",default)] pub last_run:Option<String>, #[serde(rename="nextRun",default)] pub next_run:Option<String>, #[serde(default)] pub history:Vec<RoutineRun> }
fn new_id()->String{uuid::Uuid::new_v4().to_string()}
fn root()->PathBuf{crate::support_root().join("Routines")}
fn file()->PathBuf{root().join("routines.json")}
fn defaults()->Vec<Routine>{vec![Routine{id:new_id(),name:"Morning brief".into(),prompt:"Give me a concise morning brief from my Brain: what matters today, open promises, and useful context.".into(),schedule:RoutineSchedule::Weekdays,hour:8,minute:0,once_date:None,scope:RoutineScope::WholeBrain,delivery:RoutineDelivery::NotificationAndJournal,enabled:true,last_run:None,next_run:next_run(&RoutineSchedule::Weekdays,8,0,None,Local::now()),history:vec![]},Routine{id:new_id(),name:"Weekly reflection".into(),prompt:"Write a factual weekly reflection from my Brain, including what changed and any decision check-backs due.".into(),schedule:RoutineSchedule::Weekly{weekday:1},hour:18,minute:0,once_date:None,scope:RoutineScope::WholeBrain,delivery:RoutineDelivery::NotificationAndJournal,enabled:true,last_run:None,next_run:next_run(&RoutineSchedule::Weekly{weekday:1},18,0,None,Local::now()),history:vec![]},Routine{id:new_id(),name:"Keep in touch".into(),prompt:"Identify level 1–2 people I have not contacted in 30 or 60 days and suggest a thoughtful next step.".into(),schedule:RoutineSchedule::Weekly{weekday:2},hour:9,minute:0,once_date:None,scope:RoutineScope::WholeBrain,delivery:RoutineDelivery::NotificationAndJournal,enabled:true,last_run:None,next_run:next_run(&RoutineSchedule::Weekly{weekday:2},9,0,None,Local::now()),history:vec![]}]}
fn load()->Vec<Routine>{fs::read_to_string(file()).ok().and_then(|v|serde_json::from_str(&v).ok()).unwrap_or_else(||{let value=defaults();let _=persist(&value);value})}
fn persist(values:&[Routine])->Result<(),String>{fs::create_dir_all(root()).map_err(|e|e.to_string())?;fs::write(file(),serde_json::to_vec_pretty(values).map_err(|e|e.to_string())?).map_err(|e|e.to_string())}
fn local_stamp(value:&str)->Option<chrono::DateTime<Local>>{chrono::DateTime::parse_from_rfc3339(value).ok().map(|v|v.with_timezone(&Local))}
fn next_run(schedule:&RoutineSchedule,hour:u32,minute:u32,once:Option<&String>,after:chrono::DateTime<Local>)->Option<String>{let time=|date:NaiveDate|date.and_hms_opt(hour.min(23),minute.min(59),0).and_then(|v|Local.from_local_datetime(&v).single()); if matches!(schedule,RoutineSchedule::Once){return once.and_then(|v|local_stamp(v)).filter(|v|*v>after).map(|v|v.to_rfc3339())} for offset in 0..400 {let date=after.date_naive()+Duration::days(offset as i64); let weekday=date.weekday(); let yes=match schedule{RoutineSchedule::EveryDay=>true,RoutineSchedule::Weekdays=>!matches!(weekday,Weekday::Sat|Weekday::Sun),RoutineSchedule::Weekly{weekday:w}=>weekday.number_from_sunday()==*w,RoutineSchedule::Monthly{day}=>{let first_next=if date.month()==12{NaiveDate::from_ymd_opt(date.year()+1,1,1)}else{NaiveDate::from_ymd_opt(date.year(),date.month()+1,1)}; let last=first_next.and_then(|v|v.pred_opt()).map(|v|v.day()).unwrap_or(28); date.day()==(*day).min(last)},RoutineSchedule::Once=>false}; if yes {if let Some(value)=time(date){if value>after{return Some(value.to_rfc3339())}}}} None }
fn due(value:Option<&String>,now:chrono::DateTime<Local>)->bool{value.and_then(|v| local_stamp(v)).map(|v|v<=now).unwrap_or(false)}

#[tauri::command]
pub fn routines_list()->Vec<Routine>{load()}
#[tauri::command]
pub fn routine_save(mut routine:Routine)->Result<Routine,String>{routine.hour=routine.hour.min(23);routine.minute=routine.minute.min(59);routine.next_run=next_run(&routine.schedule,routine.hour,routine.minute,routine.once_date.as_ref(),Local::now());let mut all=load();if let Some(index)=all.iter().position(|v|v.id==routine.id){all[index]=routine.clone()}else{all.push(routine.clone())}persist(&all)?;Ok(routine)}
#[tauri::command]
pub fn routine_delete(id:String)->Result<(),String>{let mut all=load();all.retain(|v|v.id!=id);persist(&all)}
fn routine_context(routine:&Routine)->String{let meetings=list_saved_meetings();let mut out=String::new();for meeting in meetings.into_iter().filter(|v|v.include_in_brain).take(8){out.push_str(&format!("### {} ({})\n{}\n{}\n",meeting.title,meeting.date,meeting.notes,meeting.transcript));}if routine.scope==RoutineScope::WholeBrain{let _=crate::brain_features::brain_orbit();}out}
fn run_inner(app:&AppHandle,state:&AppState,id:&str,scheduled:bool)->Result<RoutineRun,String>{let lock=RUNNING.get_or_init(||Mutex::new(()));let _run_lock=lock.lock().map_err(|_|"Routine is already running".to_string())?;let mut all=load();let index=all.iter().position(|v|v.id==id).ok_or("Routine not found")?;let mut routine=all[index].clone();let now=Local::now();if scheduled&&!routine.enabled{return Err("Routine is disabled.".into())}if scheduled&&!due(routine.next_run.as_ref(),now){return Err("Routine is not due yet.".into())}routine.next_run=next_run(&routine.schedule,routine.hour,routine.minute,routine.once_date.as_ref(),now);all[index]=routine.clone();persist(&all)?;let _gate=state.model_gate.lock().map_err(|_|"Model gate lock failed".to_string())?;ensure_engine(&state.engine)?;let (port,style)={let engine=state.engine.lock().map_err(|_|"Engine lock failed".to_string())?;(engine.port.ok_or("The local model is not running")?,engine.style.clone())};let user=format!("Local records:\n{}{}\n\nTask: {}\nBe concise and factual. Say when the records do not answer the task.",people_section(&routine),routine_context(&routine),routine.prompt);let system="You are a private local routine assistant. Use only the supplied local records. Nothing leaves this computer.";let result=if style.eq_ignore_ascii_case("inkling"){let value=crate::http_json(port,"/completion",&serde_json::json!({"prompt":inkling_render(system,&[ChatTurn{role:"user".into(),text:user.clone()}]),"n_predict":600,"temperature":0.2,"seed":7,"stream":false,"stop":["<|end_message|>","<|content_model_end_sampling|>"]}))?;value.get("content").and_then(|v|v.as_str()).unwrap_or_default().to_string()}else{let value=crate::http_json(port,"/v1/chat/completions",&serde_json::json!({"messages":[{"role":"system","content":system},{"role":"user","content":user}],"max_tokens":600,"temperature":0.2,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}))?;value.pointer("/choices/0/message/content").and_then(|v|v.as_str()).unwrap_or_default().to_string()};let result=result.trim().to_string();let success=!result.is_empty();let message=if success{result}else{"The routine returned an empty result.".into()};if routine.delivery!=RoutineDelivery::NotificationOnly{let _=crate::journal::save_routine_result(routine.name.clone(),message.clone(),None)?;}if routine.delivery!=RoutineDelivery::JournalOnly{let _=app.emit("routine-banner",serde_json::json!({"title":routine.name,"body":message}));}let run=RoutineRun{id:new_id(),date:Utc::now().to_rfc3339(),success,result:message};routine.last_run=Some(run.date.clone());routine.history.push(run.clone());if routine.history.len()>20{let remove=routine.history.len()-20;routine.history.drain(0..remove);}all[index]=routine;persist(&all)?;Ok(run)}
static RUNNING:std::sync::OnceLock<Mutex<()>>=std::sync::OnceLock::new();
#[tauri::command(async)]
pub async fn routine_run_now(app:AppHandle,id:String,state:tauri::State<'_,AppState>)->Result<RoutineRun,String>{run_inner(&app,state.inner(),&id,false)}
pub fn start_scheduler(app:AppHandle,state:AppState){thread::spawn(move||loop{let now=Local::now();for routine in load(){if routine.enabled&&due(routine.next_run.as_ref(),now){let _=run_inner(&app,&state,&routine.id,true);break;}}thread::sleep(StdDuration::from_secs(60));});}

#[cfg(test)]mod tests{use super::*;#[test]fn weekday_schedule_skips_weekends(){let monday=Local.with_ymd_and_hms(2026,11,23,7,59,0).single().unwrap();let next=next_run(&RoutineSchedule::Weekdays,8,0,None,monday).unwrap();assert!(next.starts_with("2026-11-23T08:00"));let after=Local.with_ymd_and_hms(2026,11,23,8,0,0).single().unwrap();assert!(next_run(&RoutineSchedule::Weekdays,8,0,None,after).unwrap().starts_with("2026-11-24"));}#[test]fn catch_up_is_one_due_occurrence(){let now=Local::now();let due_time=(now-Duration::minutes(1)).to_rfc3339();assert!(due(Some(&due_time),now));assert!(!due(None,now));}}


/// People in Orbit with closeness and last contact (whole-Brain routines only), so "Keep in touch" can see who matters.
/// Same lines as RoutineStore.peopleSection on the Mac.
fn people_section(routine: &Routine) -> String {
    if routine.scope != RoutineScope::WholeBrain { return String::new(); }
    let Ok(people) = crate::brain_features::brain_orbit() else { return String::new() };
    if people.is_empty() { return String::new(); }
    let now = chrono::Utc::now();
    let mut out = String::from("People in Orbit (closeness 1 = very close, 5 = far):\n");
    for person in people.iter().take(40) {
        let level = person.closeness_level.unwrap_or(person.suggested_closeness_level);
        let mut line = format!("- {} ({}, closeness {} of 5", person.entity.name, person.entity.world, level);
        match person.last_met.as_deref().and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok()) {
            Some(last) => line.push_str(&format!(", last met {} days ago", (now - last.with_timezone(&chrono::Utc)).num_days().max(0))),
            None => line.push_str(", no meetings recorded"),
        }
        if person.has_open_promise { line.push_str(", open promise"); }
        line.push_str(")\n");
        out.push_str(&line);
    }
    out.push('\n');
    out
}
