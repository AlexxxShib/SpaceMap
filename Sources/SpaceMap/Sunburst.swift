import SwiftUI
import AppKit

struct BranchTint {
    let hue: Double
    let depth: Int

    func child(_ rank: Int) -> BranchTint {
        let drift = [-0.052, 0.048, -0.092, 0.094, -0.13, 0.13]
        return BranchTint(hue: (hue + drift[rank % drift.count] + 1).truncatingRemainder(dividingBy: 1), depth: depth + 1)
    }
    static func first(_ rank: Int) -> BranchTint {
        let hues = [0.245, 0.572, 0.70, 0.105, 0.035, 0.46, 0.85, 0.15, 0.62, 0.355]
        return BranchTint(hue: hues[rank % hues.count], depth: 0)
    }
    var color: NSColor {
        return NSColor(calibratedHue: hue, saturation: max(0.40, 0.77 - Double(depth) * 0.055), brightness: 0.96, alpha: 1)
    }
}

func marker(_ entry: Entry, under root: Entry) -> BranchTint? {
    if entry === root { return nil }
    guard let parent = entry.parent, let rank = Grouped(parent).main.firstIndex(where: { $0 === entry }) else { return nil }
    if parent === root { return .first(rank) }
    return marker(parent, under: root)?.child(rank)
}

struct Arc {
    let entry: Entry
    let group: Bool
    let start: Double
    let end: Double
    let level: Int
    let tint: BranchTint?
    let weight: Int64
}

func makeArcs(_ root: Entry, levels: Int) -> [Arc] {
    var arcs: [Arc] = []
    func visit(_ parent: Entry, _ start: Double, _ span: Double, _ level: Int, _ tint: BranchTint?) {
        guard level < levels, parent.bytes > 0, parent.folder else { return }
        let items = Grouped(parent)
        var angle = start
        for (rank, entry) in items.main.enumerated() where entry.bytes > 0 {
            let width = span * Double(entry.bytes) / Double(parent.bytes)
            let childTint = tint?.child(rank) ?? .first(rank)
            arcs.append(Arc(entry: entry, group: false, start: angle, end: angle + width, level: level, tint: childTint, weight: entry.bytes))
            if width > 0.001 { visit(entry, angle, width, level + 1, childTint) }
            angle += width
        }
        if items.smallBytes > 0 {
            arcs.append(Arc(entry: parent, group: true, start: angle, end: start + span, level: level, tint: nil, weight: items.smallBytes))
        }
    }
    visit(root, 0, .pi * 2, 0, nil)
    return arcs
}

struct Sunburst: NSViewRepresentable {
    @ObservedObject var store: Workspace
    let root: Entry
    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {
        view.store = store
        view.configure(root: root)
    }
}

@MainActor
final class RingView: NSView, NSMenuDelegate {
    weak var store: Workspace?
    private var tree: Entry?
    private var arcs: [Arc] = []
    private var radii: [CGFloat] = []
    private var lastSize = CGSize.zero
    private var hover: Int?
    private var menuEntry: Entry?
    private var area: NSTrackingArea?
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(root: Entry) {
        if root !== tree {
            tree = root
            lastSize = .zero
            hover = nil
            toolTip = nil
            menuEntry = nil
        }
        rebuild()
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Map, " + (store?.title(root) ?? root.name) + ", " + sizeText(root.bytes) + ". Items are available in the list.")
    }

    override func layout() { super.layout(); rebuild() }
    private func rebuild() {
        guard let tree, bounds.size != lastSize else { return }
        lastSize = bounds.size
        let r = max(1, min(bounds.width, bounds.height) * 0.46)
        let limit = min(8, max(3, Int(r / 32)))
        arcs = makeArcs(tree, levels: limit)
        let n = max(1, (arcs.map(\.level).max() ?? 0) + 1)
        let hole = min(r * 0.34, max(45, r * 0.19))
        let widths = (0..<n).map { pow(0.82, Double($0)) }
        var edge = hole
        radii = [hole]
        let total = widths.reduce(0, +)
        for width in widths { edge += (r - hole) * width / total; radii.append(edge) }
        needsDisplay = true
    }

