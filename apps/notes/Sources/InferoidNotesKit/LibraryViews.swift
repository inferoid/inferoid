import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CollectionImportPreview: Identifiable {
    let id = UUID()
    let source: String
    let items: [CollectionItem]
    let warnings: [String]
}

enum CollectionImportParser {
    static func kindle(_ text: String) -> CollectionImportPreview {
        var items: [CollectionItem] = []
        var warnings: [String] = []
        for block in text.components(separatedBy: "==========") {
            let lines = block.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let first = lines.first, let marker = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("Your Highlight") || $0.localizedCaseInsensitiveContains("Your Note") }) else { continue }
            let title = first.replacingOccurrences(of: "^Book Title: ", with: "", options: .regularExpression)
            // The metadata line ("- Your Highlight on page 12 | location 120-125 | Added on ...") carries the location.
            let location = kindleLocation(lines[marker])
            let passage = lines.dropFirst(marker + 1).filter { !$0.lowercased().hasPrefix("location ") }
            let quote = passage.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !quote.isEmpty else { warnings.append("One clipping was missing a title or passage."); continue }
            if let i = items.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                items[i].highlights.append(CollectionHighlight(text: quote, location: location))
            } else {
                var item = CollectionItem(kind: .library, title: title)
                item.highlights = [CollectionHighlight(text: quote, location: location)]
                items.append(item)
            }
        }
        return CollectionImportPreview(source: "Kindle My Clippings.txt", items: items, warnings: warnings)
    }

    static func kindleLocation(_ metadata: String) -> String? {
        guard let range = metadata.range(of: #"location\s+([0-9]+(?:-[0-9]+)?)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = metadata[range].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        return value.isEmpty ? nil : "Location \(value)"
    }

    static func goodreads(_ text: String) -> CollectionImportPreview {
        let rows = csv(text)
        guard let header = rows.first else { return CollectionImportPreview(source: "Goodreads CSV", items: [], warnings: ["The file has no header row."]) }
        let columns = header.enumerated().reduce(into: [String: Int]()) { result, pair in result[normalize(pair.element)] = pair.offset }
        func value(_ row: [String], _ names: [String]) -> String { names.compactMap { columns[normalize($0)] }.compactMap { $0 < row.count ? row[$0] : nil }.first ?? "" }
        var items: [CollectionItem] = []
        for row in rows.dropFirst() {
            let title = value(row, ["Title"]); guard !title.isEmpty else { continue }
            var item = CollectionItem(kind: .library, title: title, creator: value(row, ["Author", "Author l-f"]), year: Int(value(row, ["Original Publication Year"])))
            if let date = parseDate(value(row, ["Date Read"])) { item.readingStart = date; item.readingEnd = date }
            items.append(item)
        }
        return CollectionImportPreview(source: "Goodreads CSV", items: items, warnings: [])
    }

    static func letterboxd(_ text: String) -> CollectionImportPreview {
        let rows = csv(text)
        guard let header = rows.first else { return CollectionImportPreview(source: "Letterboxd CSV", items: [], warnings: ["The file has no header row."]) }
        let columns = header.enumerated().reduce(into: [String: Int]()) { result, pair in result[normalize(pair.element)] = pair.offset }
        func value(_ row: [String], _ names: [String]) -> String { names.compactMap { columns[normalize($0)] }.compactMap { $0 < row.count ? row[$0] : nil }.first ?? "" }
        let items = rows.dropFirst().compactMap { row -> CollectionItem? in
            let title = value(row, ["Name", "Title"]); guard !title.isEmpty else { return nil }
            var item = CollectionItem(kind: .movies, title: title, year: Int(value(row, ["Year"])))
            if let date = parseDate(value(row, ["Watched Date", "Date"])) { item.watchedDates = [date] }
            return item
        }
        return CollectionImportPreview(source: "Letterboxd CSV", items: items, warnings: [])
    }

    private static func normalize(_ value: String) -> String { value.replacingOccurrences(of: "\u{feff}", with: "").lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func parseDate(_ value: String) -> Date? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["yyyy/MM/dd", "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let date = f.date(from: clean) { return date }
        }
        return ISO8601DateFormatter().date(from: clean)
    }
    private static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = [[]], field = "", quoted = false
        var characters = Array(text)
        while !characters.isEmpty {
            let c = characters.removeFirst()
            if c == "\"" { if quoted, characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted.toggle() } }
            else if c == "," && !quoted { rows[rows.count - 1].append(field); field = "" }
            else if (c == "\n" || c == "\r") && !quoted { if c == "\r", characters.first == "\n" { characters.removeFirst() }; rows[rows.count - 1].append(field); field = ""; rows.append([]) }
            else { field.append(c) }
        }
        rows[rows.count - 1].append(field)
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
}

