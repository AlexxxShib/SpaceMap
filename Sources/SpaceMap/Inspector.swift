import SwiftUI
import AppKit

private final class ListFocus: ObservableObject {
    @Published var row: ObjectIdentifier?
}

struct Inspector: View {
    @ObservedObject var store: Workspace
    let entry: Entry
    @StateObject private var focus = ListFocus()
    private var tint: BranchTint? { store.root.flatMap { marker(entry, under: $0) } }
    private var kind: String {
        switch entry.kind {
        case .directory: return "Папка"
        case .file: return "Файл"
        case .package: return "Пакет"
        case .link: return "Символическая ссылка"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    if let parent = entry.parent {
                        Button { if entry === store.root { store.open(parent) } else { store.select(parent) } } label: { Label(store.title(parent), systemImage: "chevron.left") }
                            .buttonStyle(.borderless).lineLimit(1)
                    } else {
                        Label(store.disk?.isFolder == true ? "Папка" : "Том", systemImage: store.disk?.isFolder == true ? "folder" : "internaldrive")
                    }
                    Spacer()
                }.font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let tint { Circle().fill(Color(nsColor: tint.color)).frame(width: 11, height: 11) }
                    Text(store.title(entry)).font(.title2.weight(.medium)).lineLimit(3)
                    Spacer(minLength: 4)
                    if entry.sharedOwner == nil && !(entry.bytes == 0 && entry.unknown > 0) {
                        Text(sizeText(entry.bytes)).font(.title2).monospacedDigit().fixedSize()
                            .help("\(entry.bytes.formatted()) байт")
                    }
                }
                if entry.unknown > 0 { Label("Пропущено: \(entry.unknown) · " + entry.sizeLabel, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
                if entry !== store.snapshot?.root {
                    HStack {
                        if entry.folder, entry !== store.root { Button("Открыть папку") { store.open(entry) } }
                        MarkButton(store: store, entry: entry)
                    }.controlSize(.small)
                }
            }.padding(18)
            Divider()
            if entry.folder {
                let group = Grouped(entry)
                if entry.children.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: entry.unknown > 0 ? "folder.badge.questionmark" : "folder").font(.system(size: 30))
                        Text(entry.unknown > 0 ? "Содержимое недоступно" : "Папка пуста")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $focus.row) {
                        ForEach(Array(group.main.enumerated()), id: \.element.id) { rank, node in
                            row(node, tint: entry === store.root ? .first(rank) : tint?.child(rank))
                        }
                        if !group.small.isEmpty {
                            DisclosureGroup(isExpanded: $store.groupOpen) {
                                ForEach(group.small) { node in row(node, tint: nil) }
                            } label: {
                                HStack {
                                    Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary)
                                    Text("Мелкие объекты (\(group.small.count))").lineLimit(1)
                                    Spacer()
                                    Text(sizeText(group.smallBytes)).monospacedDigit().foregroundStyle(.secondary)
                                }.contentShape(Rectangle()).onTapGesture { store.groupOpen.toggle() }
                            }.tag(entry.id).listRowBackground(store.groupSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                        }
                        ForEach(group.unknown) { node in row(node, tint: nil) }
                    }.listStyle(.inset)
                        .onKeyPress(.rightArrow) { inspectFocusedRow() }
                        .onKeyPress(.return) { inspectFocusedRow() }
                        .onKeyPress(.leftArrow) {
                            if focus.row == entry.id && store.groupOpen { store.groupOpen = false; return .handled }
                            guard let parent = entry.parent else { return .ignored }
                            if entry === store.root { store.open(parent) } else { store.select(parent) }
                            return .handled
                        }
                }
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 54, height: 54)
                    LabeledContent("Тип", value: kind)
                    LabeledContent("Размер на диске", value: entry.unknown > 0 ? "Размер неизвестен" : "\((entry.kind == .package ? entry.bytes : entry.rawBytes).formatted()) байт")
                    if let owner = entry.sharedOwner {
                        Text("Учтено по другому пути").foregroundStyle(.secondary)
                        Text(owner).textSelection(.enabled)
                    }
                    Divider()
                    Text("Полный путь").foregroundStyle(.secondary)
                    Text(entry.url.path).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Скопировать путь") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url.path, forType: .string)
                    }
                }.padding(18)
                Spacer()
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private func inspectFocusedRow() -> KeyPress.Result {
        if focus.row == entry.id { store.groupOpen.toggle(); return .handled }
        guard let node = entry.children.first(where: { $0.id == focus.row }) else { return .ignored }
        store.select(node)
        return .handled
    }

    private func row(_ node: Entry, tint: BranchTint?) -> some View {
        let marked = store.queue.covering(node.url.path) != nil
        let symbol: String = node.folder ? "folder" : (node.kind == .package ? "shippingbox" : (node.kind == .link ? "link" : "doc"))
        return HStack(spacing: 7) {
            Circle().fill(Color(nsColor: tint?.color ?? .systemGray)).frame(width: 7, height: 7)
            Image(systemName: symbol).font(.callout).foregroundStyle(.secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if marked { Image(systemName: "tray.and.arrow.down").font(.caption) }
            Text(node.sizeLabel).monospacedDigit().foregroundStyle(.secondary).font(.callout)
        }.padding(.vertical, 3).contentShape(Rectangle())
            .tag(node.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(node.name + ", " + (node.folder ? "папка" : "файл") + ", " + node.sizeLabel + (marked ? ", помечено" : ""))
            .accessibilityAction { store.select(node) }
            .onTapGesture { store.select(node) }
            .contextMenu {
                Button("Сведения") { store.select(node) }
                if node.folder { Button("Открыть папку") { store.open(node) } }
                MarkButton(store: store, entry: node)
            }
    }
}

struct MarkButton: View {
    @ObservedObject var store: Workspace
    let entry: Entry
    var body: some View {
        let marked = store.queue.covering(entry.url.path)?.id == entry.url.path
        let reason = store.blocked(entry)
        Button {
            store.toggle(entry)
        } label: {
            Label(marked ? "Снять отметку" : (reason == "В составе папки" ? "В составе папки" : "Пометить для удаления"),
                  systemImage: marked ? "minus.circle" : "tray.and.arrow.down")
        }.disabled(store.busy || (!marked && reason != nil)).help(reason ?? (marked ? "Убрать из очереди" : "Добавить в очередь"))
    }
}

struct DetailSheet: View {
    @ObservedObject var store: Workspace
    let queueMode: Bool
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(queueMode ? "Очередь удаления" : "Сведения о сканировании").font(.title2.weight(.semibold))
            if queueMode {
                Text(store.summary).monospacedDigit().foregroundStyle(.secondary)
                List(store.queue.entries) { mark in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mark.url.lastPathComponent).fontWeight(.medium)
                            Text(mark.id).font(.caption).textSelection(.enabled)
                            if let problem = mark.problem { Text(problem).foregroundStyle(.orange).font(.caption) }
                        }
                        Spacer()
                        Text(sizeText(mark.bytes)).monospacedDigit()
                        Button { store.unmark(mark.id) } label: { Image(systemName: "minus.circle").accessibilityLabel("Снять отметку") }
                            .buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }
            } else {
                Text("В карте учтены доступные файлы выбранного источника. Системные корзины и другие точки монтирования пропущены.").foregroundStyle(.secondary)
                if let snapshot = store.snapshot {
                    Text("Завершено " + snapshot.finished.formatted() + " · " + sizeText(snapshot.root.bytes))
                    if snapshot.issues.isEmpty { Text("Ошибок чтения нет.").foregroundStyle(.secondary); Spacer() }
                    else {
                        List(snapshot.issues) { item in
                            VStack(alignment: .leading) {
                                Text(item.path).textSelection(.enabled)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                if queueMode { Button("Очистить список") { store.clear() }.disabled(store.queue.entries.isEmpty || store.busy) }
                Spacer()
                Button("Готово", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 560, height: 370)
    }
}
