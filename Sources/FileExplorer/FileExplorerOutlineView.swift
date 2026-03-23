import AppKit
import SwiftUI

struct FileExplorerOutlineView: NSViewRepresentable {
    let treeState: FileExplorerTreeState
    let onToggleExpansion: (FileExplorerNodeID) -> Void
    let onRefreshNode: (FileExplorerNodeID) -> Void
    let onCopyPath: (String) -> Void
    let onOpenLocalPath: (String) -> Void
    let onRevealInFinder: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier("FileExplorerSidebarOutline")

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.style = .sourceList
        outlineView.allowsEmptySelection = true
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.setAccessibilityIdentifier("FileExplorerSidebarOutline")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileExplorerColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(treeState: treeState)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: FileExplorerOutlineView
        weak var outlineView: NSOutlineView?

        private var rootItems: [OutlineItem] = []
        private var itemByID: [FileExplorerNodeID: OutlineItem] = [:]
        private var rootNodeIDs: Set<FileExplorerNodeID> = []
        private var suppressExpansionCallbacks = false

        init(parent: FileExplorerOutlineView) {
            self.parent = parent
        }

        func apply(treeState: FileExplorerTreeState) {
            rootNodeIDs = Set(treeState.roots.map(\.id))
            rootItems = treeState.roots.map(makeItemTree(from:))

            var nextItemByID: [FileExplorerNodeID: OutlineItem] = [:]
            collectItems(rootItems, into: &nextItemByID)
            itemByID = nextItemByID

            guard let outlineView else { return }
            suppressExpansionCallbacks = true
            outlineView.reloadData()
            syncExpansionState(in: outlineView)
            suppressExpansionCallbacks = false
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let item = item as? OutlineItem {
                return item.children.count
            }
            return rootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let item = item as? OutlineItem {
                return item.children[index]
            }
            return rootItems[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? OutlineItem else { return false }
            return item.node.kind == .directory
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            item is OutlineItem
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let item = item as? OutlineItem else { return 26 }
            return item.node.errorMessage == nil ? 26 : 42
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? OutlineItem else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileExplorerRowCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerRowCellView)
                ?? FileExplorerRowCellView(frame: .zero)
            cell.identifier = identifier
            cell.configure(
                with: item.node,
                isTopLevelRoot: rootNodeIDs.contains(item.node.id),
                onRetry: { [weak self] in
                    self?.parent.onRefreshNode(item.node.id)
                }
            )
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !suppressExpansionCallbacks,
                  let item = notification.userInfo?["NSObject"] as? OutlineItem else { return }
            parent.onToggleExpansion(item.node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !suppressExpansionCallbacks,
                  let item = notification.userInfo?["NSObject"] as? OutlineItem else { return }
            parent.onToggleExpansion(item.node.id)
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0,
                  let item = outlineView.item(atRow: row) as? OutlineItem else { return }

            if item.node.kind == .directory {
                parent.onToggleExpansion(item.node.id)
                return
            }

            guard case .local = item.node.hostScope else { return }
            parent.onOpenLocalPath(item.node.canonicalPath)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let item = menuTargetItem() else { return }

            if case .local = item.node.hostScope {
                let openItem = NSMenuItem(
                    title: String(localized: "fileExplorer.action.open", defaultValue: "Open"),
                    action: #selector(openLocalNodeFromMenu(_:)),
                    keyEquivalent: ""
                )
                openItem.target = self
                openItem.representedObject = item
                menu.addItem(openItem)

                let revealItem = NSMenuItem(
                    title: String(localized: "fileExplorer.action.revealInFinder", defaultValue: "Reveal in Finder"),
                    action: #selector(revealLocalNodeFromMenu(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = item
                menu.addItem(revealItem)

                menu.addItem(.separator())
            }

            let copyPathItem = NSMenuItem(
                title: String(localized: "fileExplorer.action.copyPath", defaultValue: "Copy Path"),
                action: #selector(copyPathFromMenu(_:)),
                keyEquivalent: ""
            )
            copyPathItem.target = self
            copyPathItem.representedObject = item
            menu.addItem(copyPathItem)

            if item.node.kind == .directory {
                let refreshItem = NSMenuItem(
                    title: String(localized: "fileExplorer.action.refresh", defaultValue: "Refresh"),
                    action: #selector(refreshNodeFromMenu(_:)),
                    keyEquivalent: ""
                )
                refreshItem.target = self
                refreshItem.representedObject = item
                menu.addItem(refreshItem)
            }
        }

        @objc private func openLocalNodeFromMenu(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OutlineItem else { return }
            parent.onOpenLocalPath(item.node.canonicalPath)
        }

        @objc private func revealLocalNodeFromMenu(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OutlineItem else { return }
            parent.onRevealInFinder(item.node.canonicalPath)
        }

        @objc private func copyPathFromMenu(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OutlineItem else { return }
            parent.onCopyPath(item.node.canonicalPath)
        }

        @objc private func refreshNodeFromMenu(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OutlineItem else { return }
            parent.onRefreshNode(item.node.id)
        }

        private func menuTargetItem() -> OutlineItem? {
            guard let outlineView else { return nil }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? OutlineItem
        }

        private func syncExpansionState(in outlineView: NSOutlineView) {
            for item in rootItems {
                syncExpansionState(for: item, in: outlineView)
            }
        }

        private func syncExpansionState(for item: OutlineItem, in outlineView: NSOutlineView) {
            if item.node.isExpanded {
                outlineView.expandItem(item, expandChildren: false)
            } else {
                outlineView.collapseItem(item, collapseChildren: false)
            }

            for child in item.children {
                syncExpansionState(for: child, in: outlineView)
            }
        }

        private func makeItemTree(from node: FileExplorerNodeState) -> OutlineItem {
            OutlineItem(node: node, children: node.children.map(makeItemTree(from:)))
        }

        private func collectItems(_ items: [OutlineItem], into result: inout [FileExplorerNodeID: OutlineItem]) {
            for item in items {
                result[item.node.id] = item
                collectItems(item.children, into: &result)
            }
        }
    }
}

private final class OutlineItem: NSObject {
    let node: FileExplorerNodeState
    let children: [OutlineItem]