struct CollectionView: View {
    @EnvironmentObject var rec: Recorder
    let kind: CollectionKind
    @Binding var pane: Pane?
    @State private var items: [CollectionItem] = []
    @State private var preview: CollectionImportPreview?
    @State private var error: String?
    @State private var mediaFilter: CollectionMediaType?
    @State private var addingLink = false
    @State private var linkText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(kind.title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }
                    Spacer(); Button("Add by link") { linkText = ""; addingLink = true }.buttonStyle(.borderedProminent)
                    Menu("Import") {
                        if kind == .library { Button("Kindle My Clippings.txt") { pickText { preview = CollectionImportParser.kindle($0) } }; Button("Goodreads CSV") { pickText { preview = CollectionImportParser.goodreads($0) } } }
                        else if kind == .movies { Button("Letterboxd CSV") { pickText { preview = CollectionImportParser.letterboxd($0) } } }
                    }
                }
                if kind == .movies { mediaFilters }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if items.isEmpty { Text("Nothing here yet. Add an item or import a local file.").foregroundStyle(.secondary).padding(.top, 20) }
                else if visibleItems.isEmpty { Text("No media matches this filter.").foregroundStyle(.secondary).padding(.top, 20) }
                else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) { ForEach(visibleItems) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { pane = .content(sourceKind(for: item), item.id.uuidString) } label: { CollectionCard(item: item) }.buttonStyle(.plain)
                        if let url = CollectionLinkParser.normalize(item.url) { Link("Open link", destination: url).font(.caption).padding(.leading, 4) }
                    }
                } } }
                Label("Stored only on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(kind.title).onAppear { reload() }
        .onDrop(of: [UTType.url.identifier, UTType.plainText.identifier], isTargeted: nil) { providers in
            receiveLinkDrop(providers)
        }
        .sheet(item: $preview) { value in ImportPreviewView(preview: value) { importItems(value.items); preview = nil } }
        .sheet(isPresented: $addingLink) {
            CollectionLinkSheet(initialURL: linkText) { item in
                addingLink = false
                reload()
                pane = .content(sourceKind(for: item), item.id.uuidString)
            }
        }
    }
    private var visibleItems: [CollectionItem] { guard kind == .movies, let mediaFilter else { return items }; return items.filter { $0.mediaType == mediaFilter } }
    private var mediaFilters: some View { ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { filterChip(nil, title: "All"); ForEach(CollectionMediaType.allCases, id: \.self) { filterChip($0, title: $0.title) } } } }
    private func filterChip(_ value: CollectionMediaType?, title: String) -> some View { Button(title) { mediaFilter = value }.buttonStyle(.bordered).tint(mediaFilter == value ? .accentColor : .secondary) }
    private var subtitle: String { kind == .library ? "Books, notes and highlights." : (kind == .articles ? "Saved articles, sources and highlights." : "Movies, shows, videos, podcasts and talks.") }
    private func reload() { items = CollectionStore.load(kind) }
    private func add() { let item = CollectionItem(kind: kind); do { try CollectionStore.save(item); reload(); pane = .content(sourceKind(for: item), item.id.uuidString) } catch let caught { self.error = caught.localizedDescription } }
    private func receiveLinkDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSURL.self) {
            provider.loadObject(ofClass: NSURL.self) { value, _ in
                guard let url = value as? URL else { return }
                DispatchQueue.main.async { linkText = url.absoluteString; addingLink = true }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { linkText = text; addingLink = true }
        }
        return true
    }
    private func importItems(_ imported: [CollectionItem]) {
        do {
            for item in imported { try CollectionStore.save(item) }
            reload()
            let included = imported.filter(\.includeInBrain)
            if !included.isEmpty {
                Task {
                    for item in included { _ = await BrainContent.refresh(folder: CollectionStore.folder(for: item), model: rec.model) }
                    await MainActor.run { rec.reloadMeetings() }
                }
            }
        } catch let caught { self.error = caught.localizedDescription }
    }
    private func pickText(_ completion: @escaping (String) -> Void) { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) { completion(text) } }
}

