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
    var collapsed: Bool {
        didSet { UserDefaults.standard.set(collapsed, forKey: "menuCollapsed") }
    }

    @ObservationIgnored let actions: MenuActions
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(actions: MenuActions = MenuActions()) {
        self.actions = actions
        self.collapsed = UserDefaults.standard.bool(forKey: "menuCollapsed")
    }

    var groups: [(pr: MenuPR, items: [MenuItem])] { file.visibleGroups() }

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

    func setStatus(_ item: MenuItem, _ status: MenuItemStatus) {
        run(item.id) { actions in
            try actions.setStatus(item.id, to: status)
            return nil
        }
        selectedID = nil
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
