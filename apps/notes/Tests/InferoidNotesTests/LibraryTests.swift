import XCTest
@testable import InferoidNotesKit

final class LibraryTests: XCTestCase {
    private var root = URL(fileURLWithPath: "")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CollectionStore.rootOverride = root
        JournalStore.rootOverride = root
        TravelStore.rootOverride = root
    }

    override func tearDownWithError() throws {
        CollectionStore.rootOverride = nil
        JournalStore.rootOverride = nil
        TravelStore.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOldCollectionAndJournalDataDecodeWithDefaults() throws {
        let oldBook = #"{"id":"8C1D2E7A-9F5B-4C2E-8D1A-2B3C4D5E6F70","kind":"library","title":"Old book","creator":"An author","notes":"A note"}"#
        let item = try JSONDecoder().decode(CollectionItem.self, from: Data(oldBook.utf8))
        XCTAssertTrue(item.includeInBrain)
        XCTAssertEqual(item.highlights, [])
        XCTAssertNotEqual(item.coverSeed, 0)

        let oldMovie = #"{"id":"8C1D2E7A-9F5B-4C2E-8D1A-2B3C4D5E6F72","kind":"movies","title":"Old film"}"#
        let movie = try JSONDecoder().decode(CollectionItem.self, from: Data(oldMovie.utf8))
        XCTAssertEqual(movie.type, .movie)
        XCTAssertEqual(movie.format, .print)

        let oldEntry = #"{"id":"8C1D2E7A-9F5B-4C2E-8D1A-2B3C4D5E6F71","date":"2026-11-23T00:00:00Z","text":"Old journal"}"#
        let entry = try JSONDecoder.iso8601.decode(JournalEntry.self, from: Data(oldEntry.utf8))
        XCTAssertTrue(entry.includeInBrain)
        XCTAssertEqual(entry.voiceMemo, "")
        XCTAssertEqual(entry.kind, .daily)

        let oldVoice = #"{"date":"2026-11-23T00:00:00Z","voiceMemo":"[00:01] old voice"}"#
        XCTAssertEqual(try JSONDecoder.iso8601.decode(JournalEntry.self, from: Data(oldVoice.utf8)).kind, .voice)
    }

    func testCollectionAndJournalStorageRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var book = CollectionItem(kind: .library, title: "The Local Book", creator: "A. Writer", year: 2024,
                                  notes: "My notes", highlights: [CollectionHighlight(text: "A passage", location: "p. 12")],
                                  readingStart: date, readingEnd: date.addingTimeInterval(86_400))
        try CollectionStore.save(book)
        book = try XCTUnwrap(CollectionStore.item(id: book.id, kind: .library))
        XCTAssertEqual(book.title, "The Local Book")
        XCTAssertEqual(book.highlights.first?.location, "p. 12")
        XCTAssertTrue(FileManager.default.fileExists(atPath: CollectionStore.folder(for: book).appendingPathComponent("notes.md").path))
        XCTAssertTrue(Store.includeInBrain(in: CollectionStore.folder(for: book)))

        let entry = JournalEntry(date: date, text: "A daily note", voiceMemo: "[00:01] hello")
        try JournalStore.save(entry)
        let loaded = try XCTUnwrap(JournalStore.entry(id: entry.id))
        XCTAssertEqual(loaded.text, entry.text)
        XCTAssertEqual(loaded.voiceMemo, entry.voiceMemo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: JournalStore.folder(for: entry).appendingPathComponent("meta.json").path))

        let registered = SourceRegistry.documents(meetings: [], projects: [])
        XCTAssertEqual(Set(registered.map(\.sourceKind)), Set([.library, .journal]))
        XCTAssertTrue(registered.contains { $0.sourceID == book.id.uuidString && $0.sourceKind == .library })
        XCTAssertTrue(registered.contains { $0.sourceID == entry.id.uuidString && $0.sourceKind == .journal })
    }

    func testDecisionRoundTripGetsCheckbackAndBrainSource() throws {
        let shaped = DecisionSourceLink(sourceID: "book-1", kind: .library, title: "A local book")
        let decision = JournalEntry(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .decision,
                                    decisionTitle: "Choose the slower path", decisionWhy: "It is sustainable",
                                    decisionExpectation: "More consistent work", decisionShapedBy: [shaped])
        try JournalStore.save(decision)
        let loaded = try XCTUnwrap(JournalStore.entry(id: decision.id))
        XCTAssertEqual(loaded.kind, .decision)
        XCTAssertEqual(loaded.decisionShapedBy, [shaped])
        XCTAssertNotNil(loaded.checkBackDate)
        let sources = SourceRegistry.documents(meetings: [], projects: [])
        XCTAssertTrue(sources.contains { $0.sourceID == decision.id.uuidString && $0.includeInBrain && $0.sourceTitle == decision.decisionTitle })
        XCTAssertTrue(sources.first { $0.sourceID == decision.id.uuidString }?.textChunks.joined().contains("sustainable") ?? false)
    }

    func testWeeklyReflectionIsStoredAsJournalAndRegisteredInBrain() throws {
        let reflection = WeeklyReflection(weekStart: Date(timeIntervalSince1970: 1_700_000_000), people: ["A"],
                                          promisesMade: [], promisesKept: [], promisesOverdue: [],
                                          decisionCheckbacks: ["Choose the slower path"], itemsAdded: [])
        let entry = try JournalStore.upsertWeeklyReflection(reflection)
        XCTAssertEqual(entry.kind, .weekly)
        XCTAssertTrue(JournalStore.load().contains { $0.id == entry.id && $0.kind == .weekly })
        XCTAssertTrue(SourceRegistry.documents(meetings: [], projects: []).contains { $0.sourceID == entry.id.uuidString && $0.includeInBrain })
    }

    func testBrainSearchHonorsInclusionForEveryContentType() {
        let includedBook = BrainSourceDocument(id: "book", kind: .library, title: "Book", date: "2026-11-23",
                                                chunks: ["A memorable lighthouse passage"], includeInBrain: true)
        let excludedMovie = BrainSourceDocument(id: "movie", kind: .movies, title: "Movie", date: "2026-11-23",
                                                 chunks: ["A secret lighthouse scene"], includeInBrain: false)
        let includedJournal = BrainSourceDocument(id: "journal", kind: .journal, title: "Journal", date: "2026-11-23",
                                                   chunks: ["I walked past the lighthouse"], includeInBrain: true)

        let hits = Brain.searchSources("lighthouse", in: [excludedMovie, includedBook, includedJournal])
        XCTAssertEqual(Set(hits.map(\.kind)), Set([.library, .journal]))
        XCTAssertFalse(hits.contains { $0.kind == .movies })
    }

    func testArticlesAndTravelsRoundTripAndRegisterInBrain() throws {
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        let article = CollectionItem(kind: .articles, title: "A local article", notes: "Article notes", readingStart: date,
                                      source: "Local Site", url: "https://example.invalid/article")
        try CollectionStore.save(article)
        let loadedArticle = try XCTUnwrap(CollectionStore.item(id: article.id, kind: .articles))
        XCTAssertEqual(loadedArticle.source, "Local Site")
        XCTAssertEqual(loadedArticle.url, "https://example.invalid/article")

        let trip = Trip(title: "Northern trip", place: "Reykjavík", startDate: date, endDate: date.addingTimeInterval(86_400),
                        places: ["Harpa"], peopleMet: ["Alex"], notes: "A local trip")
        try TravelStore.save(trip)
        let loadedTrip = try XCTUnwrap(TravelStore.trip(id: trip.id))
        XCTAssertEqual(loadedTrip.places, ["Harpa"])
        XCTAssertEqual(loadedTrip.peopleMet, ["Alex"])

        let registered = SourceRegistry.documents(meetings: [], projects: [])
        XCTAssertTrue(registered.contains { $0.sourceID == article.id.uuidString && $0.sourceKind == .article && $0.includeInBrain })
        XCTAssertTrue(registered.contains { $0.sourceID == trip.id.uuidString && $0.sourceKind == .trip && $0.includeInBrain })
        XCTAssertTrue(Brain.searchSources("Reykjavík Harpa", in: registered).contains { $0.kind == .trip })
    }

    func testLocalImportParsersCreatePreviewItemsWithoutNetwork() {
        let clippings = """
        A Book (An Author)
        - Your Highlight on page 12 | location 12
        Location 12

        A useful passage.
        ==========
        """
        let kindle = CollectionImportParser.kindle(clippings)
        XCTAssertEqual(kindle.items.count, 1)
        XCTAssertEqual(kindle.items.first?.highlights.first?.location, "Location 12")

        let movies = CollectionImportParser.letterboxd("Date,Name,Year\n2026-11-23,Local Film,2025\n")
        XCTAssertEqual(movies.items.first?.watchedDates.count, 1)
        XCTAssertEqual(movies.items.first?.year, 2025)
    }

    func testCollectionLinkClassification() throws {
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://www.amazon.com/dp/123"))).kind, .library)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://www.amazon.com/kindle/dp/123"))).format, .ebook)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://www.audible.com/pd/book"))).format, .audiobook)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://youtu.be/abc"))).type, .youtube)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://open.spotify.com/episode/abc"))).type, .podcast)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://example.com/story"))).kind, .articles)
    }

    func testCollectionLinkMetadataParsesFixtureHTMLWithoutNetwork() throws {
        let html = #"""
        <html><head>
          <title>Fallback title</title>
          <meta property="og:title" content="A &amp; Better Story">
          <meta property="og:image" content="/images/cover.jpg">
          <meta property="og:site_name" content="Example Journal">
          <meta name="article:author" content="Ada Lovelace">
          <meta property="og:description" content="Published in 2026.">
        </head><body><h1>ignored</h1></body></html>
        """#
        let metadata = CollectionLinkParser.metadata(from: html, url: try XCTUnwrap(URL(string: "https://example.com/story")))
        XCTAssertEqual(metadata.title, "A & Better Story")
        XCTAssertEqual(metadata.creator, "Ada Lovelace")
        XCTAssertEqual(metadata.siteName, "Example Journal")
        XCTAssertEqual(metadata.year, 2026)
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://example.com/images/cover.jpg")
    }

    func testAmazonImageFixtureIsUsedWhenOpenGraphImageIsMissing() throws {
        let html = #"<html><head><meta property="og:title" content="Book"></head><body><img data-old-hires="https://images.example/cover.jpg"></body></html>"#
        let metadata = CollectionLinkParser.metadata(from: html, url: try XCTUnwrap(URL(string: "https://amazon.com/dp/1")))
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://images.example/cover.jpg")
    }

    func testAmazonKindleAndAudibleTitlesSplitTitleAndAuthor() {
        let book = CollectionLinkParser.amazonTitle("Think Again: The Power of Knowing What You Don't Know: Grant, Adam: 9781984878120: Amazon.com: Books")
        XCTAssertEqual(book?.title, "Think Again: The Power of Knowing What You Don't Know")
        XCTAssertEqual(book?.author, "Adam Grant")
        let kindle = CollectionLinkParser.amazonTitle("Amazon.com: Think Again eBook : Grant, Adam: Kindle Store")
        XCTAssertEqual(kindle?.title, "Think Again")
        XCTAssertEqual(kindle?.author, "Adam Grant")
        let audible = CollectionLinkParser.amazonTitle("Think Again by Adam Grant | Audiobook | Audible.com")
        XCTAssertEqual(audible?.title, "Think Again")
        XCTAssertEqual(audible?.author, "Adam Grant")
    }

    func testNumericEntitiesAreDecoded() {
        XCTAssertEqual(CollectionLinkParser.decodeEntities("Don&#x27;t &#39;stop&#39; &amp;amp;"), "Don't 'stop' &amp;")
    }

    func testEveryAmazonLinkIsABook() throws {
        let clp = CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://www.amazon.com/clp/B08H177WQP?lv=shuf&ref_=KC_GS_GB_US")))
        XCTAssertEqual(clp.kind, .library)
        XCTAssertEqual(clp.format, .ebook)
        XCTAssertEqual(CollectionLinkParser.classify(try XCTUnwrap(URL(string: "https://www.amazon.com/Think-Again-Power-Knowing-What/dp/1984878123"))).format, .print)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }

    func testIMDbAndIdTitlesAreCleaned() {
        let url = URL(string: "https://www.imdb.com/title/tt0099685/")!
        XCTAssertTrue(CollectionLinkParser.looksLikeID("Tt0099685", url: url))
        XCTAssertFalse(CollectionLinkParser.looksLikeID("Goodfellas", url: url))
        let cleaned = CollectionLinkParser.cleanTitle("Goodfellas (1990) - IMDb")
        XCTAssertEqual(cleaned.title, "Goodfellas")
        XCTAssertEqual(cleaned.year, 1990)
        XCTAssertEqual(CollectionLinkParser.cleanTitle("Breaking Bad (TV Series 2008–2013) - IMDb").title, "Breaking Bad")
    }
}