struct LibraryView: View {
    /// The tab to show when the Library opens again, so a saved item is visible in its own tab.
    static var lastTab: CollectionKind = .library
    @Binding var pane: Pane?
    @State private var tab: CollectionKind = LibraryView.lastTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $tab) {
                Text("Books").tag(CollectionKind.library)
                Text("Articles").tag(CollectionKind.articles)
                Text("Media").tag(CollectionKind.movies)
            }.pickerStyle(.segmented).padding(.horizontal, 28).padding(.top, 18)
            CollectionView(kind: tab, pane: $pane).id(tab)
        }.navigationTitle("Library")
        .onChange(of: tab) { _, value in LibraryView.lastTab = value }
    }
}

private func sourceKind(for item: CollectionItem) -> BrainSourceKind {
    switch item.kind { case .library: return .library; case .articles: return .article; case .movies: return .movies }
}

private struct CollectionCard: View {
    let item: CollectionItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { CoverView(item: item).frame(height: 205); Text(item.title.isEmpty ? "Untitled" : item.title).font(.headline).lineLimit(2); Text(item.kind == .articles ? item.source : item.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1); HStack { if item.kind == .library { badge(item.bookFormat.title) }; if item.kind == .movies { badge(item.mediaType.title) }; if !item.highlights.isEmpty { Label("\(item.highlights.count)", systemImage: "quote.opening") }; if !item.url.isEmpty { Image(systemName: "link") }; Spacer(); Image(systemName: item.includeInBrain ? "checkmark.square.fill" : "square").foregroundStyle(.secondary) }.font(.caption) }
        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }
    private func badge(_ value: String) -> some View { Text(value).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.accentColor.opacity(0.14))) }
}

