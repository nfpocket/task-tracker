import AppKit
import TaskTrackerCore

/// The outline itself, plus hooks for keyboard shortcuts, copy and paste, and width changes.
final class TaskOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?
    var copyHandler: (() -> Void)?
    var pasteHandler: (() -> Void)?
    var canPaste: (() -> Bool)?
    /// Row heights depend on the width, since titles wrap.
    var widthDidChange: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }
    @objc func paste(_ sender: Any?) { pasteHandler?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selectedRow >= 0
        case #selector(paste(_:)): canPaste?() ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { widthDidChange?() }
    }
}

extension TaskStatus {
    var symbol: String {
        switch self {
        case .inProgress: "circle.lefthalf.filled"
        case .todo: "circle"
        case .deferred: "moon.zzz"
        case .done: "checkmark.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .inProgress: .systemBlue
        case .todo: .secondaryLabelColor
        case .deferred: .systemPurple
        case .done: .systemGreen
        }
    }

    func image(pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }
}

/// How a timestamp reads in a row: the time for today, otherwise date and time. A task with a
/// reminder shows when it's due instead.
enum Stamp {
    static func short(_ task: TaskItem, in status: TaskStatus) -> String {
        guard let date = task.reminder ?? (status == .done ? task.completedAt : task.statusChangedAt) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func history(_ task: TaskItem, in status: TaskStatus) -> String {
        func full(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
        var lines = ["Added \(full(task.createdAt))"]
        switch status {
        case .done:
            lines.append(task.completedAt.map { "Done \(full($0))" } ?? "Imported as done")
        case .todo where task.statusChangedAt == task.createdAt:
            break
        default:
            lines.append("In \(status.title) since \(full(task.statusChangedAt))")
        }
        if let reminder = task.reminder { lines.append("Reminder \(full(reminder))") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Section header

final class SectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, titleLabel, countLabel])
        stack.spacing = 6
        stack.setCustomSpacing(5, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(status: TaskStatus, count: Int) {
        icon.image = status.image(pointSize: 11)
        icon.contentTintColor = status.color
        titleLabel.stringValue = status.title
        countLabel.stringValue = "\(count)"
    }
}

// MARK: - Folder

final class FolderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("folder")

    private let icon = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = titleField
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor

        for view in [icon, titleField, countLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: TaskCell.checkboxWidth),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: TaskCell.gap),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TaskCell.trailingInset),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(folder: Folder) {
        if titleField.currentEditor() == nil { titleField.stringValue = folder.title }
        countLabel.stringValue = "\(folder.tasks.count)"
    }
}

// MARK: - Task

/// A cell whose title can be renamed in place, through its `textField`.
@MainActor
protocol RenamableCell: NSTableCellView {
    func setRenaming(_ renaming: Bool)
}

extension FolderCell: RenamableCell {
    func setRenaming(_ renaming: Bool) {}
}

final class TaskCell: NSTableCellView, RenamableCell {
    static let identifier = NSUserInterfaceItemIdentifier("task")
    static let checkboxWidth: CGFloat = 18
    static let gap: CGFloat = 6
    static let stampGap: CGFloat = 8
    static let bellWidth: CGFloat = 10
    static let bellGap: CGFloat = 2
    static let trailingInset: CGFloat = 4
    static let verticalPadding: CGFloat = 4
    static let minimumHeight: CGFloat = 24

    let checkbox = NSButton()
    private let titleView = TitleView()
    /// Takes the title's place while renaming. Plain text, so links show in full.
    private let editField = NSTextField(wrappingLabelWithString: "")
    private let stampLabel = NSTextField(labelWithString: "")
    /// Shown before the stamp when the task has a reminder.
    private let bell = NSImageView()
    private var stampLeading: NSLayoutConstraint!
    private let imageStrip = ImageStrip()
    private var imageStripHeight: NSLayoutConstraint!
    private var hasReminder = false
    private var title = ""
    private var status = TaskStatus.todo

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = editField

