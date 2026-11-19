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
    private var scanTask: Task<ScanResult, Error>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDisks() }
            })
        }
    }

    func refreshDisks() {
        disks = Disk.mounted()
        if let disk { online = Disk(disk.url, folder: disk.isFolder)?.id == disk.id }
    }

    var queue: RemovalQueue { queues[disk?.id ?? ""] ?? RemovalQueue() }
    var summary: String {
        let q = queue
        return "\(q.entries.count) · " + sizeText(q.bytes) + (q.entries.contains { $0.unknown > 0 } ? " + неизвестный размер" : "")
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Сканировать"
        panel.begin { result in
            if result == .OK, let url = panel.url, let disk = Disk(url, folder: true) { self.scan(disk) }
        }
    }

    func showDisks() {
        guard !busy else { return }
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

    func scan(_ target: Disk, keepMap: Bool = false) {
        let oldPath = disk?.id == target.id ? root?.url.path : nil
        let oldSelection = disk?.id == target.id ? selection?.url.path : nil
        scanTask?.cancel()
        generation = UUID()
        let token = generation
        disk = target
        online = Disk(target.url, folder: target.isFolder)?.id == target.id
        progress = (0, target.url.path)
        if !keepMap { screen = .scanning } else { busy = true }
        let job = Task.detached(priority: .userInitiated) { [weak self] in
            try Scanner { count, path in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.progress = (count, path)
                }
            }.scan(target.url)
        }
        scanTask = job
        Task {
            do {
                let result = try await job.value
                guard token == generation else { return }
                guard let currentDisk = Disk(target.url, folder: target.isFolder), currentDisk.id == target.id else {
                    throw NSError(domain: "SpaceMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Диск отключён или заменён"])
                }
                disk = currentDisk
                snapshot = result
                var restored = result.root
                if var path = oldPath {
                    while result.root.find(path) == nil && path != "/" && !path.isEmpty {
                        path = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    }
                    restored = result.root.find(path) ?? result.root
                }
                root = restored
                history = [restored.url.path]
                position = 0
                select(oldSelection.flatMap { result.root.find($0) } ?? restored)
                var q = queue
                for i in q.entries.indices {
                    let mark = q.entries[i]
                    guard let fresh = result.root.find(mark.id), fresh.identity == mark.identity else {
                        q.entries[i].problem = "Объект исчез или был заменён"
                        continue
                    }
                    if fresh.signature != mark.signature, var updated = Mark(fresh) {
                        updated.problem = "Объект изменился. Проверьте перед подтверждением."
                        q.entries[i] = updated
                    }
                }
                queues[target.id] = q
                screen = .map
                online = true
            } catch {
                guard token == generation else { return }
                notice = "\(target.title) — \(error.localizedDescription)"
                if !keepMap { screen = .disks } else { online = false }
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
    func selectGroup(_ parent: Entry) {
        select(parent)
        groupOpen = true
        groupSelected = true
    }
    func open(_ entry: Entry) {
        guard entry.folder else { return }
        if root !== entry {
            history = Array(history.prefix(position + 1)) + [entry.url.path]
            position = history.count - 1
            root = entry
        }
        select(entry)
    }
    func step(_ delta: Int) {
        let index = position + delta
        guard history.indices.contains(index), let node = snapshot?.root.find(history[index]) else { return }
        position = index
        root = node
        select(node)
    }

    func blocked(_ entry: Entry) -> String? {
        if busy { return "Операция выполняется" }
        if !online { return "Диск недоступен" }
        if disk?.readOnly == true { return "Том только для чтения" }
        if entry === snapshot?.root { return "Корень сканирования" }
        if entry.identity == nil { return "Не удалось проверить объект" }
        if entry.excludedChildren { return "Папка содержит исключённые пути" }
        if let existing = queue.covering(entry.url.path), existing.id != entry.url.path { return "В составе папки" }
        if !FileManager.default.isDeletableFile(atPath: entry.url.path) { return "Недостаточно прав" }
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
                    mark.problem = "Размер или состав изменился. Проверьте и подтвердите повторно."
                }
                remaining.entries.append(mark)
            }
            queues[disk.id] = remaining
            busy = false
            notice = "Перемещено в Корзину: \(moved). Пропущено: \(remaining.entries.count)." +
                (remaining.entries.isEmpty ? "" : " Причины указаны в очереди.")
            if moved > 0 { scan(disk, keepMap: true) }
        }
    }
}