private struct CoverView: View {
    let item: CollectionItem
    var body: some View {
        if let url = CollectionStore.coverURL(for: item), let image = NSImage(contentsOf: url) {
            Color.black.opacity(0.25)
                .overlay(Image(nsImage: image).resizable().scaledToFill())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else { GeneratedCover(title: item.title.isEmpty ? "Untitled" : item.title, seed: item.coverSeed) }
    }
}

private struct GeneratedCover: View {
    let title: String; let seed: Int
    var body: some View { ZStack { LinearGradient(colors: [Color(hue: Double(seed % 360) / 360, saturation: 0.62, brightness: 0.78), Color(hue: Double((seed / 7) % 360) / 360, saturation: 0.72, brightness: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing); Text(title).font(.title3.bold()).multilineTextAlignment(.center).foregroundStyle(.white).padding(14) }.clipShape(RoundedRectangle(cornerRadius: 8)) }
}

struct CollectionItemView: View {
    @EnvironmentObject var rec: Recorder
    let original: CollectionItem
    @Binding var pane: Pane?
    @State private var draft: CollectionItem
    @State private var highlightText = ""
    @State private var highlightLocation = ""
    @State private var confirmDelete = false
    @State private var saveError: String?
    init(item: CollectionItem, pane: Binding<Pane?>) { original = item; _pane = pane; _draft = State(initialValue: item) }
    private var coverSize: CGSize {
        guard draft.kind == .movies else { return CGSize(width: 170, height: 240) }
        switch draft.mediaType {
        case .youtube, .talk: return CGSize(width: 256, height: 144)
        case .podcast: return CGSize(width: 200, height: 200)
        case .movie, .show: return CGSize(width: 170, height: 240)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            linkField
            HStack(alignment: .top, spacing: 18) {
                CoverView(item: draft).frame(width: coverSize.width, height: coverSize.height).fixedSize()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: $draft.title).font(.title2.bold()).textFieldStyle(.plain)
                    Picker("Kind", selection: $draft.kind) { ForEach(CollectionKind.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 240)
                    metadataFields
                    if draft.kind != .articles { TextField("Year", text: Binding(get: { draft.year.map { String($0) } ?? "" }, set: { draft.year = Int($0) })).frame(width: 100) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if draft.kind == .library { libraryDates } else if draft.kind == .articles { articleDates } else { mediaDates }
            Toggle("Include in Brain", isOn: Binding(get: { draft.includeInBrain }, set: { value in setInclude(value) })).toggleStyle(.checkbox)
            if !draft.includeInBrain { Text("The Brain and chat won't use this item.").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) { Text("Notes").font(.headline); TextEditor(text: $draft.notes).font(.body).frame(minHeight: 150).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))) }
            highlights
        }.padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity) }
        Divider()
        HStack(spacing: 10) {
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete this item")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .navigationTitle(draft.title.isEmpty ? draft.kind.title : draft.title)
        .confirmationDialog("Delete this item? Its notes and Brain context move to the Trash.", isPresented: $confirmDelete) { Button("Delete", role: .destructive) { try? CollectionStore.delete(original); LibraryView.lastTab = original.kind; pane = .library }; Button("Cancel", role: .cancel) {} }
    }
    @ViewBuilder private var metadataFields: some View {
        if draft.kind == .articles { TextField("Source / site", text: $draft.source) }
        else { TextField(draft.kind.creatorLabel, text: $draft.creator) }
        if draft.kind == .library { Picker("Format", selection: $draft.bookFormat) { ForEach(CollectionBookFormat.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
        if draft.kind == .movies { Picker("Type", selection: $draft.mediaType) { ForEach(CollectionMediaType.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
    }
    private var libraryDates: some View { VStack(alignment: .leading, spacing: 8) { Text("Reading period").font(.headline); DatePicker("Started", selection: Binding(get: { draft.readingStart ?? Date() }, set: { draft.readingStart = $0 }), displayedComponents: .date); Toggle("Reading now", isOn: $draft.readingNow).toggleStyle(.checkbox); if !draft.readingNow { DatePicker("Finished", selection: Binding(get: { draft.readingEnd ?? draft.readingStart ?? Date() }, set: { draft.readingEnd = $0 }), displayedComponents: .date) } } }
    private var articleDates: some View { VStack(alignment: .leading, spacing: 8) { Text("Date read").font(.headline); DatePicker("Read on", selection: Binding(get: { draft.readingStart ?? Date() }, set: { draft.readingStart = $0; draft.readingEnd = $0 }), displayedComponents: .date) } }
    private var mediaDates: some View { VStack(alignment: .leading, spacing: 8) { Text("Watched / listened").font(.headline); ForEach(Array(draft.watchedDates.enumerated()), id: \.offset) { index, _ in HStack { DatePicker(index == 0 ? "Date" : "Again", selection: Binding(get: { draft.watchedDates[index] }, set: { draft.watchedDates[index] = $0 }), displayedComponents: .date); Button("Remove") { draft.watchedDates.remove(at: index) }.buttonStyle(.borderless) } }; Button("Add date") { draft.watchedDates.append(Date()) } } }
    private var highlights: some View { VStack(alignment: .leading, spacing: 10) { Text("Highlights").font(.headline); ForEach(draft.highlights) { highlight in HStack(alignment: .top) { Text("\u{201C}\(highlight.text)\u{201D}").textSelection(.enabled); if let location = highlight.location { Text(location).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Remove") { draft.highlights.removeAll { $0.id == highlight.id } }.buttonStyle(.borderless) } }; TextField("Quote or passage", text: $highlightText); HStack { TextField("Page or time (optional)", text: $highlightLocation); Button("Add highlight") { addHighlight() }.disabled(highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }
    private func addHighlight() { draft.highlights.append(CollectionHighlight(text: highlightText.trimmingCharacters(in: .whitespacesAndNewlines), location: highlightLocation.isEmpty ? nil : highlightLocation)); highlightText = ""; highlightLocation = "" }
    private func save() {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { saveError = "Add a title first."; return }
        if !highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addHighlight() }
        do {
            if draft.kind != original.kind { try CollectionStore.move(original, to: draft.kind) }
            try CollectionStore.save(draft)
            saveError = nil
            triggerBrain()
            close()
        } catch { saveError = "Couldn't save: \(error.localizedDescription)" }
    }
    private func close() { LibraryView.lastTab = draft.kind; pane = .library }
    private func setInclude(_ value: Bool) { draft.includeInBrain = value; try? CollectionStore.setIncludeInBrain(value, for: draft); if value { triggerBrain() }; rec.reloadMeetings() }
    private func triggerBrain() { guard draft.includeInBrain else { return }; Task { _ = await BrainContent.refresh(folder: CollectionStore.folder(for: draft), model: rec.model); await MainActor.run { rec.reloadMeetings() } } }
    private var linkField: some View {
        HStack(spacing: 8) {
            TextField("Link", text: $draft.url)
            if let url = CollectionLinkParser.normalize(draft.url) {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open link in browser")
            }
        }
    }
}

private struct CollectionLinkSheet: View {
    let initialURL: String
    let saved: (CollectionItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var fetching = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(initialURL: String, saved: @escaping (CollectionItem) -> Void) {
        self.initialURL = initialURL; self.saved = saved; _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add by link").font(.title2.bold())
            Text("Paste a link or drop one here. Metadata and the thumbnail are copied into the local vault.").foregroundStyle(.secondary)
            TextField("https://…", text: $urlText).textFieldStyle(.roundedBorder).onSubmit(fetch)
            if fetching { HStack { ProgressView(); Text("Fetching…").foregroundStyle(.secondary); Spacer(); Button("Cancel") { task?.cancel(); fetching = false } } }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Fetch") { fetch() }.buttonStyle(.borderedProminent).disabled(fetching || CollectionLinkParser.normalize(urlText) == nil) }
        }
        .padding(24).frame(width: 480)
        .onDisappear { task?.cancel() }
    }

    private func fetch() {
        guard let url = CollectionLinkParser.normalize(urlText) else { return }
        task?.cancel(); fetching = true; error = nil
        task = Task {
            let classification = CollectionLinkParser.classify(url)
            do {
                let result = try await CollectionLinkFetcher.fetch(url)
                try await save(result: result)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let fallback = CollectionItem(kind: classification.kind, title: CollectionLinkParser.fallbackTitle(for: url), url: url.absoluteString,
                                               format: classification.format, type: classification.type)
                do { try CollectionStore.save(fallback); await MainActor.run { fetching = false; saved(fallback) } }
                catch { await MainActor.run { fetching = false; self.error = error.localizedDescription } }
            }
        }
    }

    private func save(result: FetchedCollectionLink) async throws {
        var item = CollectionItem(kind: result.classification.kind,
                                  title: result.metadata.title.isEmpty ? CollectionLinkParser.fallbackTitle(for: result.url) : result.metadata.title,
                                  creator: result.metadata.creator,
                                  year: result.metadata.year,
                                  source: result.metadata.siteName,
                                  url: result.url.absoluteString,
                                  format: result.classification.format,
                                  type: result.classification.type)
        try CollectionStore.save(item)
        if let image = result.thumbnailData { item = try CollectionStore.setCoverData(image, fileExtension: result.thumbnailExtension, for: item) }
        await MainActor.run { fetching = false; saved(item) }
    }
}

/// Journal: one page per day. Your own notes, plus an automatic summary of what happened that day (meetings, chats,
/// books and media added, trips), written by the local model when the day has activity.
struct JournalView: View {
    @EnvironmentObject var rec: Recorder
    @Binding var pane: Pane?
    var initialDay: Date? = nil
    @State private var entries: [JournalEntry] = []
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    /// Today first, then every day that has a page or activity, newest first.
    private var days: [Date] {
        let calendar = Calendar.current
        var set = Set(entries.filter { $0.kind == .daily && (!$0.text.isEmpty || !$0.summary.isEmpty) }.map { calendar.startOfDay(for: $0.date) })
        set.formUnion(JournalActivity.activeDays(meetings: rec.meetings))
        set.insert(calendar.startOfDay(for: Date()))
        return set.sorted(by: >)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Journal").font(.title2.weight(.semibold))
                Text("One page a day. What happened is filled in for you; add your own thoughts.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            JournalDayCard(day: day, entry: JournalStore.day(day, in: entries), selected: Calendar.current.isDate(day, inSameDayAs: selectedDay)) {
                                selectedDay = day
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 360, alignment: .topLeading)
            .overlay(alignment: .trailing) { Divider() }
            JournalDayView(day: selectedDay, entry: JournalStore.day(selectedDay, in: entries), others: otherEntries(selectedDay), didSave: reload)
                .id(selectedDay)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Journal")
        .onAppear {
            JournalStore.removeEmptyDuplicateDays()
            if let initialDay { selectedDay = Calendar.current.startOfDay(for: initialDay) }
            reload()
        }
    }

    /// Weekly reflections and entries made before the one-page-a-day Journal, shown read-only on their day.
    private func otherEntries(_ day: Date) -> [JournalEntry] {
        entries.filter { $0.kind != .daily && Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    private func reload() { entries = JournalStore.load() }
}

private struct JournalDayCard: View {
    let day: Date
    let entry: JournalEntry
    let selected: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                Text(JournalActivity.dayLabel(day).uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                let preview = !entry.text.isEmpty ? entry.text : (!entry.summary.isEmpty ? entry.summary : "Nothing written yet")
                Text(preview.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).lineLimit(2)
                    .foregroundStyle(entry.text.isEmpty && entry.summary.isEmpty ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor)))
        }.buttonStyle(.plain)
    }
}

struct JournalDayView: View {
    @EnvironmentObject var rec: Recorder
    let day: Date
    let others: [JournalEntry]
    let didSave: () -> Void
    @State private var draft: JournalEntry
    @State private var savedText: String
    @ObservedObject private var writer = JournalWriter.shared
    @State private var saveError: String?
    @State private var savedAt: Date?
    @State private var confirmClear = false
    @State private var confirmRewrite = false
    @StateObject private var voice = VoiceMemoRecorder()

    init(day: Date, entry: JournalEntry, others: [JournalEntry], didSave: @escaping () -> Void) {
        self.day = day; self.others = others; self.didSave = didSave
        // Days summarized before the journal became one editable text: show the summary as the journal.
        var start = entry
        if start.text.isEmpty && !start.summary.isEmpty { start.text = start.summary }
        _draft = State(initialValue: start); _savedText = State(initialValue: start.text)
    }

    private var activity: JournalActivity { JournalActivity(day: day, meetings: rec.meetings) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).font(.system(size: 26, weight: .medium, design: .serif))
                        Spacer()
                        Toggle("Include in Brain", isOn: $draft.includeInBrain).toggleStyle(.checkbox)
                    }
                    journalEditor
                    ForEach(others) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.sourceTitle).font(.headline)
                            Text(entry.brainText.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
                .padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Button { confirmClear = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Clear this day's journal").disabled(draft.text.isEmpty)
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2) }
                else if savedAt != nil && draft.text == savedText { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { draft.text = savedText }.keyboardShortcut(.cancelAction).disabled(draft.text == savedText)
                Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .confirmationDialog("Clear this day's journal?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { draft.text = ""; save() }
            Button("Cancel", role: .cancel) {}
        }
        .task { await summarizeIfNeeded() }
        .onChange(of: writer.finished[JournalActivity.stamp(day)]) { _, _ in reloadFromStore() }
    }

    /// One journal for the day: the local model writes the first draft from the day's activity; the user edits it.
    @ViewBuilder private var journalEditor: some View {
        let current = activity
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Journal").font(.headline)
                if summarizing { ProgressView().controlSize(.small); Text("Writing from your day…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !current.isEmpty && !summarizing {
                    Button { if edited { confirmRewrite = true } else { Task { await summarize(force: true) } } } label: {
                        Label("Rewrite from my day", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless).help("Write the day again from its meetings, chats and new items")
                }
                Button { Task { if voice.isRecording { await voice.stop(); appendVoice() } else { await voice.start() } } } label: {
                    Label(voice.isRecording ? "Stop" : "Dictate", systemImage: voice.isRecording ? "stop.circle" : "mic")
                }
                .buttonStyle(.bordered).help("Speak and it is added to the journal")
            }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text(current.isEmpty ? "How was your day? What's on your mind?" : "Your day will be written here…")
                        .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 12)
                }
                TextEditor(text: $draft.text).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 320)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            if voice.isRecording { Text(voice.status).font(.caption).foregroundStyle(.secondary) }
            if !current.isEmpty {
                Text("\(current.headline). Edit freely: add, cut, and Save. Your version is kept.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Rewrite today's journal from your day? Your edits will be replaced.", isPresented: $confirmRewrite) {
            Button("Rewrite", role: .destructive) { Task { await summarize(force: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The user changed the text the model wrote (or wrote their own).
    private var edited: Bool { !draft.text.isEmpty && draft.text != draft.summary }

    private var dayKey: String { JournalActivity.stamp(day) }
    private var summarizing: Bool { writer.writing.contains(dayKey) }

    private func summarizeIfNeeded() async {
        let current = activity
        // Automatic only once per day, for a day with no journal yet; after that, only the Rewrite button.
        let flag = "journal.autowritten." + dayKey
        guard !current.isEmpty, draft.text.isEmpty, draft.summary.isEmpty, !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        await summarize(force: false)
    }

    private func summarize(force: Bool) async {
        let current = activity
        guard !current.isEmpty else { return }
        writer.write(day: day, activity: current, model: rec.model, force: force)
    }

    /// The writer finished (possibly while this page was closed): show what it saved, unless the user is mid-edit.
    private func reloadFromStore() {
        let latest = JournalStore.day(day, in: JournalStore.load())
        if draft.text == savedText || draft.text.isEmpty {
            draft = latest; savedText = latest.text
        } else {
            draft.summary = latest.summary; draft.summaryKey = latest.summaryKey
        }
        if let error = writer.errors[dayKey] { saveError = "Couldn't write the day: \(error)" } else { savedAt = Date() }
        didSave()
    }

    private func save() {
        do {
            try JournalStore.save(draft); savedText = draft.text; saveError = nil; savedAt = Date(); didSave(); process()
        } catch { saveError = "Couldn't save: \(error.localizedDescription)" }
    }
    private func appendVoice() {
        let spoken = voice.lines.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        draft.text += (draft.text.isEmpty ? "" : "\n") + spoken
    }
    private func process() {
        guard draft.includeInBrain else { try? BrainStore().removeMeetingData(meetingFolder: JournalStore.folder(for: draft)); return }
        Task { _ = await BrainContent.refresh(folder: JournalStore.folder(for: draft), model: rec.model); await MainActor.run { rec.reloadMeetings() } }
    }
}

/// What happened on one day, gathered from this Mac: meetings, chats, Library items and trips.
@MainActor
struct JournalActivity {
    let day: Date
    var meetings: [Meeting] = []
    var chats: [ChatThread] = []
    var items: [CollectionItem] = []
    var trips: [Trip] = []

    init(day: Date, meetings allMeetings: [Meeting]) {
        self.day = day
        let calendar = Calendar.current
        let stamp = Self.stamp(day)
        meetings = allMeetings.filter { $0.sourceKind == .meeting && $0.date.hasPrefix(stamp) }
        chats = ChatStore.shared.threads.filter { thread in thread.messages.contains { $0.role == "user" && calendar.isDate($0.date, inSameDayAs: day) } }
        items = CollectionStore.brainItems().filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
        trips = TravelStore.load().filter { trip in
            calendar.isDate(trip.createdAt, inSameDayAs: day)
                || (calendar.startOfDay(for: trip.startDate) <= day && calendar.startOfDay(for: trip.endDate) >= day)
        }
    }

    var isEmpty: Bool { meetings.isEmpty && chats.isEmpty && items.isEmpty && trips.isEmpty }

    /// Changes when the day's activity changes, so the summary is redone only then.
    var key: String {
        (meetings.map(\.id) + chats.map { "\($0.id)-\($0.messages.count)" } + items.map { "\($0.id)-\($0.notes.count)" } + trips.map { "\($0.id)-\($0.notes.count)" })
            .sorted().joined(separator: "|")
    }

    var headline: String {
        var parts: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
        count(meetings.count, "meeting", "meetings"); count(chats.count, "chat", "chats"); count(items.count, "item added", "items added"); count(trips.count, "trip", "trips")
        return "From " + parts.joined(separator: ", ")
    }

    static let systemPrompt = """
    You write the user's private daily journal from what happened that day. Write 2 to 5 sentences in the second person \
    ("You met…", "You read…"), warm and plain. Use only the activity given. No headings, no lists, no advice. \
    Chats are conversations with the user's AI assistant: write "you asked your assistant…" or "you talked with your \
    assistant about…". Never treat a chat's title or the assistant's name as a person.
    """

    var prompt: String {
        func clip(_ text: String, _ n: Int) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return flat.count > n ? String(flat.prefix(n)) + "…" : flat
        }
        var s = "Activity on \(day.formatted(date: .complete, time: .omitted)):\n"
        for m in meetings { s += "- Meeting \"\(m.title)\": \(clip(m.notes, 500))\n" }
        for c in chats {
            let asked = c.messages.filter { $0.role == "user" && Calendar.current.isDate($0.date, inSameDayAs: day) }.prefix(4).map { clip($0.text, 140) }
            let about = PersonChats.person(for: c.id).map { " about \($0)" } ?? ""
            s += "- Conversation with your assistant\(about); you asked: \(asked.joined(separator: " / "))\n"
        }
        for i in items { s += "- Added to Library (\(i.kind.title)): \(i.title)\(i.creator.isEmpty ? "" : " by \(i.creator)")\(i.notes.isEmpty ? "" : ". Your notes: \(clip(i.notes, 200))")\n" }
        for t in trips { s += "- Trip: \(t.title.isEmpty ? t.place : t.title)\(t.notes.isEmpty ? "" : ". Your notes: \(clip(t.notes, 200))")\n" }
        return String(s.prefix(6_000))
    }

    static func stamp(_ day: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: day)
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Days with meetings, chats, Library items or trips (the last 60 days), for the Journal list.
    static func activeDays(meetings: [Meeting], within days: Int = 60) -> Set<Date> {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        var out = Set<Date>()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        for m in meetings where m.sourceKind == .meeting { if let d = f.date(from: String(m.date.prefix(10))), d >= cutoff { out.insert(calendar.startOfDay(for: d)) } }
        for t in ChatStore.shared.threads { for m in t.messages where m.role == "user" && m.date >= cutoff { out.insert(calendar.startOfDay(for: m.date)) } }
        for i in CollectionStore.brainItems() where i.createdAt >= cutoff { out.insert(calendar.startOfDay(for: i.createdAt)) }
        for t in TravelStore.load() where t.createdAt >= cutoff { out.insert(calendar.startOfDay(for: t.createdAt)) }
        return out
    }
}

private struct DecisionSourcePicker: View {
    let choose: (DecisionSourceLink) -> Void
    @Environment(\.dismiss) private var dismiss
    private var sources: [BrainSourceDocument] { SourceRegistry.documents(meetings: Recorder.shared.meetings, projects: ProjectStore.shared.projects) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What shaped this decision").font(.title3.bold())
            List(sources, id: \.sourceID) { source in Button { choose(DecisionSourceLink(sourceID: source.sourceID, kind: source.sourceKind, title: source.sourceTitle)); dismiss() } label: { Label(source.sourceTitle, systemImage: source.sourceKind.icon) } }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }.padding(18).frame(width: 500, height: 440)
    }
}

private struct ImportPreviewView: View {
    let preview: CollectionImportPreview
    let performImport: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("Preview import").font(.title2.bold()); Text("\(preview.source) · \(preview.items.count) item\(preview.items.count == 1 ? "" : "s")").foregroundStyle(.secondary); List(preview.items) { item in Text(item.title + (item.highlights.isEmpty ? "" : " · \(item.highlights.count) highlights")) }; ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }; HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Import") { performImport(); dismiss() }.buttonStyle(.borderedProminent).disabled(preview.items.isEmpty) } }.padding(22).frame(width: 520, height: 440) }
}

/// Writes a day's journal with the local model. It is not tied to the Journal page, so leaving the page does not
/// cancel it; the result is saved to the day either way.
@MainActor
final class JournalWriter: ObservableObject {
    static let shared = JournalWriter()
    @Published private(set) var writing: Set<String> = []
    @Published private(set) var finished: [String: Date] = [:]
    private(set) var errors: [String: String] = [:]

    func write(day: Date, activity: JournalActivity, model: String, force: Bool) {
        let key = JournalActivity.stamp(day)
        guard !writing.contains(key) else { return }
        writing.insert(key)
        let prompt = activity.prompt, activityKey = activity.key
        Task { @MainActor in
            defer { writing.remove(key); finished[key] = Date() }
            do {
                try await ModelManager.shared.ensure(model)
                let text = try await Summarizer.chat(system: JournalActivity.systemPrompt, turns: [ChatTurn(role: "user", text: prompt)],
                                                     model: model, maxTokens: 260)
                ModelManager.shared.idle()
                let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
                var entry = JournalStore.day(day, in: JournalStore.load())
                // Never overwrite the user's own words unless they asked for a rewrite.
                if force || entry.text.isEmpty || entry.text == entry.summary { entry.text = written }
                entry.summary = written
                entry.summaryKey = activityKey
                try JournalStore.save(entry)
                errors[key] = nil
                if entry.includeInBrain {
                    _ = await BrainContent.refresh(folder: JournalStore.folder(for: entry), model: model)
                }
            } catch {
                ModelManager.shared.idle()
                errors[key] = error.localizedDescription
            }
        }
    }
}
