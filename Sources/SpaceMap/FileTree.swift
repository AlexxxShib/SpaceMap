import Foundation
import Darwin

struct FileID: Hashable {
    let device: dev_t
    let inode: ino_t
    let birth: timespec

    init(_ s: stat) {
        device = s.st_dev
        inode = s.st_ino
        birth = s.st_birthtimespec
    }

    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.birth.tv_sec == b.birth.tv_sec && a.birth.tv_nsec == b.birth.tv_nsec
    }

    func hash(into h: inout Hasher) {
        h.combine(device)
        h.combine(inode)
        h.combine(birth.tv_sec)
        h.combine(birth.tv_nsec)
    }
}

func fileStatus(_ url: URL) throws -> stat {
    var value = stat()
    let result = url.withUnsafeFileSystemRepresentation { lstat($0, &value) }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return value
}

enum EntryKind { case directory, file, package, link }

final class Entry: Identifiable {
    let name: String
    let identity: FileID?
    let kind: EntryKind
    let rawBytes: Int64
    var bytes: Int64
    var unknown = 0
    var signature: Int = 0
    var sharedOwner: String?
    let multiLink: Bool
    var containsLinks = false
    var excludedChildren = false
    var children: [Entry] = []
    weak var parent: Entry?
    private let anchor: URL
    private let anchorIsParent: Bool

    init(url: URL, parent: Entry?, status: stat?, kind: EntryKind, bytes: Int64) {
        name = url.lastPathComponent
        anchorIsParent = parent != nil && kind != .directory && kind != .package
        anchor = anchorIsParent ? parent!.anchor : url
        self.parent = parent
        identity = status.map(FileID.init)
        multiLink = kind != .directory && kind != .package && (status?.st_nlink ?? 0) > 1
        containsLinks = multiLink
        self.kind = kind
        rawBytes = bytes
        self.bytes = bytes
    }

    var url: URL { anchorIsParent ? anchor.appendingPathComponent(name, isDirectory: false) : anchor }
    var folder: Bool { kind == .directory }
    var sizeLabel: String {
        if sharedOwner != nil { return "Учтено по другому пути" }
        if unknown > 0 { return bytes == 0 ? "Размер неизвестен" : "Учтено " + sizeText(bytes) }
        return sizeText(bytes)
    }

    func find(_ path: String) -> Entry? {
        let base = url.path
        if path == base { return self }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = self
        for part in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == part }) else { return nil }
            current = next
        }
        return current
    }
}

func sizeText(_ bytes: Int64) -> String {
    if bytes == 0 { return "0 Б" }
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
    var amount = Double(bytes), index = 0
    while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
    return amount.formatted(.number.precision(.fractionLength(0...1))) + " " + units[index]
}

struct Grouped {
    var main: [Entry] = []
    var small: [Entry] = []
    var unknown: [Entry] = []
    var smallBytes: Int64 = 0

    init(_ parent: Entry) {
        for entry in parent.children {
            if entry.bytes == 0 && entry.unknown > 0 {
                unknown.append(entry)
            } else if main.isEmpty || (main.count < 10 && (parent.bytes == 0 || Double(entry.bytes) >= Double(parent.bytes) / 100)) {
                main.append(entry)
            } else {
                small.append(entry)
                smallBytes += entry.bytes
            }
        }
    }
}

struct ScanIssue: Identifiable {
    var id: String { path }
    let path: String
    let reason: String
}

struct ScanResult {
    let root: Entry
    let issues: [ScanIssue]
    let finished: Date
}

final class Scanner {
    private var hardLinks: [FileID: String] = [:]
    private var devices: Set<dev_t> = []
    private var issues: [ScanIssue] = []
    private var count = 0
    private var lastReport = Date.distantPast
    private let manager = FileManager.default
    let progress: (Int, String) -> Void

    init(progress: @escaping (Int, String) -> Void = { _, _ in }) { self.progress = progress }

    func scan(_ root: URL) throws -> ScanResult {
        devices = [try fileStatus(root).st_dev]
        if root.path == "/", let data = try? fileStatus(URL(fileURLWithPath: "/System/Volumes/Data")) {
            devices.insert(data.st_dev)
        }
        let entry = try visit(root, parent: nil, retainChildren: true)!
        return ScanResult(root: entry, issues: issues, finished: Date())
    }

    private func visit(_ url: URL, parent: Entry?, retainChildren: Bool) throws -> Entry? {
        try Task.checkCancellation()
        count += 1
        if count == 1 || count % 128 == 0, Date().timeIntervalSince(lastReport) > 0.12 {
            lastReport = Date()
            progress(count, url.deletingLastPathComponent().path)
        }
        let s: stat
        do { s = try fileStatus(url) }
        catch {
            if parent == nil { throw error }
            let entry = Entry(url: url, parent: parent, status: nil, kind: .file, bytes: 0)
            entry.unknown = 1
            issues.append(ScanIssue(path: url.path, reason: error.localizedDescription))
            return entry
        }
        guard parent == nil || devices.contains(s.st_dev) else { return nil }
        let mode = s.st_mode & S_IFMT
        let kind: EntryKind
        if mode == S_IFDIR {
            let isPackage = retainChildren && parent != nil && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            kind = isPackage ? .package : .directory
        } else {
            kind = mode == S_IFLNK ? .link : .file
        }
        let directory = mode == S_IFDIR
        let actual = directory ? 0 : Int64(s.st_blocks) * 512
        let node = Entry(url: url, parent: parent, status: s, kind: kind, bytes: actual)
        var digest = Hasher()
        digest.combine(node.identity)
        digest.combine(s.st_mtimespec.tv_sec)
        digest.combine(s.st_mtimespec.tv_nsec)
        digest.combine(s.st_size)
        digest.combine(actual)
        if !directory {
            if node.multiLink, let id = node.identity {
                if let path = hardLinks[id] { node.sharedOwner = path; node.bytes = 0 }
                else { hardLinks[id] = url.path }
            }
        } else {
            let names: [String]
            do { names = try manager.contentsOfDirectory(atPath: url.path) }
            catch {
                if parent == nil { throw error }
                issues.append(ScanIssue(path: url.path, reason: error.localizedDescription))
                node.unknown = 1
                digest.combine("unreadable")
                node.signature = digest.finalize()
                return node
            }
            let path = url.path
            let showChildren = retainChildren && kind != .package
            for name in names.sorted() {
                let specialRoot = path == "/" && [".nofollow", ".vol", "dev"].contains(name)
                let mounts = path == "/System" && name == "Volumes"
                let trash = name == ".Trashes" || (name == ".Trash" && url.deletingLastPathComponent().path == "/Users")
                if specialRoot || mounts || trash { node.excludedChildren = true; continue }
                let child = try autoreleasepool {
                    try visit(url.appendingPathComponent(name, isDirectory: false), parent: node, retainChildren: showChildren)
                }
                guard let child else { node.excludedChildren = true; continue }
                node.containsLinks = node.containsLinks || child.containsLinks
                node.excludedChildren = node.excludedChildren || child.excludedChildren
                // Keep hard-link accounting inside opaque packages without retaining every internal file.
                if showChildren || child.containsLinks { node.children.append(child) }
                node.bytes += child.bytes
                node.unknown += child.unknown
                digest.combine(child.name)
                digest.combine(child.signature)
            }
            node.children.sort {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
        }
        node.signature = digest.finalize()
        return node
    }

}
