import AppKit
import Carbon.HIToolbox
import SwiftUI
import TaskTrackerCore

/// Lets the SwiftUI content react to the popover opening and ask it to close.
@MainActor
@Observable
final class PanelState {
    private(set) var openCount = 0
    @ObservationIgnored var close: () -> Void = {}

    func didOpen() { openCount += 1 }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let hotKeyLabel = "⌃⌥T"

    private let store = TaskStore(fileURL: TaskStore.defaultFileURL)
    private let panel = PanelState()
    private let menu = MenuPanel()
    private lazy var outline = TaskOutlineController(store: store)
    private lazy var reminders = Reminders(store: store, center: Reminders.notificationCenter)
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps have no visible menu bar, but text fields still need the Edit menu's
        // key equivalents (⌘C, ⌘V, ⌘Z, …) to exist.
        NSApp.mainMenu = makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Task Tracker")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let content = NSHostingController(rootView: ContentView(store: store, panel: panel, outline: outline, menu: menu))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        panel.close = { [weak self] in self?.popover.performClose(nil) }
        outline.onCancel = panel.close
        reminders.showTask = { [weak self] id in self?.show(id) }
        reminders.start()
        menu.start()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.togglePopover()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            let key: CommandKey? = switch event.keyCode {
            case 36, 76: .lineBreak // Return, Enter
            default: event.charactersIgnoringModifiers == "v" ? .paste : nil
            }
            guard let key else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { self?.handle(key, inWindow: windowNumber) ?? false }
            return handled ? nil : event
        }
    }

    /// Shortcuts text fields would otherwise get wrong: ⌘V with an image (they'd drop it) and
    /// ⌘Return (they'd ignore it instead of starting a new line).
    private enum CommandKey {
        case paste, lineBreak
    }

    private func handle(_ key: CommandKey, inWindow windowNumber: Int) -> Bool {
        guard let window = popover.contentViewController?.view.window, window.windowNumber == windowNumber else { return false }
        return switch key {
        case .paste: outline.pasteImageIfNeeded(firstResponder: window.firstResponder)
        case .lineBreak: outline.insertLineBreakIfNeeded(firstResponder: window.firstResponder)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        panel.didOpen()
    }

    /// Opens the list with a task selected.
    private func show(_ taskID: UUID) {
        if popover.isShown {
            outline.select(taskID)
        } else {
            outline.selectOnOpen = taskID
            togglePopover()
        }
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Task Tracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
