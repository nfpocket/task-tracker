import ServiceManagement
import SwiftUI
import TaskTrackerCore

struct ContentView: View {
    let store: TaskStore
    let panel: PanelState
    let outline: TaskOutlineController
    let menu: MenuPanel

    @Environment(\.undoManager) private var undoManager
    @State private var draft = ""
    @FocusState private var addFieldFocused: Bool
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if let problem = store.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            MenuSection(panel: menu)
            OutlineContainer(controller: outline)
            Divider()
            footer
        }
        .frame(width: 420, height: 620)
        .onAppear(perform: didOpen)
        .onChange(of: panel.openCount, didOpen)
        .onChange(of: outline.addFieldFocusRequests) { addFieldFocused = true }
        .onExitCommand { panel.close() }
    }

    private func didOpen() {
        store.undoManager = undoManager
        outline.prepareForOpen()
        menu.didOpen()
        addFieldFocused = true
    }

    // MARK: - Add

    private var addBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
            TextField(outline.addPlaceholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($addFieldFocused)
                .onSubmit(addDraft)
                .help("Return adds the task, ⌘Return starts a new line")
            ForEach(outline.pendingImages) { image in
                PendingImageChip(image: image) { outline.removePendingImage(image.id) }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func addDraft() {
        if outline.addFromField(draft) == nil {
            // Images need a task name to go with them.
            if !outline.pendingImages.isEmpty { NSSound.beep() }
            return
        }
        draft = ""
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(message ?? summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(AppDelegate.hotKeyLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Open Task Tracker from anywhere")
            Menu {
                Button("New Folder", action: outline.newFolder)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Copy List as Text", action: copyList)
                Button("Import from Clipboard", action: importClipboard)
                Divider()
                Toggle("Open at Login", isOn: openAtLogin)
                Button("Show Data File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                Divider()
                Button("Quit Task Tracker") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let inProgress = store.list.tasks(in: .inProgress).count
        let todo = store.list.tasks(in: .todo).count
        let doneToday = store.list.completedCount(onSameDayAs: .now)
        let tasks = "\(inProgress) in progress · \(todo) todo · \(doneToday) done today"
        let checks = menu.file.openChecks
        return checks == 0 ? tasks : "\(checks) to check · \(tasks)"
    }

    private func copyList() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ListText.format(store.list), forType: .string)
        flash("Copied the list to the clipboard")
    }

    private func importClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let count = store.importText(text)
        flash(count == 0 ? "Nothing to import on the clipboard" : "Imported \(count) tasks — ⌘Z to undo")
    }

    private func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if message == text { message = nil }
        }
    }

    private var openAtLogin: Binding<Bool> {
        Binding {
            SMAppService.mainApp.status == .enabled
        } set: { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                flash("Couldn't change login item: \(error.localizedDescription)")
            }
        }
    }
}

/// An image pasted into the add field, shown until the task is added. Click the × to drop it.
private struct PendingImageChip: View {
    let image: TaskOutlineController.PendingImage
    let remove: () -> Void

    var body: some View {
        Group {
            if let preview = image.preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove image")
        }
    }
}

private struct OutlineContainer: NSViewRepresentable {
    let controller: TaskOutlineController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
