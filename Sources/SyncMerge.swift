import Foundation

// MARK: - Wire model
//
// Everything in this file is Foundation-only so the merge logic can be compiled
// and tested without AppKit/SwiftUI (see Tests/sync_merge_test.swift). SyncNote
// mirrors Note field-for-field; the conversion lives in WebDAVSync.swift.

struct SyncNote: Codable, Equatable {
    var id: String
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var pinned: Bool = false
    var order: Double = 0
}

struct SyncTombstone: Codable, Equatable {
    var id: String
    var deletedAt: Date
}

/// The full snapshot at {root}/NoneNote/sync.json.
struct SyncSnapshot: Codable, Equatable {
    var app: String = "NoneNote"
    var version: Int = 1
    var updated: Date = Date()
    var notes: [SyncNote] = []
    var deleted: [SyncTombstone] = []
}

struct MergeResult: Codable, Equatable {
    var notes: [SyncNote]
    var deleted: [SyncTombstone]
}

// MARK: - JSON (ISO8601 dates, fractional seconds)

enum SyncJSON {
    /// Writes fractional seconds so sub-second edits keep their ordering.
    private static let writer: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Reads either fractional or whole-second ISO8601, so snapshots written by
    /// other platforms (or older builds) still decode.
    private static let reader = ISO8601DateFormatter()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(writer.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = writer.date(from: s) ?? reader.date(from: s) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: dec.codingPath, debugDescription: "not ISO8601: \(s)"))
        }
        return d
    }()
}

// MARK: - Merge

enum SyncMerge {
    /// The one merge every platform implements:
    ///   - union local and remote notes by id; for the same id the larger
    ///     `modified` wins, and a tie goes to the remote copy;
    ///   - a tombstone with `deletedAt > note.modified` deletes the note;
    ///   - the merged state is the new local state and is pushed back.
    /// Tombstones whose note survived (note.modified >= deletedAt, e.g. an
    /// undo or a newer edit) are pruned from the result.
    static func merge(local: [SyncNote], tombstones: [SyncTombstone],
                      remote: SyncSnapshot?) -> MergeResult {
        var byId: [String: SyncNote] = [:]
        for n in local { byId[n.id] = n }
        for n in remote?.notes ?? [] {
            if let l = byId[n.id], l.modified > n.modified { continue }
            byId[n.id] = n   // newer remote wins; equal modified goes to remote
        }

        var stones: [String: SyncTombstone] = [:]
        for t in tombstones + (remote?.deleted ?? []) {
            if let e = stones[t.id], e.deletedAt >= t.deletedAt { continue }
            stones[t.id] = t
        }

        for t in stones.values {
            if let n = byId[t.id], t.deletedAt > n.modified {
                byId.removeValue(forKey: t.id)
            }
        }

        let surviving = Set(byId.keys)
        let deleted = stones.values
            .filter { !surviving.contains($0.id) }
            .sorted { $0.id < $1.id }
        // Deterministic order keeps the pushed payload stable, which is what the
        // lastPushedHash loop-guard compares against.
        let notes = byId.values.sorted {
            ($0.order, $0.id) < ($1.order, $1.id)
        }
        return MergeResult(notes: notes, deleted: deleted)
    }

    /// Ids present at the last sync but gone now were deleted locally while
    /// offline (or between syncs) — each becomes a tombstone stamped `now`.
    static func detectDeletions(knownIds: Set<String>, currentIds: Set<String>,
                                at now: Date = Date()) -> [SyncTombstone] {
        knownIds.subtracting(currentIds).sorted().map { SyncTombstone(id: $0, deletedAt: now) }
    }
}
