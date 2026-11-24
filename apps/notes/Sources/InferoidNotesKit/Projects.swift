import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

public struct ProjectFile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var size: Int64
    public var type: String
    public var relativePath: String
    public var text: String
    public var includeInBrain: Bool

    public init(id: UUID = UUID(), name: String, size: Int64, type: String, relativePath: String,
                text: String, includeInBrain: Bool = true) {
        self.id = id; self.name = name; self.size = size; self.type = type
        self.relativePath = relativePath; self.text = text; self.includeInBrain = includeInBrain
    }

    private enum CodingKeys: String, CodingKey { case id, name, size, type, relativePath, text, includeInBrain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath) ?? name
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        includeInBrain = try c.decodeIfPresent(Bool.self, forKey: .includeInBrain) ?? true
    }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var instructions: String
    public var files: [ProjectFile]
    public var includeInBrain: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var chatIDs: [UUID]

    /// Compatibility for callers that only know about the first project chat.
    /// New project data is encoded using `chatIDs`.
    public var chatID: UUID {
        get { chatIDs.first ?? UUID() }
        set { chatIDs = [newValue] + chatIDs.dropFirst() }
    }

    public init(id: UUID = UUID(), name: String, instructions: String = "", files: [ProjectFile] = [],
                includeInBrain: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date(),
                chatIDs: [UUID] = [], chatID: UUID? = nil) {
        self.id = id; self.name = name; self.instructions = instructions; self.files = files
        self.includeInBrain = includeInBrain; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.chatIDs = chatID.map { [$0] } ?? chatIDs
    }

    private enum CodingKeys: String, CodingKey { case id, name, instructions, files, includeInBrain, createdAt, updatedAt, chatIDs, chatID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        files = try c.decodeIfPresent([ProjectFile].self, forKey: .files) ?? []
        includeInBrain = try c.decodeIfPresent(Bool.self, forKey: .includeInBrain) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        if let ids = try c.decodeIfPresent([UUID].self, forKey: .chatIDs), !ids.isEmpty {
            chatIDs = ids
        } else if let oldID = try c.decodeIfPresent(UUID.self, forKey: .chatID) {
            chatIDs = [oldID]
        } else {
            chatIDs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(files, forKey: .files)
        try c.encode(includeInBrain, forKey: .includeInBrain)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(chatIDs, forKey: .chatIDs)
    }
}

public enum ProjectFileReader {
    public static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "kts", "sh", "zsh", "bash", "html", "css", "scss",
        "sql", "toml", "ini", "conf", "log", "pdf"
    ]

    public static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    public static func read(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw ProjectStoreError.unsupportedFile(url.lastPathComponent) }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum ProjectStoreError: LocalizedError, Equatable {
    case unsupportedFile(String), invalidName, missingProject

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): return "This file type is not supported: \(name)"
        case .invalidName: return "A project needs a name."
        case .missingProject: return "The project is no longer available."
        }
    }
}

