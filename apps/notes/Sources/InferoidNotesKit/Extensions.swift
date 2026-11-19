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

/// Process-local registry for tabs, the Home status card and chat tools supplied by the executable using the kit.
@MainActor
public enum InferoidExtensions {
    private static var items: [SidebarItem] = []
    private static var tools: [ChatTool] = []

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
