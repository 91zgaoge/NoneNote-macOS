import Foundation

// Build & run:  swiftc Tests/sync_merge_test.swift Sources/SyncMerge.swift -o /tmp/merge_test && /tmp/merge_test
// SyncMerge.swift is Foundation-only, so this test binary needs no AppKit.

@main
enum MergeTestMain {
    static func main() {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    func note(_ id: String, body: String = "", modified: Date, order: Double = 0) -> SyncNote {
        SyncNote(id: id, title: "", body: body, color: 0,
                 created: modified, modified: modified,
                 archived: false, pinned: false, order: order)
    }

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t1 = t0.addingTimeInterval(10)
    let t2 = t0.addingTimeInterval(20)

    // MARK: JSON round-trip

    do {
        let snap = SyncSnapshot(updated: t1, notes: [note("a", body: "hi", modified: t1)],
                                deleted: [SyncTombstone(id: "b", deletedAt: t2)])
        let data = try SyncJSON.encoder.encode(snap)
        let back = try SyncJSON.decoder.decode(SyncSnapshot.self, from: data)
        check(back == snap, "json round-trip")
        let s = String(decoding: data, as: UTF8.self)
        check(s.contains("\"app\":\"NoneNote\"") && s.contains("\"version\":1"), "schema fields")
        // Whole-second ISO8601 from other platforms must still decode.
        let whole = #"{"app":"NoneNote","version":1,"updated":"2023-11-14T22:13:20Z","notes":[],"deleted":[]}"#
        check((try? SyncJSON.decoder.decode(SyncSnapshot.self, from: Data(whole.utf8))) != nil,
              "decodes whole-second ISO8601")
    } catch {
        check(false, "json round-trip threw \(error)")
    }

    // MARK: LWW

    do {
        // Remote newer → remote wins.
        let r = SyncMerge.merge(local: [note("a", body: "old", modified: t0)],
                                tombstones: [],
                                remote: SyncSnapshot(notes: [note("a", body: "new", modified: t1)]))
        check(r.notes.first { $0.id == "a" }?.body == "new", "LWW remote newer wins")

        // Local newer → local wins.
        let r2 = SyncMerge.merge(local: [note("a", body: "local", modified: t2)],
                                 tombstones: [],
                                 remote: SyncSnapshot(notes: [note("a", body: "remote", modified: t1)]))
        check(r2.notes.first { $0.id == "a" }?.body == "local", "LWW local newer wins")

        // Equal modified → remote wins.
        let r3 = SyncMerge.merge(local: [note("a", body: "local", modified: t1)],
                                 tombstones: [],
                                 remote: SyncSnapshot(notes: [note("a", body: "remote", modified: t1)]))
        check(r3.notes.first { $0.id == "a" }?.body == "remote", "equal modified → remote wins")

        // Disjoint sets union.
        let r4 = SyncMerge.merge(local: [note("a", modified: t0)],
                                 tombstones: [],
                                 remote: SyncSnapshot(notes: [note("b", modified: t0)]))
        check(Set(r4.notes.map(\.id)) == ["a", "b"], "disjoint ids union")
    }

    // MARK: Tombstones

    do {
        // deletedAt > modified deletes the note (tombstone from either side).
        let r = SyncMerge.merge(local: [note("a", modified: t0)],
                                tombstones: [SyncTombstone(id: "a", deletedAt: t1)],
                                remote: nil)
        check(r.notes.isEmpty && r.deleted.count == 1, "local tombstone deletes note")

        let r2 = SyncMerge.merge(local: [note("a", modified: t0)],
                                 tombstones: [],
                                 remote: SyncSnapshot(deleted: [SyncTombstone(id: "a", deletedAt: t1)]))
        check(r2.notes.isEmpty && r2.deleted.count == 1, "remote tombstone deletes note")

        // deletedAt <= modified: note survives, tombstone pruned.
        let r3 = SyncMerge.merge(local: [note("a", modified: t2)],
                                 tombstones: [SyncTombstone(id: "a", deletedAt: t1)],
                                 remote: nil)
        check(r3.notes.count == 1 && r3.deleted.isEmpty, "stale tombstone pruned, note kept")

        // Same tombstone on both sides merges to one, max deletedAt kept.
        let r4 = SyncMerge.merge(local: [],
                                 tombstones: [SyncTombstone(id: "a", deletedAt: t1)],
                                 remote: SyncSnapshot(deleted: [SyncTombstone(id: "a", deletedAt: t2)]))
        check(r4.deleted == [SyncTombstone(id: "a", deletedAt: t2)], "tombstone union keeps max deletedAt")
    }

    // MARK: Local deletion detection

    do {
        let tombs = SyncMerge.detectDeletions(knownIds: ["a", "b", "c"],
                                              currentIds: ["b", "d"], at: t1)
        check(tombs.map(\.id) == ["a", "c"], "deleted locally → tombstones")
        check(tombs.allSatisfy { $0.deletedAt == t1 }, "tombstones stamped now")
    }

    // MARK: Idempotence

    do {
        let local = [note("a", body: "la", modified: t1, order: 0),
                     note("b", body: "lb", modified: t0, order: 1)]
        let stones = [SyncTombstone(id: "z", deletedAt: t2)]
        let remote = SyncSnapshot(updated: t1,
                                  notes: [note("a", body: "ra", modified: t2, order: 0),
                                          note("c", body: "rc", modified: t0, order: 2)],
                                  deleted: [SyncTombstone(id: "z", deletedAt: t1)])
        let once = SyncMerge.merge(local: local, tombstones: stones, remote: remote)
        let twice = SyncMerge.merge(local: once.notes, tombstones: once.deleted, remote: remote)
        check(once == twice, "merge is idempotent")
        check(once.notes.first { $0.id == "a" }?.body == "ra", "idempotent merge content sane")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
    }
}
