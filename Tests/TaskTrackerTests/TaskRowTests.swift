import AppKit
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

@MainActor
struct TaskRowTests {
    @Test func onlyAddressesWithASchemeOrWwwBecomeLinks() {
        let title = "Check https://ui.nuxt.com/raw/docs/components/table.md (and README.md) or www.apple.com."
        #expect(TitleText.links(in: title).map(\.url.absoluteString) == [
            "https://ui.nuxt.com/raw/docs/components/table.md",
            "http://www.apple.com",
        ])
        let shown = TitleText.attributed(title, color: .labelColor, linkColor: .linkColor, underlineLinks: false)
        #expect(shown.string == "Check ui.nuxt.com/raw/docs/components/table.md (and README.md) or apple.com.")
    }

    @Test func longLinksAreShortenedInTheMiddle() {
        let url = URL(string: "https://github.com/acme/warehouse-inventory-and-shipping-tracker")!
        let short = TitleText.shortened(url)
        #expect(short.count == 42)
        #expect(short.hasPrefix("github.com/acme/"))
        #expect(short.hasSuffix("…ping-tracker"))
        #expect(TitleText.shortened(URL(string: "https://www.apple.com/")!) == "apple.com")
    }

    /// Every task row must be exactly as tall as its wrapped title (plus images), at the width
    /// the title really gets — otherwise rows get clipped or show gaps.
    @Test func rowHeightsFitTitlesLinksAndImages() throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "collapsedItems")
        let file = FileManager.default.temporaryDirectory.appending(path: "TaskRowTests-\(UUID().uuidString)/tasks.json")
        let store = TaskStore(fileURL: file)
        let folder = store.addFolder(to: .todo)
        let titles = [
            "short",
            "can we show the app-console-logs in the fleet UI? and a bit more so it wraps",
            "Fleet git viewer is broken https://github.com/acme/warehouse-inventory-and-shipping-tracker see there",
            #"lines like api-1  | {"ts":"2026-10-14T07:16:13.973Z","level":"info","tenant_id":"1","user_id":2}"#,
            "https://ui.nuxt.com/raw/docs/components/table.md",
            "Several lines\nsecond line\n\nafter an empty line with https://github.com/acme/app",
        ]
            // Lengths in ~3pt steps, so some title always sits right at a line break and any
            // error in the measured width shows up as a wrong line count.
            + stride(from: 60, through: 200, by: 1).map { "see " + String(repeating: "i", count: $0) }
        let loose = titles.compactMap { store.addTask($0) }
        let nested = titles.compactMap { store.addTask($0, to: .folder(folder)) }
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        for id in [loose[0], loose[2], nested[1]] {
            store.attachImages([.data(png, fileExtension: "png"), .data(png, fileExtension: "png")], to: id)
        }
        store.setStatus([loose[3]], to: .done)
        // A reminder puts a bell before the stamp, which leaves the title less room.
        store.setReminder(.now.addingTimeInterval(3 * 86400), for: Array(loose[6...]) + [nested[1], nested[4]])

        let controller = TaskOutlineController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 2000), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(controller.scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let outlineView = controller.outlineView
        var checked = 0
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskCell else { continue }
            cell.layoutSubtreeIfNeeded()
            let titleView = try #require(cell.subviews.compactMap { $0 as? TitleView }.first)
            let layoutManager = try #require(titleView.layoutManager)
            let container = try #require(titleView.textContainer)
            layoutManager.ensureLayout(for: container)
            let titleHeight = max(ceil(layoutManager.usedRect(for: container).height), TitleText.lineHeight)
            guard case .task(let id)? = (outlineView.item(atRow: row) as? OutlineNode)?.kind else { continue }
            let images = store.list.task(id)?.images.isEmpty == false ? ImageStrip.height : 0
            let expected = max(TaskCell.minimumHeight, titleHeight + 2 * TaskCell.verticalPadding + images)
            let actual = outlineView.rect(ofRow: row).height
            #expect(actual == expected, "row \(row): \(actual)pt tall, content needs \(expected)pt")
            checked += 1
        }
        #expect(checked == titles.count * 2)
    }
}
