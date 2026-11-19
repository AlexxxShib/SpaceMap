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
        let store = Workspace()
        store.scan(disk)
        while store.screen == .scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(store.screen == .map && store.root != nil, "сканирование из окна выбора")
        let initial = store.root!, child = initial.find(folder.url.path)!
        store.select(child)
        expect(store.selection === child && store.root === initial, "выбор без смены корня")
        store.open(child)
        store.step(-1)
        expect(store.root === initial, "возврат к предыдущей папке")
        store.step(1)
        expect(store.root === child, "переход вперёд")
        store.toggle(child)
        store.showDisks()
        store.scan(disk)
        while store.screen == .scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(store.queue.entries.count == 1, "очередь восстановлена для своего источника")
        store.scan(disk)
        store.showDisks()
        try await Task.sleep(nanoseconds: 80_000_000)
        expect(store.screen == .disks && store.snapshot == nil, "отмена не публикует устаревший снимок")
    }
}
