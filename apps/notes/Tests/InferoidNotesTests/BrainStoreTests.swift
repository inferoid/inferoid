import XCTest
@testable import InferoidNotesKit

final class BrainStoreTests: XCTestCase {
    private var root = URL(fileURLWithPath: "")
    private var store: BrainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try BrainStore(url: root.appendingPathComponent("brain.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testSchemaAndMigration() throws {
        XCTAssertEqual(store.schemaVersion, BrainStore.latestSchemaVersion)
        let reopened = try BrainStore(url: root.appendingPathComponent("brain.sqlite"))
        XCTAssertEqual(reopened.schemaVersion, BrainStore.latestSchemaVersion)
        XCTAssertFalse(store.hasEpisode(meetingFolder: root.appendingPathComponent("missing")))
    }

    func testExtractionParserAndMalformedFixture() throws {
        let json = try String(contentsOf: Bundle.module.url(forResource: "good", withExtension: "json", subdirectory: "Fixtures")!)
        let payload = try BrainExtraction.parseJSON(json)
        XCTAssertEqual(payload.entities.first?.name, "Ryan Green")
        XCTAssertEqual(payload.facts.first?.lineStart, 1)
        let malformed = try String(contentsOf: Bundle.module.url(forResource: "malformed", withExtension: "txt", subdirectory: "Fixtures")!)
        XCTAssertThrowsError(try BrainExtraction.parseJSON(malformed))
    }

    func testInventedQuoteIsDropped() async throws {
        let folder = root.appendingPathComponent("meeting-one")
        let transcript = "[00:01] Ryan Green: We discussed the budget and the launch timeline."
        let invented = try String(contentsOf: Bundle.module.url(forResource: "invented", withExtension: "json", subdirectory: "Fixtures")!)
        let payload = try BrainExtraction.parseJSON(invented)
        _ = try await store.ingest(meetingFolder: folder, startedAt: "2026-11-01T10:00:00Z", model: "fixture", attendees: [], transcript: transcript, payload: payload)
        XCTAssertTrue(try store.conflictSearch("Ryan").facts.isEmpty)
    }

    func testEmailNameAndFirstNameResolveButDifferentFullNamesStayApart() async throws {
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let third = root.appendingPathComponent("third")
        let firstPayload = BrainExtractionPayload(entities: [BrainExtractionEntity(name: "Ryan Green", kind: "person", email: "ryan.green@x.com")], facts: [])
        let secondPayload = BrainExtractionPayload(entities: [BrainExtractionEntity(name: "Ryan", kind: "person")], facts: [])
        let thirdPayload = BrainExtractionPayload(entities: [BrainExtractionEntity(name: "Ryan Smith", kind: "person")], facts: [])
        _ = try await store.ingest(meetingFolder: first, startedAt: "2026-11-01T10:00:00Z", model: "fixture", attendees: ["Ryan Green"], transcript: "[00:01] Ryan Green: Hello.", payload: firstPayload)
        _ = try await store.ingest(meetingFolder: second, startedAt: "2026-11-02T10:00:00Z", model: "fixture", attendees: ["Ryan Green"], transcript: "[00:01] Ryan: Hello.", payload: secondPayload)
        _ = try await store.ingest(meetingFolder: third, startedAt: "2026-11-03T10:00:00Z", model: "fixture", attendees: ["Ryan Smith"], transcript: "[00:01] Ryan Smith: Hello.", payload: thirdPayload)
        XCTAssertEqual(try store.personDossier("Ryan Green")?.entity.name, "Ryan Green")
        XCTAssertEqual(try store.personDossier("ryan.green@x.com")?.entity.name, "Ryan Green")
        XCTAssertEqual(try store.conflictSearch("Ryan").entities.count, 2)
    }

    func testPositionsSupersedeAndCorrectionsCompletePromises() async throws {
        let first = BrainExtractionPayload(
            entities: [BrainExtractionEntity(name: "Ryan Green", kind: "person"), BrainExtractionEntity(name: "Me", kind: "person")],
            facts: [BrainExtractionFact(kind: "position", subject: "Ryan Green", predicate: "budget", value: "Ryan supports a large budget", quote: "Ryan supports a large budget.", lineStart: 1, lineEnd: 1),
                    BrainExtractionFact(kind: "commitment", subject: "Me", predicate: "send draft", owner: "Me", counterparty: "Ryan Green", due: "Friday", value: "send the draft", quote: "I will send the draft Friday.", lineStart: 2, lineEnd: 2)]
        )
        let second = BrainExtractionPayload(
            entities: [BrainExtractionEntity(name: "Ryan Green", kind: "person")],
            facts: [BrainExtractionFact(kind: "position", subject: "Ryan Green", predicate: "budget", value: "Ryan supports a smaller budget", quote: "Ryan supports a smaller budget.", lineStart: 1, lineEnd: 1)]
        )
        _ = try await store.ingest(meetingFolder: root.appendingPathComponent("position-one"), startedAt: "2026-11-01T10:00:00Z", model: "fixture", attendees: ["Ryan Green"], transcript: "[00:01] Ryan Green: Ryan supports a large budget.\n[00:02] Me: I will send the draft Friday.", payload: first)
        _ = try await store.ingest(meetingFolder: root.appendingPathComponent("position-two"), startedAt: "2026-11-02T10:00:00Z", model: "fixture", attendees: ["Ryan Green"], transcript: "[00:01] Ryan Green: Ryan supports a smaller budget.", payload: second)
        let dossier = try XCTUnwrap(store.personDossier("Ryan Green"))
        XCTAssertEqual(dossier.positions.count, 1)
        XCTAssertEqual(dossier.positionHistory.count, 2)
        XCTAssertNotNil(dossier.positionHistory.first(where: { $0.invalidatedAt != nil }))
        let promises = try store.openPromises()
        XCTAssertEqual(promises.iOwe.count, 1)
        try store.applyCorrection(factID: promises.iOwe[0].id, action: "done")
        XCTAssertTrue(try store.openPromises().iOwe.isEmpty)
    }

    func testDossierAndFTSSearch() async throws {
        let payload = BrainExtractionPayload(
            entities: [BrainExtractionEntity(name: "Ryan Green", kind: "person")],
            facts: [BrainExtractionFact(kind: "fact", subject: "Ryan Green", predicate: "launch", value: "Northstar launch is in October", quote: "Ryan Green said the Northstar launch is in October.", lineStart: 1, lineEnd: 1)]
        )
        _ = try await store.ingest(meetingFolder: root.appendingPathComponent("fts"), startedAt: "2026-11-04T10:00:00Z", model: "fixture", attendees: [], transcript: "[00:01] Ryan Green: Ryan Green said the Northstar launch is in October.", payload: payload)
        let hits = try store.factsForChat("Northstar")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meetingDate, "2026-11-04T10:00:00Z")
        XCTAssertEqual(hits[0].fact.lineStart, 1)
    }
}
