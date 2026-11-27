import SwiftUI

/// Where an extension's sidebar row sits: with Home and Meetings at the top, or at the bottom (like an account row).
public enum SidebarPlacement: Sendable {
    case top, bottom
}

/// A tab that an app built on InferoidNotesKit can add to the main sidebar.
public struct SidebarItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let view: AnyView
    public let placement: SidebarPlacement

    public init(id: String, title: String, systemImage: String, view: AnyView, placement: SidebarPlacement = .top) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.view = view
        self.placement = placement
    }
}

/// An action the chat can ask to run. The model requests it with a fenced ```action block; the user must Approve
/// before `handler` runs. The handler's text is shown in the conversation.
public struct ChatTool {
    public let name: String
    public let description: String
    /// Plain words for the arguments, e.g. `template (intake-classifier | follow-up-draft), name, target`.
    public let argumentsHint: String
    public let handler: @MainActor ([String: String]) async throws -> String

    public init(name: String, description: String, argumentsHint: String,
                handler: @escaping @MainActor ([String: String]) async throws -> String) {
        self.name = name
        self.description = description
        self.argumentsHint = argumentsHint
        self.handler = handler
    }
}

/// Pauses recording and chat (for example while an app built on the kit needs the person to sign in). Saved meetings,
/// notes and transcripts stay readable and can still be copied or exported.
public struct KitLock {
    public let message: String
    public let actionTitle: String
    public let action: @MainActor () -> Void

    public init(message: String, actionTitle: String, action: @escaping @MainActor () -> Void) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// A saved meeting as plain values, for extensions that send it somewhere.
public struct SavedMeetingInfo: Sendable {
    public let folder: URL
    public let title: String
    public let started: Date?
    public let durationSeconds: Int
    public let attendeeNames: [String]
    public let attendeeEmails: [String]
    /// notes.md as written (summary, decisions, action items, depending on the template).
    public let notesMarkdown: String
    public let transcriptMarkdown: String
    /// Recorded in private mode. Extensions should not send these anywhere automatically.
    public let privateMode: Bool

    /// Reads a meeting folder (notes.md, transcript.md, meta.json). Nil when the meeting has no notes.
    public init?(folder: URL) {
        guard let notes = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) else { return nil }
        let meta = (try? Data(contentsOf: folder.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        self.folder = folder
        self.notesMarkdown = notes
        self.transcriptMarkdown = (try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let heading = notes.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        self.title = heading ?? folder.lastPathComponent
        self.started = (meta["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        self.durationSeconds = meta["duration_s"] as? Int ?? 0
        self.attendeeNames = meta["attendees"] as? [String] ?? []
        self.attendeeEmails = meta["attendee_emails"] as? [String] ?? []
        self.privateMode = meta["privateMode"] as? Bool ?? false
    }
}

/// Something a person can do with a saved meeting, shown under "Send to" on the meeting. The handler's text is shown
/// to the person when it finishes (for example "Sent to Notion").
public struct MeetingAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let handler: @MainActor (SavedMeetingInfo) async throws -> String

    public init(id: String, title: String, systemImage: String,
                handler: @escaping @MainActor (SavedMeetingInfo) async throws -> String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.handler = handler
    }
}

/// Process-local registry for tabs, the Home status card and chat tools supplied by the executable using the kit.
@MainActor
public enum InferoidExtensions {
    private static var items: [SidebarItem] = []
    private static var tools: [ChatTool] = []
    private static var actions: [MeetingAction] = []
    private static var savedHandlers: [@MainActor (SavedMeetingInfo) -> Void] = []

    /// When set, recording and chat don't start and show `message`; everything saved stays readable.
    public static var lock: KitLock?

    public static var meetingActions: [MeetingAction] { actions }

    public static func registerMeetingAction(_ action: MeetingAction) {
        actions.removeAll { $0.id == action.id }
        actions.append(action)
    }

    /// Called on the main actor after a recorded meeting's notes are saved.
    public static func onMeetingSaved(_ handler: @escaping @MainActor (SavedMeetingInfo) -> Void) {
        savedHandlers.append(handler)
    }

    static func meetingSaved(folder: URL) {
        guard let info = SavedMeetingInfo(folder: folder) else { return }
        for handler in savedHandlers { handler(info) }
    }

    /// Shown at the top of Home when set (for example: plan, setup checklist).
    public static var homeStatus: AnyView?

    public static var sidebarItems: [SidebarItem] { items }
    public static var topItems: [SidebarItem] { items.filter { $0.placement == .top } }
    public static var bottomItems: [SidebarItem] { items.filter { $0.placement == .bottom } }
    public static var chatTools: [ChatTool] { tools }

    public static func register(_ item: SidebarItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    public static func registerChatTool(_ tool: ChatTool) {
        tools.removeAll { $0.name == tool.name }
        tools.append(tool)
    }

    public static func view(for id: String) -> AnyView? {
        items.first { $0.id == id }?.view
    }

    static func tool(named name: String) -> ChatTool? {
        tools.first { $0.name == name }
    }
}
