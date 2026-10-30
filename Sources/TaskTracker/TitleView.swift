import AppKit

extension NSAttributedString.Key {
    static let taskLink = NSAttributedString.Key("TaskTrackerLink")
}

/// A task title as shown in a row: web addresses become shortened, clickable links.
@MainActor
enum TitleText {
    static let font = NSFont.systemFont(ofSize: 13)

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Web addresses in a title. Only ones written with http(s):// or www. count, so file
    /// names like "table.md" stay plain text.
    static func links(in title: String) -> [(range: Range<String.Index>, url: URL)] {
        let matches = detector.matches(in: title, range: NSRange(title.startIndex..., in: title))
        return matches.compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: title) else { return nil }
            let text = title[range].lowercased()
            guard text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.") else { return nil }
            return (range, url)
        }
    }

    static func attributed(_ title: String, color: NSColor, linkColor: NSColor, underlineLinks: Bool) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var link = plain
        link[.foregroundColor] = linkColor
        if underlineLinks { link[.underlineStyle] = NSUnderlineStyle.single.rawValue }

        let result = NSMutableAttributedString()
        var rest = title.startIndex
        for found in links(in: title) {
            result.append(NSAttributedString(string: String(title[rest..<found.range.lowerBound]), attributes: plain))
            link[.taskLink] = found.url
            result.append(NSAttributedString(string: shortened(found.url), attributes: link))
            rest = found.range.upperBound
        }
        result.append(NSAttributedString(string: String(title[rest...]), attributes: plain))
        return result
    }

    /// "https://www.github.com/org/a-very-long-repository-name" → "github.com/org/a-very-lon…ository-name"
    static func shortened(_ url: URL, limit: Int = 42) -> String {
        var text = url.absoluteString
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        guard text.count > limit else { return text }
        return text.prefix(limit - 13) + "…" + text.suffix(12)
    }

    /// The height `text` needs at `width`, laid out exactly as `TitleView` lays it out.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        sizer.container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        sizer.storage.setAttributedString(text)
        sizer.layoutManager.ensureLayout(for: sizer.container)
        return ceil(sizer.layoutManager.usedRect(for: sizer.container).height)
    }

    /// Where the first line's baseline sits below the top of the text.
    static let baselineOffset = NSLayoutManager().defaultBaselineOffset(for: font)
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

    private static let sizer: (storage: NSTextStorage, layoutManager: NSLayoutManager, container: NSTextContainer) = {
        let (storage, layoutManager, container) = makeTextSystem()
        return (storage, layoutManager, container)
    }()

    static func makeTextSystem() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        return (storage, layoutManager, container)
    }
}

/// Shows a task title. Links can be clicked (or dragged out); every other click passes through
/// to the row underneath, so selecting and dragging rows works as usual.
final class TitleView: NSTextView {
    /// The text storage owns the layout manager and container; nothing else keeps it alive.
    private var storage: NSTextStorage?

    init() {
        let (storage, _, container) = TitleText.makeTextSystem()
        container.widthTracksTextView = true
        super.init(frame: .zero, textContainer: container)
        self.storage = storage
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func show(_ text: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        updateLinkAreas()
    }

    override var acceptsFirstResponder: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLinkAreas()
    }

    // MARK: Links

    private func linkRects() -> [(rect: NSRect, url: URL)] {
        guard let layoutManager, let textContainer, let storage = textStorage else { return [] }
        var result: [(NSRect, URL)] = []
        storage.enumerateAttribute(.taskLink, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                result.append((rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), url))
            }
        }
        return result
    }

    func link(at point: NSPoint) -> URL? {
        linkRects().first { $0.rect.contains(point) }?.url
    }

    private func updateLinkAreas() {
        removeAllToolTips()
        for (rect, url) in linkRects() {
            addToolTip(rect, owner: url.absoluteString as NSString, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for (rect, _) in linkRects() { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return link(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let url = link(at: start) else { return }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if link(at: point) == url { NSWorkspace.shared.open(url) }
                return
            }
            if hypot(point.x - start.x, point.y - start.y) > 4 {
                drag(url, event: event, from: start)
                return
            }
        }
    }

    private func drag(_ url: URL, event: NSEvent, from point: NSPoint) {
        guard let rect = linkRects().first(where: { $0.url == url && $0.rect.contains(point) })?.rect,
              let snapshot = bitmapImageRepForCachingDisplay(in: rect)
        else { return }
        cacheDisplay(in: rect, to: snapshot)
        let image = NSImage(size: rect.size)
        image.addRepresentation(snapshot)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(rect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        // Let the list show its own menu for this row.
        nextResponder?.rightMouseDown(with: event)
    }
}
