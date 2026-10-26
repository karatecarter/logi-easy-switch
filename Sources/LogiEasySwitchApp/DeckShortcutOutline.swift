import AppKit
import SwiftUI

struct DeckShortcutOutline: NSViewRepresentable {
    @Binding var buttons: [DeckButton]
    @Binding var selection: UUID?
    var readOnly: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { makeScrollView(coordinator: context.coordinator) }
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = DeckOutlineScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        column.width = 160
        column.minWidth = 40
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 28
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.toggleSelectedFolder(_:))
        outline.registerForDraggedTypes([Coordinator.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.autoresizingMask = [.width]
        scroll.documentView = outline
        coordinator.refresh(outline, owner: self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        context.coordinator.refresh(outline, owner: self)
    }

    final class Node: NSObject { let id: UUID; init(_ id: UUID) { self.id = id } }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("local.switchboard.shortcut-id")
        var owner: DeckShortcutOutline
        private var nodes: [UUID: Node] = [:]
        private var displayedButtons: [DeckButton]
        private var initialized = false
        private var previousSelection: UUID?
        private var updating = false
        init(_ owner: DeckShortcutOutline) { self.owner = owner; displayedButtons = owner.buttons }
        private func node(_ id: UUID) -> Node {
            if let existing = nodes[id] { return existing }
            let created = Node(id); nodes[id] = created
            return created
        }
        private func button(_ item: Any?) -> DeckButton? {
            guard let node = item as? Node else { return nil }
            return displayedButtons.first { $0.id == node.id }
        }
        private func children(_ item: Any?) -> [DeckButton] {
            if let node = item as? Node { return displayedButtons.filter { $0.parentID == node.id } }
            let ids = Set(displayedButtons.map(\.id))
            return displayedButtons.filter { $0.parentID == nil || !ids.contains($0.parentID!) }
        }
        func refresh(_ outline: NSOutlineView, owner: DeckShortcutOutline) {
            let changed = !initialized || displayedButtons != owner.buttons
            let selectionChanged = previousSelection != owner.selection
            let expanded = Set(nodes.values.filter { outline.isItemExpanded($0) }.map(\.id))
            self.owner = owner
            updating = true
            defer { updating = false }
            for button in owner.buttons where nodes[button.id] == nil { nodes[button.id] = Node(button.id) }
            if changed {
                displayedButtons = owner.buttons
                initialized = true
                outline.reloadData()
                func restore(_ item: Any?) {
                    for child in children(item) where expanded.contains(child.id) {
                        if let node = nodes[child.id] {
                            outline.expandItem(node)
                            restore(node)
                        }
                    }
                }
                restore(nil)
            }
            if selectionChanged, let selected = owner.selection {
                var parent = owner.buttons.first { $0.id == selected }?.parentID
                var ancestors: [UUID] = []
                while let id = parent, !ancestors.contains(id) {
                    ancestors.insert(id, at: 0)
                    parent = owner.buttons.first { $0.id == id }?.parentID
                }
                for id in ancestors { if let node = nodes[id] { outline.expandItem(node) } }
            }
            if let selected = owner.selection, let node = nodes[selected], outline.row(forItem: node) >= 0 {
                let row = outline.row(forItem: node)
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if selectionChanged { outline.scrollRowToVisible(row) }
            } else if owner.selection == nil { outline.deselectAll(nil) }
            previousSelection = owner.selection
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { node(children(item)[index].id) }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { button(item).map(DeckShortcutTree.isContainer) ?? false }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let button = button(item) else { return nil }
            let id = NSUserInterfaceItemIdentifier("shortcutRow")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = id
                let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                let badge = NSImageView(); badge.translatesAutoresizingMaskIntoConstraints = false
                badge.identifier = NSUserInterfaceItemIdentifier("localOnlyBadge")
                badge.image = NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: "Local to this Mac")
                badge.toolTip = "Local to this Mac"
                let badgeWidth = badge.widthAnchor.constraint(equalToConstant: 0)
                badgeWidth.identifier = "localBadgeWidth"
                let label = NSTextField(wrappingLabelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: NSFont.systemFontSize)
                label.maximumNumberOfLines = 0
                label.lineBreakMode = .byWordWrapping
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(image); cell.addSubview(label); cell.addSubview(badge)
                cell.imageView = image; cell.textField = label
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 15), image.heightAnchor.constraint(equalToConstant: 15),
                    label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4), label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5), label.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -5),
                    badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor), badge.heightAnchor.constraint(equalToConstant: 12), badgeWidth
                ])
            }
            cell.textField?.stringValue = button.name
            var configuration = DeckConfiguration(); configuration.buttons = owner.buttons
            let local = !DeckSyncScope.isShared(button, in: configuration)
            let iconButton = DeckGroups.mainAction(button, in: configuration) ?? button
            cell.imageView?.image = DeckImageIcons.image(iconButton) ?? NSImage(systemSymbolName: DeckImageIcons.symbol(iconButton), accessibilityDescription: button.name)
            if let badge = cell.subviews.first(where: { $0.identifier?.rawValue == "localOnlyBadge" }) {
                badge.isHidden = !local
                badge.constraints.first { $0.identifier == "localBadgeWidth" }?.constant = local ? 12 : 0
            }
            cell.toolTip = button.name + (local ? " — Local to this Mac" : "")
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let button = button(item) else { return 28 }
            let level = max(0, outlineView.level(forItem: item))
            var configuration = DeckConfiguration(); configuration.buttons = displayedButtons
            let badgeSpace: CGFloat = DeckSyncScope.isShared(button, in: configuration) ? 0 : 12
            let width = max(30, (outlineView.tableColumns.first?.width ?? 160) - CGFloat(level + 1) * outlineView.indentationPerLevel - 39 - badgeSpace)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let height = (button.name as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: paragraph]).height
            return max(28, ceil(height) + 10)
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline = notification.object as? NSOutlineView else { return }
            owner.selection = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.id : nil
            previousSelection = owner.selection
        }
        @objc func toggleSelectedFolder(_ outline: NSOutlineView) {
            guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow), outline.isExpandable(item) else { return }
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !owner.readOnly, let node = item as? Node else { return nil }
            let value = NSPasteboardItem(); value.setString(node.id.uuidString, forType: Self.dragType)
            return value
        }
        private func destination(_ item: Any?, index: Int) -> (UUID?, Int)? {
            if index >= 0 { return ((item as? Node)?.id, index) }
            guard let target = button(item) else { return (nil, children(nil).count) }
            if DeckShortcutTree.isContainer(target) { return (target.id, children(item).count) }
            let siblings = owner.buttons.filter { $0.parentID == target.parentID }
            return (target.parentID, siblings.firstIndex { $0.id == target.id } ?? 0)
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !owner.readOnly, info.draggingSource as? NSOutlineView === outlineView,
                  let value = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: value),
                  let (parent, position) = destination(item, index: index), DeckShortcutTree.canMove(id, to: parent, buttons: owner.buttons) else { return [] }
            if index < 0, let target = button(item), !DeckShortcutTree.isContainer(target) {
                outlineView.setDropItem(parent.flatMap { nodes[$0] }, dropChildIndex: position)
            }
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard !owner.readOnly, info.draggingSource as? NSOutlineView === outlineView, let value = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: value),
                  let (parent, position) = destination(item, index: index), let moved = DeckShortcutTree.moving(id, to: parent, at: position, buttons: owner.buttons) else { return false }
            previousSelection = nil // Reveal the destination even when the dragged row was already selected.
            owner.buttons = moved
            owner.selection = id
            if let parent, let node = nodes[parent] { outlineView.expandItem(node) }
            return true
        }
    }
}


/// Keep the document and column inside the actual clip width (including when a
/// legacy scroller consumes space) so the row selection cannot be clipped.
final class DeckOutlineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let outline = documentView as? NSOutlineView else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        if abs(outline.frame.width - width) > 0.5 {
            outline.setFrameSize(NSSize(width: width, height: outline.frame.height))
            // AppKit accounts for source-list style insets when fitting the column.
            outline.sizeLastColumnToFit()
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }
}
