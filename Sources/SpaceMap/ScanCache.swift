import CryptoKit
import Foundation
import SQLite3

private let invalidMap = CocoaError(.fileReadCorruptFile)

private struct SavedID: Codable {
    let device: dev_t
    let inode: ino_t
    let seconds: Int
    let nanos: Int
    init(_ id: FileID) {
        device = id.device
        inode = id.inode
        seconds = id.birth.tv_sec
        nanos = id.birth.tv_nsec
    }
    var value: FileID { FileID(device: device, inode: inode, birth: timespec(tv_sec: seconds, tv_nsec: nanos)) }
}

private struct SavedEntry: Codable {
    let name: String
    let identity: SavedID?
    let kind: EntryKind
    let raw: Int64
    let bytes: Int64
    let signature: Int
    let unknown: Int
    let links: Bool
    let multi: Bool
    let excluded: Bool
    let owner: String?
    let hasChildren: Bool
    // Packages expose only the hard links needed by the removal queue.
    let hidden: [SavedEntry]?

    init(_ entry: Entry, insidePackage: Bool = false) {
        name = entry.name
        identity = entry.identity.map(SavedID.init)
        kind = entry.kind
        raw = entry.rawBytes
        bytes = entry.bytes
        signature = entry.signature
        unknown = entry.unknown
        links = entry.containsLinks
        multi = entry.multiLink
        excluded = entry.excludedChildren
        owner = entry.sharedOwner
        // A reused branch may still have its children on disk. Keep it lazy when saving the parent.
        hasChildren = entry.restoreChildren != nil || !entry.children.isEmpty
        hidden = (kind == .package || insidePackage) && hasChildren
            ? entry.children.map { SavedEntry($0, insidePackage: true) } : nil
    }
}

private struct SavedMap: Codable {
    let source: String
    let path: String
    let root: SavedEntry
    let issues: [ScanIssue]
    let finished: Date
    let point: JournalPoint?
    let boot: String
    let hardLinks: [SavedID]
}

// Each key holds one directory listing. A single SQLite transaction commits changed
// listings and their journal cursor together. Older on-screen maps pin a read transaction.
private final class MapDatabase {
    let handle: OpaquePointer
    private let readLock = NSLock()
    private var lookup: OpaquePointer?
    private var put: OpaquePointer?
    init(_ url: URL, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        handle = db
        sqlite3_busy_timeout(db, 1500)
        if !readOnly {
            try sql("PRAGMA journal_mode=WAL")
            try sql("CREATE TABLE IF NOT EXISTS entries (path TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID")
        }
        guard sqlite3_prepare_v2(db, "SELECT data FROM entries WHERE path=?", -1, &lookup, nil) == SQLITE_OK else { throw invalidMap }
        if !readOnly {
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO entries VALUES (?,?)", -1, &put, nil) == SQLITE_OK else { throw invalidMap }
        }
    }
    deinit { sqlite3_finalize(lookup); sqlite3_finalize(put); sqlite3_close(handle) }

