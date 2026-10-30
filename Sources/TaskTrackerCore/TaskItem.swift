import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order the sections appear in.
    case inProgress, todo, deferred, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inProgress: "In Progress"
        case .todo: "Todo"
        case .deferred: "Deferred"
        case .done: "Done"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

public struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// May contain web addresses, which are shown as links.
    public var title: String
    public let createdAt: Date
    /// When the task entered its current section.
    public var statusChangedAt: Date
    /// When the task was moved to Done. Nil while not done, and for done tasks imported without a date.
    public var completedAt: Date?
    public var images: [ImageAttachment]
    /// When to remind the user about the task. Cleared once the reminder has gone off.
    public var reminder: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        statusChangedAt: Date? = nil,
        completedAt: Date? = nil,
        images: [ImageAttachment] = [],
        reminder: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.statusChangedAt = statusChangedAt ?? createdAt
        self.completedAt = completedAt
        self.images = images
        self.reminder = reminder
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, statusChangedAt, completedAt, images, reminder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        statusChangedAt = try container.decode(Date.self, forKey: .statusChangedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        // Files from before images existed have no key.
        images = try container.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
        reminder = try container.decodeIfPresent(Date.self, forKey: .reminder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(statusChangedAt, forKey: .statusChangedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        if !images.isEmpty { try container.encode(images, forKey: .images) }
        try container.encodeIfPresent(reminder, forKey: .reminder)
    }
}

/// An image attached to a task, stored as a file in the attachments folder next to the data file.
public struct ImageAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String

    public init(id: UUID = UUID(), fileName: String) {
        self.id = id
        self.fileName = fileName
    }
}

/// A named group of tasks inside a section. Folders don't nest.
public struct Folder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var tasks: [TaskItem]
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, tasks: [TaskItem] = [], createdAt: Date) {
        self.id = id
        self.title = title
        self.tasks = tasks
        self.createdAt = createdAt
    }
}

/// What a section holds: loose tasks and folders, in the user's order.
public enum ListEntry: Identifiable, Equatable, Sendable {
    case task(TaskItem)
    case folder(Folder)

    public var id: UUID {
        switch self {
        case .task(let task): task.id
        case .folder(let folder): folder.id
        }
    }
}

extension ListEntry: Codable {
    private enum CodingKeys: String, CodingKey { case task, folder }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let folder = try container.decodeIfPresent(Folder.self, forKey: .folder) {
            self = .folder(folder)
        } else {
            self = .task(try container.decode(TaskItem.self, forKey: .task))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .task(let task): try container.encode(task, forKey: .task)
        case .folder(let folder): try container.encode(folder, forKey: .folder)
        }
    }
}

public struct TaskSection: Codable, Equatable, Sendable {
    public let status: TaskStatus
    public internal(set) var entries: [ListEntry]

    public init(status: TaskStatus, entries: [ListEntry] = []) {
        self.status = status
        self.entries = entries
    }
}

/// Something tasks can be put into.
public enum Container: Hashable, Sendable {
    case section(TaskStatus)
    case folder(UUID)
}
