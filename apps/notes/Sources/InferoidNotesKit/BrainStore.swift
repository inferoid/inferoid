import Foundation
import SQLite3

// MARK: - Public graph values

public enum BrainEntityKind: String, Codable, CaseIterable, Sendable {
    case person, org, matter, topic
}

public enum BrainWorld: String, Codable, CaseIterable, Sendable {
    case client, opposing, court, team, personal, other, unknown
}

public enum BrainFactKind: String, Codable, CaseIterable, Sendable {
    case decision, commitment, position, fact, relationship
}

public struct BrainEpisode: Codable, Hashable, Sendable {
    public let id: String
    public let meetingFolder: String
    public let startedAt: String
    public let processedAt: String?
    public let model: String?

    public init(id: String, meetingFolder: String, startedAt: String, processedAt: String?, model: String?) {
        self.id = id; self.meetingFolder = meetingFolder; self.startedAt = startedAt
        self.processedAt = processedAt; self.model = model
    }
}

public struct BrainEntity: Codable, Hashable, Sendable {
    public let id: Int64
    public let kind: BrainEntityKind
    public let name: String
    public let world: BrainWorld
    public let summary: String
    public let createdAt: String
    public let updatedAt: String
    public let forgotten: Bool

    public init(id: Int64, kind: BrainEntityKind, name: String, world: BrainWorld, summary: String,
                createdAt: String, updatedAt: String, forgotten: Bool) {
        self.id = id; self.kind = kind; self.name = name; self.world = world; self.summary = summary
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.forgotten = forgotten
    }
}

public struct BrainAlias: Codable, Hashable, Sendable {
    public let entityID: Int64
    public let aliasNorm: String
    public let aliasDisplay: String
    public let source: String

    public init(entityID: Int64, aliasNorm: String, aliasDisplay: String, source: String) {
        self.entityID = entityID; self.aliasNorm = aliasNorm; self.aliasDisplay = aliasDisplay; self.source = source
    }
}

public struct BrainFact: Codable, Hashable, Sendable {
    public let id: Int64
    public let kind: BrainFactKind
    public let subjectID: Int64?
    public let predicate: String
    public let objectID: Int64?
    public let value: String
    public let ownerID: Int64?
    public let counterpartyID: Int64?
    public let due: String?
    public let done: Bool
    public let validFrom: String
    public let invalidatedAt: String?
    public let supersededBy: Int64?
    public let status: String
    public let confidence: Double
    public let episodeID: String
    public let lineStart: Int
    public let lineEnd: Int
    public let quote: String
    public let createdAt: String
    public let embedding: Data?

    public init(id: Int64, kind: BrainFactKind, subjectID: Int64?, predicate: String, objectID: Int64?, value: String,
                ownerID: Int64?, counterpartyID: Int64?, due: String?, done: Bool, validFrom: String,
                invalidatedAt: String?, supersededBy: Int64?, status: String, confidence: Double,
                episodeID: String, lineStart: Int, lineEnd: Int, quote: String, createdAt: String, embedding: Data?) {
        self.id = id; self.kind = kind; self.subjectID = subjectID; self.predicate = predicate
        self.objectID = objectID; self.value = value; self.ownerID = ownerID; self.counterpartyID = counterpartyID
        self.due = due; self.done = done; self.validFrom = validFrom; self.invalidatedAt = invalidatedAt
        self.supersededBy = supersededBy; self.status = status; self.confidence = confidence; self.episodeID = episodeID
        self.lineStart = lineStart; self.lineEnd = lineEnd; self.quote = quote; self.createdAt = createdAt
        self.embedding = embedding
    }
}

public struct BrainFactHit: Codable, Hashable, Sendable {
    public let fact: BrainFact
    public let meetingDate: String
    public let line: String

    public init(fact: BrainFact, meetingDate: String, line: String) {
        self.fact = fact; self.meetingDate = meetingDate; self.line = line
    }
}

public struct BrainPersonDossier: Codable, Hashable, Sendable {
    public let entity: BrainEntity
    public let aliases: [BrainAlias]
    public let openCommitmentsByPerson: [BrainFact]
    public let openCommitmentsToPerson: [BrainFact]
    public let positions: [BrainFact]
    public let positionHistory: [BrainFact]
    public let meetings: [BrainEpisode]

    public init(entity: BrainEntity, aliases: [BrainAlias], openCommitmentsByPerson: [BrainFact],
                openCommitmentsToPerson: [BrainFact], positions: [BrainFact], positionHistory: [BrainFact],
                meetings: [BrainEpisode]) {
        self.entity = entity; self.aliases = aliases; self.openCommitmentsByPerson = openCommitmentsByPerson
        self.openCommitmentsToPerson = openCommitmentsToPerson; self.positions = positions
        self.positionHistory = positionHistory; self.meetings = meetings
    }
}

public struct BrainPromises: Codable, Hashable, Sendable {
    public let iOwe: [BrainFact]
    public let owedToMe: [BrainFact]

    public init(iOwe: [BrainFact], owedToMe: [BrainFact]) { self.iOwe = iOwe; self.owedToMe = owedToMe }
}

public struct BrainConflictSearch: Codable, Hashable, Sendable {
    public let entities: [BrainEntity]
    public let facts: [BrainFact]

    public init(entities: [BrainEntity], facts: [BrainFact]) { self.entities = entities; self.facts = facts }
}

public struct BrainExtractionEntity: Codable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var world: String?
    public var summary: String?
    public var email: String?

    public init(name: String, kind: String, world: String? = nil, summary: String? = nil, email: String? = nil) {
        self.name = name; self.kind = kind; self.world = world; self.summary = summary; self.email = email
    }
}

