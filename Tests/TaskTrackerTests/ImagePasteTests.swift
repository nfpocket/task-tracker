import AppKit
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

/// ⌘V with an image on the clipboard used to do nothing whenever a text field had focus —
/// while renaming a task, or while writing a new one in the add field — because the field
/// took the paste and dropped the image.
@MainActor
struct ImagePasteTests {
    let store: TaskStore
    let controller: TaskOutlineController
    let window: NSWindow
    let pasteboard = NSPasteboard(name: .init("ImagePasteTests-\(UUID().uuidString)"))

    init() {
        _ = NSApplication.shared
        store = TaskStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "ImagePasteTests-\(UUID().uuidString)/tasks.json"))
        controller = TaskOutlineController(store: store)
        controller.pasteboard = pasteboard
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        controller.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(controller.scrollView)
    }

    private func copyScreenshot(withText text: String? = nil) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pasteboard.clearContents()
        pasteboard.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
        pasteboard.setData(rep.tiffRepresentation!, forType: .tiff)
        if let text { pasteboard.setString(text, forType: .string) }
    }

    /// A text field being edited somewhere other than the list, like the add field.
    private func focusOtherTextField() -> NSResponder? {
        let field = NSTextField(string: "")
        window.contentView!.addSubview(field)
        window.makeFirstResponder(field)
        return window.firstResponder
    }

    @Test func pastingWhileRenamingATaskAttachesTheImageToIt() throws {
        let id = try #require(store.add("Fix the git viewer").first)
        controller.sync()
        controller.rename(id)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)

        copyScreenshot()
        #expect(controller.pasteImageIfNeeded(firstResponder: window.firstResponder))
        #expect(store.list.task(id)?.images.count == 1)
        #expect(window.firstResponder === editor, "still renaming")
    }

    @Test func pastingInTheAddFieldHoldsTheImageForTheNewTask() throws {
        copyScreenshot()
        #expect(controller.pasteImageIfNeeded(firstResponder: focusOtherTextField()))
        #expect(controller.pendingImages.count == 1)

        let id = controller.addFromField("Login button misaligned")
        #expect(store.list.task(try #require(id))?.images.count == 1)
        #expect(controller.pendingImages.isEmpty)
    }

    @Test func textOnTheClipboardStillPastesAsText() {
        // Some apps put a picture of copied text on the clipboard alongside the text.
        copyScreenshot(withText: "copied words")
        #expect(!controller.pasteImageIfNeeded(firstResponder: focusOtherTextField()))
        #expect(controller.pendingImages.isEmpty)
    }

    @Test func theListHandlesItsOwnPaste() throws {
        let id = try #require(store.add("task").first)
        controller.sync()
        copyScreenshot()
        window.makeFirstResponder(controller.outlineView)
        #expect(!controller.pasteImageIfNeeded(firstResponder: window.firstResponder))
        #expect(store.list.task(id)?.images.isEmpty == true)
    }
}
