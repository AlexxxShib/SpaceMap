import AppKit

// Keep the URL returned by the picker alive for scans, navigation and Trash.
// A normal macOS bookmark can carry the picker's implicit access across launches.
final class FolderSelection {
    let url: URL
    let bookmark: Data?
    private let accessing: Bool

    init(_ url: URL, bookmark: Data? = nil) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
        self.bookmark = bookmark ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    convenience init(resolving data: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        self.init(url, bookmark: stale ? nil : data)
    }

    deinit {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }
}

struct Disk: Identifiable {
    let id: String
    let url: URL
    let title: String
    let capacity: Int64
    let available: Int64
    let readOnly: Bool
    let isFolder: Bool

    let selection: FolderSelection?

    init?(selection: FolderSelection) {
        self.init(selection.url, folder: true, selection: selection)
    }

    func refreshed() -> Disk? {
        Disk(url, folder: isFolder, selection: selection)
    }

    init?(_ url: URL, folder: Bool = false) {
        self.init(url, folder: folder, selection: nil)
    }

    private init?(_ url: URL, folder: Bool, selection: FolderSelection?) {
        self.selection = selection
        guard let s = try? fileStatus(url), s.st_mode & S_IFMT == S_IFDIR else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeIsLocalKey])
        if !folder && values?.volumeIsLocal == false { return nil }
        let root = url.standardizedFileURL
        self.url = root
        id = (values?.volumeUUIDString ?? "dev-\(s.st_dev)") + (folder ? "/\(s.st_ino):\(root.path)" : "")
        isFolder = folder
        title = folder ? FileManager.default.displayName(atPath: root.path) : values?.volumeName ?? FileManager.default.displayName(atPath: root.path)
        capacity = Int64(values?.volumeTotalCapacity ?? 0)
        available = Int64(values?.volumeAvailableCapacity ?? 0)
        readOnly = root.path == "/" ? false : values?.volumeIsReadOnly ?? false
    }

    static func mounted() -> [Disk] {
        let root = URL(fileURLWithPath: "/")
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var seen: Set<String> = []
        return ([root] + volumes.filter { $0.path.hasPrefix("/Volumes/") }.sorted { $0.lastPathComponent < $1.lastPathComponent })
            .compactMap { Disk($0) }.filter { seen.insert($0.id).inserted }
    }
}