public struct BrainExtractionFact: Codable, Hashable, Sendable {
    public var kind: String
    public var subject: String
    public var predicate: String
    public var object: String?
    public var value: String?
    public var owner: String?
    public var counterparty: String?
    public var due: String?
    public var quote: String?
    public var lineStart: Int?
    public var lineEnd: Int?
    public var confidence: Double?

    public init(kind: String, subject: String, predicate: String, object: String? = nil, value: String? = nil,
                owner: String? = nil, counterparty: String? = nil, due: String? = nil, quote: String? = nil,
                lineStart: Int? = nil, lineEnd: Int? = nil, confidence: Double? = nil) {
        self.kind = kind; self.subject = subject; self.predicate = predicate; self.object = object
        self.value = value; self.owner = owner; self.counterparty = counterparty; self.due = due; self.quote = quote
        self.lineStart = lineStart; self.lineEnd = lineEnd; self.confidence = confidence
    }
}

public struct BrainExtractionPayload: Codable, Hashable, Sendable {
    public var entities: [BrainExtractionEntity]
    public var facts: [BrainExtractionFact]

    public init(entities: [BrainExtractionEntity] = [], facts: [BrainExtractionFact] = []) {
        self.entities = entities; self.facts = facts
    }
}

public protocol Embedder: Sendable {
    func embedding(for text: String) async throws -> [Float]?
}

public struct NoOpEmbedder: Embedder {
    public init() {}
    public func embedding(for text: String) async throws -> [Float]? { nil }
}

// MARK: - SQLite store

