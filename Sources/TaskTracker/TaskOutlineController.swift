import AppKit
import Observation
import TaskTrackerCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let taskItem = NSPasteboard.PasteboardType("local.tasktracker.item")
}

/// One row in the outline. A node lives as long as its section, folder or task does, so the
/// outline can follow it across moves and animate them.
final class OutlineNode: NSObject {
    enum Kind: Hashable {
        case section(TaskStatus)
        case folder(UUID)
        case task(UUID)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    var id: UUID? {
        switch kind {
        case .section: nil
        case .folder(let id), .task(let id): id
        }
    }

    var container: Container? {
        switch kind {
        case .section(let status): .section(status)
        case .folder(let id): .folder(id)
        case .task: nil
        }
    }

    /// What its collapsed state is remembered under. Tasks don't expand.
    var expansionKey: String? {
        switch kind {
        case .section(let status): "section.\(status.rawValue)"
        case .folder(let id): "folder.\(id.uuidString)"
        case .task: nil
        }
    }
}

/// Shows the store in an NSOutlineView: sections, folders and tasks with native drag and drop,
/// inline renaming, context menus and keyboard shortcuts.
@MainActor
@Observable
final class TaskOutlineController: NSObject {
    /// Where the add field puts new tasks: the selected folder, or Todo.
    private(set) var addTarget: Container = .section(.todo)
    /// Bumped when the add field should take focus.
    private(set) var addFieldFocusRequests = 0
    /// Images pasted into the add field, waiting for the task being written there.
    private(set) var pendingImages: [PendingImage] = []

    struct PendingImage: Identifiable {
        let id = UUID()
        let source: TaskStore.ImageSource
        let preview: NSImage?

        init(_ source: TaskStore.ImageSource) {
            self.source = source
            switch source {
            case .file(let url): preview = NSImage(contentsOf: url)
            case .data(let data, _): preview = NSImage(data: data)
            }
        }
    }

    @ObservationIgnored let store: TaskStore
    @ObservationIgnored let scrollView = NSScrollView()
    @ObservationIgnored let outlineView = TaskOutlineView()
    @ObservationIgnored var onCancel: () -> Void = {}
    /// A task to select the next time the popover opens, e.g. one whose reminder was clicked.
    @ObservationIgnored var selectOnOpen: UUID?
    /// Where copy and paste go. Tests swap in a private one.
    @ObservationIgnored var pasteboard = NSPasteboard.general

    private enum Parent: Hashable {
        case root
        case node(OutlineNode.Kind)
    }

    private struct TaskInfo {
        var task: TaskItem
        var status: TaskStatus
        var inFolder: Bool
    }

    @ObservationIgnored private var nodes: [OutlineNode.Kind: OutlineNode] = [:]
    /// What the outline currently shows. The data source reads from this, and `sync` walks it
    /// towards the store one animated step at a time.
    @ObservationIgnored private var shown: [Parent: [OutlineNode]] = [:]
    @ObservationIgnored private var parents: [OutlineNode.Kind: Parent] = [:]
    @ObservationIgnored private var taskInfo: [UUID: TaskInfo] = [:]
    @ObservationIgnored private var folderInfo: [UUID: (folder: Folder, status: TaskStatus)] = [:]
    @ObservationIgnored private var sectionCounts: [TaskStatus: Int] = [:]
    @ObservationIgnored private var rowHeights: [OutlineNode.Kind: CGFloat] = [:]
    @ObservationIgnored private var collapsed: Set<String>
    @ObservationIgnored private var restoringExpansion = false
    @ObservationIgnored private var draggedIDs: [UUID] = []
    @ObservationIgnored private var editing: (id: UUID, field: NSTextField, original: String)?

    private static let collapsedKey = "collapsedItems"

    init(store: TaskStore) {
        self.store = store
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        super.init()
        configureOutline()
        sync()
        observeStore()
    }

