import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct Trip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var place: String
    var startDate: Date
    var endDate: Date
    var coverColor: String
    var coverFile: String?
    var places: [String]
    var peopleMet: [String]
    var notes: String
    var photos: [String]
    var includeInBrain: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", place: String = "", startDate: Date = Date(), endDate: Date = Date(),
         coverColor: String = "blue", coverFile: String? = nil, places: [String] = [], peopleMet: [String] = [],
         notes: String = "", photos: [String] = [], includeInBrain: Bool = !PrivateMode.isEnabled,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.place = place; self.startDate = startDate; self.endDate = endDate
        self.coverColor = coverColor; self.coverFile = coverFile; self.places = places; self.peopleMet = peopleMet
        self.notes = notes; self.photos = photos; self.includeInBrain = includeInBrain
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, place, startDate, endDate, coverColor, coverFile, places, peopleMet, notes, photos, includeInBrain
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        place = try values.decodeIfPresent(String.self, forKey: .place) ?? ""
        startDate = try values.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate) ?? startDate
        coverColor = try values.decodeIfPresent(String.self, forKey: .coverColor) ?? "blue"
        coverFile = try values.decodeIfPresent(String.self, forKey: .coverFile)
        places = try values.decodeIfPresent([String].self, forKey: .places) ?? []
        peopleMet = try values.decodeIfPresent([String].self, forKey: .peopleMet) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        photos = try values.decodeIfPresent([String].self, forKey: .photos) ?? []
        includeInBrain = try values.decodeIfPresent(Bool.self, forKey: .includeInBrain) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? startDate
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

enum TravelStore {
    static var rootOverride: URL?
    static var root: URL { (rootOverride ?? InferoidPaths.support).appendingPathComponent("Travels", isDirectory: true) }
    static func folder(for trip: Trip) -> URL { root.appendingPathComponent(trip.id.uuidString, isDirectory: true) }

    static func load() -> [Trip] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("trip.json")) else { return nil }
            return try? decoder.decode(Trip.self, from: data)
        }.sorted { $0.startDate > $1.startDate }
    }

    static func trip(id: UUID) -> Trip? { load().first { $0.id == id } }
    static func trips(forPerson name: String) -> [Trip] { load().filter { trip in trip.peopleMet.contains { $0.caseInsensitiveCompare(name) == .orderedSame } } }

    static func save(_ trip: Trip) throws {
        let folder = folder(for: trip)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var value = trip; value.updatedAt = Date()
        if PrivateMode.isEnabled { value.includeInBrain = false }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: folder.appendingPathComponent("trip.json"), options: .atomic)
        try writeBrainFiles(value, folder: folder)
        let meta: [String: Any] = ["started": ISO8601DateFormatter().string(from: value.startDate), "includeInBrain": value.includeInBrain]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func setIncludeInBrain(_ included: Bool, for trip: Trip) throws -> Trip {
        var value = trip; value.includeInBrain = included; try save(value)
        if !included { try? BrainStore().removeMeetingData(meetingFolder: folder(for: trip)) }
        return value
    }

    static func addPhoto(_ source: URL, to trip: Trip) throws -> Trip {
        let folder = folder(for: trip)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photosFolder = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosFolder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let name = "photo-" + UUID().uuidString + "." + ext
        try FileManager.default.copyItem(at: source, to: photosFolder.appendingPathComponent(name))
        var value = trip; value.photos.append(name); if value.coverFile == nil { value.coverFile = name }
        try save(value); return value
    }

    static func photoURL(_ name: String, for trip: Trip) -> URL { folder(for: trip).appendingPathComponent("photos", isDirectory: true).appendingPathComponent(name) }

    static func delete(_ trip: Trip) throws {
        try? FileManager.default.trashItem(at: folder(for: trip), resultingItemURL: nil)
        try? BrainStore().removeMeetingData(meetingFolder: folder(for: trip))
    }

    private static func writeBrainFiles(_ trip: Trip, folder: URL) throws {
        var text = "# \(trip.title.isEmpty ? trip.place : trip.title)\n\nPlace: \(trip.place)\n"
        if !trip.places.isEmpty { text += "Places: \(trip.places.joined(separator: ", "))\n" }
        if !trip.peopleMet.isEmpty { text += "People met: \(trip.peopleMet.joined(separator: ", "))\n" }
        if !trip.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n## Notes\n\n\(trip.notes)\n" }
        try text.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try text.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }
}

struct TravelsView: View {
    @Binding var pane: Pane?
    @State private var trips: [Trip] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Travels").font(.largeTitle.bold()); Spacer(); Button("Add trip") { add() }.buttonStyle(.borderedProminent) }
                if trips.isEmpty { Text("Your trips, places and people met, kept locally.").foregroundStyle(.secondary) }
                else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) { ForEach(trips) { trip in Button { pane = .content(.trip, trip.id.uuidString) } label: { TripCard(trip: trip) }.buttonStyle(.plain) } } }
                Label("Stored only on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Travels").onAppear { trips = TravelStore.load() }
    }

    private func add() {
        let trip = Trip()
        try? TravelStore.save(trip)
        trips = TravelStore.load()
        pane = .content(.trip, trip.id.uuidString)
    }
}

private struct TripCard: View {
    let trip: Trip
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TripCover(trip: trip).frame(height: 125)
            Text(trip.title.isEmpty ? (trip.place.isEmpty ? "Untitled trip" : trip.place) : trip.title).font(.headline).lineLimit(2)
            if !trip.place.isEmpty { Text(trip.place).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text(Self.range(trip)).font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }
    static func range(_ trip: Trip) -> String { "\(trip.startDate.formatted(date: .abbreviated, time: .omitted)) – \(trip.endDate.formatted(date: .abbreviated, time: .omitted))" }
}

