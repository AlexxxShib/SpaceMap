import AppKit

struct Disk: Identifiable {
    let id: String
    let url: URL
    let title: String
    let capacity: Int64
    let available: Int64
    let readOnly: Bool
    let isFolder: Bool

    init?(_ url: URL, folder: Bool = false) {
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
