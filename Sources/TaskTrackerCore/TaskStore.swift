import Foundation
import Observation

/// The task list plus its JSON file. Every change is saved immediately and can be undone.
@MainActor
@Observable
public final class TaskStore {
    public private(set) var list: TaskList
    /// A problem reading or writing the data file, shown to the user.
    public private(set) var problem: String?
    public let fileURL: URL
    @ObservationIgnored public weak var undoManager: UndoManager?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.list = TaskList()
        load()
    }

    public static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["TASKTRACKER_DATA"] {
            return URL(fileURLWithPath: override)
        }
        return URL.applicationSupportDirectory
            .appending(path: "TaskTracker", directoryHint: .isDirectory)
            .appending(path: "tasks.json")
    }

    /// Adds one task per line of text.
    @discardableResult
    public func add(_ text: String, to container: Container = .section(.todo), at index: Int? = nil) -> [UUID] {
        change("Add Task") { $0.add(ListText.titles(in: text), to: container, at: index) }
    }

    /// Adds one task, keeping any line breaks in its title.
    @discardableResult
    public func addTask(_ title: String, to container: Container = .section(.todo), at index: Int? = nil) -> UUID? {
        change("Add Task") { $0.add([title], to: container, at: index).first }
    }

    public func move(_ ids: [UUID], to container: Container, at index: Int?) {
        change("Move") { $0.move(ids, to: container, at: index) }
    }

    public func setStatus(_ ids: [UUID], to status: TaskStatus) {
        change("Move to \(status.title)") { $0.setStatus(ids, to: status) }
    }

    public func rename(_ id: UUID, to title: String) {
        change("Rename") { $0.rename(id, to: title) }
    }

    public func delete(_ ids: [UUID]) {
        change("Delete") { $0.delete(ids) }
    }

    @discardableResult
    public func addFolder(to status: TaskStatus, at index: Int? = nil) -> UUID {
        change("New Folder") { $0.addFolder(to: status, at: index) }
    }

    @discardableResult
    public func groupIntoNewFolder(_ ids: [UUID]) -> UUID? {
        change("New Folder") { $0.groupIntoNewFolder(ids) }
    }

    public func ungroup(_ folderID: UUID) {
        change("Ungroup") { $0.ungroup(folderID) }
    }

    public func appendLink(_ url: URL, to taskID: UUID) {
        change("Add Link") { $0.appendLink(url, to: taskID) }
    }

    // MARK: - Images

    public enum ImageSource: Sendable {
        case file(URL)
        case data(Data, fileExtension: String)
    }

    public var attachmentsDirectory: URL {
        fileURL.deletingLastPathComponent().appending(path: "attachments", directoryHint: .isDirectory)
    }

    public func imageURL(_ image: ImageAttachment) -> URL {
        attachmentsDirectory.appending(path: image.fileName)
    }

    /// Copies the images into the attachments folder and attaches them. Returns how many were added.
    @discardableResult
    public func attachImages(_ sources: [ImageSource], to taskID: UUID) -> Int {
        guard list.task(taskID) != nil else { return 0 }
        let fm = FileManager.default
        var images: [ImageAttachment] = []
        do {
            try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            for source in sources {
                let id = UUID()
                switch source {
                case .file(let url):
                    let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
                    let image = ImageAttachment(id: id, fileName: "\(id.uuidString).\(fileExtension)")
                    try fm.copyItem(at: url, to: imageURL(image))
                    images.append(image)
                case .data(let data, let fileExtension):
                    let image = ImageAttachment(id: id, fileName: "\(id.uuidString).\(fileExtension)")
                    try data.write(to: imageURL(image))
                    images.append(image)
                }
            }
        } catch {
            problem = "Couldn't save the image: \(error.localizedDescription)"
        }
        guard !images.isEmpty else { return 0 }
        change(images.count == 1 ? "Add Image" : "Add Images") { $0.addImages(images, to: taskID) }
        return images.count
    }

    /// Detaches an image. Its file stays until the next launch, so the removal can be undone.
    public func removeImage(_ imageID: UUID, from taskID: UUID) {
        change("Remove Image") { $0.removeImage(imageID, from: taskID) }
    }

    /// Deletes image files no task refers to any more, e.g. from deleted tasks.
    private func removeUnusedAttachments() {
        let fm = FileManager.default
        let used = Set(list.allImages.map(\.fileName))
        guard let names = try? fm.contentsOfDirectory(atPath: attachmentsDirectory.path) else { return }
        for name in names where !used.contains(name) && !name.hasPrefix(".") {
            try? fm.removeItem(at: attachmentsDirectory.appending(path: name))
        }
    }

    // MARK: - Reminders

    /// Sets the reminder of tasks, or removes it with nil.
    public func setReminder(_ date: Date?, for ids: [UUID]) {
        change(date == nil ? "Remove Reminder" : "Set Reminder") { $0.setReminder(date, for: ids) }
    }

    /// Clears reminders that have gone off. This can't be undone: undoing it would only remind again.
    public func clearReminders(_ ids: [UUID]) {
        let before = list
        list.setReminder(nil, for: ids)
        if list != before { save() }
    }

    // MARK: - Import

    /// Imports text in the list format and returns how many tasks were added.
    @discardableResult
    public func importText(_ text: String) -> Int {
        let parsed = ListText.parse(text)
        change("Import") { $0.appendImported(parsed) }
        return parsed.count
    }

    private func change<Result>(_ actionName: String, _ body: (inout TaskList) -> Result) -> Result {
        let before = list
        let result = body(&list)
        if list != before {
            registerUndo(restoring: before, actionName)
            save()
        }
        return result
    }

    private func registerUndo(restoring snapshot: TaskList, _ actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(snapshot, actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: TaskList, _ actionName: String) {
        let current = list
        list = snapshot
        registerUndo(restoring: current, actionName)
        save()
    }

    // MARK: - File

    private struct FileContents: Codable {
        var version = 2
        var sections: [TaskSection]
    }

    private struct VersionProbe: Decodable {
        var version: Int?
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let version = try Self.decoder.decode(VersionProbe.self, from: data).version ?? 1
            if version >= 2 {
                list = TaskList(sections: try Self.decoder.decode(FileContents.self, from: data).sections)
            } else {
                list = try Self.migrateVersion1(data)
                // Keep the original around, then write the new format right away.
                let original = sibling("v1.json")
                if !fm.fileExists(atPath: original.path) { try? fm.copyItem(at: fileURL, to: original) }
                save()
            }
            // Keep the last file that loaded cleanly, in case a later save goes wrong.
            let backup = sibling("backup.json")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: fileURL, to: backup)
            // Only after a clean load: with no list to go by, every image would look unused.
            removeUnusedAttachments()
        } catch {
            // Never overwrite a file we couldn't read: move it aside and start fresh.
            let aside = sibling("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: aside)
            problem = "Couldn't read your tasks file, so it was moved to \(aside.lastPathComponent) and a new list was started."
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(FileContents(sections: list.sections))
            try data.write(to: fileURL, options: .atomic)
            if problem?.hasPrefix("Couldn't save") == true { problem = nil }
        } catch {
            problem = "Couldn't save your tasks: \(error.localizedDescription)"
        }
    }

    /// tasks.json → tasks.<suffix>
    private func sibling(_ suffix: String) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension(suffix)
    }

    /// Version 1 was a flat array of tasks, each with a status. Done was shown newest first,
    /// so it keeps that order now that every section is ordered by hand.
    private static func migrateVersion1(_ data: Data) throws -> TaskList {
        struct OldTask: Decodable {
            var id: UUID
            var title: String
            var status: TaskStatus
            var createdAt: Date
            var statusChangedAt: Date
            var completedAt: Date?
        }
        struct OldFile: Decodable {
            var tasks: [OldTask]
        }

        let old = try decoder.decode(OldFile.self, from: data).tasks
        let sections = TaskStatus.allCases.map { status in
            var tasks = old.filter { $0.status == status }
            if status == .done {
                let order = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.id, $0) })
                tasks.sort { a, b in
                    switch (a.completedAt, b.completedAt) {
                    case let (x?, y?) where x != y: x > y
                    case (.some, nil): true
                    case (nil, .some): false
                    default: order[a.id]! < order[b.id]!
                    }
                }
            }
            return TaskSection(status: status, entries: tasks.map { task in
                .task(TaskItem(
                    id: task.id,
                    title: task.title,
                    createdAt: task.createdAt,
                    statusChangedAt: task.statusChangedAt,
                    completedAt: task.completedAt
                ))
            })
        }
        return TaskList(sections: sections)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