private struct TripCover: View {
    let trip: Trip
    var body: some View {
        if let file = trip.coverFile, let image = NSImage(contentsOf: TravelStore.photoURL(file, for: trip)) {
            Image(nsImage: image).resizable().scaledToFill().clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack { tripColor(trip.coverColor); Image(systemName: "airplane").font(.system(size: 36)).foregroundStyle(.white.opacity(0.8)) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private func tripColor(_ value: String) -> Color {
        switch value { case "orange": return .orange; case "green": return .green; case "purple": return .purple; case "red": return .red; default: return .blue }
    }
}

struct TripView: View {
    @EnvironmentObject var rec: Recorder
    let original: Trip
    @Binding var pane: Pane?
    @State private var draft: Trip
    @State private var newPlace = ""
    @State private var availablePeople: [BrainOrbitPerson] = []
    @State private var confirmDelete = false
    @State private var saveError: String?

    init(trip: Trip, pane: Binding<Pane?>) { original = trip; _pane = pane; _draft = State(initialValue: trip) }

    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) { TripCover(trip: draft).frame(width: 190, height: 145); tripFields }
            dates
            places
            people
            photos
            Toggle("Include in Brain", isOn: includeBinding).toggleStyle(.checkbox)
            if !draft.includeInBrain { Text("The Brain and chat won't use this trip.").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) { Text("Notes").font(.headline); TextEditor(text: $draft.notes).frame(minHeight: 150).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))) }
        }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity) }
        Divider()
        HStack(spacing: 10) {
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete this trip")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Cancel") { pane = .travels }.keyboardShortcut(.cancelAction)
            Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!canSave)
        }.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .navigationTitle(draft.title.isEmpty ? "Trip" : draft.title)
        .confirmationDialog("Delete this trip? Its notes and photos move to the Trash.", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { try? TravelStore.delete(draft); pane = .travels }
            Button("Cancel", role: .cancel) {}
        }.task { loadPeople() }
    }

    private var tripFields: some View { VStack(alignment: .leading, spacing: 10) {
        TextField("Trip title", text: $draft.title).font(.title2.bold())
        TextField("Place", text: $draft.place)
        Picker("Cover colour", selection: $draft.coverColor) { ForEach(["blue", "orange", "green", "purple", "red"], id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.menu)
        Button("Add photos") { choosePhotos() }
    } }

    private var dates: some View { HStack { DatePicker("From", selection: $draft.startDate, displayedComponents: .date); DatePicker("To", selection: $draft.endDate, displayedComponents: .date) } }

    private var places: some View { VStack(alignment: .leading, spacing: 8) {
        Text("Places").font(.headline)
        ForEach(draft.places, id: \.self) { place in HStack { Text(place); Spacer(); Button("Remove") { draft.places.removeAll { $0 == place } }.buttonStyle(.borderless) } }
        HStack { TextField("Add a place", text: $newPlace); Button("Add") { let value = newPlace.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { draft.places.append(value); newPlace = "" } }.disabled(newPlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    } }

    private var people: some View { VStack(alignment: .leading, spacing: 8) {
        Text("People met").font(.headline)
        ForEach(draft.peopleMet, id: \.self) { name in HStack { Label(name, systemImage: "person"); Spacer(); Button("Remove") { draft.peopleMet.removeAll { $0 == name } }.buttonStyle(.borderless) } }
        if availablePeople.isEmpty { Text("Add people in Orbit first.").font(.caption).foregroundStyle(.secondary) }
        else { Menu("Choose from Orbit") { ForEach(availablePeople, id: \.entity.id) { person in Button { togglePerson(person.entity.name) } label: { Label(person.entity.name, systemImage: draft.peopleMet.contains { $0.caseInsensitiveCompare(person.entity.name) == .orderedSame } ? "checkmark" : "person") } } } }
    } }

    private var photos: some View { VStack(alignment: .leading, spacing: 8) {
        Text("Photos").font(.headline)
        if draft.photos.isEmpty { Text("Photos are copied into this trip's local vault folder.").font(.caption).foregroundStyle(.secondary) }
        else { ScrollView(.horizontal) { HStack { ForEach(draft.photos, id: \.self) { name in if let image = NSImage(contentsOf: TravelStore.photoURL(name, for: draft)) { Image(nsImage: image).resizable().scaledToFill().frame(width: 110, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) } } } } }
    } }

    private var includeBinding: Binding<Bool> { Binding(get: { draft.includeInBrain }, set: { value in draft.includeInBrain = value; try? TravelStore.setIncludeInBrain(value, for: draft); if value { refreshBrain() }; rec.reloadMeetings() }) }
    private func togglePerson(_ name: String) { if let index = draft.peopleMet.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { draft.peopleMet.remove(at: index) } else { draft.peopleMet.append(name) } }
    private func loadPeople() { availablePeople = (try? BrainStore().orbitPeople(limit: 200)) ?? [] }
    private func save() {
        guard canSave else { saveError = "Add a title or place first."; return }
        let place = newPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty { draft.places.append(place); newPlace = "" }
        do { try TravelStore.save(draft); saveError = nil; refreshBrain(); pane = .travels }
        catch { saveError = "Couldn't save: \(error.localizedDescription)" }
    }
    private func refreshBrain() { guard draft.includeInBrain else { return }; Task { _ = await BrainContent.refresh(folder: TravelStore.folder(for: draft), model: rec.model); await MainActor.run { rec.reloadMeetings() } } }
    private func choosePhotos() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.image]; if panel.runModal() == .OK { for url in panel.urls { draft = (try? TravelStore.addPhoto(url, to: draft)) ?? draft }; refreshBrain() } }
}