    private func path(_ arc: Arc) -> NSBezierPath {
        let p = NSBezierPath()
        let from = arc.start * 180 / .pi, to = arc.end * 180 / .pi
        p.appendArc(withCenter: center, radius: radii[arc.level + 1], startAngle: from, endAngle: to)
        p.appendArc(withCenter: center, radius: radii[arc.level], startAngle: to, endAngle: from, clockwise: true)
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tree, !radii.isEmpty else { return }
        let marked = store?.queue.entries.map(\.id) ?? []
        var outlines: [(NSBezierPath, Bool)] = []
        for (i, arc) in arcs.enumerated() {
            let p = path(arc)
            let selected = store?.selection === arc.entry && store?.groupSelected == arc.group
            let color = arc.tint?.color ?? NSColor.systemGray
            (hover == i ? color.highlight(withLevel: 0.21) ?? color : color).setFill()
            p.fill()
            NSColor.windowBackgroundColor.withAlphaComponent(0.84).setStroke()
            p.lineWidth = 0.85
            p.stroke()
            if !marked.isEmpty {
                let full = arc.entry.url.path
                if marked.contains(where: { $0 == full || full.hasPrefix($0 + "/") }) {
                    NSGraphicsContext.saveGraphicsState()
                    p.addClip()
                    let lines = NSBezierPath(), box = p.bounds
                    for x in stride(from: box.minX - box.height, through: box.maxX, by: 7) {
                        lines.move(to: CGPoint(x: x, y: box.minY))
                        lines.line(to: CGPoint(x: x + box.height, y: box.maxY))
                    }
                    NSColor.black.withAlphaComponent(0.35).setStroke()
                    lines.lineWidth = 1.5
                    lines.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            if selected || hover == i { outlines.append((p, selected)) }
        }
        for (p, selected) in outlines {
            NSColor.labelColor.withAlphaComponent(selected ? 0.92 : 0.6).setStroke()
            p.lineWidth = selected ? 2.25 : 1.35
            p.stroke()
        }
        let parts = sizeText(tree.bytes).components(separatedBy: " ")
        let value = parts.dropLast().joined(separator: " ")
        let hole = radii[0]
        func label(_ text: String, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: y), withAttributes: attrs)
        }
        label(value, center.y - 0.50 * hole, .systemFont(ofSize: min(30, hole * 0.56), weight: .medium), .labelColor)
        label(parts.last ?? "", center.y + 0.12 * hole, .systemFont(ofSize: min(15, hole * 0.30), weight: .medium), .secondaryLabelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }

    private func hit(_ point: CGPoint) -> (Bool, Int?) {
        let x = point.x - center.x, y = point.y - center.y, r = hypot(x, y)
        guard let inner = radii.first else { return (false, nil) }
        if r < inner { return (true, nil) }
        var angle = atan2(y, x)
        if angle < 0 { angle += .pi * 2 }
        guard let edge = radii.dropFirst().firstIndex(where: { $0 >= r }) else { return (false, nil) }
        return (false, arcs.firstIndex { $0.level == edge - 1 && $0.start <= angle && angle < $0.end })
    }
    override func mouseMoved(with event: NSEvent) {
        let (_, i) = hit(convert(event.locationInWindow, from: nil))
        if i != hover {
            hover = i
            toolTip = i.map { (arcs[$0].group ? "Small items" : arcs[$0].entry.name) + " · " + sizeText(arcs[$0].weight) }
            needsDisplay = true
        }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; toolTip = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        let (middle, i) = hit(convert(event.locationInWindow, from: nil))
        if middle, let tree { store?.select(tree); return }
        guard let i else { return }
        let arc = arcs[i]
        if arc.group { store?.selectGroup(arc.entry) }
        else { store?.activate(arc.entry) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = hit(convert(event.locationInWindow, from: nil)).1, !arcs[i].group, let store else { return nil }
        let entry = arcs[i].entry
        menuEntry = entry
        let menu = NSMenu()
        menu.autoenablesItems = false
        if entry.folder {
            menu.addItem(withTitle: "Open Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        }
        let marked = store.queue.covering(entry.url.path)?.id == entry.url.path
        let reason = store.blocked(entry)
        let item = menu.addItem(withTitle: marked ? "Unmark" : reason ?? "Mark for Removal", action: #selector(markItem), keyEquivalent: "")
        item.isEnabled = !store.busy && (marked || reason == nil)
        item.target = self
        return menu
    }
    @objc private func markItem() { if let menuEntry { store?.toggle(menuEntry) } }
    @objc private func openFolder() { if let menuEntry { store?.open(menuEntry) } }
}
