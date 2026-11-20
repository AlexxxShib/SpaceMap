import AppKit
import Foundation

@main
struct Checks {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        print("✓ " + label)
    }

    static func checkBatchedListing(in directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for index in 0..<1000 {
            try Data().write(to: directory.appendingPathComponent("запись-\(index)"))
        }
        let sparse = directory.appendingPathComponent("разреженный файл")
        try Data([1]).write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()

        let dataFile = directory.appendingPathComponent("две вилки")
        try Data([2]).write(to: dataFile)
        try Data(repeating: 3, count: 16_384).write(to: URL(fileURLWithPath: dataFile.path + "/..namedfork/rsrc"))
        let snapshot = try Scanner().scan(directory)
        expect(snapshot.root.children.count == 1002 && snapshot.issues.isEmpty, "несколько порций метаданных без потерь")
        var total: Int64 = 0
        for child in snapshot.root.children {
            let status = try fileStatus(child.url)
            precondition(child.identity == FileID(status) && child.rawBytes == status.st_blocks * 512)
            total += status.st_blocks * 512
        }
        expect(total == snapshot.root.bytes, "пакетный обход совпадает с индивидуальным учётом байтов")
        for url in [sparse, dataFile] {
            let single = try Scanner().scan(url).root
            expect(snapshot.root.find(url.path)?.signature == single.signature, "проверка перед удалением: " + url.lastPathComponent)
        }
    }

    static func checkIncremental(in base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("source", isDirectory: true)
        let nested = root.appendingPathComponent("A/nested", isDirectory: true)
        let stable = root.appendingPathComponent("stable", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 32768).write(to: stable.appendingPathComponent("unchanged"))
        let changed = nested.appendingPathComponent("data")
        try Data([5]).write(to: changed)
        let disk = Disk(root, folder: true)!
        let cacheURL = base.appendingPathComponent("cache")
        var changedPaths = ChangedPaths()
        let live = CommandLine.arguments.contains("--live-journal")
        let cache: ScanCache
        if live {
            // Start immediately after this fixture's creation events, so an older
            // on-disk journal segment cannot mark the entire new fixture dirty.
            try fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            guard let point = ChangeJournal.checkpoint(for: root),
                  let delta = ChangeJournal.changes(since: point, to: point, root: root, synchronizeAt: cacheURL) else {
                throw CocoaError(.featureUnsupported)
            }
            let baseline = JournalPoint(uuid: point.uuid, event: delta.latest, device: point.device,
                                        mount: point.mount, prefix: point.prefix)
            cache = ScanCache(directory: cacheURL, checkpoint: { _ in baseline })
        } else {
            let point = JournalPoint(uuid: "test", event: 1, device: 1, mount: "/", prefix: "")
            cache = ScanCache(directory: cacheURL, checkpoint: { _ in point }, changedPaths: { _, _, _ in changedPaths })
        }
        let first = try cache.scan(disk, scanner: Scanner())
        let next = Scanner()
        changedPaths.add(changed.path)
        var beforeUpdate: ScanResult?
        try Data(repeating: 9, count: 131072).write(to: changed)
        let second = try cache.scan(disk, scanner: next) { old in
            beforeUpdate = old
            expect(old.root.bytes == first.root.bytes && old.root.find(changed.path)?.bytes == first.root.find(changed.path)?.bytes,
                   "до обновления доступна сохранённая карта с вложенными файлами")
        }
        let reference = try Scanner().scan(root)
        expect(second.root.bytes == reference.root.bytes && second.root.signature == reference.root.signature,
               "изменение вложенного файла совпадает с полным пересчётом")
        print("Журнал: прочитано папок \(next.directoriesRead), из кэша \(next.directoriesReused)")
        expect(next.directoriesReused > 0, "неизменённая ветка пропущена при обновлении")
        if live {
            for count in [8192, 98304, 16384, 65536] {
                try Data(repeating: 6, count: count).write(to: changed)
                let update = Scanner()
                let immediate = try cache.scan(disk, scanner: update)
                let current = try Scanner().scan(root)
                expect(immediate.root.signature == current.root.signature && update.directoriesReused > 0,
                       "немедленное обновление после записи \(count) байт")
            }
        }
        try fm.moveItem(at: nested, to: root.appendingPathComponent("moved"))
        try fm.removeItem(at: stable)
        changedPaths.add(nested.path)
        changedPaths.add(root.appendingPathComponent("moved").path)
        changedPaths.add(stable.path)
        let third = try cache.scan(disk, scanner: Scanner())
        let fresh = try Scanner().scan(root)
        expect(third.root.signature == fresh.root.signature && third.root.find(stable.path) == nil &&
               third.root.find(root.appendingPathComponent("moved/data").path)?.bytes == fresh.root.bytes,
               "удаление и перенос папок отражены в сохранённой карте")
        expect(beforeUpdate?.root.find(stable.appendingPathComponent("unchanged").path)?.bytes == first.root.find(stable.path)?.bytes,
               "открытая старая карта читает прежнюю версию после удаления ветки")
        if !live {
            changedPaths = ChangedPaths()
            let clean = Scanner()
            _ = try cache.scan(disk, scanner: clean)
            expect(clean.directoriesRead == 0 && clean.directoriesReused == 1, "без изменений каталоги не читаются")
            let alias = root.appendingPathComponent("alias")
            try fm.linkItem(at: root.appendingPathComponent("moved/data"), to: alias)
            changedPaths.add(alias.path)
            let linked = try cache.scan(disk, scanner: Scanner())
            let full = try Scanner().scan(root)
            expect(linked.root.bytes == full.root.bytes && linked.root.find(alias.path)?.bytes == full.root.find(alias.path)?.bytes,
                   "новая жёсткая ссылка в другой ветке учтена один раз")
            let unavailable = ScanCache(directory: cacheURL, checkpoint: { _ in nil })
            let fallback = Scanner()
            _ = try unavailable.scan(disk, scanner: fallback)
            expect(fallback.directoriesRead > 0 && fallback.directoriesReused == 0,
                   "недоступная история вызывает полный обход")
        }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("SpaceMap-Tests-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: base) }

        func write(_ name: String, _ count: Int) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x52, count: count).write(to: url)
            return url
        }
        try checkIncremental(in: base.appendingPathComponent("incremental"))
        try checkBatchedListing(in: base.appendingPathComponent("Много файлов"))
        let a = try write("A/alpha", 20_000)
        let b = base.appendingPathComponent("beta")
        try fm.linkItem(at: a, to: b)
        try fm.createSymbolicLink(at: base.appendingPathComponent("A/loop"), withDestinationURL: base)
        _ = try write("A/zero", 0)
        let replace = try write("replaced", 16_000)
        _ = try write("Example.app/Contents/MacOS/test", 65_536)
        let root = try Scanner().scan(base).root
        let alpha = root.find(a.path)!, beta = root.find(b.path)!, folder = alpha.parent!
        expect(alpha.bytes == Int64(try fileStatus(a).st_blocks) * 512, "выделенные байты")
        expect(beta.bytes == 0 && beta.sharedOwner == a.path, "повторная жёсткая ссылка")
        expect(folder.children.first(where: { $0.name == "loop" })?.kind == .link, "ссылка на предка завершается")
        expect(root.find(base.appendingPathComponent("A/zero").path)?.bytes == 0, "нулевой файл в дереве")
        let package = root.children.first { $0.name == "Example.app" }!
        expect(package.kind == .package && package.bytes > 0 && package.children.isEmpty, "пакет с учтённым содержимым")

        var q = RemovalQueue()
        q.toggle(alpha)
        q.toggle(beta)
        expect(q.bytes == alpha.bytes && q.entries.count == 2, "две ссылки, один объём в очереди")
        q.toggle(folder)
        expect(q.entries.count == 2 && q.bytes == folder.bytes && q.covering(a.path)?.id == folder.url.path, "папка замещает отметки потомков")
        q.toggle(folder)
        expect(q.entries.count == 1 && q.bytes == alpha.bytes, "оставшаяся ссылка сохраняет свой вес")

        let disk = Disk(base, folder: true)!
        let mark = Mark(root.find(replace.path)!)!
        try fm.moveItem(at: replace, to: base.appendingPathComponent("old"))
        _ = try write("replaced", 16_000)
        if case .skipped = Trash.apply(mark, disk: disk, move: { _ in fatalError("replaced item") }) {} else { fatalError("identity") }
        expect(fm.fileExists(atPath: replace.path), "замена по тому же пути пропущена")
        let folderMark = Mark(folder)!
        _ = try write("A/new", 8192)
        guard case .changed(let updated) = Trash.apply(folderMark, disk: disk, move: { _ in fatalError("changed folder") }) else { fatalError("folder refresh") }
        expect(updated.signature != folderMark.signature, "изменившаяся папка требует повторного подтверждения")

        let candidate = try write("SpaceMap-Trash-Test-" + UUID().uuidString, 2048)
        let only = try Scanner().scan(candidate).root
        if CommandLine.arguments.contains("--system-trash") {
            guard case .moved = Trash.apply(Mark(only)!, disk: disk) else { fatalError("system trash") }
            expect(!fm.fileExists(atPath: candidate.path), "перенос временного файла в системную Корзину")
        } else {
            let destination = base.appendingPathComponent("moved")
            guard case .moved = Trash.apply(Mark(only)!, disk: disk, move: { try fm.moveItem(at: $0, to: destination) }) else { fatalError("move") }
            expect(fm.fileExists(atPath: destination.path), "подтверждённая операция применена")
        }

        func node(_ name: String, _ bytes: Int64, _ parent: Entry?, _ kind: EntryKind = .file) -> Entry {
            let n = Entry(url: URL(fileURLWithPath: "/fixture/" + name), parent: parent, status: nil, kind: kind, bytes: bytes)
            parent?.children.append(n)
            return n
        }
        let chartRoot = node("root", 100_000_000, nil, .directory)
        _ = node("big", 60_000_000, chartRoot)
        let dir = node("branch", 35_000_000, chartRoot, .directory)
        _ = node("child", 35_000_000, dir)
        for i in 0..<10 { _ = node("small-\(i)", 500_000, chartRoot) }
        let group = Grouped(chartRoot)
        let arcs = makeArcs(chartRoot, levels: 5)
        expect(group.main.count == 2 && group.small.count == 10 && group.smallBytes == 5_000_000, "десять мелких файлов объединены")
        let small = arcs.first { $0.group }!
        expect(abs((small.end - small.start) * 180 / .pi - 18) < 0.00001, "сектор группы занимает 18°")
        let proportional = node("disk", 100, nil, .directory)
        _ = node("other", 60, proportional)
        let forty = node("forty", 40, proportional, .directory)
        _ = node("thirty", 30, forty)
        let ten = node("ten", 10, forty)
        func degrees(_ parent: Entry, _ child: Entry) -> Double {
            let arc = makeArcs(parent, levels: 3).first { $0.entry === child }!
            return (arc.end - arc.start) * 180 / .pi
        }
        expect(abs(degrees(proportional, forty) - 144) < 0.00001 && abs(degrees(proportional, ten) - 36) < 0.00001 && abs(degrees(forty, ten) - 90) < 0.00001, "геометрия 144° / 36° / 90°")
        expect(makeArcs(node("empty", 0, nil, .directory), levels: 4).isEmpty, "карта пустой папки")
        let suite = "SpaceMap-Checks-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let cachePath = fm.temporaryDirectory.appendingPathComponent("SpaceMap-cache-" + UUID().uuidString)
        defer { try? fm.removeItem(at: cachePath) }
        let cache = ScanCache(directory: cachePath)
        let store = Workspace(cache: cache, preferences: preferences)
        // Deliver a native click inside the 40% folder sector on the first ring.
        let ring = RingView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        ring.store = store
        ring.configure(root: proportional)
        let angle = 1.6 * Double.pi
        let point = NSPoint(x: 200 + 50 * cos(angle), y: 200 + 50 * sin(angle))
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: ring.convert(point, to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        ring.mouseDown(with: click)
        expect(store.root === forty && store.selection === forty, "щелчок по сектору открывает папку в диаграмме и списке")
        ring.configure(root: forty)
        expect(ring.accessibilityLabel()?.contains(forty.name) == true, "диаграмма подписана именем открытой папки")
        store.scan(disk)
        while store.screen == .scanning || store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(store.screen == .map && store.root != nil, "сканирование из окна выбора")
        let initial = store.root!, child = initial.find(folder.url.path)!
        store.select(child)
        expect(store.selection === child && store.root === initial, "выбор без смены корня")
        store.activate(child)
        expect(store.root === child && store.selection === child, "переход из списка меняет центр диаграммы")
        let relaunched = Workspace(cache: cache, preferences: preferences)
        relaunched.restoreLastMap()
        while relaunched.screen == .scanning || relaunched.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(relaunched.root?.url == child.url && relaunched.snapshot?.root.bytes == initial.bytes,
               "новая сессия восстанавливает источник и открытую папку")
        let picked = Workspace(cache: cache, preferences: preferences)
        let selectedDisk = Disk(selection: FolderSelection(disk.url))!
        picked.scan(selectedDisk)
        while picked.screen == .scanning || picked.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let savedFolder = Workspace(cache: cache, preferences: preferences)
        savedFolder.restoreLastMap()
        while savedFolder.screen == .scanning || savedFolder.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(savedFolder.disk?.selection?.bookmark != nil && savedFolder.disk?.id == disk.id,
               "выбранная папка восстанавливается из закладки и сохраняется после обновления карты")
        store.step(-1)
        expect(store.root === initial, "возврат к предыдущей папке")
        store.step(1)
        expect(store.root === child, "переход вперёд")
        store.toggle(child)
        store.showDisks()
        store.scan(disk)
        while store.screen == .scanning || store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(store.queue.entries.count == 1, "очередь восстановлена для своего источника")
        store.scan(disk)
        store.showDisks()
        try await Task.sleep(nanoseconds: 80_000_000)
        expect(store.screen == .disks && store.snapshot == nil, "отмена не публикует устаревший снимок")
    }
}