public final class BrainStore: @unchecked Sendable {
    public static let latestSchemaVersion = 2
    public static var defaultURL: URL { InferoidPaths.support.appendingPathComponent("brain.sqlite") }

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = BrainStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw BrainStoreError.open(String(cString: sqlite3_errstr(SQLITE_CANTOPEN)))
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try exec("PRAGMA foreign_keys = ON")
            try migrate()
        } catch {
            sqlite3_close(handle); db = nil; throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public enum BrainStoreError: LocalizedError, Equatable {
        case open(String), sqlite(String), malformed(String), unsupportedSchema(Int)
        public var errorDescription: String? {
            switch self {
            case .open(let message): return "Brain database could not open: \(message)"
            case .sqlite(let message): return "Brain database error: \(message)"
            case .malformed(let message): return "Brain data is malformed: \(message)"
            case .unsupportedSchema(let version): return "Brain database schema \(version) is newer than this app."
            }
        }
    }

    public var schemaVersion: Int {
        lock.lock(); defer { lock.unlock() }
        return (try? pragmaUserVersion()) ?? 0
    }

    private func errorMessage() -> String {
        guard let db else { return "closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw BrainStoreError.sqlite("closed") }
        var message: UnsafeMutablePointer<Int8>?
        defer { if let message { sqlite3_free(message) } }
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            throw BrainStoreError.sqlite(message.map { String(cString: $0) } ?? errorMessage())
        }
    }

    private func pragmaUserVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BrainStoreError.sqlite(errorMessage()) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func migrate() throws {
        let version = try pragmaUserVersion()
        guard version <= Self.latestSchemaVersion else { throw BrainStoreError.unsupportedSchema(version) }
        if version == 0 {
            try exec("""
                CREATE TABLE IF NOT EXISTS episodes (
                    id TEXT PRIMARY KEY,
                    meeting_folder TEXT NOT NULL UNIQUE,
                    started_at TEXT NOT NULL,
                    processed_at TEXT,
                    model TEXT
                );
                CREATE TABLE IF NOT EXISTS entities (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    world TEXT NOT NULL DEFAULT 'unknown',
                    summary TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    forgotten INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS aliases (
                    entity_id INTEGER NOT NULL REFERENCES entities(id),
                    alias_norm TEXT NOT NULL,
                    alias_display TEXT NOT NULL,
                    source TEXT NOT NULL,
                    PRIMARY KEY(entity_id, alias_norm)
                );
                CREATE TABLE IF NOT EXISTS facts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    subject_id INTEGER REFERENCES entities(id),
                    predicate TEXT NOT NULL,
                    object_id INTEGER REFERENCES entities(id),
                    value TEXT NOT NULL DEFAULT '',
                    owner_id INTEGER REFERENCES entities(id),
                    counterparty_id INTEGER REFERENCES entities(id),
                    due TEXT,
                    done INTEGER NOT NULL DEFAULT 0,
                    valid_from TEXT NOT NULL,
                    invalidated_at TEXT,
                    superseded_by INTEGER REFERENCES facts(id),
                    status TEXT NOT NULL DEFAULT 'verified',
                    confidence REAL NOT NULL DEFAULT 0.0,
                    episode_id TEXT NOT NULL REFERENCES episodes(id),
                    line_start INTEGER NOT NULL DEFAULT 0,
                    line_end INTEGER NOT NULL DEFAULT 0,
                    quote TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS facts_subject_idx ON facts(subject_id, kind, predicate);
                CREATE INDEX IF NOT EXISTS facts_owner_idx ON facts(owner_id, done, invalidated_at);
                CREATE INDEX IF NOT EXISTS facts_counterparty_idx ON facts(counterparty_id, done, invalidated_at);
                CREATE INDEX IF NOT EXISTS aliases_norm_idx ON aliases(alias_norm);
                CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(value, quote, content='facts', content_rowid='id');
                CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts USING fts5(name, summary, content='entities', content_rowid='id');
                CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
                    INSERT INTO facts_fts(rowid, value, quote) VALUES (new.id, new.value, new.quote);
                END;
                CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
                    INSERT INTO facts_fts(facts_fts, rowid, value, quote) VALUES ('delete', old.id, old.value, old.quote);
                END;
                CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE OF value, quote ON facts BEGIN
                    INSERT INTO facts_fts(facts_fts, rowid, value, quote) VALUES ('delete', old.id, old.value, old.quote);
                    INSERT INTO facts_fts(rowid, value, quote) VALUES (new.id, new.value, new.quote);
                END;
                CREATE TRIGGER IF NOT EXISTS entities_ai AFTER INSERT ON entities BEGIN
                    INSERT INTO entities_fts(rowid, name, summary) VALUES (new.id, new.name, new.summary);
                END;
                CREATE TRIGGER IF NOT EXISTS entities_ad AFTER DELETE ON entities BEGIN
                    INSERT INTO entities_fts(entities_fts, rowid, name, summary) VALUES ('delete', old.id, old.name, old.summary);
                END;
                CREATE TRIGGER IF NOT EXISTS entities_au AFTER UPDATE OF name, summary ON entities BEGIN
                    INSERT INTO entities_fts(entities_fts, rowid, name, summary) VALUES ('delete', old.id, old.name, old.summary);
                    INSERT INTO entities_fts(rowid, name, summary) VALUES (new.id, new.name, new.summary);
                END;
                CREATE TABLE IF NOT EXISTS corrections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    fact_id INTEGER NOT NULL REFERENCES facts(id),
                    action TEXT NOT NULL,
                    old_json TEXT NOT NULL,
                    new_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                PRAGMA user_version = 1;
            """)
            // A rebuild makes migration safe if a database was interrupted after table creation.
            try exec("INSERT INTO facts_fts(facts_fts) VALUES ('rebuild'); INSERT INTO entities_fts(entities_fts) VALUES ('rebuild');")
        }
        if try pragmaUserVersion() == 1 {
            try exec("ALTER TABLE facts ADD COLUMN embedding BLOB; PRAGMA user_version = 2;")
        }
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw BrainStoreError.sqlite("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BrainStoreError.sqlite(errorMessage())
        }
        return stmt
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        if let value {
            let result = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }
        }
    }

    private func bind(_ value: Int64?, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value ?? 0) == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }
        if value == nil { guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) } }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }
    }

    private func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else { guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }; return }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw BrainStoreError.sqlite(errorMessage()) }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw BrainStoreError.sqlite(errorMessage()) }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    public func hasEpisode(meetingFolder: URL) -> Bool {
        (try? episode(meetingFolder: meetingFolder.path)) != nil
    }

    public func episode(meetingFolder: String) throws -> BrainEpisode? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT id, meeting_folder, started_at, processed_at, model FROM episodes WHERE meeting_folder = ?")
        defer { sqlite3_finalize(statement) }
        try bind(meetingFolder, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return BrainEpisode(id: text(statement, 0), meetingFolder: text(statement, 1), startedAt: text(statement, 2),
                            processedAt: optionalText(statement, 3), model: optionalText(statement, 4))
    }

    /// Records a short meeting as processed without adding model-generated facts.
    public func markSkipped(meetingFolder: URL, startedAt: String, reason: String = "short") throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT OR REPLACE INTO episodes(id, meeting_folder, started_at, processed_at, model) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(UUID().uuidString, at: 1, to: statement); try bind(meetingFolder.path, at: 2, to: statement)
        try bind(startedAt, at: 3, to: statement); try bind(Self.now(), at: 4, to: statement); try bind("skipped-\(reason)", at: 5, to: statement)
        try step(statement)
    }

    /// Inserts one extracted meeting and resolves all names within one transaction.
    public func ingest(meetingFolder: URL, startedAt: String, model: String, attendees: [String],
                       transcript: String, payload: BrainExtractionPayload, embedder: Embedder = NoOpEmbedder()) async throws -> BrainEpisode {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let validEntities = payload.entities.filter { Self.groundedName($0.name, transcript: transcript, attendees: attendees) }
        var validFacts: [(BrainExtractionFact, Int, Int, String, String)] = []
        for fact in payload.facts {
            let references = [fact.subject, fact.object, fact.owner, fact.counterparty].compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            guard references.allSatisfy({ Self.groundedName($0, transcript: transcript, attendees: attendees) }) else { continue }
            let quote = fact.quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if quote.isEmpty {
                validFacts.append((fact, fact.lineStart ?? 0, fact.lineEnd ?? 0, "", "unverified"))
            } else if let range = Self.matchQuote(quote, lines: lines, hintStart: fact.lineStart, hintEnd: fact.lineEnd) {
                validFacts.append((fact, range.0, range.1, quote, "verified"))
            }
        }
        var embeddings: [[Float]?] = []
        for (fact, _, _, quote, _) in validFacts {
            embeddings.append(try await embedder.embedding(for: [fact.predicate, fact.value ?? fact.object ?? "", quote].joined(separator: " ")))
        }
        let validEntityPayload = validEntities
        lock.lock(); defer { lock.unlock() }
        return try withTransaction {
            let episodeID = UUID().uuidString
            let now = Self.now()
            let episodeStatement = try prepare("INSERT OR REPLACE INTO episodes(id, meeting_folder, started_at, processed_at, model) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(episodeStatement) }
            try bind(episodeID, at: 1, to: episodeStatement); try bind(meetingFolder.path, at: 2, to: episodeStatement)
            try bind(startedAt, at: 3, to: episodeStatement); try bind(now, at: 4, to: episodeStatement); try bind(model, at: 5, to: episodeStatement)
            try step(episodeStatement)

            var ids: [String: Int64] = [:]
            for entity in validEntityPayload {
                let canonical = Self.canonicalName(entity.name, email: entity.email)
                let resolvedName = entity.kind.lowercased() == "person" ? Self.contextualName(canonical, attendees: attendees) : canonical
                let id = try resolveEntity(name: resolvedName, kind: entity.kind, world: entity.world, summary: entity.summary ?? "",
                                           email: entity.email, attendees: attendees, contextIDs: ids, now: now)
                for alias in Self.aliases(for: entity, canonical: resolvedName, attendees: attendees) { ids[Self.normalize(alias)] = id }
            }
            // Calendar names are context, not automatically entities. They only influence resolving names extracted from speech.
            for factRecord in validFacts.enumerated() {
                let (fact, lineStart, lineEnd, quote, quoteStatus) = factRecord.element
                let subjectID = try resolveReference(fact.subject, ids: ids)
                let objectID = try resolveReference(fact.object, ids: ids)
                let ownerID = try resolveReference(fact.owner, ids: ids)
                let counterpartyID = try resolveReference(fact.counterparty, ids: ids)
                let rawValue = (fact.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let value = rawValue.isEmpty ? (fact.object ?? "") : rawValue
                let kind = BrainFactKind(rawValue: fact.kind.lowercased()) ?? .fact
                let predicate = fact.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !predicate.isEmpty else { continue }
                let statement = try prepare("""
                    INSERT INTO facts(kind, subject_id, predicate, object_id, value, owner_id, counterparty_id, due, done,
                                      valid_from, invalidated_at, superseded_by, status, confidence, episode_id,
                                      line_start, line_end, quote, created_at, embedding)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(statement) }
                try bind(kind.rawValue, at: 1, to: statement); try bind(subjectID, at: 2, to: statement)
                try bind(predicate, at: 3, to: statement); try bind(objectID, at: 4, to: statement); try bind(value, at: 5, to: statement)
                try bind(ownerID, at: 6, to: statement); try bind(counterpartyID, at: 7, to: statement); try bind(fact.due, at: 8, to: statement)
                try bind(startedAt, at: 9, to: statement); try bind(quoteStatus, at: 10, to: statement)
                try bind(fact.confidence ?? (quoteStatus == "verified" ? 0.9 : 0.35), at: 11, to: statement)
                try bind(episodeID, at: 12, to: statement); try bind(Int64(lineStart), at: 13, to: statement); try bind(Int64(lineEnd), at: 14, to: statement)
                try bind(quote, at: 15, to: statement); try bind(now, at: 16, to: statement); try bind(Self.floatData(embeddings[factRecord.offset]), at: 17, to: statement)
                try step(statement)
                let factID = sqlite3_last_insert_rowid(db)
                if kind == .position, let subjectID {
                    let invalidate = try prepare("UPDATE facts SET invalidated_at = ?, superseded_by = ? WHERE kind = 'position' AND subject_id = ? AND predicate = ? AND invalidated_at IS NULL AND id <> ?")
                    defer { sqlite3_finalize(invalidate) }
                    try bind(startedAt, at: 1, to: invalidate); try bind(factID, at: 2, to: invalidate); try bind(subjectID, at: 3, to: invalidate)
                    try bind(predicate, at: 4, to: invalidate); try bind(factID, at: 5, to: invalidate); try step(invalidate)
                }
            }
            return BrainEpisode(id: episodeID, meetingFolder: meetingFolder.path, startedAt: startedAt, processedAt: now, model: model)
        }
    }

    private func resolveReference(_ name: String?, ids: [String: Int64]) throws -> Int64? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let id = ids[Self.normalize(name)] { return id }
        let statement = try prepare("SELECT entity_id FROM aliases WHERE alias_norm = ? LIMIT 2")
        defer { sqlite3_finalize(statement) }
        try bind(Self.normalize(name), at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) != SQLITE_ROW else { return nil } // ambiguous aliases never resolve
        return id
    }

    private func resolveEntity(name: String, kind: String, world: String?, summary: String, email: String?, attendees: [String],
                               contextIDs: [String: Int64], now: String) throws -> Int64 {
        let kindValue = BrainEntityKind(rawValue: kind.lowercased()) ?? .topic
        let worldValue = BrainWorld(rawValue: (world ?? "unknown").lowercased()) ?? .unknown
        let norm = Self.normalize(name)
        var existing: Int64?
        let fullName = norm.split(separator: " ").count > 1
        let aliasesToTry = [norm, email.map(Self.normalize)].compactMap { $0 }
        for alias in aliasesToTry {
            let statement = try prepare("SELECT e.id, e.name FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE a.alias_norm = ? AND e.kind = ? LIMIT 3")
            defer { sqlite3_finalize(statement) }
            try bind(alias, at: 1, to: statement); try bind(kindValue.rawValue, at: 2, to: statement)
            var candidates: [(Int64, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW { candidates.append((sqlite3_column_int64(statement, 0), text(statement, 1))) }
            if candidates.count == 1, Self.canMerge(existingName: candidates[0].1, incomingName: name, fullIncoming: fullName) { existing = candidates[0].0; break }
        }
        if existing == nil, kindValue == .person, let first = norm.split(separator: " ").first, norm.split(separator: " ").count == 1 {
            let firstName = String(first)
            let contextNames = attendees.map(Self.normalize).filter { $0.split(separator: " ").first.map(String.init) == firstName }
            let ids = Set(contextNames.compactMap { contextIDs[$0] })
            if ids.count == 1 { existing = ids.first }
        }
        if let existing {
            let update = try prepare("UPDATE entities SET summary = CASE WHEN ? <> '' THEN ? ELSE summary END, updated_at = ? WHERE id = ?")
            defer { sqlite3_finalize(update) }
            try bind(summary, at: 1, to: update); try bind(summary, at: 2, to: update); try bind(now, at: 3, to: update); try bind(existing, at: 4, to: update); try step(update)
            try insertAlias(existing, value: name, source: email == nil ? "transcript" : "email")
            if let email { try insertAlias(existing, value: email, source: "email") }
            return existing
        }
        let statement = try prepare("INSERT INTO entities(kind, name, world, summary, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(kindValue.rawValue, at: 1, to: statement); try bind(name, at: 2, to: statement); try bind(worldValue.rawValue, at: 3, to: statement)
        try bind(summary, at: 4, to: statement); try bind(now, at: 5, to: statement); try bind(now, at: 6, to: statement); try step(statement)
        let id = sqlite3_last_insert_rowid(db)
        try insertAlias(id, value: name, source: email == nil ? "transcript" : "email")
        if let email { try insertAlias(id, value: email, source: "email") }
        if kindValue == .person, let first = name.split(separator: " ").first, name.split(separator: " ").count > 1 {
            let matching = attendees.map(Self.normalize).filter { $0.split(separator: " ").first.map(String.init) == Self.normalize(String(first)) }
            if matching.count <= 1 { try insertAlias(id, value: String(first), source: "context") }
        }
        return id
    }

    private func insertAlias(_ entityID: Int64, value: String, source: String) throws {
        let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = Self.normalize(display)
        guard !norm.isEmpty else { return }
        let statement = try prepare("INSERT OR IGNORE INTO aliases(entity_id, alias_norm, alias_display, source) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(entityID, at: 1, to: statement); try bind(norm, at: 2, to: statement); try bind(display, at: 3, to: statement); try bind(source, at: 4, to: statement); try step(statement)
    }

    private func queryEntity(id: Int64) throws -> BrainEntity? {
        let statement = try prepare("SELECT id, kind, name, world, summary, created_at, updated_at, forgotten FROM entities WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return entity(statement)
    }

    public func personDossier(_ name: String) throws -> BrainPersonDossier? {
        lock.lock(); defer { lock.unlock() }
        guard let id = try entityID(matching: name, kind: .person), let person = try queryEntity(id: id) else { return nil }
        let aliases = try queryAliases(entityID: id)
        let allCommitments = try queryFacts("kind = 'commitment' AND invalidated_at IS NULL AND done = 0 AND status <> 'forgotten' AND (owner_id = ? OR counterparty_id = ?)", ids: [id, id])
        let by = allCommitments.filter { $0.ownerID == id }, to = allCommitments.filter { $0.counterpartyID == id }
        let positions = try queryFacts("kind = 'position' AND subject_id = ? AND invalidated_at IS NULL AND status <> 'forgotten'", ids: [id])
        let history = try queryFacts("kind = 'position' AND subject_id = ? AND status <> 'forgotten'", ids: [id])
        let meetings = try queryEpisodesForFacts(personID: id)
        return BrainPersonDossier(entity: person, aliases: aliases, openCommitmentsByPerson: by, openCommitmentsToPerson: to,
                                  positions: positions, positionHistory: history, meetings: meetings)
    }

    public func openPromises(me: String = "Me") throws -> BrainPromises {
        lock.lock(); defer { lock.unlock() }
        guard let id = try entityID(matching: me, kind: .person) else { return BrainPromises(iOwe: [], owedToMe: []) }
        let facts = try queryFacts("kind = 'commitment' AND invalidated_at IS NULL AND done = 0 AND status <> 'forgotten' AND (owner_id = ? OR counterparty_id = ?)", ids: [id, id])
        return BrainPromises(iOwe: facts.filter { $0.ownerID == id }.sorted { ($0.due ?? "zzzz") < ($1.due ?? "zzzz") },
                             owedToMe: facts.filter { $0.counterpartyID == id }.sorted { ($0.due ?? "zzzz") < ($1.due ?? "zzzz") })
    }

    public func changes(since date: Date) throws -> [BrainFact] {
        lock.lock(); defer { lock.unlock() }
        return try queryFacts("valid_from >= ? OR invalidated_at >= ?", strings: [ISO8601DateFormatter().string(from: date), ISO8601DateFormatter().string(from: date)])
    }

    public func conflictSearch(_ name: String) throws -> BrainConflictSearch {
        lock.lock(); defer { lock.unlock() }
        let terms = Self.normalize(name).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return BrainConflictSearch(entities: [], facts: []) }
        let pattern = "%\(terms.joined(separator: "%"))%"
        let entityStatement = try prepare("SELECT id, kind, name, world, summary, created_at, updated_at, forgotten FROM entities WHERE lower(name) LIKE ? OR id IN (SELECT entity_id FROM aliases WHERE alias_norm LIKE ?) ORDER BY name")
        defer { sqlite3_finalize(entityStatement) }
        try bind(pattern, at: 1, to: entityStatement); try bind(pattern, at: 2, to: entityStatement)
        var entities: [BrainEntity] = []; var ids: [Int64] = []
        while sqlite3_step(entityStatement) == SQLITE_ROW { entities.append(entity(entityStatement)); ids.append(sqlite3_column_int64(entityStatement, 0)) }
        let facts = try ids.isEmpty ? [] : queryFacts("subject_id IN (\(ids.map { String($0) }.joined(separator: ","))) OR object_id IN (\(ids.map { String($0) }.joined(separator: ","))) OR owner_id IN (\(ids.map { String($0) }.joined(separator: ","))) OR counterparty_id IN (\(ids.map { String($0) }.joined(separator: ",")))")
        return BrainConflictSearch(entities: entities, facts: facts)
    }

    public func factsForChat(_ query: String, limit: Int = 8) throws -> [BrainFactHit] {
        lock.lock(); defer { lock.unlock() }
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\(Self.ftsQuote($0))*" }.joined(separator: " OR ")
        let statement = try prepare("""
            SELECT f.id, e.started_at, f.line_start, f.line_end
            FROM facts_fts JOIN facts f ON f.id = facts_fts.rowid
            JOIN episodes e ON e.id = f.episode_id
            WHERE facts_fts MATCH ? AND f.status <> 'forgotten'
            ORDER BY bm25(facts_fts) LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        try bind(match, at: 1, to: statement); try bind(Int64(limit), at: 2, to: statement)
        var hits: [BrainFactHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            if let fact = try queryFact(id: id) {
                hits.append(BrainFactHit(fact: fact, meetingDate: text(statement, 1), line: "line \(sqlite3_column_int(statement, 2))"))
            }
        }
        return hits
    }

    public func applyCorrection(factID: Int64, action: String, oldJSON: String = "", newJSON: String = "") throws {
        lock.lock(); defer { lock.unlock() }
        try withTransaction {
            let now = Self.now()
            let correction = try prepare("INSERT INTO corrections(fact_id, action, old_json, new_json, created_at) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(correction) }
            try bind(factID, at: 1, to: correction); try bind(action, at: 2, to: correction); try bind(oldJSON, at: 3, to: correction); try bind(newJSON, at: 4, to: correction); try bind(now, at: 5, to: correction); try step(correction)
            if action == "edit", let data = newJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data), let patch = object as? [String: Any] {
                let statement = try prepare("UPDATE facts SET predicate = COALESCE(?, predicate), value = COALESCE(?, value), due = COALESCE(?, due), quote = COALESCE(?, quote), status = 'corrected' WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(patch["predicate"] as? String, at: 1, to: statement); try bind(patch["value"] as? String, at: 2, to: statement)
                try bind(patch["due"] as? String, at: 3, to: statement); try bind(patch["quote"] as? String, at: 4, to: statement)
                try bind(factID, at: 5, to: statement); try step(statement)
            } else {
                let sql: String
                switch action {
                case "done": sql = "UPDATE facts SET done = 1, status = 'verified' WHERE id = ?"
                case "forget": sql = "UPDATE facts SET status = 'forgotten' WHERE id = ?"
                case "confirm": sql = "UPDATE facts SET status = 'verified' WHERE id = ?"
                case "wrong": sql = "UPDATE facts SET status = 'corrected' WHERE id = ?"
                default: sql = "UPDATE facts SET status = 'corrected' WHERE id = ?"
                }
                let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(factID, at: 1, to: statement); try step(statement)
            }
        }
    }

    // MARK: query helpers

    private func entityID(matching name: String, kind: BrainEntityKind) throws -> Int64? {
        let statement = try prepare("SELECT e.id FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE a.alias_norm = ? AND e.kind = ? AND e.forgotten = 0 LIMIT 2")
        defer { sqlite3_finalize(statement) }
        try bind(Self.normalize(name), at: 1, to: statement); try bind(kind.rawValue, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(statement, 0); guard sqlite3_step(statement) != SQLITE_ROW else { return nil }; return id
    }

    private func queryAliases(entityID: Int64) throws -> [BrainAlias] {
        let statement = try prepare("SELECT entity_id, alias_norm, alias_display, source FROM aliases WHERE entity_id = ? ORDER BY alias_display")
        defer { sqlite3_finalize(statement) }; try bind(entityID, at: 1, to: statement)
        var out: [BrainAlias] = []; while sqlite3_step(statement) == SQLITE_ROW { out.append(BrainAlias(entityID: sqlite3_column_int64(statement, 0), aliasNorm: text(statement, 1), aliasDisplay: text(statement, 2), source: text(statement, 3))) }; return out
    }

    private func queryEpisodesForFacts(personID: Int64) throws -> [BrainEpisode] {
        let statement = try prepare("SELECT DISTINCT e.id, e.meeting_folder, e.started_at, e.processed_at, e.model FROM episodes e JOIN facts f ON f.episode_id = e.id WHERE f.subject_id = ? OR f.object_id = ? OR f.owner_id = ? OR f.counterparty_id = ? ORDER BY e.started_at DESC")
        defer { sqlite3_finalize(statement) }; for (index, value) in [personID, personID, personID, personID].enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
        var out: [BrainEpisode] = []; while sqlite3_step(statement) == SQLITE_ROW { out.append(BrainEpisode(id: text(statement, 0), meetingFolder: text(statement, 1), startedAt: text(statement, 2), processedAt: optionalText(statement, 3), model: optionalText(statement, 4))) }; return out
    }

    private func queryFact(id: Int64) throws -> BrainFact? {
        let statement = try prepare(Self.factSQL + " WHERE f.id = ?"); defer { sqlite3_finalize(statement) }; try bind(id, at: 1, to: statement); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return fact(statement)
    }

    private func queryFacts(_ whereClause: String, ids: [Int64] = [], strings: [String] = []) throws -> [BrainFact] {
        let statement = try prepare(Self.factSQL + " WHERE " + whereClause + " ORDER BY f.valid_from DESC, f.id DESC"); defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in ids { try bind(value, at: index, to: statement); index += 1 }
        for value in strings { try bind(value, at: index, to: statement); index += 1 }
        var out: [BrainFact] = []; while sqlite3_step(statement) == SQLITE_ROW { out.append(fact(statement)) }; return out
    }

    private static let factSQL = "SELECT f.id, f.kind, f.subject_id, f.predicate, f.object_id, f.value, f.owner_id, f.counterparty_id, f.due, f.done, f.valid_from, f.invalidated_at, f.superseded_by, f.status, f.confidence, f.episode_id, f.line_start, f.line_end, f.quote, f.created_at, f.embedding FROM facts f"

    private func entity(_ statement: OpaquePointer) -> BrainEntity {
        BrainEntity(id: sqlite3_column_int64(statement, 0), kind: BrainEntityKind(rawValue: text(statement, 1)) ?? .topic,
                    name: text(statement, 2), world: BrainWorld(rawValue: text(statement, 3)) ?? .unknown, summary: text(statement, 4),
                    createdAt: text(statement, 5), updatedAt: text(statement, 6), forgotten: sqlite3_column_int(statement, 7) != 0)
    }

    private func fact(_ statement: OpaquePointer) -> BrainFact {
        BrainFact(id: sqlite3_column_int64(statement, 0), kind: BrainFactKind(rawValue: text(statement, 1)) ?? .fact,
                  subjectID: optionalInt(statement, 2), predicate: text(statement, 3), objectID: optionalInt(statement, 4), value: text(statement, 5),
                  ownerID: optionalInt(statement, 6), counterpartyID: optionalInt(statement, 7), due: optionalText(statement, 8), done: sqlite3_column_int(statement, 9) != 0,
                  validFrom: text(statement, 10), invalidatedAt: optionalText(statement, 11), supersededBy: optionalInt(statement, 12), status: text(statement, 13), confidence: sqlite3_column_double(statement, 14),
                  episodeID: text(statement, 15), lineStart: Int(sqlite3_column_int(statement, 16)), lineEnd: Int(sqlite3_column_int(statement, 17)), quote: text(statement, 18), createdAt: text(statement, 19), embedding: blob(statement, 20))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index) }
    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int64? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index) }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? { guard sqlite3_column_type(statement, index) != SQLITE_NULL, let bytes = sqlite3_column_blob(statement, index) else { return nil }; return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))) }

    // MARK: deterministic resolution and grounding

    public static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" }).map(String.init).joined(separator: " ")
    }

    private static func canonicalName(_ name: String, email: String?) -> String {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.contains("@") { return MeetingCalendar.displayName(name: candidate, url: nil) ?? candidate }
        if let email, candidate.isEmpty { return MeetingCalendar.displayName(name: nil, url: URL(string: "mailto:\(email)")) ?? email }
        return candidate
    }

    private static func contextualName(_ name: String, attendees: [String]) -> String {
        let normalized = normalize(name)
        guard normalized.split(separator: " ").count == 1 else { return name }
        let matches = attendees.filter { attendee in
            let normalizedAttendee = normalize(attendee)
            return normalizedAttendee.split(separator: " ").first.map(String.init) == normalized
        }
        return matches.count == 1 ? matches[0] : name
    }

    private static func aliases(for entity: BrainExtractionEntity, canonical: String, attendees: [String]) -> [String] {
        var values = [canonical, entity.name]; if let email = entity.email { values.append(email) }
        if entity.kind.lowercased() == "person", canonical.split(separator: " ").count > 1 {
            let first = String(canonical.split(separator: " ").first!)
            if attendees.map(normalize).filter({ $0.split(separator: " ").first.map(String.init) == normalize(first) }).count <= 1 { values.append(first) }
        }
        return Array(Set(values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
    }

    private static func canMerge(existingName: String, incomingName: String, fullIncoming: Bool) -> Bool {
        let existing = normalize(existingName), incoming = normalize(incomingName)
        let existingFull = existing.split(separator: " ").count > 1
        return !(existingFull && fullIncoming && existing != incoming)
    }

    private static func groundedName(_ name: String, transcript: String, attendees: [String]) -> Bool {
        let clean = canonicalName(name, email: nil); let norm = normalize(clean)
        guard !norm.isEmpty else { return false }
        let transcriptNorm = normalize(transcript)
        if transcriptNorm.contains(norm) { return true }
        return attendees.map(normalize).contains(where: { $0 == norm || $0.contains(norm) || norm.contains($0) })
    }

    private static func normalizedTokens(_ value: String) -> [String] { normalize(value).split(separator: " ").map(String.init) }

    private static func matchQuote(_ quote: String, lines: [String], hintStart: Int?, hintEnd: Int?) -> (Int, Int)? {
        let q = normalizedTokens(quote); guard !q.isEmpty else { return nil }
        guard !lines.isEmpty else { return nil }
        func score(_ tokens: [String]) -> Double {
            let distance = levenshtein(q, tokens); return Double(distance) / Double(max(q.count, tokens.count, 1))
        }
        func candidate(_ start: Int, _ end: Int) -> Bool {
            let tokens = normalizedTokens(lines[(start - 1)...(end - 1)].joined(separator: " "))
            if tokens == q || tokens.count >= q.count && tokens.joined(separator: " ").contains(q.joined(separator: " ")) { return true }
            return q.count >= 4 && score(tokens) <= 0.24
        }
        if let hintStart, let hintEnd, hintStart > 0, hintEnd >= hintStart, hintEnd <= lines.count, candidate(hintStart, hintEnd) { return (hintStart, hintEnd) }
        for start in 1...max(1, lines.count) {
            for end in start...min(lines.count, start + 2) where candidate(start, end) { return (start, end) }
        }
        return nil
    }

    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))) }
            row = next
        }
        return row[b.count]
    }

    private static func ftsQuote(_ term: String) -> String { "\"\(term.replacingOccurrences(of: "\"", with: ""))\"" }
    private static func floatData(_ values: [Float]?) -> Data? { values?.withUnsafeBufferPointer { Data(buffer: $0) } }
}