    func sql(_ command: String) throws {
        guard sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> NSError {
        NSError(domain: "SpaceMap.Cache", code: Int(sqlite3_errcode(handle)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }

    func read<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let data: Data = try key.withCString { key in
            readLock.lock()
            defer { readLock.unlock() }
            defer { sqlite3_reset(lookup); sqlite3_clear_bindings(lookup) }
            sqlite3_bind_text(lookup, 1, key, -1, nil)
            guard sqlite3_step(lookup) == SQLITE_ROW, let ptr = sqlite3_column_blob(lookup, 0) else { throw invalidMap }
            return Data(bytes: ptr, count: Int(sqlite3_column_bytes(lookup, 0)))
        }
        return try PropertyListDecoder().decode(type, from: data)
    }
    func write<T: Encodable>(_ item: T, key: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(item)
        try key.withCString { path in
            try data.withUnsafeBytes { buffer in
                defer { sqlite3_reset(put); sqlite3_clear_bindings(put) }
                sqlite3_bind_text(put, 1, path, -1, nil)
                sqlite3_bind_blob64(put, 2, buffer.baseAddress, UInt64(buffer.count), nil)
                guard sqlite3_step(put) == SQLITE_DONE else { throw error() }
            }
        }
    }

    func removeBranch(_ path: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM entries WHERE path=?1 OR (path >= ?2 AND path < ?3)", -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, path, -1, transient)
        sqlite3_bind_text(stmt, 2, path + "/", -1, transient)
        sqlite3_bind_text(stmt, 3, path + "0", -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
}

private final class MapReader {
    let db: MapDatabase
    let header: SavedMap
    let damaged: () -> Void
    init(file: URL, disk: Disk, damaged: @escaping () -> Void) throws {
        db = try MapDatabase(file, readOnly: true)
        try db.sql("BEGIN")
        header = try db.read(SavedMap.self, key: "")
        self.damaged = damaged
        guard header.source == disk.id, header.path == disk.url.path,
              header.root.identity?.value == FileID(try fileStatus(disk.url)) else { throw invalidMap }
    }

    func entry(_ record: SavedEntry, anchor: URL, parent: Entry?) -> Entry {
        let node = Entry(name: record.name, anchor: anchor, parent: parent, identity: record.identity?.value,
                         multiLink: record.multi, kind: record.kind, bytes: record.raw)
        node.bytes = record.bytes
        node.unknown = record.unknown
        node.signature = record.signature
        node.containsLinks = record.links
        node.excludedChildren = record.excluded
        node.sharedOwner = record.owner
        if record.hasChildren {
            node.restoreChildren = { [self] parent in
                do {
                    let rows = try record.hidden ?? db.read([SavedEntry].self, key: anchor.path)
                    return rows.map { child in
                        let url = child.kind == .directory || child.kind == .package
                            ? anchor.appendingPathComponent(child.name, isDirectory: true) : anchor
                        return entry(child, anchor: url, parent: parent)
                    }
                } catch {
                    parent.unknown = max(1, parent.unknown)
                    damaged()
                    return []
                }
            }
        }
        return node
    }
    func snapshot(_ disk: Disk) -> ScanResult {
        ScanResult(root: entry(header.root, anchor: disk.url, parent: nil), issues: header.issues, finished: header.finished)
    }
}

struct ScanCache {
    let directory: URL
    private let checkpoint: (URL) -> JournalPoint?
    private let changedPaths: (JournalPoint, JournalPoint, URL) -> ChangedPaths?
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.spacemap.app/Maps-v1", isDirectory: true),
         checkpoint: @escaping (URL) -> JournalPoint? = ChangeJournal.checkpoint,
         changedPaths: ((JournalPoint, JournalPoint, URL) -> ChangedPaths?)? = nil) {
        self.directory = directory
        self.checkpoint = checkpoint
        self.changedPaths = changedPaths ?? {
            ChangeJournal.changes(since: $0, to: $1, root: $2, synchronizeAt: directory)?.paths
        }
    }
    func file(for disk: Disk) -> URL {
        let key = SHA256.hash(data: Data((disk.id + "\u{0}" + disk.url.path).utf8))
        return directory.appendingPathComponent(key.map { String(format: "%02x", $0) }.joined() + ".sqlite")
    }

    private var boot: String {
        var buffer = [CChar](repeating: 0, count: 128)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return UUID().uuidString }
        return String(cString: buffer)
    }

    func scan(_ disk: Disk, scanner: Scanner, forceFull: Bool = false,
              preview: (ScanResult) -> Void = { _ in }, damaged: @escaping () -> Void = {},
              warning: @escaping (String) -> Void = { _ in }) throws -> ScanResult {
        let file = file(for: disk)
        var writer: MapDatabase?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let db = try MapDatabase(file, readOnly: false)
            try db.sql("BEGIN IMMEDIATE")
            writer = db
        } catch { warning("Couldn’t save the map: " + error.localizedDescription) }
        let previous = forceFull ? nil : try? MapReader(file: file, disk: disk, damaged: damaged)
        if let previous { preview(previous.snapshot(disk)) }
        let start = checkpoint(disk.url)
        let session = boot
        var changes: ChangedPaths?
        if let previous, previous.header.boot == session || disk.url.path != "/",
           let old = previous.header.point, let start {
            // Only persist the per-device historical checkpoint. Recent file events
            // may still be coalesced by fseventsd across rapid consecutive updates.
            changes = changedPaths(old, start, disk.url)
        }
        try Task.checkCancellation()

        // Only index directories along changed paths. A clean sibling remains a summary
        // with its saved children available for drill-down, regardless of subtree size.
        var listings: [String: [String: SavedEntry]] = [:]
        func listing(_ path: String) throws -> [String: SavedEntry] {
            if let found = listings[path] { return found }
            guard let previous else { return [:] }
            let rows = try previous.db.read([SavedEntry].self, key: path)
            let dirs = rows.filter { $0.kind == .directory || $0.kind == .package }
            let found = Dictionary(dirs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            listings[path] = found
            return found
        }
        if let changes, let previous {
            scanner.reuse = { location, parent, info, kind in
                guard !changes.affects(location.path) else { return nil }
                let row: SavedEntry?
                if let parent { row = (try? listing(parent.url.path))?[location.lastPathComponent] }
                else { row = previous.header.root }
                guard let row, row.identity?.value == info.identity, row.kind == kind,
                      row.unknown == 0, !row.links, !row.excluded else { return nil }
                return previous.entry(row, anchor: location, parent: parent)
            }
        }
        func clearListings() {
            do { try writer?.sql("DELETE FROM entries") }
            catch { writer = nil; warning("Couldn’t save the map: " + error.localizedDescription) }
        }
        if changes == nil { clearListings() }
        scanner.excludedDirectory = (try? fileStatus(directory)).map(FileID.init)
        scanner.didRead = { node in
            guard let db = writer, node.folder else { return }
            do {
                let path = node.url.path
                if changes != nil, let old = try? listing(path) {
                    let current = Set(node.children.filter(\.folder).map(\.name))
                    for child in old.values where child.kind == .directory && !current.contains(child.name) {
                        try db.removeBranch(node.url.appendingPathComponent(child.name).path)
                    }
                }
                try db.write(node.children.map { SavedEntry($0) }, key: path)
                listings.removeValue(forKey: path)
            } catch { writer = nil; warning("Couldn’t save the map: " + error.localizedDescription) }
        }
        defer { scanner.reuse = nil; scanner.didRead = nil }
        var result = try scanner.scan(disk.url)
        if scanner.directoriesReused > 0, let previous,
           !scanner.linkedIdentities.isSubset(of: Set(previous.header.hardLinks.map(\.value))) {
            // A formerly single-link inode can have an alias in a clean cached folder.
            // Re-establish traversal order and ownership across the whole source.
            changes = nil
            scanner.reuse = nil
            listings.removeAll()
            clearListings()
            result = try scanner.scan(disk.url)
        }
        try Task.checkCancellation()
        guard result.root.identity == FileID(try fileStatus(disk.url)),
              Disk(disk.url, folder: disk.isFolder)?.id == disk.id else { throw CocoaError(.fileReadNoSuchFile) }
        if let writer {
            do {
                try writer.write(SavedMap(source: disk.id, path: disk.url.path, root: SavedEntry(result.root),
                                          issues: result.issues, finished: result.finished, point: start, boot: session,
                                          hardLinks: scanner.linkedIdentities.map(SavedID.init)), key: "")
                try Task.checkCancellation()
                try writer.sql("COMMIT")
            } catch is CancellationError { throw CancellationError() }
            catch { warning("Couldn’t save the map: " + error.localizedDescription) }
        }
        return result
    }
}
