import Foundation
import AppKit
import Combine
import CryptoKit

// MARK: - Note ↔ SyncNote

extension SyncNote {
    init(_ n: Note) {
        id = n.id; title = n.title; body = n.body; color = n.color
        created = n.created; modified = n.modified
        archived = n.archived; pinned = n.pinned; order = n.order
    }
    var note: Note {
        Note(id: id, title: title, body: body, color: color, created: created,
             modified: modified, archived: archived, pinned: pinned, order: order)
    }
}

// MARK: - Configuration (UserDefaults)

enum WebDAVConfig {
    private static let d = UserDefaults.standard

    static var url: String {
        get { d.string(forKey: "webdavURL") ?? "" }
        set { d.set(newValue, forKey: "webdavURL") }
    }
    static var user: String {
        get { d.string(forKey: "webdavUser") ?? "" }
        set { d.set(newValue, forKey: "webdavUser") }
    }
    static var pass: String {
        get { d.string(forKey: "webdavPass") ?? "" }
        set { d.set(newValue, forKey: "webdavPass") }
    }
    static var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Internal sync state.
    static var knownIds: Set<String> {
        get {
            guard let data = d.data(forKey: "syncKnownIds"),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(ids)
        }
        set { d.set(try? JSONEncoder().encode(newValue.sorted()), forKey: "syncKnownIds") }
    }
    static var tombstones: [SyncTombstone] {
        get {
            guard let data = d.data(forKey: "syncDeleted") else { return [] }
            return (try? SyncJSON.decoder.decode([SyncTombstone].self, from: data)) ?? []
        }
        set { d.set(try? SyncJSON.encoder.encode(newValue), forKey: "syncDeleted") }
    }
    /// Hash of the last pushed notes+tombstones; unchanged content skips the PUT.
    static var pushedHash: String {
        get { d.string(forKey: "syncPushedHash") ?? "" }
        set { d.set(newValue, forKey: "syncPushedHash") }
    }
    static var lastSyncAt: Date? {
        get { d.object(forKey: "syncLastAt") as? Date }
        set { d.set(newValue, forKey: "syncLastAt") }
    }
}

// MARK: - HTTP client

enum SyncError: Error {
    case badURL, http(Int), empty
}

/// Minimal WebDAV client: HTTP Basic auth, PROPFIND/MKCOL/GET/PUT.
/// Every failure is logged and swallowed — sync must never pop alerts or crash.
struct WebDAVClient {
    let root: String   // server root, no trailing slash
    let user: String
    let pass: String

    var dirURL: URL?  { URL(string: root + "/NoneNote/") }
    var fileURL: URL? { URL(string: root + "/NoneNote/sync.json") }

    private func request(_ method: String, _ url: URL, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        let cred = Data("\(user):\(pass)".utf8).base64EncodedString()
        r.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        if method == "PROPFIND" { r.setValue("0", forHTTPHeaderField: "Depth") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    @discardableResult
    private func send(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Int, Data) {
        let (data, resp) = try await URLSession.shared.data(for: request(method, url, body: body))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    /// Probe the sync file. Returns true when it exists; creates the NoneNote
    /// collection when the whole tree is missing.
    func probe() async throws -> Bool {
        guard let fileURL, let dirURL else { throw SyncError.badURL }
        let (status, _) = try await send("PROPFIND", fileURL)
        if status == 404 {
            _ = try? await send("MKCOL", dirURL)   // ignore: may already exist or be refused
            return false
        }
        guard (200..<300).contains(status) else { throw SyncError.http(status) }
        return true
    }

    func pull() async throws -> SyncSnapshot? {
        guard let fileURL else { throw SyncError.badURL }
        let (status, data) = try await send("GET", fileURL)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw SyncError.http(status) }
        return try SyncJSON.decoder.decode(SyncSnapshot.self, from: data)
    }

    func push(_ snapshot: SyncSnapshot) async throws {
        guard let fileURL else { throw SyncError.badURL }
        let data = try SyncJSON.encoder.encode(snapshot)
        let (status, _) = try await send("PUT", fileURL, body: data)
        guard (200..<300).contains(status) else { throw SyncError.http(status) }
    }
}

// MARK: - Sync manager

/// Serialises sync runs: once at launch, 2 s after any local change, and on
/// demand from the menus/settings. Merge rules live in SyncMerge (pure).
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date? = WebDAVConfig.lastSyncAt

    private var bag = Set<AnyCancellable>()
    private var runAgain = false
    private var applyingRemote = false

    private init() {}

    /// Called once from AppDelegate: wires the debounced push and kicks the
    /// initial pull+merge.
    func start() {
        NoteStore.shared.$notes
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.applyingRemote else { return }
                self.syncNow()
            }
            .store(in: &bag)
        syncNow()
    }

    func syncNow() {
        guard WebDAVConfig.isConfigured else { return }
        guard !isSyncing else { runAgain = true; return }
        isSyncing = true
        Task { await run() }
    }

    private func run() async {
        defer {
            DispatchQueue.main.async {
                self.isSyncing = false
                if self.runAgain { self.runAgain = false; self.syncNow() }
            }
        }
        do {
            try await syncOnce()
            DispatchQueue.main.async { self.lastSyncAt = WebDAVConfig.lastSyncAt }
        } catch {
            NSLog("NoneNote sync failed: \(error.localizedDescription)")
        }
    }

    private func syncOnce() async throws {
        let client = WebDAVClient(
            root: WebDAVConfig.url.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression),
            user: WebDAVConfig.user, pass: WebDAVConfig.pass)

        // Local state: current notes + tombstones for anything deleted since the
        // last sync (ids we knew then but no longer have).
        let local: [SyncNote] = await MainActor.run { NoteStore.shared.notes.map(SyncNote.init) }
        let now = Date()
        var stones = WebDAVConfig.tombstones
        stones += SyncMerge.detectDeletions(knownIds: WebDAVConfig.knownIds,
                                            currentIds: Set(local.map(\.id)), at: now)

        let exists = try await client.probe()
        let remote = exists ? try await client.pull() : nil

        let merged = SyncMerge.merge(local: local, tombstones: stones, remote: remote)

        // Apply the merged state locally before pushing, so the UI reflects
        // remote wins even if the PUT below fails.
        let mergedNotes = merged.notes
        await MainActor.run {
            applyingRemote = true
            NoteStore.shared.applyMerged(mergedNotes.map(\.note))
            applyingRemote = false
        }

        // Loop guard: identical content means no PUT (and no echo of our own push).
        let contentData = try SyncJSON.encoder.encode(merged)
        let hash = SHA256.hash(data: contentData).map { String(format: "%02x", $0) }.joined()
        if hash != WebDAVConfig.pushedHash {
            try await client.push(SyncSnapshot(updated: now, notes: merged.notes,
                                               deleted: merged.deleted))
            WebDAVConfig.pushedHash = hash
        }

        WebDAVConfig.knownIds = Set(merged.notes.map(\.id))
        WebDAVConfig.tombstones = merged.deleted
        WebDAVConfig.lastSyncAt = now
    }
}