// MARK: - Extraction and backfill

public enum BrainExtraction {
    public static let systemPrompt = """
    You extract a small, durable fact graph from a meeting transcript. Return one JSON object and nothing else.
    Use only what is directly said in the transcript. Never infer a name, organization, matter, date, commitment, or stance.
    An entity name must be spoken or supplied as a calendar attendee. A position is a party's stated stance on a topic.
    A fact's quote must be copied exactly from the transcript text (without inventing or paraphrasing); line_start and line_end are 1-based transcript line numbers.
    If a fact is useful but has no direct quote, set quote to "", line_start and line_end to 0; it will be stored as unverified.
    For commitments, owner and counterparty are the people or organizations who owe and receive the work. Use due only for a due phrase actually said.
    Keep the lists empty when the transcript does not support an item. Use kind values person|org|matter|topic and world values client|opposing|court|team|personal|other|unknown.
    Use fact kinds decision|commitment|position|fact|relationship. For positions, predicate is the topic and value is the stated stance.
    """

    public static func prompt(transcript: String, attendees: [String]) -> String {
        let calendar = attendees.isEmpty ? "none" : attendees.joined(separator: ", ")
        return """
        Calendar attendees (allowed entity names even if not spoken): \(calendar)
        Return exactly this shape:
        {"entities":[{"name":"","kind":"person|org|matter|topic","world":"unknown","summary":"","email":""}],"facts":[{"kind":"fact","subject":"","predicate":"","object":"","value":"","owner":"","counterparty":"","due":"","quote":"","line_start":0,"line_end":0,"confidence":0.0}]}

        Transcript:
        \(transcript)
        """
    }

