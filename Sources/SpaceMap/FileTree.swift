import Foundation
import Darwin

struct FileID: Hashable {
    let device: dev_t
    let inode: ino_t
    let birth: timespec

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

extension FileID {
    init(_ s: stat) {
        self.init(device: s.st_dev, inode: s.st_ino, birth: s.st_birthtimespec)
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
    private var displayOrderReady = false

    // Published trees are inspected on the main actor. Sort each folder once, when shown.
    func prepareDisplayOrder() {
        guard !displayOrderReady else { return }
        children.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
        displayOrderReady = true
    }

    weak var parent: Entry?
    private let anchor: URL
    private let anchorIsParent: Bool

    convenience init(url: URL, parent: Entry?, status: stat?, kind: EntryKind, bytes: Int64) {
        let info = status.map(FileMetadata.init)
        let isLeaf = kind != .directory && kind != .package
        self.init(name: url.lastPathComponent, anchor: isLeaf ? parent?.anchor ?? url : url,
                  parent: parent, info: info, kind: kind, bytes: bytes)
    }

    init(name: String, anchor: URL, parent: Entry?, info: FileMetadata?, kind: EntryKind, bytes: Int64) {
        self.name = name
        anchorIsParent = parent != nil && kind != .directory && kind != .package
        self.anchor = anchor
        self.parent = parent
        identity = info?.identity
        multiLink = info?.multiLink == true
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
        parent.prepareDisplayOrder()
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
    private let reader = DirectoryReader()
    let progress: (Int, String) -> Void

    init(progress: @escaping (Int, String) -> Void = { _, _ in }) { self.progress = progress }

    func scan(_ root: URL) throws -> ScanResult {
        let info = FileMetadata(try fileStatus(root))
        devices = [info.identity.device]
        if root.path == "/", let data = try? fileStatus(URL(fileURLWithPath: "/System/Volumes/Data")) {
            devices.insert(data.st_dev)
        }
        let entry = try visit(name: root.lastPathComponent, location: root, parent: nil, info: info, retainChildren: true)
        return ScanResult(root: entry, issues: issues, finished: Date())
    }

    // For leaves, location is the parent URL. Only directories, links and exceptional
    // records need a full path while scanning a typical volume.
    private func visit(name: String, location: URL, parent: Entry?, info: FileMetadata, retainChildren: Bool) throws -> Entry {
        try Task.checkCancellation()
        count += 1
        if count == 1 || count % 128 == 0, Date().timeIntervalSince(lastReport) > 0.12 {
            lastReport = Date()
            progress(count, location.path)
        }
        let directory = info.kind == .directory
        let isPackage = directory && retainChildren && parent != nil && isFilePackage(name, at: location)
        let kind: EntryKind = isPackage ? .package : info.kind
        let node = Entry(name: name, anchor: location, parent: parent, info: info, kind: kind, bytes: info.allocatedBytes)
        var digest = Hasher()
        digest.combine(node.identity)
        digest.combine(info.modified.tv_sec)
        digest.combine(info.modified.tv_nsec)
        digest.combine(info.logicalBytes)
        digest.combine(info.allocatedBytes)
        if !directory {
            if info.multiLink {
                if let owner = hardLinks[info.identity] { node.sharedOwner = owner; node.bytes = 0 }
                else { hardLinks[info.identity] = node.url.path }
            }
        } else {
            var members: [DirectoryMember]
            do { members = try reader.members(at: location) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if parent == nil { throw error }
                issues.append(ScanIssue(path: location.path, reason: error.localizedDescription))
                node.unknown = 1
                digest.combine("unreadable")
                node.signature = digest.finalize()
                return node
            }
            let path = location.path
            let showChildren = retainChildren && !isPackage
            members.sort { $0.name < $1.name }
            if showChildren { node.children.reserveCapacity(members.count) }
            for member in members {
                let name = member.name
                let specialRoot = path == "/" && [".nofollow", ".vol", "dev"].contains(name)
                let mounts = path == "/System" && name == "Volumes"
                let trash = name == ".Trashes" || (name == ".Trash" && location.deletingLastPathComponent().path == "/Users")
                if specialRoot || mounts || trash { node.excludedChildren = true; continue }
                let child: Entry
                if let metadata = member.metadata {
                    guard devices.contains(metadata.identity.device) else { node.excludedChildren = true; continue }
                    child = try visit(name: name, location: location, parent: node, info: metadata, retainChildren: showChildren)
                } else {
                    let result = try autoreleasepool {
                        try visitByPath(name, directory: location, parent: node, retainChildren: showChildren)
                    }
                    guard let result else { node.excludedChildren = true; continue }
                    child = result
                }
                node.containsLinks = node.containsLinks || child.containsLinks
                node.excludedChildren = node.excludedChildren || child.excludedChildren
                if showChildren || child.containsLinks { node.children.append(child) }
                node.bytes += child.bytes
                node.unknown += child.unknown
                digest.combine(child.name)
                digest.combine(child.signature)
            }
        }
        node.signature = digest.finalize()
        return node
    }

    private func isFilePackage(_ name: String, at url: URL) -> Bool {
        // Finder recognizes packages by extension or Finder metadata. Most directories
        // have neither. Preserve the system check for custom types, flags and errors.
        if !name.contains(".") {
            let lacksFinderInfo = url.withUnsafeFileSystemRepresentation { path in
                getxattr(path, "com.apple.FinderInfo", nil, 0, 0, XATTR_NOFOLLOW) < 0 && errno == ENOATTR
            }
            if lacksFinderInfo { return false }
        }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private func visitByPath(_ name: String, directory: URL, parent: Entry, retainChildren: Bool) throws -> Entry? {
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let info: FileMetadata
        do { info = FileMetadata(try fileStatus(url)) }
        catch {
            count += 1
            issues.append(ScanIssue(path: url.path, reason: error.localizedDescription))
            let child = Entry(name: name, anchor: directory, parent: parent, info: nil, kind: .file, bytes: 0)
            child.unknown = 1
            return child
        }
        guard devices.contains(info.identity.device) else { return nil }
        return try visit(name: name, location: info.kind == .directory ? url : directory, parent: parent,
                         info: info, retainChildren: retainChildren)
    }
}
