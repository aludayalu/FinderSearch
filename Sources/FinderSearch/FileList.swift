import SwiftUI
import AppKit

/// Fixed-height AppKit rows avoid SwiftUI Table's automatic-height diffing work
/// when hundreds of search results are replaced by a cached folder listing.
@MainActor struct FileList: NSViewRepresentable {
    @ObservedObject var model: SearchModel
    let focusFiles: () -> Void
    let newTab: (URL) -> Void
    var addFavorite: (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { makeView(coordinator: context.coordinator) }
    func makeView(coordinator: Coordinator) -> NSScrollView {
        let table = BrowserTable()
        table.delegate = coordinator; table.dataSource = coordinator
        table.rowHeight = 24; table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width, minimum) in [
            ("name", "Name", 300.0, 180.0), ("modified", "Date Modified", 180.0, 145.0),
            ("size", "Size", 85.0, 70.0), ("kind", "Kind", 130.0, 90.0),
            ("where", "Where", 200.0, 130.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = minimum
            if key != "where" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            table.addTableColumn(column)
        }
        table.target = coordinator; table.doubleAction = #selector(Coordinator.openClicked)
        table.dragExit = { [weak model = model] in model?.springLoader.cancel() }
        table.menuProvider = { [weak coordinator = coordinator] row in coordinator?.menu(for: row) }
        table.focusHandler = { [weak coordinator = coordinator] in
            guard let coordinator else { return }
            coordinator.parent.focusFiles(); coordinator.parent.model.cancelRename()
        }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true;
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true; scroll.documentView = table
        coordinator.table = table
        let marquee = table.marquee
        marquee.frame = table.bounds
        marquee.autoresizingMask = [.width, .height]
        marquee.table = table
        marquee.pathForRow = { [weak coordinator] row in
            guard let coordinator else { return nil }
            return coordinator.hitPath(at: row)
        }
        table.addSubview(marquee)
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.rememberScroll() }
        }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileList
        weak var table: BrowserTable?
        fileprivate var items: [Hit] = []
        /// Table row of each item. Section headers occupy rows, so this is not
        /// the same as the item's index in `items`.
        private var rowByPath: [String: Int] = [:]
        /// Table rows holding a section title rather than a file.
        private var headerRows: [Int: String] = [:]
        private var rowCount = 0
        private var updating = false
        private weak var renameField: RenameTextField?
        private var actions: [Int: @MainActor () -> Void] = [:]
        var scrollObserver: NSObjectProtocol?
        private var restoredRoute: String?
        private var displayedTab: UUID?
        init(_ parent: FileList) { self.parent = parent }
        func update() {
            guard let table else { return }
            table.marquee.configure(
                model: parent.model, identity: parent.model.route + ":" + parent.model.query)
            table.marquee.focusFiles = parent.focusFiles
            let switchingTab = displayedTab != parent.model.id
            if switchingTab {
                renameField?.cancelEditing(); renameField = nil
                displayedTab = parent.model.id; restoredRoute = nil
            }
            let next = parent.model.sortedHits
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("where"))?.isHidden =
                !parent.model.isSearch
            rebuildRows(next)
            if let hit = parent.model.renaming, let row = rowByPath[hit.path] {
                updating = true; defer { updating = false }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                // Do not rebuild a live field editor when metadata or sorting
                // finishes; its draft and selection belong to the user.
                table.scrollRowToVisible(row)
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell,
                    let field = cell.textField as? RenameTextField
                {
                    let model = parent.model
                    renameField = field
                    field.begin(
                        hit, commit: { model.commitRename($0) }, cancel: { model.cancelRename() })
                }
                return
            }
            if renameField?.editingPath != nil { renameField?.cancelEditing() }
            updating = true; defer { updating = false }
            let selected = IndexSet(parent.model.selection.compactMap { rowByPath[$0] })
            if table.selectedRowIndexes != selected {
                table.selectRowIndexes(selected, byExtendingSelection: false)
            }
            if displayedTab == parent.model.id, !parent.model.marqueeSelecting,
                let path = parent.model.focusedPath,
                let row = rowByPath[path]
            {
                table.scrollRowToVisible(row)
            }
            let key: String?
            switch parent.model.sort {
            case .name: key = "name";
            case .modified: key = "modified";
            case .size: key = "size";
            case .kind: key = "kind";
            case .relevance: key = nil
            }
            let descriptors =
                key.map { [NSSortDescriptor(key: $0, ascending: parent.model.ascending)] } ?? []
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            if restoredRoute != parent.model.route,
                let anchor = parent.model.scrollAnchor, let row = rowByPath[anchor],
                let scroll = table.enclosingScrollView
            {
                let y = table.rect(ofRow: row).minY + parent.model.scrollOffset
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                restoredRoute = parent.model.route
            } else if parent.model.scrollAnchor == nil {
                if switchingTab, let scroll = table.enclosingScrollView {
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                restoredRoute = parent.model.route
            }
            if let hit = parent.model.renaming, let row = rowByPath[hit.path],
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell,
                let field = cell.textField as? RenameTextField
            {
                table.scrollRowToVisible(row)
                renameField = field
                let model = parent.model
                field.begin(
                    hit, commit: { model.commitRename($0) }, cancel: { model.cancelRename() })
            }
        }
        /// Map the flat display order onto table rows, reserving a header row
        /// for each date section. Reload only when rows actually change.
        private func rebuildRows(_ next: [Hit]) {
            guard let table else { return }
            var headers: [Int: String] = [:]
            var rows: [String: Int] = [:]
            rows.reserveCapacity(next.count)
            if let sections = parent.model.groupedSections {
                var position = 0
                var row = 0
                for section in sections {
                    headers[row] = section.title
                    row += 1
                    for hit in section.items {
                        if position < next.count, next[position].path == hit.path {
                            rows[hit.path] = row
                        }
                        row += 1; position += 1
                    }
                }
                for index in position..<next.count { rows[next[index].path] = row + index - position }
                row += next.count - position
            } else {
                for (index, hit) in next.enumerated() { rows[hit.path] = index }
            }
            let count = next.count + headers.count
            if items != next || headerRows != headers {
                items = next; rowByPath = rows; headerRows = headers; rowCount = count
                table.reloadData()
            } else {
                rowByPath = rows; rowCount = count
            }
        }
        private func hit(at row: Int) -> Hit? {
            guard !headerRows.keys.contains(row) else { return nil }
            let index = row - headerRows.keys.filter { $0 < row }.count
            return items.indices.contains(index) ? items[index] : nil
        }
        fileprivate func hitPath(at row: Int) -> String? { hit(at: row)?.path }
        func rememberScroll() {
            guard !updating, let table, let clip = table.enclosingScrollView?.contentView,
                !parent.model.loading
            else { return }
            var row = table.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
            // A section header borrows the position of its first item.
            while headerRows.keys.contains(row), row + 1 < rowCount { row += 1 }
            guard let hit = hit(at: row) else { return }
            parent.model.scrollOffset = max(0, clip.bounds.minY - table.rect(ofRow: row).minY)
            if parent.model.scrollAnchor != hit.path {
                parent.model.scrollAnchor = hit.path
            }
        }
        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            headerRows[row] == nil ? 24 : 28
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard let title = headerRows[row] else { return nil }
            return FileSectionRowView(title: title)
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            headerRows[row] == nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            guard headerRows[row] == nil, let tableColumn else { return nil }
            let columnIndex = table?.tableColumns.firstIndex(of: tableColumn) ?? 0
            guard columnIndex == 0, let hit = hit(at: row) else { return nil }
            let key = tableColumn.identifier.rawValue
            let cell =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? FileCell
                ?? FileCell(identifier: tableColumn.identifier, withIcon: key == "name")
            cell.path = hit.path
            switch key {
            case "name": cell.textField?.stringValue = hit.name
            case "modified":
                cell.textField?.stringValue =
                    hit.metadataPending == true
                    ? "—" : Self.dateFormatter.string(from: hit.modified)
            case "size":
                cell.textField?.stringValue =
                    hit.kind == "dir" || hit.metadataPending == true
                    ? "—" : Self.sizeFormatter.string(fromByteCount: Int64(clamping: hit.size))
            case "kind": cell.textField?.stringValue = hit.typeName
            default: cell.textField?.stringValue = hit.parent
            }
            cell.textField?.textColor = key == "name" ? .labelColor : .secondaryLabelColor
            cell.textField?.alignment = key == "size" ? .right : .left
            if key == "name" {
                cell.imageView?.image = FileIcons.shared.placeholder(hit, size: .row)
                cell.iconTask?.cancel()
                guard hit.metadataPending != true else { cell.iconTask = nil; return cell }
                cell.iconTask = Task { @MainActor [weak cell] in
                    guard let icon = await FileIcons.shared.load(hit, size: .row) else { return }
                    guard !Task.isCancelled, let cell, cell.path == hit.path else { return }
                    cell.imageView?.image = icon
                }
            }
            return cell
        }
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
        }()
        private static let sizeFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter(); f.countStyle = .file; return f
        }()
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.model.cancelRename()
            parent.focusFiles(); table.window?.makeFirstResponder(table)
            let rows = table.selectedRowIndexes.filter { headerRows[$0] == nil }
            var paths = Set<String>()
            paths.reserveCapacity(rows.count)
            for row in rows { if let hit = hit(at: row) { paths.insert(hit.path) } }
            // Shift-click may report a stale anchor when the model re-sorted
            // underneath a held selection; keep the model's anchor.
            if let existing = parent.model.selectionAnchor,
                paths.contains(existing),
                table.selectedRowIndexes.count > 1
            {
                parent.model.selectionAnchor = existing
                if let last = table.selectedRowIndexes.last, let path = hit(at: last)?.path {
                    parent.model.focusedPath = path
                } else {
                    parent.model.focusedPath = existing
                }
            }
            parent.model.selection = paths
        }
        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            switch descriptor.key {
            case "modified": parent.model.sort = .modified;
            case "size": parent.model.sort = .size;
            case "kind": parent.model.sort = .kind;
            default: parent.model.sort = .name
            }
            parent.model.ascending = descriptor.ascending
        }
        @objc func openClicked() {
            guard let table, table.clickedRow >= 0, let hit = hit(at: table.clickedRow) else {
                return
            }
            parent.model.open(hit)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
            -> NSPasteboardWriting?
        { hit(at: row)?.url as NSURL? }
        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard !parent.model.busy else { parent.model.springLoader.cancel(); return [] }
            let target = row >= 0 ? hit(at: row) : nil
            parent.model.hoverFolder(
                operation == .on && target?.isFolder == true ? target!.url : nil)
            if operation == .on {
                guard target?.isFolder == true else { return [] }
            } else {
                guard row >= rowCount, parent.model.canWriteHere else { return [] }
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return NSEvent.modifierFlags.contains(.option)
                || !info.draggingSourceOperationMask.contains(.move) ? .copy : .move
        }
        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation operation: NSTableView.DropOperation
        ) -> Bool {
            parent.model.springLoader.cancel()
            let destination: URL
            if operation == .on, let target = row >= 0 ? hit(at: row) : nil,
                target.isFolder
            {
                destination = target.url
            } else if parent.model.canWriteHere && (row == -1 || row >= rowCount) {
                destination = parent.model.location
            } else {
                return false
            }
            let urls =
                info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                ?? []
            guard !urls.isEmpty, !parent.model.busy else { return false }
            parent.model.transfer(
                urls, to: destination,
                move: !NSEvent.modifierFlags.contains(.option)
                    && info.draggingSourceOperationMask.contains(.move))
            return true
        }
        func menu(for row: Int) -> NSMenu {
            let menu = NSMenu(); actions.removeAll()
            guard let table else { return menu }
            let model = parent.model
            @discardableResult func add(
                _ title: String, enabled: Bool = true, to submenu: NSMenu? = nil,
                _ action: @escaping @MainActor () -> Void
            ) -> NSMenuItem {
                let item = NSMenuItem(
                    title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = actions.count; item.isEnabled = enabled
                actions[item.tag] = action; (submenu ?? menu).addItem(item)
                return item
            }
            menu.autoenablesItems = false
            if hit(at: row) == nil {
                let writable = model.canWriteHere && !model.busy
                add("New Folder", enabled: writable) { model.newFolder() }
                add("New Text File", enabled: writable) { model.newTextFile() }
                add("Paste Items", enabled: writable) { model.paste() }
                add("Move Items Here", enabled: writable) { model.paste(move: true) }
                menu.addItem(.separator())
                add("Open in New Tab", enabled: model.canWriteHere) { [weak self] in
                    self?.parent.newTab(model.location)
                }
                add("Add Folder to Sidebar", enabled: model.canWriteHere) { [weak self] in
                    self?.parent.addFavorite(model.location)
                }
                menu.addItem(.separator())
                let views = NSMenu(); views.autoenablesItems = false
                for mode in FileViewMode.allCases {
                    let item = add(mode.title, to: views) { model.viewMode = mode }
                    item.state = model.viewMode == mode ? .on : .off
                }
                let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
                viewItem.submenu = views; menu.addItem(viewItem)
                let hidden = add("Show Hidden Files  ⌘H") { model.toggleHidden() }
                hidden.state = model.showHidden ? .on : .off
                add("Refresh", enabled: !model.busy) { model.schedule() }
                return menu
            }
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            guard let hit = hit(at: row) else { return menu }
            add("Open") { model.open(hit) }
            if !hit.isFolder {
                let applications = NSMenu(); applications.autoenablesItems = false
                for application in OpenWithApps.applications(for: hit) {
                    add(OpenWithApps.title(application, for: hit), to: applications) {
                        model.openWith(application, hit: hit)
                    }
                }
                applications.addItem(.separator())
                add("Other…", to: applications) { model.chooseApplication(for: hit) }
                let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                item.submenu = applications; menu.addItem(item)
            }
            add("Open in New Tab", enabled: hit.isFolder) { [weak self] in
                self?.parent.newTab(hit.url)
            }
            add("Quick Look") { model.preview = hit }
            add("Open Enclosing Folder") { model.navigate(hit.url.deletingLastPathComponent()) }
            menu.addItem(.separator())
            add("Get Info") { model.info() }
            add("Rename…", enabled: !model.busy) { model.renameItems() }
            add("Compress", enabled: !model.busy && model.canWriteHere) { model.compress() }
            add("Extract ZIP", enabled: !model.busy && hit.url.pathExtension.lowercased() == "zip")
            { model.extract() }
            add("Duplicate", enabled: !model.busy) { model.duplicate() }
            add("Copy") { model.copy() }
            add("Copy Path") { model.copyPath() }
            let tags = NSMenu(); tags.autoenablesItems = false
            for name in ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"] {
                let item = NSMenuItem(
                    title: name, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = actions.count; item.isEnabled = !model.busy;
                actions[item.tag] = { model.tag(name) }; tags.addItem(item)
            }
            let tagItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "");
            tagItem.submenu = tags; menu.addItem(tagItem)
            menu.addItem(.separator()); add("Move to Trash", enabled: !model.busy) { model.trash() }
            return menu
        }
        @objc private func runMenuAction(_ sender: NSMenuItem) { actions[sender.tag]?() }
    }
}

@MainActor final class BrowserTable: NSTableView {
    let marquee = MarqueeSelectionView()
    var menuProvider: ((Int) -> NSMenu?)?
    var dragExit: (() -> Void)?
    var focusHandler: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusHandler?() }
        return accepted
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragExit?(); super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragExit?(); super.draggingEnded(sender)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: point))
    }
}
/// Full-width date header drawn by the table's row view.
@MainActor final class FileSectionRowView: NSTableRowView {
    private let label: NSTextField
    init(title: String) {
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isEmphasized: Bool { get { false } set {} }
    override var isSelected: Bool { get { false } set {} }
}
@MainActor final class FileCell: NSTableCellView {
    var path = ""
    var iconTask: Task<Void, Never>?
    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        super.init(frame: .zero); self.identifier = identifier
        let text = RenameTextField(labelWithString: ""); text.font = .systemFont(ofSize: 12);
        text.lineBreakMode = .byTruncatingTail;
        text.translatesAutoresizingMaskIntoConstraints = false
        textField = text; addSubview(text)
        var leading: NSLayoutXAxisAnchor = leadingAnchor
        if withIcon {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false;
            icon.imageScaling = .scaleProportionallyUpOrDown
            imageView = icon; addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { iconTask?.cancel() }
}