    /// Defensive parser used by the live extractor and by fixture tests. It accepts a fenced or prefixed JSON object.
    public static func parseJSON(_ text: String) throws -> BrainExtractionPayload {
        let raw = Summarizer.extractJSON(text)
        guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrainStore.BrainStoreError.malformed("expected a JSON object")
        }
        func string(_ dict: [String: Any], _ keys: [String]) -> String? { for key in keys { if let value = dict[key] as? String { return value } }; return nil }
        func int(_ dict: [String: Any], _ keys: [String]) -> Int? { for key in keys { if let value = dict[key] as? Int { return value }; if let value = dict[key] as? NSNumber { return value.intValue }; if let value = dict[key] as? String, let number = Int(value) { return number } }; return nil }
        func double(_ dict: [String: Any], _ keys: [String]) -> Double? { for key in keys { if let value = dict[key] as? Double { return value }; if let value = dict[key] as? NSNumber { return value.doubleValue }; if let value = dict[key] as? String, let number = Double(value) { return number } }; return nil }
        let entityObjects = object["entities"] as? [[String: Any]] ?? []
        let factObjects = object["facts"] as? [[String: Any]] ?? []
        let entities = entityObjects.compactMap { item -> BrainExtractionEntity? in
            guard let name = string(item, ["name"])?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let kind = string(item, ["kind"])?.lowercased() else { return nil }
            return BrainExtractionEntity(name: name, kind: kind, world: string(item, ["world"]), summary: string(item, ["summary"]), email: string(item, ["email"]))
        }
        let facts = factObjects.compactMap { item -> BrainExtractionFact? in
            guard let kind = string(item, ["kind"])?.lowercased(), let subject = string(item, ["subject", "subject_name"]),
                  let predicate = string(item, ["predicate"]) else { return nil }
            return BrainExtractionFact(kind: kind, subject: subject, predicate: predicate, object: string(item, ["object", "object_name"]), value: string(item, ["value"]), owner: string(item, ["owner", "owner_name"]), counterparty: string(item, ["counterparty", "counterparty_name"]), due: string(item, ["due"]), quote: string(item, ["quote"]), lineStart: int(item, ["line_start", "lineStart"]), lineEnd: int(item, ["line_end", "lineEnd"]), confidence: double(item, ["confidence"]))
        }
        guard object["entities"] != nil || object["facts"] != nil else { throw BrainStore.BrainStoreError.malformed("missing entities/facts") }
        return BrainExtractionPayload(entities: entities, facts: facts)
    }

    public static func process(folder: URL, model: String, store: BrainStore, embedder: Embedder = NoOpEmbedder()) async -> Result {
        do {
            if store.hasEpisode(meetingFolder: folder) { return .alreadyProcessed }
            let transcript = try savedTranscript(at: folder)
            let attendees = try savedAttendees(at: folder)
            let started = try savedStarted(at: folder)
            guard transcriptWordCount(transcript) >= Grounding.minWords else {
                try store.markSkipped(meetingFolder: folder, startedAt: started); return .skippedShort
            }
            let output = try await Summarizer.complete(system: systemPrompt, user: prompt(transcript: transcript, attendees: attendees), model: model, maxTokens: 3500)
            let payload = try parseJSON(output)
            _ = try await store.ingest(meetingFolder: folder, startedAt: started, model: model, attendees: attendees, transcript: transcript, payload: payload, embedder: embedder)
            return .processed
        } catch {
            print("[Brain] skipped \(folder.lastPathComponent): \(error.localizedDescription)")
            return .failed
        }
    }

    public enum Result: Sendable { case processed, skippedShort, alreadyProcessed, failed }

    private static func savedTranscript(at folder: URL) throws -> String {
        let raw = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        return raw.split(separator: "\n").compactMap { line -> String? in
            let clean = String(line).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.hasPrefix("[") ? clean : nil
        }.joined(separator: "\n")
    }

    private static func savedAttendees(at folder: URL) throws -> [String] {
        let data = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["attendees"] as? [String] ?? []
    }

    private static func transcriptWordCount(_ transcript: String) -> Int {
        transcript.split(separator: "\n").reduce(0) { count, line in
            guard let close = line.firstIndex(of: "]"), let colon = line[close...].firstIndex(of: ":") else {
                return count + line.split(whereSeparator: \.isWhitespace).count
            }
            return count + line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).count
        }
    }

    private static func savedStarted(at folder: URL) throws -> String {
        let data = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let date = object["started"] as? String else {
            throw BrainStore.BrainStoreError.malformed("meeting has no started date")
        }
        return date
    }
}

public enum BrainBackfill {
    /// Processes one saved meeting at a time. The caller should ensure the notes model is already loaded.
    public static func run(root: URL = InferoidPaths.documents, model: String, store: BrainStore,
                           embedder: Embedder = NoOpEmbedder(), onResult: ((BrainExtraction.Result) -> Void)? = nil) async {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            if Task.isCancelled { return }
            let result = await BrainExtraction.process(folder: folder, model: model, store: store, embedder: embedder)
            onResult?(result)
        }
    }
}
