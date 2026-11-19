import SwiftUI
import AppKit

/// The initial ratio follows the map layout. AppKit manages subsequent divider drags.
struct MapSplit<Map: View, Details: View>: NSViewControllerRepresentable {
    @ViewBuilder var map: () -> Map
    @ViewBuilder var details: () -> Details

    func makeNSViewController(context: Context) -> MapSplitController {
        let controller = MapSplitController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        let mapItem = NSSplitViewItem(viewController: NSHostingController(rootView: map()))
        mapItem.minimumThickness = 370
        let inspector = NSSplitViewItem(viewController: NSHostingController(rootView: details()))
        inspector.minimumThickness = 310
        controller.addSplitViewItem(mapItem)
        controller.addSplitViewItem(inspector)
        return controller
    }

    func updateNSViewController(_ controller: MapSplitController, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Map>)?.rootView = map()
        (controller.splitViewItems[1].viewController as? NSHostingController<Details>)?.rootView = details()
    }
}

final class MapSplitController: NSSplitViewController {
    private var placed = false
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, splitView.bounds.width >= 680 else { return }
        placed = true
        splitView.setPosition(min(splitView.bounds.width - 311, splitView.bounds.width * 0.61), ofDividerAt: 0)
    }
}
