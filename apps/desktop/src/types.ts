export type Page = "home" | "meetings" | "orbit" | "library" | "travels" | "journal" | "projects" | "routines" | "chat" | "settings";
export type World = "friend" | "family" | "business" | "mentor" | "mentee" | "other" | "unknown";

export interface Meeting {
  id: string;
  folder: string;
  title: string;
  date: string;
  started: string;
  notes: string;
  transcript: string;
  includeInBrain: boolean;
}

export interface OrbitPerson { entity: { id: number; kind: string; name: string; world: World; summary: string; createdAt: string; updatedAt: string; forgotten: boolean; closenessLevel?: number }; meetingCount: number; lastMet?: string; hasOpenPromise: boolean; hasChanged: boolean; closenessLevel?: number; suggestedClosenessLevel: number }
export interface PersonDetails { includeInBrain: boolean; likes: string[]; dislikes: string[]; familyNames: string[]; importantDates: string[]; giftIdeas: string[]; learned: { category: string; value: string; learned: boolean; sourceEpisodeID?: string }[]; notes?: string }
export interface PersonPage { entity: OrbitPerson["entity"]; details: PersonDetails; meetings: { id: string; meetingFolder: string; startedAt: string; processedAt?: string; model?: string }[]; openCommitmentsByPerson: { id: number; kind: string; predicate: string; value: string; due?: string; done: boolean; validFrom: string; invalidatedAt?: string; status: string; quote: string; episodeID: string }[]; openCommitmentsToPerson: PersonPage["openCommitmentsByPerson"]; facts: PersonPage["openCommitmentsByPerson"] }
export interface BrainNudge { id: string; title: string; detail: string; personName?: string }
export interface BrainPromise { fact: PersonPage["openCommitmentsByPerson"][number]; otherPartyName?: string; iOwe: boolean }
export interface ProjectFile { id: string; name: string; size: number; type: string; relativePath: string; text: string; includeInBrain: boolean }
export interface Project { id: string; name: string; instructions: string; files: ProjectFile[]; includeInBrain: boolean; createdAt: string; updatedAt: string; chatIDs: string[] }
export type RoutineSchedule = { everyDay: object } | { weekdays: object } | { weekly: { weekday: number } } | { monthly: { day: number } } | { once: object };
export type RoutineScope = "wholeBrain" | { project: string } | "libraryOnly";
export type RoutineDelivery = "notificationAndJournal" | "notificationOnly" | "journalOnly";
export interface RoutineRun { id: string; date: string; success: boolean; result: string }
export interface Routine { id: string; name: string; prompt: string; schedule: RoutineSchedule; hour: number; minute: number; onceDate?: string; scope: RoutineScope; delivery: RoutineDelivery; enabled: boolean; lastRun?: string; nextRun?: string; history: RoutineRun[] }
export interface ChatMessage { id?: string; role: "user" | "assistant" | "tool"; text: string; sources: string[]; date?: string; prompt?: string; sourceHashes?: Record<string, string> }
export interface ChatThread { id: string; title: string; created?: string; updated?: string; messages: ChatMessage[] }
export interface AssistantProfile { assistantName: string; emoji: string; userName: string; callMe: string; aboutUser: string; style: string; useEmoji?: boolean; step: number }
export interface AssistantState { profile: AssistantProfile; thread_id: string; opening: string }
export interface ResearchPreferences { enabled: boolean; pages: number; searxng_url: string; exa_key: string }
export interface EngineSettings { model_path: string; llama_server_path?: string; whisper_model_path?: string; whisper_path?: string; style: string; server_args: string[]; folder: string }
export interface ModelHealth { ready: boolean; last_ok?: string; last_error?: string }

export type CollectionKind = "library" | "articles" | "movies";
export type CollectionMediaType = "movie" | "show" | "youtube" | "podcast" | "talk";
export type CollectionBookFormat = "print" | "ebook" | "audiobook";
export interface CollectionHighlight { id: string; text: string; location?: string }
export interface CollectionItem { id: string; kind: CollectionKind; title: string; creator: string; year?: number; coverFile?: string; coverSeed: number; source: string; url: string; format: CollectionBookFormat; type: CollectionMediaType; notes: string; highlights: CollectionHighlight[]; includeInBrain: boolean; readingStart?: string; readingEnd?: string; readingNow: boolean; watchedDates: string[]; createdAt: string; updatedAt: string }
export interface CollectionImportPreview { source: string; items: CollectionItem[]; warnings: string[] }
export interface Trip { id: string; title: string; place: string; startDate: string; endDate: string; coverColor: string; coverFile?: string; places: string[]; peopleMet: string[]; notes: string; photos: string[]; includeInBrain: boolean; createdAt: string; updatedAt: string }
export type JournalEntryKind = "daily" | "voice" | "decision" | "weekly" | "routine";
export interface JournalEntry { id: string; date: string; kind: JournalEntryKind; text: string; voiceMemo: string; decisionTitle: string; decisionWhy: string; decisionExpectation: string; decisionShapedBy: { sourceID: string; kind: string; title: string }[]; checkBackDate?: string; includeInBrain: boolean; createdAt: string; updatedAt: string; summary: string; summaryKey: string }
export interface JournalActivity { day: string; meetings: { title: string; notes: string }[]; chats: { questions: string[] }[]; items: { kind: string; title: string; creator: string; notes: string }[]; trips: { title: string; place: string; notes: string }[]; is_empty: boolean; headline: string; key: string }
export interface JournalDaySummary { day: string; entry: JournalEntry }
export interface JournalDayData { day: string; entry: JournalEntry; others: JournalEntry[]; activity: JournalActivity }
