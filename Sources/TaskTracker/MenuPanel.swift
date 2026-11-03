import AppKit
import Foundation
import Observation
import TaskTrackerCore

/// The menu as the popover shows it: the file, kept current while agents write to it, plus what
/// you have selected and are typing. Anything that talks to GitHub or Ghostty runs off the main thread.
@MainActor
@Observable
final class MenuPanel {
    private(set) var file = MenuFile()
    /// The item whose details are open.
    var selectedID: String?
    /// The item you're writing a problem for.
    var reportingID: String?
    var draft = ""
    /// Items and PRs with a GitHub or Ghostty call running.
    private(set) var busy: Set<String> = []
    private(set) var message: String?
    private(set) var messageIsError = false
    /// PRs you opened or closed by hand, by `MenuPR.id`. The others follow `isExpanded`'s default.
    private(set) var expandedByHand: [String: Bool] {
        didSet { UserDefaults.standard.set(expandedByHand, forKey: Self.expandedKey) }
    }

    @ObservationIgnored let actions: MenuActions
    /// The popover's: ⌘Z takes back a status change or a delete.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(actions: MenuActions = MenuActions()) {
        self.actions = actions
        self.expandedByHand = UserDefaults.standard.dictionary(forKey: Self.expandedKey) as? [String: Bool] ?? [:]
    }

    private static let expandedKey = "menuExpandedPRs"

    /// PRs with something left to do first, newest first; then the ones you're done with.
    var groups: [(pr: MenuPR, items: [MenuItem])] {
        let all = file.visibleGroups()
        return all.filter { Self.hasWork($0.items) } + all.filter { !Self.hasWork($0.items) }
    }

    static func hasWork(_ items: [MenuItem]) -> Bool {
        items.contains { !$0.status.isSettled }
    }

    var openCount: Int { file.openChecks + file.openIdeas }
    var problemsWaiting: Int { file.items.filter { $0.status == .problem }.count }

    // MARK: - Opening and closing PRs

    /// Unless you opened or closed it yourself, only the newest PR with work left is open, so a
    /// long menu reads as one line per PR. A PR also stays open while an item in it is selected.
    func isExpanded(_ pr: MenuPR, items: [MenuItem]) -> Bool {
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return true }
        if let byHand = expandedByHand[pr.id] { return byHand }
        return groups.first(where: { Self.hasWork($0.items) })?.pr.id == pr.id
    }

    func setExpanded(_ pr: MenuPR, items: [MenuItem], _ expanded: Bool) {
        expandedByHand[pr.id] = expanded
        if !expanded, let selectedID, items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            reportingID = nil
        }
        // Forget PRs that left the menu.
        let shown = Set(file.prs.map(\.id))
        expandedByHand = expandedByHand.filter { shown.contains($0.key) }
    }

    /// Loads the file and reloads it whenever something in its folder changes.
    func start() {
        reload()
        let directory = actions.store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    func reload() {
        guard let latest = try? actions.store.read(), latest != file else { return }
        file = latest
        if let selectedID, latest.item(selectedID) == nil { self.selectedID = nil }
    }

    /// When the popover opens: reload, and ask GitHub in the background whether the PRs are still open.
    func didOpen() {
        reload()
        let actions = actions
        Task.detached {
            try? actions.refresh(maxAge: 300)
            await MainActor.run { [weak self] in self?.reload() }
        }
    }

    // MARK: - Selecting

    func toggle(_ item: MenuItem) {
        if selectedID == item.id {
            selectedID = nil
        } else {
            selectedID = item.id
        }
        if reportingID != selectedID { reportingID = nil }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // MARK: - Deciding

    /// Works, Later, Dismiss, back to open. Local, so it happens at once and ⌘Z takes it back.
    func setStatus(_ item: MenuItem, _ status: MenuItemStatus) {
        if selectedID == item.id {
            selectedID = nil
            reportingID = nil
        }
        apply(status, to: item.id)
    }

    private func apply(_ status: MenuItemStatus, to id: String) {
        guard let before = file.item(id)?.status, before != status else { return }
        do {
            try actions.setStatus(id, to: status)
        } catch {
            return flash(error.localizedDescription, isError: true)
        }
        reload()
        registerUndo(Self.actionName(status)) { $0.apply(before, to: id) }
    }

    /// Takes items off the menu for good. ⌘Z puts them back.
    func delete(_ items: [MenuItem]) {
        let ids = items.map(\.id)
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = nil
            reportingID = nil
        }
        do {
            let removal = try actions.delete(ids)
            reload()
            registerUndo(ids.count == 1 ? "Delete" : "Delete \(ids.count) Items") { $0.restore(removal) }
            flash(ids.count == 1 ? "Deleted · ⌘Z to undo" : "Deleted \(ids.count) items · ⌘Z to undo", isError: false)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func restore(_ removal: MenuRemoval) {
        do {
            try actions.restore(removal)
            reload()
            registerUndo(removal.items.count == 1 ? "Delete" : "Delete \(removal.items.count) Items") { panel in
                panel.delete(removal.items)
            }
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func registerUndo(_ name: String, _ body: @escaping @MainActor (MenuPanel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { panel in
            MainActor.assumeIsolated { body(panel) }
        }
        undoManager.setActionName(name)
    }

    private static func actionName(_ status: MenuItemStatus) -> String {
        switch status {
        case .works: "Works"
        case .later: "Later"
        case .dismissed: "Dismiss"
        case .open: "Back to Open"
        default: "Change"
        }
    }

    func beginProblem(_ item: MenuItem) {
        selectedID = item.id
        reportingID = item.id
        draft = ""
    }

    func cancelProblem() {
        reportingID = nil
    }

    func sendProblem(_ item: MenuItem) {
        let text = draft
        run(item.id) { actions in
            try actions.reportProblem(item.id, text).message
        } onSuccess: { [weak self] in
            self?.reportingID = nil
            self?.selectedID = nil
            self?.draft = ""
        }
    }

    func makeIssue(_ item: MenuItem) {
        run(item.id) { actions in
            try actions.makeIssue(item.id).message
        } onSuccess: { [weak self] in
            self?.selectedID = nil
        }
    }

    func fix(_ pr: MenuPR) {
        run(pr.id) { actions in
            try actions.fix(pr).message
        }
    }

    func open(_ item: MenuItem) {
        guard let url = item.openURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openLink(_ item: MenuItem) {
        guard let link = item.link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Running

    private func run(
        _ key: String,
        _ work: @escaping @Sendable (MenuActions) throws -> String?,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        let actions = actions
        Task.detached {
            let result = Result { try work(actions) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                busy.remove(key)
                reload()
                switch result {
                case .success(let text):
                    onSuccess?()
                    if let text { flash(text, isError: false) }
                case .failure(let error):
                    flash(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func flash(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 10 : 5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
