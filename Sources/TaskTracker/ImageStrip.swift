import AppKit
import ImageIO
import TaskTrackerCore
import UniformTypeIdentifiers

/// A row of image thumbnails under a task's title. Thumbnails that don't fit collapse into
/// a "+N" on the last one that does.
final class ImageStrip: NSView {
    static let thumbnailSize = NSSize(width: 58, height: 44)
    static let spacing: CGFloat = 6
    /// Space the strip adds below the title when a task has images.
    static let height = thumbnailSize.height + 6

    private var thumbnails: [ThumbnailView] = []
    private var imageCount = 0

    override var isFlipped: Bool { true }

    func show(_ images: [(id: UUID, url: URL)], onRemove: @escaping (UUID) -> Void) {
        while thumbnails.count < images.count {
            let thumbnail = ThumbnailView()
            addSubview(thumbnail)
            thumbnails.append(thumbnail)
        }
        for (thumbnail, image) in zip(thumbnails, images) {
            thumbnail.show(image.url)
            thumbnail.onRemove = { onRemove(image.id) }
        }
        imageCount = images.count
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let fit = max(1, Int((bounds.width + Self.spacing) / (Self.thumbnailSize.width + Self.spacing)))
        let visible = min(imageCount, fit)
        for (index, thumbnail) in thumbnails.enumerated() {
            thumbnail.isHidden = index >= visible
            thumbnail.overflowCount = index == visible - 1 && imageCount > visible ? imageCount - visible + 1 : 0
            thumbnail.frame = NSRect(
                x: CGFloat(index) * (Self.thumbnailSize.width + Self.spacing),
                y: bounds.height - Self.thumbnailSize.height,
                width: Self.thumbnailSize.width,
                height: Self.thumbnailSize.height
            )
        }
    }
}

/// One thumbnail. Click to open the image, drag it out to share it, right-click for more.
final class ThumbnailView: NSView, NSDraggingSource {
    private(set) var url: URL?
    var onRemove: () -> Void = {}
    var overflowCount = 0 {
        didSet {
            overflowLabel.stringValue = "+\(overflowCount)"
            overflowLabel.isHidden = overflowCount == 0
            dimmer.isHidden = overflowCount == 0
        }
    }

    private let dimmer = NSView()
    private let overflowLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.contentsGravity = .resizeAspectFill
        toolTip = "Click to open, drag to share"

        dimmer.wantsLayer = true
        dimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimmer.isHidden = true
        overflowLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        overflowLabel.textColor = .white
        overflowLabel.alignment = .center
        overflowLabel.isHidden = true
        for view in [dimmer, overflowLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dimmer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmer.topAnchor.constraint(equalTo: topAnchor),
            dimmer.bottomAnchor.constraint(equalTo: bottomAnchor),
            overflowLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            overflowLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        layer?.contents = ThumbnailCache.image(for: url)
    }

    override func viewDidChangeBackingProperties() {
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        let start = convert(event.locationInWindow, from: nil)
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if bounds.contains(point) { NSWorkspace.shared.open(url) }
                return
            }
            if hypot(point.x - start.x, point.y - start.y) > 4 {
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let image = ThumbnailCache.image(for: url).map { NSImage(cgImage: $0, size: bounds.size) }
                item.setDraggingFrame(bounds, contents: image)
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let url else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Open Image") { NSWorkspace.shared.open(url) })
        menu.addItem(ActionMenuItem("Copy Image") {
            guard let image = NSImage(contentsOf: url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        })
        menu.addItem(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Remove Image") { [weak self] in self?.onRemove() })
        return menu
    }
}

/// Small versions of attached images, made once per file.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, CGImage>()

    static func image(for url: URL) -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Reads images, web links and text from the clipboard or a drag.
@MainActor
enum Clipboard {
    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func images(_ pasteboard: NSPasteboard) -> [TaskStore.ImageSource] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL] ?? []
        if !files.isEmpty { return files.map { .file($0) } }
        if let png = pasteboard.data(forType: .png) { return [.data(png, fileExtension: "png")] }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.data(png, fileExtension: "png")]
        }
        return []
    }

    /// Whether ⌘V into a text field should take the image rather than the text. Image files
    /// always do (Finder also puts their names on the clipboard as text); image data only when
    /// there's no text, because some apps add a picture of copied text alongside it.
    static func prefersImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions) { return true }
        return pasteboard.availableType(from: [.png, .tiff]) != nil && pasteboard.string(forType: .string) == nil
    }

    /// A web address, if that's what's there — on its own, not inside other text.
    static func webLink(_ pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if let url = urls.first(where: isWeb) { return url }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace), let url = URL(string: text), isWeb(url)
        else { return nil }
        return url
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