        checkbox.isBordered = false
        checkbox.imagePosition = .imageOnly
        checkbox.setButtonType(.momentaryChange)
        editField.font = TitleText.font
        editField.isSelectable = false
        editField.isHidden = true
        Self.styleStamp(stampLabel)
        stampLabel.setContentHuggingPriority(.required, for: .horizontal)
        stampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bell.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Reminder")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        for view in [titleView, editField] as [NSView] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
        }

        for view in [checkbox, titleView, editField, stampLabel, bell, imageStrip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageStripHeight = imageStrip.heightAnchor.constraint(equalToConstant: 0)
        stampLeading = stampLabel.leadingAnchor.constraint(equalTo: titleView.trailingAnchor, constant: Self.stampGap)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: Self.checkboxWidth),
            checkbox.centerYAnchor.constraint(equalTo: titleView.topAnchor, constant: TitleText.baselineOffset - 4),
            titleView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Self.gap),
            titleView.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            titleView.bottomAnchor.constraint(equalTo: imageStrip.topAnchor),
            stampLeading,
            stampLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            stampLabel.firstBaselineAnchor.constraint(equalTo: titleView.topAnchor, constant: TitleText.baselineOffset),
            bell.widthAnchor.constraint(equalToConstant: Self.bellWidth),
            bell.trailingAnchor.constraint(equalTo: stampLabel.leadingAnchor, constant: -Self.bellGap),
            bell.centerYAnchor.constraint(equalTo: stampLabel.centerYAnchor),
            imageStrip.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            imageStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            imageStrip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
            imageStripHeight,
            editField.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            editField.trailingAnchor.constraint(equalTo: titleView.trailingAnchor),
            editField.topAnchor.constraint(equalTo: titleView.topAnchor),
            editField.bottomAnchor.constraint(equalTo: titleView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(
        task: TaskItem,
        status: TaskStatus,
        imageURL: (ImageAttachment) -> URL,
        onToggle: (target: AnyObject, action: Selector),
        onRemoveImage: @escaping (UUID) -> Void
    ) {
        self.status = status
        title = task.title
        checkbox.image = status.image(pointSize: 14)
        checkbox.target = onToggle.target
        checkbox.action = onToggle.action
        checkbox.toolTip = status == .done ? "Move back to Todo" : "Mark as done"
        if editField.currentEditor() == nil { editField.stringValue = task.title }
        stampLabel.stringValue = Stamp.short(task, in: status)
        hasReminder = task.reminder != nil
        bell.isHidden = !hasReminder
        stampLeading.constant = Self.stampGap + Self.bellSpace(hasReminder)
        toolTip = Stamp.history(task, in: status)
        imageStrip.show(task.images.map { ($0.id, imageURL($0)) }, onRemove: onRemoveImage)
        imageStripHeight.constant = task.images.isEmpty ? 0 : ImageStrip.height
        updateColors()
    }

    func setRenaming(_ renaming: Bool) {
        titleView.isHidden = renaming
        editField.isHidden = !renaming
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let onSelection = NSColor.alternateSelectedControlTextColor
        checkbox.contentTintColor = selected ? onSelection : status.color
        titleView.show(TitleText.attributed(
            title,
            color: selected ? onSelection : status == .done ? .secondaryLabelColor : .labelColor,
            linkColor: selected ? onSelection : .linkColor,
            underlineLinks: selected
        ))
        stampLabel.textColor = selected ? onSelection.withAlphaComponent(0.75) : hasReminder ? .systemOrange : .tertiaryLabelColor
        bell.contentTintColor = selected ? onSelection : .systemOrange
    }

    /// The row height that fits the wrapped title and any images, for a cell of the given width.
    static func height(
        title: String,
        showsLinks: Bool = true,
        stamp: String,
        hasReminder: Bool = false,
        hasImages: Bool,
        cellWidth: CGFloat
    ) -> CGFloat {
        stampSizer.stringValue = stamp
        let stampWidth = stampGap + bellSpace(hasReminder) + stampSizer.intrinsicContentSize.width
        let width = max(cellWidth - checkboxWidth - gap - stampWidth - trailingInset, 40)
        let text = showsLinks
            ? TitleText.attributed(title, color: .labelColor, linkColor: .linkColor, underlineLinks: false)
            : NSAttributedString(string: title, attributes: [.font: TitleText.font])
        let titleHeight = max(TitleText.height(of: text, width: width), TitleText.lineHeight)
        return max(minimumHeight, titleHeight + 2 * verticalPadding + (hasImages ? ImageStrip.height : 0))
    }

    private static func bellSpace(_ hasReminder: Bool) -> CGFloat {
        hasReminder ? bellWidth + bellGap : 0
    }

    private static let stampSizer: NSTextField = {
        let label = NSTextField(labelWithString: "")
        styleStamp(label)
        return label
    }()

    private static func styleStamp(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