    init(node: FileExplorerNodeState, children: [OutlineItem]) {
        self.node = node
        self.children = children
        super.init()
    }
}

private final class FileExplorerRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let markerView = FileExplorerRootMarkerView(frame: .zero)
    private let subtitleField = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: String(localized: "fileExplorer.action.retry", defaultValue: "Retry"), target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()
    private let textStack = NSStackView()
    private let contentStack = NSStackView()
    private let secondaryRow = NSStackView()

    private var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        markerView.translatesAutoresizingMaskIntoConstraints = false
        markerView.setContentHuggingPriority(.required, for: .horizontal)
        markerView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: 12, weight: .medium)

        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 1

        retryButton.isBordered = false
        retryButton.controlSize = .small
        retryButton.font = .systemFont(ofSize: 11, weight: .semibold)
        retryButton.contentTintColor = cmuxAccentNSColor()
        retryButton.target = self
        retryButton.action = #selector(handleRetryButton(_:))

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false

        secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .firstBaseline
        secondaryRow.spacing = 6
        secondaryRow.addArrangedSubview(subtitleField)
        secondaryRow.addArrangedSubview(retryButton)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleField)
        textStack.addArrangedSubview(secondaryRow)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(markerView)
        contentStack.addArrangedSubview(loadingIndicator)

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    func configure(
        with node: FileExplorerNodeState,
        isTopLevelRoot: Bool,
        onRetry: @escaping () -> Void
    ) {
        self.onRetry = onRetry

        titleField.stringValue = isTopLevelRoot ? node.displayPath : node.displayName
        titleField.font = .systemFont(ofSize: 12, weight: isTopLevelRoot ? .semibold : .medium)
        titleField.textColor = .labelColor

        if let errorMessage = node.errorMessage {
            subtitleField.stringValue = errorMessage
            subtitleField.isHidden = false
            retryButton.isHidden = false
        } else {
            subtitleField.stringValue = ""
            subtitleField.isHidden = true
            retryButton.isHidden = true
        }

        markerView.isHidden = !node.isExplicitSurfaceRoot
        loadingIndicator.isHidden = !node.isLoading
        if node.isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }

        alphaValue = node.isHidden ? 0.68 : 1.0
        iconView.image = icon(for: node)
    }

    @objc private func handleRetryButton(_ sender: Any?) {
        _ = sender
        onRetry?()
    }

    private func icon(for node: FileExplorerNodeState) -> NSImage {
        if case .local = node.hostScope {
            let image = NSWorkspace.shared.icon(forFile: node.canonicalPath)
            image.size = NSSize(width: 16, height: 16)
            return image
        }

        let symbolName: String
        switch node.kind {
        case .directory:
            symbolName = "folder"
        case .file:
            symbolName = "doc"
        case .symlink:
            symbolName = "arrow.up.forward.square"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

private final class FileExplorerRootMarkerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        cmuxAccentNSColor().setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
