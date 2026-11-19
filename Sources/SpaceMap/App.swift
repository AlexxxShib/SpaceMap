import AppKit
import SwiftUI

@main
struct SpaceMapApp: App {
    @StateObject private var store = Workspace()

    var body: some Scene {
        Window("Space Map", id: "workspace") {
            ContentView(store: store)
                .frame(minWidth: 780, minHeight: 465)
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Сканировать папку…") { store.pickFolder() }
                    .keyboardShortcut("o").disabled(store.busy || store.screen == .scanning)
            }
        }
    }
}

private enum Panel: String, Identifiable {
    case queue, coverage
    var id: String { rawValue }
}

private final class WindowDialogs: ObservableObject {
    @Published var panel: Panel?
    @Published var confirming = false
    @Published var confirmSummary = ""
}

struct ContentView: View {
    @ObservedObject var store: Workspace
    @StateObject private var dialogs = WindowDialogs()
    var body: some View {
        VStack(spacing: 0) {
            if store.screen == .map, let root = store.root, let disk = store.disk {
                MapSplit {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.pie").foregroundStyle(.secondary)
                            Text(store.title(root)).font(.headline).lineLimit(1)
                            Spacer()
                        }.padding(.horizontal, 22).padding(.top, 18)
                        Sunburst(store: store, root: root)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack(spacing: 6) {
                            Image(systemName: "internaldrive")
                            Text(disk.title).lineLimit(1)
                            Spacer()
                            Text("Доступно " + sizeText(disk.available))
                        }.font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 22).padding(.bottom, 15)
                    }.frame(minWidth: 370, idealWidth: 650, maxWidth: .infinity)
                } details: {
                    if let selected = store.selection {
                        Inspector(store: store, entry: selected)
                            .frame(minWidth: 310, idealWidth: 400, maxWidth: .infinity)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    if !store.queue.entries.isEmpty {
                        Image(systemName: "tray.full")
                        Text("К удалению").fontWeight(.medium)
                        Text(store.summary).monospacedDigit()
                        Button("Посмотреть") { dialogs.panel = .queue }
                        Spacer()
                        Button("Удалить…") {
                            dialogs.confirmSummary = (store.queue.entries.count == 1 ? store.queue.entries[0].url.lastPathComponent + " · " : "Объекты: ") + store.summary
                            dialogs.confirming = true
                        }.disabled(store.busy || !store.online)
                    } else {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        if let date = store.snapshot?.finished {
                            Text("Сканирование в " + date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if store.busy { ProgressView().controlSize(.small) }
                    Button {
                        dialogs.panel = .coverage
                    } label: {
                        if !store.online { Label("Диск недоступен", systemImage: "externaldrive.badge.xmark") }
                        else if store.snapshot?.issues.isEmpty == false { Label("Сканирование неполное", systemImage: "exclamationmark.circle") }
                        else { Image(systemName: "info.circle").accessibilityLabel("Сведения о сканировании") }
                    }.buttonStyle(.borderless)
                }.font(.callout).padding(.horizontal, 18).frame(height: 46)
            } else {
                DiskChooser(store: store)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            if store.screen == .map {
                ToolbarItemGroup(placement: .navigation) {
                    Button { store.showDisks() } label: { Image(systemName: "internaldrive").accessibilityLabel("Выбрать диск") }
                        .help("К выбору диска").disabled(store.busy)
                    Button { store.step(-1) } label: { Image(systemName: "chevron.left").accessibilityLabel("Назад") }
                        .disabled(store.position == 0).keyboardShortcut("[")
                    Button { store.step(1) } label: { Image(systemName: "chevron.right").accessibilityLabel("Вперёд") }
                        .disabled(store.position + 1 >= store.history.count).keyboardShortcut("]")
                }
                ToolbarItem { PathMenu(store: store) }
                ToolbarItem(placement: .primaryAction) {
                    Button { if let disk = store.disk { store.scan(disk) } } label: {
                        Label("Сканировать снова", systemImage: "arrow.clockwise")
                    }.help("Сканировать снова").keyboardShortcut("r").disabled(store.busy)
                }
            }
        }
        .sheet(item: $dialogs.panel) { choice in
            DetailSheet(store: store, queueMode: choice == .queue) { dialogs.panel = nil }
        }
        .alert("Переместить выбранные объекты в Корзину?", isPresented: $dialogs.confirming) {
            Button("Отмена", role: .cancel) {}
            Button("Переместить в Корзину", role: .destructive) { store.trashConfirmed() }
        } message: { Text(dialogs.confirmSummary) }
        .alert("Space Map", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

struct PathMenu: View {
    @ObservedObject var store: Workspace
    var chain: [Entry] {
        var entries: [Entry] = [], e = store.root
        while let current = e { entries.append(current); e = current.parent }
        return entries.reversed()
    }
    var body: some View {
        let entries = chain
        let visible = entries.suffix(3)
        HStack(spacing: 5) {
            if entries.count > 3 {
                Menu("…") {
                    ForEach(entries.dropLast(3)) { e in Button(store.title(e)) { store.open(e) } }
                }.fixedSize()
            }
            ForEach(visible) { e in
                if e !== visible.first { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).fixedSize() }
                let title = store.title(e)
                Button { store.open(e) } label: {
                    Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(title)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct DiskChooser: View {
    @ObservedObject var store: Workspace
    var scanning: Bool { store.screen == .scanning }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 57, height: 57)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scanning ? "Сканирование" : "Диски").font(.system(size: 31, weight: .semibold))
                    Text(scanning ? (store.disk?.title ?? "") : "Выберите диск для анализа занятого места.")
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            if scanning {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView().progressViewStyle(.linear)
                    HStack {
                        Text("Просмотрено объектов: " + store.progress.0.formatted()).monospacedDigit()
                        Spacer()
                        Button("Отменить") { store.showDisks() }.keyboardShortcut(.cancelAction)
                    }
                    Text(store.progress.1).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.padding(20).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.disks) { disk in
                            HStack(spacing: 15) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: disk.url.path)).resizable().frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(disk.title).font(.headline)
                                    Text(sizeText(disk.capacity) + (disk.url.path == "/" ? " · Загрузочный диск" : " · Локальный том"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("Доступно " + sizeText(disk.available)).font(.callout).monospacedDigit()
                                    ProgressView(value: min(1, max(0, 1 - Double(disk.available) / Double(max(1, disk.capacity)))))
                                        .progressViewStyle(.linear).tint(.accentColor)
                                }.frame(width: 140)
                                Button("Сканировать") { store.scan(disk) }.padding(.leading, 5)
                            }.padding(.horizontal, 19).padding(.vertical, 16)
                            if disk.id != store.disks.last?.id { Divider().padding(.leading, 75) }
                        }
                    }.background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                }.frame(maxHeight: CGFloat(min(store.disks.count, 5)) * 80 + 6)
                Button { store.pickFolder() } label: { Label("Сканировать папку…", systemImage: "folder") }
            }
        }.padding(34).frame(maxWidth: 910).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
