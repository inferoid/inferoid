import SwiftUI

/// A tab that an app built on InferoidNotesKit can add to the main sidebar.
public struct SidebarItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let view: AnyView

    public init(id: String, title: String, systemImage: String, view: AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.view = view
    }
}

/// Process-local registry for tabs supplied by the executable using the kit.
@MainActor
public enum InferoidExtensions {
    private static var items: [SidebarItem] = []

    public static var sidebarItems: [SidebarItem] { items }

    public static func register(_ item: SidebarItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    public static func view(for id: String) -> AnyView? {
        items.first { $0.id == id }?.view
    }
}