    var addPlaceholder: String {
        if !pendingImages.isEmpty { return "Name the task for this image" }
        return switch addTarget {
        case .section(let status): "Add to \(status.title)"
        case .folder(let id): "Add to \(store.list.folder(id)?.title ?? "folder")"
        }
    }

    /// Adds what was typed in the add field as one task, line breaks and all, with any images
    /// pasted there, and shows it.
    @discardableResult
    func addFromField(_ text: String) -> UUID? {
        guard let id = store.addTask(text, to: addTarget) else { return nil }
        if !pendingImages.isEmpty {
            store.attachImages(pendingImages.map(\.source), to: id)
            pendingImages = []
        }
        reveal(id)
        return id
    }

    /// ⌘Return in a text field: a line break, for tasks with several lines. Folder names stay
    /// on one line. Returns false to let the key go ahead as usual.
    func insertLineBreakIfNeeded(firstResponder: NSResponder?) -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        if let editing, folderInfo[editing.id] != nil { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    /// ⌘V with an image on the clipboard while a text field has focus — the field would only
    /// take text and drop the image. Renaming a task attaches it to that task; in the add field
    /// it's held for the new task. Returns false to let the paste go ahead as usual.
    func pasteImageIfNeeded(firstResponder: NSResponder?) -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor,
              Clipboard.prefersImage(pasteboard)
        else { return false }
        if let editing {
            guard taskInfo[editing.id] != nil else { return false }
            store.attachImages(Clipboard.images(pasteboard), to: editing.id)
        } else {
            pendingImages += Clipboard.images(pasteboard).map(PendingImage.init)
        }
        return true
    }

    /// Called whenever the popover opens.
    func prepareForOpen() {
        finishEditing()
        outlineView.deselectAll(nil)
        addTarget = .section(.todo)
        if let id = selectOnOpen {
            selectOnOpen = nil
            select(id)
        }
    }