@MainActor
public final class ProjectStore: ObservableObject {
    public static let shared = ProjectStore()
    @Published public private(set) var projects: [Project] = []
    @Published public var error: String?

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = InferoidPaths.support.appendingPathComponent("Projects", isDirectory: true)) {
        self.root = root
        self.encoder = JSONEncoder(); self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601; self.decoder.dateDecodingStrategy = .iso8601
        load()
    }

    public func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = files.compactMap { folder in
            guard folder.hasDirectoryPath else { return nil }
            let file = folder.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: file), let project = try? decoder.decode(Project.self, from: data) else { return nil }
            return project
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func create(name: String, instructions: String = "") throws -> Project {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectStoreError.invalidName }
        var project = Project(name: clean, instructions: instructions, includeInBrain: !PrivateMode.isEnabled)
        try save(project)
        projects.insert(project, at: 0)
        return project
    }

    public func update(_ project: Project) throws {
        var updated = project; updated.updatedAt = Date()
        try save(updated)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = updated }
    }

    public func setIncludeInBrain(_ included: Bool, projectID: UUID) throws {
        guard var project = projects.first(where: { $0.id == projectID }) else { throw ProjectStoreError.missingProject }
        project.includeInBrain = included
        try update(project)
        updateBrain(for: project)
    }

    public func setIncludeInBrain(_ included: Bool, projectID: UUID, fileID: UUID) throws {
        guard var project = projects.first(where: { $0.id == projectID }),
              let index = project.files.firstIndex(where: { $0.id == fileID }) else { throw ProjectStoreError.missingProject }
        project.files[index].includeInBrain = included
        try update(project)
        updateBrain(for: project)
    }

    @discardableResult
    public func addFile(_ url: URL, to projectID: UUID) throws -> ProjectFile {
        guard ProjectFileReader.isSupported(url) else { throw ProjectStoreError.unsupportedFile(url.lastPathComponent) }
        guard var project = projects.first(where: { $0.id == projectID }) else { throw ProjectStoreError.missingProject }
        let text = try ProjectFileReader.read(url)
        let id = UUID()
        let relative = "files/\(id.uuidString)-\(url.lastPathComponent)"
        let folder = root.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(relative))
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        let file = ProjectFile(name: url.lastPathComponent, size: size, type: url.pathExtension.lowercased(), relativePath: relative,
                               text: text, includeInBrain: !PrivateMode.isEnabled)
        project.files.append(file)
        try update(project)
        updateBrain(for: project)
        return file
    }

    public func removeFile(_ fileID: UUID, from projectID: UUID) throws {
        guard var project = projects.first(where: { $0.id == projectID }), let fileIndex = project.files.firstIndex(where: { $0.id == fileID }) else {
            throw ProjectStoreError.missingProject
        }
        let file = project.files.remove(at: fileIndex)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(project.id.uuidString).appendingPathComponent(file.relativePath))
        try update(project)
        updateBrain(for: project)
    }

    public func delete(_ projectID: UUID) throws {
        guard let project = projects.first(where: { $0.id == projectID }) else { throw ProjectStoreError.missingProject }
        for chatID in project.chatIDs { ChatStore.shared.delete(chatID) }
        if let brain = try? BrainStore() { try? brain.removeMeetingData(meetingFolder: URL(fileURLWithPath: "project:\(projectID.uuidString)")) }
        try FileManager.default.trashItem(at: root.appendingPathComponent(projectID.uuidString), resultingItemURL: nil)
        projects.removeAll { $0.id == projectID }
    }

    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    @discardableResult
    public func createChat(in projectID: UUID, chatStore: ChatStore = .shared) throws -> UUID {
        guard var project = projects.first(where: { $0.id == projectID }) else { throw ProjectStoreError.missingProject }
        let id = chatStore.newThread(id: UUID())
        project.chatIDs.append(id)
        try update(project)
        return id
    }

    public func deleteChat(_ chatID: UUID, from projectID: UUID, chatStore: ChatStore = .shared) throws {
        guard var project = projects.first(where: { $0.id == projectID }) else { throw ProjectStoreError.missingProject }
        project.chatIDs.removeAll { $0 == chatID }
        try update(project)
        chatStore.delete(chatID)
    }

    nonisolated public static func documents(for project: Project, includedOnly: Bool = false) -> [BrainSourceDocument] {
        guard !includedOnly || project.includeInBrain else { return [] }
        let documents = project.files.enumerated().compactMap { index, file -> BrainSourceDocument? in
            guard !includedOnly || file.includeInBrain else { return nil }
            let instructions = index == 0 && !project.instructions.isEmpty ? "\n\(project.instructions)\n" : ""
            return BrainSourceDocument(id: "project:\(project.id.uuidString):\(file.id.uuidString)", kind: .project,
                                       title: "\(project.name) · \(file.name)", date: project.updatedAt.iso8601,
                                       chunks: Brain.chunks(instructions + file.text), includeInBrain: project.includeInBrain && file.includeInBrain)
        }
        if documents.isEmpty {
            return [BrainSourceDocument(id: "project:\(project.id.uuidString)", kind: .project, title: project.name,
                                        date: project.updatedAt.iso8601, chunks: Brain.chunks(project.instructions),
                                        includeInBrain: project.includeInBrain)]
        }
        return documents
    }

    private func save(_ project: Project) throws {
        let folder = root.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(project).write(to: folder.appendingPathComponent("project.json"), options: .atomic)
    }

    private func updateBrain(for project: Project) {
        guard let model = NotesConfig.defaultModel, let brain = try? BrainStore() else { return }
        Task { @MainActor in
            try? brain.removeMeetingData(meetingFolder: URL(fileURLWithPath: "project:\(project.id.uuidString)"))
            if project.includeInBrain { _ = await BrainExtraction.processProject(project, model: model, store: brain) }
            ModelManager.shared.idle()
        }
    }
}

