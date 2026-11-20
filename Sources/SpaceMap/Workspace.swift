import SwiftUI
import AppKit

@MainActor
final class Workspace: ObservableObject {
    enum Screen { case disks, scanning, map }
    @Published var screen: Screen = .disks
    @Published var disks = Disk.mounted()
    @Published var disk: Disk?
    @Published var snapshot: ScanResult?
    @Published var root: Entry?
    @Published var selection: Entry?
    @Published var groupOpen = false
    @Published var groupSelected = false
    @Published var progress = (0, "")
    @Published var queues: [String: RemovalQueue] = [:]
    @Published var history: [String] = []
    @Published var position = 0
    @Published var busy = false
    @Published var notice: String?
    @Published var online = true
    private let cache: ScanCache
    private let preferences: UserDefaults
    private var restoredLaunch = false
    private let lastSourceKey = "SpaceMap.lastSource"
    private var scanTask: Task<ScanResult, Error>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    init(cache: ScanCache = ScanCache(), preferences: UserDefaults = .standard) {
        self.cache = cache
        self.preferences = preferences
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDisks() }
            })
        }
    }

    func restoreLastMap() {
        guard !restoredLaunch else { return }
        restoredLaunch = true
        guard let saved = preferences.dictionary(forKey: lastSourceKey),
              let path = saved["path"] as? String, let folder = saved["folder"] as? Bool else { return }
        let target: Disk?
        if folder, let data = saved["bookmark"] as? Data {
            guard let selection = try? FolderSelection(resolving: data) else {
                notice = "Choose the folder again to open its saved map."
                return
            }
            target = Disk(selection: selection)
        } else {
            // Also restore maps saved by versions that only recorded the path.
            target = Disk(URL(fileURLWithPath: path), folder: folder)
        }
        guard let target, target.id == saved["source"] as? String,
              FileManager.default.fileExists(atPath: cache.file(for: target).path) else { return }
        scan(target, opening: saved["view"] as? String)
    }

    private func rememberLocation() {
        guard let disk, let root else { return }
        var saved: [String: Any] = ["path": disk.url.path, "folder": disk.isFolder, "source": disk.id, "view": root.url.path]
        saved["bookmark"] = disk.selection?.bookmark
        preferences.set(saved, forKey: lastSourceKey)
    }

    func refreshDisks() {
        disks = Disk.mounted()
        if let disk { online = disk.refreshed()?.id == disk.id }
    }

    var queue: RemovalQueue { queues[disk?.id ?? ""] ?? RemovalQueue() }
    var summary: String {
        let q = queue
        return "\(q.entries.count) · " + sizeText(q.bytes) + (q.entries.contains { $0.unknown > 0 } ? " + unknown size" : "")
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Scan"
        panel.begin { result in
            if result == .OK, let url = panel.url, let disk = Disk(selection: FolderSelection(url)) {
                self.scan(disk)
            }
        }
    }

    var canChooseDisk: Bool { !busy || scanTask != nil }

    func showDisks() {
        guard canChooseDisk else { return }
        busy = false
        preferences.removeObject(forKey: lastSourceKey)
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        disk = nil
        selection = nil
        root = nil
        snapshot = nil
        history = []
        screen = .disks
        refreshDisks()
    }

    func scan(_ target: Disk, keepMap: Bool = false, opening: String? = nil, forceFull: Bool = false) {
        let sameMap = target.id == disk?.id && screen == .map
        let oldPath = opening ?? (sameMap ? root?.url.path : nil)
        let oldSelection = disk?.id == target.id ? selection?.url.path : nil
        scanTask?.cancel()
        generation = UUID()
        let token = generation
        disk = target
        online = target.refreshed()?.id == target.id
        progress = (0, target.url.path)
        let showingMap = sameMap || keepMap
        busy = showingMap
        if !showingMap {
            screen = .scanning
            root = nil
            selection = nil
            snapshot = nil
            history = []
            position = 0
        }
        let cache = self.cache
        let job = Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = Scanner { count, path in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.progress = (count, path)
                }
            }
            return try cache.scan(target, scanner: scanner, forceFull: forceFull) { saved in
                guard !showingMap else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.screen == .scanning, self.scanTask != nil else { return }
                    self.snapshot = saved
                    let previousFolder = oldPath.flatMap { saved.root.find($0) }
                    let location = previousFolder.flatMap { $0.folder ? $0 : nil } ?? saved.root
                    self.root = location
                    self.select(location)
                    self.history = [location.url.path]
                    self.position = 0
                    self.busy = true
                    self.screen = .map
                }
            } damaged: {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.scan(target, keepMap: self.screen == .map, forceFull: true)
                }
            } warning: { message in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.notice = message
                }
            }
        }
        scanTask = job
        Task {
            do {
                let result = try await job.value
                guard token == generation else { return }
                guard let currentDisk = target.refreshed(), currentDisk.id == target.id else {
                    throw NSError(domain: "SpaceMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk was disconnected or replaced."])
                }
                disk = currentDisk
                snapshot = result
                var restored = result.root
                if var path = root?.url.path ?? oldPath {
                    while result.root.find(path)?.folder != true && path != "/" && !path.isEmpty {
                        path = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    }
                    restored = result.root.find(path) ?? result.root
                }
                root = restored
                if !history.indices.contains(position) || history[position] != restored.url.path {
                    history = [restored.url.path]
                    position = 0
                } else {
                    let prior = history.prefix(position).filter { result.root.find($0)?.folder == true }
                    history = prior + [restored.url.path] + history.dropFirst(position + 1).filter { result.root.find($0)?.folder == true }
                    position = prior.count
                }
                select((selection?.url.path ?? oldSelection).flatMap { result.root.find($0) } ?? restored)
                rememberLocation()
                var q = queue
                for i in q.entries.indices {
                    let mark = q.entries[i]
                    guard let fresh = result.root.find(mark.id), fresh.identity == mark.identity else {
                        q.entries[i].problem = "The item is missing or has been replaced."
                        continue
                    }
                    if fresh.signature != mark.signature, var updated = Mark(fresh) {
                        updated.problem = "The item has changed. Review it before confirming."
                        q.entries[i] = updated
                    }
                }
                queues[target.id] = q
                screen = .map
                online = true
            } catch {
                guard token == generation else { return }
                notice = "\(target.title) — \(error.localizedDescription)"
                if screen != .map { screen = .disks } else { online = false }
            }
            busy = false
            scanTask = nil
        }
    }

    func title(_ entry: Entry) -> String {
        entry === snapshot?.root ? disk?.title ?? entry.name : entry.name
    }
    func select(_ entry: Entry) {
        selection = entry
        groupOpen = false
        groupSelected = false
    }
    func activate(_ entry: Entry) {
        if entry.folder { open(entry) } else { select(entry) }
    }
    func selectGroup(_ parent: Entry) {
        open(parent)
        groupOpen = true
        groupSelected = true
    }
    func open(_ entry: Entry) {
        guard entry.folder else { return }
        if root !== entry {
            history = Array(history.prefix(position + 1)) + [entry.url.path]
            position = history.count - 1
            root = entry
            rememberLocation()
        }
        select(entry)
    }
    func step(_ delta: Int) {
        let index = position + delta
        guard history.indices.contains(index), let node = snapshot?.root.find(history[index]) else { return }
        position = index
        root = node
        rememberLocation()
        select(node)
    }

    func blocked(_ entry: Entry) -> String? {
        if busy { return "An operation is in progress" }
        if !online { return "Disk unavailable" }
        if disk?.readOnly == true { return "This volume is read-only" }
        if entry === snapshot?.root { return "This is the root of the scan" }
        if entry.identity == nil { return "Couldn’t verify the item" }
        if entry.excludedChildren { return "This folder contains excluded paths" }
        if let existing = queue.covering(entry.url.path), existing.id != entry.url.path { return "Included in a marked folder" }
        if !FileManager.default.isDeletableFile(atPath: entry.url.path) { return "Insufficient permissions" }
        return nil
    }

    func toggle(_ entry: Entry) {
        guard let disk, !busy else { return }
        if queue.covering(entry.url.path)?.id != entry.url.path && blocked(entry) != nil { return }
        queues[disk.id, default: RemovalQueue()].toggle(entry)
    }
    func unmark(_ path: String) {
        guard let disk, !busy else { return }
        queues[disk.id]?.entries.removeAll { $0.id == path }
    }
    func clear() {
        guard let disk, !busy else { return }
        queues[disk.id] = RemovalQueue()
    }

    func trashConfirmed() {
        guard let disk, !busy, online, !queue.entries.isEmpty else { return }
        busy = true
        let entries = queue.entries
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                entries.map { Trash.apply($0, disk: disk) }
            }.value
            var remaining = RemovalQueue()
            var moved = 0
            for (var mark, result) in zip(entries, results) {
                switch result {
                case .moved: moved += 1; continue
                case .skipped(let message): mark.problem = message
                case .changed(let fresh):
                    mark = fresh
                    mark.problem = "The size or contents have changed. Review the item and confirm again."
                }
                remaining.entries.append(mark)
            }
            queues[disk.id] = remaining
            busy = false
            notice = "Moved to Trash: \(moved). Skipped: \(remaining.entries.count)." +
                (remaining.entries.isEmpty ? "" : " See the removal queue for details.")
            if moved > 0 { scan(disk, keepMap: true) }
        }
    }
}
