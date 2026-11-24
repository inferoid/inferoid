import XCTest
@testable import InferoidNotesKit

final class ProjectTests: XCTestCase {
    func testOldProjectDataDecodesWithNewDefaults() throws {
        let data = Data(#"{"name":"Old notes","files":[{"name":"old.txt","text":"old"}]}"#.utf8)
        let project = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(project.name, "Old notes")
        XCTAssertEqual(project.instructions, "")
        XCTAssertEqual(project.files.first?.name, "old.txt")
        XCTAssertTrue(project.files.first?.includeInBrain ?? false)
        XCTAssertFalse(project.includeInBrain)
        XCTAssertTrue(project.chatIDs.isEmpty)
    }

    func testOldProjectChatIDMigratesToChatIDs() throws {
        let oldID = try XCTUnwrap(UUID(uuidString: "8C1D2E7A-9F5B-4C2E-8D1A-2B3C4D5E6F72"))
        let data = Data("{\"name\":\"Old chat\",\"chatID\":\"\(oldID.uuidString)\"}".utf8)
        let project = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(project.chatIDs, [oldID])
        XCTAssertEqual(project.chatID, oldID)
    }

    @MainActor func testCreatingAndDeletingProjectChatUpdatesProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-project-chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let project = try store.create(name: "Chat project")

        let chatID = try store.createChat(in: project.id)
        XCTAssertEqual(store.project(project.id)?.chatIDs.last, chatID)
        XCTAssertNotNil(ChatStore.shared.thread(chatID))

        try store.deleteChat(chatID, from: project.id)
        XCTAssertFalse(store.project(project.id)?.chatIDs.contains(chatID) ?? true)
        XCTAssertNil(ChatStore.shared.thread(chatID))
    }

    @MainActor func testProjectStorageCopiesAndLoadsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-project-\(UUID().uuidString)")
        let input = root.appendingPathComponent("notes.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "The local launch plan".write(to: input, atomically: true, encoding: .utf8)

        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let project = try store.create(name: "Launch")
        let file = try store.addFile(input, to: project.id)
        XCTAssertEqual(file.text, "The local launch plan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects").appendingPathComponent(project.id.uuidString).appendingPathComponent(file.relativePath).path))

        let loaded = ProjectStore(root: root.appendingPathComponent("Projects")).project(project.id)
        XCTAssertEqual(loaded?.files.first?.name, "notes.md")
        XCTAssertEqual(loaded?.files.first?.text, "The local launch plan")
    }

    @MainActor func testProjectBrainInclusionAndExclusion() {
        let project = Project(name: "Plans",
                              files: [ProjectFile(name: "plan.md", size: 12, type: "md", relativePath: "plan.md", text: "secret launch plan")],
                              includeInBrain: true)
        let included = ProjectStore.documents(for: project, includedOnly: true)
        XCTAssertEqual(Brain.searchSources("launch", in: included).map(\.sourceID).count, 1)

        var excluded = project
        excluded.includeInBrain = false
        XCTAssertTrue(Brain.searchSources("launch", in: ProjectStore.documents(for: excluded, includedOnly: true)).isEmpty)
        XCTAssertTrue(Brain.searchSources("launch", in: ProjectStore.documents(for: excluded, includedOnly: false)).isEmpty)
    }

    @MainActor func testPrivateModeDisablesNewProjectsAndFiles() throws {
        let previous = PrivateMode.isEnabled
        defer { PrivateMode.setEnabled(previous) }
        PrivateMode.setEnabled(true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-private-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("private.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "private".write(to: input, atomically: true, encoding: .utf8)
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let project = try store.create(name: "Private")
        let file = try store.addFile(input, to: project.id)
        XCTAssertFalse(project.includeInBrain)
        XCTAssertFalse(file.includeInBrain)
    }
}
