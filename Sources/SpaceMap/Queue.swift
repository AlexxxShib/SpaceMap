import Foundation

struct Mark: Identifiable {
    var id: String { url.path }
    let url: URL
    let identity: FileID
    let signature: Int
    let uniqueBytes: Int64
    let links: [FileID: Int64]
    let unknown: Int
    var problem: String?

    init?(_ node: Entry) {
        guard let identity = node.identity else { return nil }
        self.identity = identity
        url = node.url
        signature = node.signature
        unknown = node.unknown
        var linked: [FileID: Int64] = [:]
        var ownedLinkBytes: Int64 = 0
        func collect(_ e: Entry) {
            if e.multiLink, let id = e.identity {
                linked[id] = e.rawBytes
                ownedLinkBytes += e.bytes
            }
            for child in e.children where child.containsLinks { collect(child) }
        }
        if node.containsLinks { collect(node) }
        links = linked
        uniqueBytes = node.bytes - ownedLinkBytes
    }

    var bytes: Int64 { uniqueBytes + links.values.reduce(0, +) }
}

struct RemovalQueue {
    var entries: [Mark] = []
    var bytes: Int64 {
        var seen: Set<FileID> = []
        return entries.reduce(0) { result, mark in
            result + mark.uniqueBytes + mark.links.reduce(0) { subtotal, pair in
                subtotal + (seen.insert(pair.key).inserted ? pair.value : 0)
            }
        }
    }
    func covering(_ path: String) -> Mark? {
        entries.first { path == $0.id || path.hasPrefix($0.id + "/") }
    }
    mutating func toggle(_ node: Entry) {
        let path = node.url.path
        if let mark = covering(path) {
            if path == mark.id { entries.removeAll { $0.id == path } }
            return
        }
        guard let mark = Mark(node) else { return }
        entries.removeAll { $0.id.hasPrefix(path + "/") }
        entries.append(mark)
    }
}

enum TrashResult {
    case moved, skipped(String), changed(Mark)
}

enum Trash {
    static func apply(_ mark: Mark, disk: Disk, move: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) -> TrashResult {
        do {
            guard Disk(disk.url, folder: disk.isFolder)?.id == disk.id else { return .skipped("Disk unavailable") }
            let path = mark.url.path
            guard path != disk.url.path, path.hasPrefix(disk.url.path == "/" ? "/" : disk.url.path + "/"),
                  FileID(try fileStatus(mark.url)) == mark.identity else { return .skipped("The item at this path has changed.") }
            let fresh = try Scanner().scan(mark.url).root
            guard fresh.identity == mark.identity else { return .skipped("The item has been replaced.") }
            guard fresh.unknown == 0 && !fresh.excludedChildren else { return .skipped("Couldn’t verify all contents.") }
            if fresh.signature != mark.signature, let updated = Mark(fresh) { return .changed(updated) }
            guard FileID(try fileStatus(mark.url)) == mark.identity else { return .skipped("The item has been replaced.") }
            try move(mark.url)
            return .moved
        } catch { return .skipped(error.localizedDescription) }
    }
}