    /// Scrolls to a task or folder, expanding whatever it's inside.
    func reveal(_ id: UUID) {
        sync()
        guard let node = nodes[.task(id)] ?? nodes[.folder(id)] else { return }
        var ancestors: [OutlineNode] = []
        var parent = parents[node.kind]
        while case .node(let kind)? = parent, let ancestor = nodes[kind] {
            ancestors.insert(ancestor, at: 0)
            parent = parents[kind]
        }
        for ancestor in ancestors where !outlineView.isItemExpanded(ancestor) {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }

    /// Shows a task or folder and selects it.
    func select(_ id: UUID) {
        reveal(id)
        guard let node = nodes[.task(id)] ?? nodes[.folder(id)] else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
    }

    /// Makes a folder from the selected tasks, or an empty one, and starts renaming it.
    func newFolder() {
        let ids = selectedIDs()
        if let folder = store.groupIntoNewFolder(ids) {
            rename(folder)
        } else {
            let status = ids.first.flatMap { store.list.status(of: $0) } ?? .todo
            rename(store.addFolder(to: status, at: 0))
        }
    }

    // MARK: - Setup

    private func configureOutline() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .inset
        outlineView.rowSizeStyle = .custom
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 14
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        outlineView.copyHandler = { [weak self] in
            guard let self else { return }
            copy(selectedIDs())
        }
        outlineView.pasteHandler = { [weak self] in self?.paste() }
        outlineView.canPaste = { [weak self] in self?.canPaste() ?? false }

        outlineView.registerForDraggedTypes([.taskItem, .string, .fileURL, .URL, .png, .tiff])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .regular

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        outlineView.widthDidChange = { [weak self] in
            // Let the column follow the new width first.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.updateRowHeights(force: true) }
            }
        }
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.list
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observeStore()
            }
        }
    }

    // MARK: - Keeping the outline in step with the store

    /// Brings the outline up to date with the store, animating moves, insertions and removals.
    func sync() {
        let list = store.list
        index(list)

        var desired: [Parent: [OutlineNode]] = [.root: TaskStatus.allCases.map { node(.section($0)) }]
        var order: [Parent] = [.root]
        var folderParents: [Parent] = []
        for section in list.sections {
            var children: [OutlineNode] = []
            for entry in section.entries {
                switch entry {
                case .task(let task):
                    children.append(node(.task(task.id)))
                case .folder(let folder):
                    children.append(node(.folder(folder.id)))
                    desired[.node(.folder(folder.id))] = folder.tasks.map { node(.task($0.id)) }
                    folderParents.append(.node(.folder(folder.id)))
                }
            }
            desired[.node(.section(section.status))] = children
            order.append(.node(.section(section.status)))
        }
        order += folderParents

        if shown.isEmpty {
            shown = desired
            for (parent, children) in desired {
                for child in children { parents[child.kind] = parent }
            }
            outlineView.reloadData()
            restoreExpansion(under: .root)
        } else if desired != shown {
            apply(desired, order: order)
            restoreExpansion(under: .root)
        }
        nodes = nodes.filter { parents[$0.key] != nil }
        if case .folder(let id) = addTarget, folderInfo[id] == nil { addTarget = .section(.todo) }
        refreshVisibleRows()
        updateRowHeights(force: false)
    }

    /// Places each parent's children in order, moving rows that exist and inserting new ones;
    /// whatever is left over afterwards was deleted.
    private func apply(_ desired: [Parent: [OutlineNode]], order: [Parent]) {
        outlineView.beginUpdates()
        for parent in order {
            for (index, node) in (desired[parent] ?? []).enumerated() {
                let current = shown[parent] ?? []
                if index < current.count, current[index] === node { continue }
                if let from = parents[node.kind], let fromIndex = shown[from]?.firstIndex(of: node) {
                    shown[from]?.remove(at: fromIndex)
                    shown[parent, default: []].insert(node, at: index)
                    parents[node.kind] = parent
                    outlineView.moveItem(at: fromIndex, inParent: item(for: from), to: index, inParent: item(for: parent))
                } else {
                    shown[parent, default: []].insert(node, at: index)
                    parents[node.kind] = parent
                    if case .folder = node.kind { shown[.node(node.kind)] = [] }
                    outlineView.insertItems(at: [index], inParent: item(for: parent), withAnimation: .effectFade)
                }
            }
        }
        for parent in order {
            let keep = desired[parent]?.count ?? 0
            while let count = shown[parent]?.count, count > keep {
                if let removed = shown[parent]?.removeLast() { forget(removed) }
                outlineView.removeItems(at: [count - 1], inParent: item(for: parent), withAnimation: .effectFade)
            }
        }
        outlineView.endUpdates()
    }

    private func forget(_ node: OutlineNode) {
        parents[node.kind] = nil
        rowHeights[node.kind] = nil
        for child in shown.removeValue(forKey: .node(node.kind)) ?? [] { forget(child) }
    }

    private func node(_ kind: OutlineNode.Kind) -> OutlineNode {
        if let node = nodes[kind] { return node }
        let node = OutlineNode(kind)
        nodes[kind] = node
        return node
    }

    private func item(for parent: Parent) -> OutlineNode? {
        switch parent {
        case .root: nil
        case .node(let kind): nodes[kind]
        }
    }

    private func index(_ list: TaskList) {
        taskInfo = [:]
        folderInfo = [:]
        sectionCounts = [:]
        for section in list.sections {
            for entry in section.entries {
                switch entry {
                case .task(let task):
                    taskInfo[task.id] = TaskInfo(task: task, status: section.status, inFolder: false)
                case .folder(let folder):
                    folderInfo[folder.id] = (folder, section.status)
                    for task in folder.tasks {
                        taskInfo[task.id] = TaskInfo(task: task, status: section.status, inFolder: true)
                    }
                }
            }
            sectionCounts[section.status] = list.tasks(in: section.status).count
        }
    }

    private func refreshVisibleRows() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outlineView.item(atRow: row) as? OutlineNode,
                  let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            else { continue }
            configure(view, for: node)
        }
    }

    /// Tells the outline about rows whose height changed, e.g. after a rename or a move into a folder.
    private func updateRowHeights(force: Bool) {
        var changed = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? OutlineNode else { continue }
            if force || rowHeights[node.kind] != height(for: node) { changed.insert(row) }
        }
        if !changed.isEmpty { outlineView.noteHeightOfRows(withIndexesChanged: changed) }
    }

    private func height(for node: OutlineNode) -> CGFloat {
        switch node.kind {
        case .section(let status):
            return status == TaskStatus.allCases.first ? 26 : 36
        case .folder:
            return 26
        case .task(let id):
            guard let info = taskInfo[id] else { return TaskCell.minimumHeight }
            // While renaming, fit what's being typed, shown as plain text.
            let renaming = editing?.id == id ? editing?.field.stringValue : nil
            return TaskCell.height(
                title: renaming ?? info.task.title,
                showsLinks: renaming == nil,
                stamp: Stamp.short(info.task, in: info.status),
                hasReminder: info.task.reminder != nil,
                hasImages: !info.task.images.isEmpty,
                cellWidth: cellWidth(level: info.inFolder ? 2 : 1)
            )
        }
    }

    /// Width of a row's content at an outline level. Row 0 is always the first section, at level 0.
    private func cellWidth(level: Int) -> CGFloat {
        guard outlineView.numberOfRows > 0 else { return 300 }
        let base = outlineView.frameOfCell(atColumn: 0, row: 0).width
        return base - CGFloat(level) * outlineView.indentationPerLevel
    }

    // MARK: - Expansion

    private func restoreExpansion(under parent: Parent) {
        restoringExpansion = true
        defer { restoringExpansion = false }
        applyExpansion(under: parent)
    }

    private func applyExpansion(under parent: Parent) {
        for node in shown[parent] ?? [] {
            guard let key = node.expansionKey else { continue }
            if collapsed.contains(key) {
                if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
            } else {
                if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                applyExpansion(under: .node(node.kind))
            }
        }
    }

    private func toggleExpansion(_ node: OutlineNode) {
        if outlineView.isItemExpanded(node) {
            outlineView.animator().collapseItem(node)
        } else {
            outlineView.animator().expandItem(node)
        }
    }

    private func rememberExpansion(_ node: OutlineNode, expanded: Bool) {
        guard !restoringExpansion, let key = node.expansionKey else { return }
        if expanded { collapsed.remove(key) } else { collapsed.insert(key) }
        // Forget folders that no longer exist.
        collapsed = collapsed.filter { key in
            guard key.hasPrefix("folder."), let id = UUID(uuidString: String(key.dropFirst(7))) else { return true }
            return folderInfo[id] != nil
        }
        UserDefaults.standard.set(collapsed.sorted(), forKey: Self.collapsedKey)
    }

    // MARK: - Selection and actions

    private func selectedIDs() -> [UUID] {
        outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? OutlineNode)?.id }
    }

    /// What a context menu acts on: the selection if the clicked row is part of it, else the clicked row.
    private func clickedIDs() -> [UUID] {
        let row = outlineView.clickedRow
        if outlineView.selectedRowIndexes.contains(row) { return selectedIDs() }
        return (outlineView.item(atRow: row) as? OutlineNode)?.id.map { [$0] } ?? []
    }

    private func status(of id: UUID) -> TaskStatus? {
        taskInfo[id]?.status ?? folderInfo[id]?.status
    }

    @objc private func toggleTask(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let id = (outlineView.item(atRow: row) as? OutlineNode)?.id else { return }
        toggleDone([id])
    }

    private func toggleDone(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let allDone = ids.allSatisfy { status(of: $0) == .done }
        store.setStatus(ids, to: allDone ? .todo : .done)
    }

    private func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let row = outlineView.selectedRowIndexes.first
        store.delete(ids)
        sync()
        // Keep the keyboard in the list: select whatever moved into the deleted row's place.
        if let row, row < outlineView.numberOfRows, (outlineView.item(atRow: row) as? OutlineNode)?.id != nil {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private func focusAddField(on target: Container) {
        addTarget = target
        addFieldFocusRequests += 1
    }

    private func copy(_ ids: [UUID]) {
        let titles = ids.compactMap { taskInfo[$0]?.task.title ?? folderInfo[$0]?.folder.title }
        pasteboard.clearContents()
        pasteboard.setString(titles.joined(separator: "\n"), forType: .string)
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode,
              case .section = node.kind
        else { return }
        // Clicking the disclosure triangle already toggles it.
        if let event = NSApp.currentEvent {
            let point = outlineView.convert(event.locationInWindow, from: nil)
            if outlineView.frameOfOutlineCell(atRow: row).contains(point) { return }
        }
        toggleExpansion(node)
    }

    @objc private func rowDoubleClicked() {
        guard let id = (outlineView.item(atRow: outlineView.clickedRow) as? OutlineNode)?.id else { return }
        rename(id)
    }

    // MARK: - Pasting and images

    /// ⌘V in the list. With one task selected, an image is attached and a link is added to it;
    /// text becomes new tasks after the selection, or inside a selected folder.
    private func paste() {
        let ids = selectedIDs()
        if ids.count == 1, taskInfo[ids[0]] != nil {
            if Clipboard.hasImages(pasteboard) {
                store.attachImages(Clipboard.images(pasteboard), to: ids[0])
                return
            }
            if let link = Clipboard.webLink(pasteboard) {
                store.appendLink(link, to: ids[0])
                return
            }
        }
        guard let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        var container = Container.section(.todo)
        var index: Int?
        if ids.count == 1, folderInfo[ids[0]] != nil {
            container = .folder(ids[0])
        } else if let last = ids.last, let parent = store.list.container(of: last),
                  let position = store.list.childIDs(of: parent).firstIndex(of: last) {
            container = parent
            index = position + 1
        }
        if let id = store.add(text, to: container, at: index).last { reveal(id) }
    }

    private func canPaste() -> Bool {
        if pasteboard.string(forType: .string) != nil { return true }
        let ids = selectedIDs()
        return ids.count == 1 && taskInfo[ids[0]] != nil
            && (Clipboard.hasImages(pasteboard) || Clipboard.webLink(pasteboard) != nil)
    }

    private func chooseImages(for taskID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to attach"
        guard panel.runModal() == .OK else { return }
        store.attachImages(panel.urls.map { .file($0) }, to: taskID)
    }

    // MARK: - Reminders

    private func reminderMenuItem(for ids: [UUID]) -> NSMenuItem {
        let submenu = NSMenu()
        let presets: [(String, TimeInterval)] = [
            ("In 15 Minutes", 15 * 60),
            ("In 30 Minutes", 30 * 60),
            ("In 1 Hour", 60 * 60),
            ("In 3 Hours", 3 * 60 * 60),
        ]
        for (title, interval) in presets {
            submenu.addItem(ActionMenuItem(title) { [weak self] in
                self?.store.setReminder(.now.addingTimeInterval(interval), for: ids)
            })
        }
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        submenu.addItem(ActionMenuItem("Tomorrow at \(morning.formatted(date: .omitted, time: .shortened))") { [weak self] in
            self?.store.setReminder(morning, for: ids)
        })
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Custom…") { [weak self] in self?.chooseReminder(for: ids) })
        if ids.contains(where: { taskInfo[$0]?.task.reminder != nil }) {
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem("Remove Reminder") { [weak self] in self?.store.setReminder(nil, for: ids) })
        }
        let item = NSMenuItem(title: "Remind Me", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func chooseReminder(for ids: [UUID]) {
        let tasks = ids.compactMap { taskInfo[$0]?.task }
        guard let first = tasks.first else { return }
        let subject = tasks.count == 1 ? first.title : "\(tasks.count) tasks"
        guard let date = ReminderPrompt.run(about: subject, current: tasks.count == 1 ? first.reminder : nil) else { return }
        store.setReminder(date, for: ids)
    }

    // MARK: - Renaming

    func rename(_ id: UUID) {
        finishEditing()
        reveal(id)
        guard let node = nodes[.task(id)] ?? nodes[.folder(id)] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField
        else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        (cell as? RenamableCell)?.setRenaming(true)
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        editing = (id, field, field.stringValue)
        outlineView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        guard let editing else { return }
        outlineView.window?.makeFirstResponder(outlineView)
        if self.editing != nil { endEditing(editing.field, commit: true) }
    }

    private func endEditing(_ field: NSTextField, commit: Bool) {
        guard let editing, editing.field === field else { return }
        self.editing = nil
        field.isEditable = false
        field.isSelectable = false
        (field.superview as? RenamableCell)?.setRenaming(false)
        if commit { store.rename(editing.id, to: field.stringValue) }
        // Show the saved title: a blank one isn't saved, and a cancelled edit keeps the old one.
        field.stringValue = store.list.task(editing.id)?.title
            ?? store.list.folder(editing.id)?.title
            ?? editing.original
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let ids = selectedIDs()

        switch (event.keyCode, flags) {
        case (36, []), (76, []): // Return, Enter
            guard ids.count == 1 else { return false }
            rename(ids[0])
        case (51, []), (51, .command), (117, []): // Delete, ⌘Delete, Forward Delete
            delete(ids)
        case (49, []): // Space
            toggleDone(ids)
        case (53, []): // Escape
            onCancel()
        default:
            if flags == .command, let digit = Int(key), (1...TaskStatus.allCases.count).contains(digit) {
                store.setStatus(ids, to: TaskStatus.allCases[digit - 1])
            } else if flags == [.command, .shift], key == "n" {
                newFolder()
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Data source

extension TaskOutlineController: NSOutlineViewDataSource {
    private func parent(of item: Any?) -> Parent {
        (item as? OutlineNode).map { .node($0.kind) } ?? .root
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        shown[parent(of: item)]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        shown[parent(of: item)]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? OutlineNode)?.expansionKey != nil
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? OutlineNode, let id = node.id else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.uuidString, forType: .taskItem)
        // Dragged into another app, a task is just its text.
        pasteboardItem.setString(taskInfo[id]?.task.title ?? folderInfo[id]?.folder.title ?? "", forType: .string)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        finishEditing()
        draggedIDs = draggedItems.compactMap { ($0 as? OutlineNode)?.id }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedIDs = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let proposed = item as? OutlineNode
        if isLocal(info) {
            let movingFolder = draggedIDs.contains { folderInfo[$0] != nil }
            guard let (target, childIndex) = dropTarget(proposed, index, info, movingFolder: movingFolder) else { return [] }
            retarget(to: target, childIndex, from: proposed, index)
            return .move
        }
        let pasteboard = info.draggingPasteboard
        // Images and links attach to the task under the pointer.
        let images = Clipboard.hasImages(pasteboard)
        if images || Clipboard.webLink(pasteboard) != nil, let task = taskUnderPointer(info) {
            retarget(to: task, NSOutlineViewDropOnItemIndex, from: proposed, index)
            return .copy
        }
        // Any other text becomes new tasks.
        guard !images, pasteboard.string(forType: .string)?.isEmpty == false,
              let (target, childIndex) = dropTarget(proposed, index, info, movingFolder: false)
        else { return [] }
        retarget(to: target, childIndex, from: proposed, index)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? OutlineNode else { return false }
        let pasteboard = info.draggingPasteboard
        // Dropped onto a section or folder: put it at the top.
        let position = index == NSOutlineViewDropOnItemIndex ? 0 : index
        if isLocal(info), let container = node.container {
            store.move(draggedIDs, to: container, at: position)
        } else if case .task(let taskID) = node.kind {
            if Clipboard.hasImages(pasteboard) {
                guard store.attachImages(Clipboard.images(pasteboard), to: taskID) > 0 else { return false }
            } else if let link = Clipboard.webLink(pasteboard) {
                store.appendLink(link, to: taskID)
            } else {
                return false
            }
        } else if let container = node.container, let text = pasteboard.string(forType: .string) {
            guard !store.add(text, to: container, at: position).isEmpty else { return false }
        } else {
            return false
        }
        sync()
        return true
    }

    private func retarget(to target: OutlineNode, _ childIndex: Int, from proposed: OutlineNode?, _ index: Int) {
        if target !== proposed || childIndex != index {
            outlineView.setDropItem(target, dropChildIndex: childIndex)
        }
    }

    private func taskUnderPointer(_ info: any NSDraggingInfo) -> OutlineNode? {
        let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
        guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode, case .task = node.kind else { return nil }
        return node
    }

    private func isLocal(_ info: any NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) === outlineView && !draggedIDs.isEmpty
    }

    /// Where a drop really goes. Dropping onto a task means beside it, and folders only go
    /// directly into sections.
    private func dropTarget(_ node: OutlineNode?, _ index: Int, _ info: any NSDraggingInfo, movingFolder: Bool) -> (OutlineNode, Int)? {
        guard let node else {
            // Between two sections: the end of the one above.
            let sections = shown[.root] ?? []
            guard index > 0, let above = sections[safe: min(index, sections.count) - 1] else {
                return sections.first.map { ($0, 0) }
            }
            return outlineView.isItemExpanded(above)
                ? (above, shown[.node(above.kind)]?.count ?? 0)
                : (above, NSOutlineViewDropOnItemIndex)
        }
        switch node.kind {
        case .section:
            return (node, index)
        case .folder:
            guard movingFolder else { return (node, index) }
            return besideFolder(node, after: index != NSOutlineViewDropOnItemIndex || isLowerHalf(node, info))
        case .task:
            guard let parent = parents[node.kind], let parentNode = item(for: parent),
                  let position = shown[parent]?.firstIndex(of: node)
            else { return nil }
            if movingFolder, case .folder = parentNode.kind {
                return besideFolder(parentNode, after: true)
            }
            return (parentNode, position + (isLowerHalf(node, info) ? 1 : 0))
        }
    }

    private func besideFolder(_ folder: OutlineNode, after: Bool) -> (OutlineNode, Int)? {
        guard let parent = parents[folder.kind], let section = item(for: parent),
              let position = shown[parent]?.firstIndex(of: folder)
        else { return nil }
        return (section, position + (after ? 1 : 0))
    }

    private func isLowerHalf(_ node: OutlineNode, _ info: any NSDraggingInfo) -> Bool {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        return point.y > outlineView.rect(ofRow: row).midY
    }
}

// MARK: - Delegate

extension TaskOutlineController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OutlineNode else { return nil }
        let view: NSView
        switch node.kind {
        case .section:
            view = outlineView.makeView(withIdentifier: SectionCell.identifier, owner: nil) ?? SectionCell()
        case .folder:
            view = outlineView.makeView(withIdentifier: FolderCell.identifier, owner: nil) ?? FolderCell()
        case .task:
            view = outlineView.makeView(withIdentifier: TaskCell.identifier, owner: nil) ?? TaskCell()
        }
        configure(view, for: node)
        return view
    }

    private func configure(_ view: NSView, for node: OutlineNode) {
        switch node.kind {
        case .section(let status):
            (view as? SectionCell)?.configure(status: status, count: sectionCounts[status] ?? 0)
        case .folder(let id):
            guard let info = folderInfo[id] else { return }
            (view as? FolderCell)?.configure(folder: info.folder)
        case .task(let id):
            guard let info = taskInfo[id] else { return }
            (view as? TaskCell)?.configure(
                task: info.task,
                status: info.status,
                imageURL: store.imageURL,
                onToggle: (self, #selector(toggleTask(_:))),
                onRemoveImage: { [weak self] imageID in self?.store.removeImage(imageID, from: id) }
            )
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? OutlineNode else { return TaskCell.minimumHeight }
        let height = height(for: node)
        rowHeights[node.kind] = height
        return height
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? OutlineNode)?.id != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? OutlineNode }
        if selected.count == 1, case .folder(let id) = selected[0].kind {
            addTarget = .folder(id)
        } else {
            addTarget = .section(.todo)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
        rememberExpansion(node, expanded: true)
        restoreExpansion(under: .node(node.kind))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
        rememberExpansion(node, expanded: false)
    }
}

// MARK: - Renaming

extension TaskOutlineController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // Let the row grow or shrink with the lines being typed.
        guard let field = notification.object as? NSTextField, field === editing?.field else { return }
        updateRowHeights(force: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        endEditing(field, commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            field.abortEditing()
            endEditing(field, commit: false)
            outlineView.window?.makeFirstResponder(outlineView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            outlineView.window?.makeFirstResponder(outlineView)
            return true
        default:
            return false
        }
    }
}

// MARK: - Context menu

extension TaskOutlineController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? OutlineNode else { return }

        if case .section(let status) = node.kind {
            menu.addItem(ActionMenuItem("Add Task Here") { [weak self] in self?.focusAddField(on: .section(status)) })
            menu.addItem(ActionMenuItem("New Folder") { [weak self] in
                guard let self else { return }
                rename(store.addFolder(to: status, at: 0))
            })
            return
        }

        let ids = clickedIDs()
        let statuses = Set(ids.compactMap(status(of:)))
        for (offset, status) in TaskStatus.allCases.enumerated() where statuses != [status] {
            menu.addItem(ActionMenuItem("Move to \(status.title)", key: "\(offset + 1)") { [weak self] in
                self?.store.setStatus(ids, to: status)
            })
        }
        menu.addItem(.separator())
        if ids.count == 1 {
            menu.addItem(ActionMenuItem("Rename", key: "\r", modifiers: []) { [weak self] in self?.rename(ids[0]) })
        }
        let remindable = ids.filter { taskInfo[$0].map { $0.status != .done } ?? false }
        if !remindable.isEmpty {
            menu.addItem(reminderMenuItem(for: remindable))
        }
        if ids.count == 1, taskInfo[ids[0]] != nil {
            let taskID = ids[0]
            menu.addItem(ActionMenuItem("Add Image…") { [weak self] in self?.chooseImages(for: taskID) })
            if Clipboard.hasImages(pasteboard) {
                menu.addItem(ActionMenuItem("Paste Image") { [weak self] in
                    guard let self else { return }
                    store.attachImages(Clipboard.images(pasteboard), to: taskID)
                })
            } else if let link = Clipboard.webLink(pasteboard) {
                menu.addItem(ActionMenuItem("Paste Link") { [weak self] in self?.store.appendLink(link, to: taskID) })
            }
        }
        if case .folder(let folderID) = node.kind, ids == [folderID] {
            menu.addItem(ActionMenuItem("Add Task Here") { [weak self] in self?.focusAddField(on: .folder(folderID)) })
            menu.addItem(ActionMenuItem("Ungroup") { [weak self] in self?.store.ungroup(folderID) })
        }
        if ids.contains(where: { taskInfo[$0] != nil }) {
            menu.addItem(ActionMenuItem("New Folder with Selection", key: "n", modifiers: [.command, .shift]) { [weak self] in
                guard let self, let folder = store.groupIntoNewFolder(ids) else { return }
                rename(folder)
            })
        }
        menu.addItem(ActionMenuItem("Copy") { [weak self] in self?.copy(ids) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(ids.count > 1 ? "Delete \(ids.count) Items" : "Delete", key: "\u{8}", modifiers: []) { [weak self] in
            self?.delete(ids)
        })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