public extension Date {
    var iso8601: String { ISO8601DateFormatter().string(from: self) }
}

public enum PrivateMode {
    private static let key = "privateMode"
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
    public static func setEnabled(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: key) }
}

struct ProjectsView: View {
    @ObservedObject private var store = ProjectStore.shared
    @Binding var pane: Pane?
    @State private var creating = false
    @State private var name = ""
    @State private var instructions = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Projects").font(.largeTitle.bold())
                    Spacer()
                    Button("New project") { name = ""; instructions = ""; creating = true }
                        .buttonStyle(.borderedProminent)
                }
                Text("Keep files and instructions together for focused chats.").foregroundStyle(.secondary)
                if store.projects.isEmpty {
                    Text("Your projects will appear here, stored on this Mac.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(store.projects) { project in
                            Button { pane = .project(project.id) } label: { ProjectRow(project: project) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Projects")
        .alert("New project", isPresented: $creating) {
            TextField("Name", text: $name)
            TextField("Instructions (optional)", text: $instructions)
            Button("Create") {
                if let project = try? store.create(name: name, instructions: instructions) { pane = .project(project.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Spacer()
                Image(systemName: project.includeInBrain ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(project.includeInBrain ? Color.accentColor : Color.secondary)
            }
            Text(project.name).font(.headline).lineLimit(2)
            Text("\(project.chatIDs.count) chat\(project.chatIDs.count == 1 ? "" : "s") · \(project.files.count) file\(project.files.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

struct ProjectView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var chats = ChatStore.shared
    let projectID: UUID
    @Binding var pane: Pane?
    @State private var draft = ""
    @State private var importing = false
    @State private var dropTarget = false
    @State private var editingInstructions = false
    @State private var confirmingDelete = false

    private var project: Project? { store.project(projectID) }

    var body: some View {
        if let project { projectPage(project) } else { Text("Project not found").padding(28) }
    }

    private func projectPage(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Projects") { pane = .projects }.buttonStyle(.link)
                Text("/").foregroundStyle(.secondary)
                Text(project.name).foregroundStyle(.secondary)
                Spacer()
                Button("Delete project", role: .destructive) { confirmingDelete = true }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 16)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 34) {
                    projectMain(project)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    projectSidebar(project)
                        .frame(width: 320, alignment: .topLeading)
                }
                .padding(28)
                .frame(maxWidth: 1280, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle(project.name)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { add($0, to: project) }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { drop($0, into: project) }
        .confirmationDialog("Delete this project? Its copied files and chats move to the Trash.", isPresented: $confirmingDelete) {
            Button("Delete project", role: .destructive) { try? store.delete(project.id); pane = .projects }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingInstructions) {
            ProjectInstructionsEditor(project: project) { value in updateInstructions(value, for: project) }
        }
    }

    private func projectMain(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(project.name).font(.system(size: 38, weight: .semibold, design: .serif))
            ProjectComposer(projectName: project.name, draft: $draft, importing: $importing, send: { send($0, in: project) })
            VStack(alignment: .leading, spacing: 10) {
                Text("CHATS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                let projectChats = project.chatIDs.compactMap { chats.thread($0) }.sorted { $0.updated > $1.updated }
                if projectChats.isEmpty {
                    Text("Your project chats will appear here.").foregroundStyle(.secondary).padding(.top, 4)
                } else {
                    ForEach(projectChats) { thread in
                        Button { pane = .projectChat(project.id, thread.id) } label: {
                            ProjectChatRow(thread: thread) { try? store.deleteChat(thread.id, from: project.id) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete chat", role: .destructive) { try? store.deleteChat(thread.id, from: project.id) } }
                    }
                }
            }
        }
    }

    private func projectSidebar(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectInstructionsSection(project: project, edit: { editingInstructions = true })
            Divider().padding(.vertical, 22)
            ProjectFilesSection(project: project, importing: $importing, dropTarget: dropTarget)
            Divider().padding(.vertical, 22)
            Toggle("Include in Brain", isOn: Binding(get: { project.includeInBrain }, set: { try? store.setIncludeInBrain($0, projectID: project.id) }))
            Text("Off: only this project's chats use these files.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            Spacer(minLength: 28)
            Label("Stored only on this Mac", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send(_ text: String, in project: Project) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let id = try? store.createChat(in: project.id) else { return }
        draft = ""
        pane = .projectChat(project.id, id)
        ChatStore.shared.send(question, in: id, model: rec.model, meetings: rec.meetings,
                              projects: store.projects, project: project)
    }

    private func updateInstructions(_ value: String, for project: Project) {
        var changed = project
        changed.instructions = value
        try? store.update(changed)
    }

    private func drop(_ providers: [NSItemProvider], into project: Project) -> Bool {
        for provider in providers {
            provider.loadObject(ofClass: NSURL.self) { value, _ in
                guard let url = value as? URL else { return }
                Task { @MainActor in try? store.addFile(url, to: project.id) }
            }
        }
        return true
    }

    private func add(_ result: Result<[URL], Error>, to project: Project) {
        guard case .success(let urls) = result else { return }
        for url in urls { try? store.addFile(url, to: project.id) }
    }
}

struct ProjectComposer: View {
    let projectName: String
    var placeholder: String? = nil
    var showsAttach = true
    @Binding var draft: String
    @Binding var importing: Bool
    let send: (String) -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder ?? "New chat in \(projectName)").foregroundStyle(.tertiary)
                        .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body).scrollContentBackground(.hidden).background(Color.clear)
                    .focused($focused)
                    .frame(minHeight: 54, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if canSend { send(draft) }
                        return .handled
                    }
            }
            HStack {
                if showsAttach {
                    Button { importing = true } label: { Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderless).help("Add files to the project")
                }
                Spacer()
                Button { send(draft) } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(!canSend).help("Start chat (Return). Shift-Return for a new line.")
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

struct ProjectChatRow: View {
    let thread: ChatThread
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title).font(.body.weight(.medium)).lineLimit(1)
                Text(thread.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hovering {
                Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete chat")
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ProjectInstructionsSection: View {
    let project: Project
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Instructions").font(.headline); Spacer(); Button("Edit", action: edit).buttonStyle(.link) }
            Text(project.instructions.isEmpty ? "No project instructions yet." : project.instructions)
                .font(.callout).foregroundStyle(project.instructions.isEmpty ? .secondary : .primary)
                .lineLimit(5).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectFilesSection: View {
    let project: Project
    @Binding var importing: Bool
    let dropTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files").font(.headline)
                Text("\(project.files.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add") { importing = true }.buttonStyle(.bordered)
            }
            ForEach(project.files) { file in ProjectFileRow(project: project, file: file) }
            HStack {
                Image(systemName: "arrow.down.doc")
                Text("Drop files here").font(.callout)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropTarget ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
    }
}

private struct ProjectInstructionsEditor: View {
    let project: Project
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(project: Project, save: @escaping (String) -> Void) {
        self.project = project
        self.save = save
        _text = State(initialValue: project.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Instructions").font(.title2.bold())
            TextEditor(text: $text).font(.body).frame(minHeight: 180)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(text); dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(24).frame(width: 520)
    }
}

private struct ProjectFileRow: View {
    @ObservedObject private var store = ProjectStore.shared
    let project: Project
    let file: ProjectFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.type.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Include in Brain", isOn: Binding(get: { file.includeInBrain }, set: { try? store.setIncludeInBrain($0, projectID: project.id, fileID: file.id) }))
                .labelsHidden().toggleStyle(.checkbox).help("Include in Brain")
            Button { try? store.removeFile(file.id, from: project.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Remove file")
        }
        .padding(.vertical, 5)
    }
}
