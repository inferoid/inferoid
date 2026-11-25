import { ChevronRight, FileText, Search } from "lucide-react";
import type { Meeting } from "../types";

export function MeetingList({ meetings, selected, onSelect }: { meetings: Meeting[]; selected?: string; onSelect: (m: Meeting) => void }) {
  const groups = meetings.reduce<Record<string, Meeting[]>>((all, meeting) => { (all[meeting.date] ??= []).push(meeting); return all; }, {});
  return <div className="meeting-list"><div className="search-box"><Search size={16} /><input placeholder="Search meetings" /></div>{Object.entries(groups).map(([day, entries]) => <section className="day-group" key={day}><div className="eyebrow">{formatDay(day)}</div>{entries.map((m) => <button key={m.id} className={selected === m.id ? "meeting-row selected" : "meeting-row"} onClick={() => onSelect(m)}><div className="meeting-icon"><FileText size={17} /></div><div className="meeting-copy"><strong>{m.title}</strong><span>{time(m.started)} · {m.transcript ? `${m.transcript.split(/\s+/).length} words` : "No transcript"}</span></div><span className="brain-state">{m.includeInBrain ? "●" : "○"}</span><ChevronRight size={16} /></button>)}</section>)}</div>;
}
function formatDay(value: string) { const date = new Date(`${value}T12:00:00`); return Number.isNaN(date.valueOf()) ? value : date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" }); }
function time(value: string) { const date = new Date(value); return Number.isNaN(date.valueOf()) ? "" : date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); }
