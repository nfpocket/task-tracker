import Foundation

/// Four sections, each holding loose tasks and folders of tasks, in the user's order.
public struct TaskList: Equatable, Sendable {
    public private(set) var sections: [TaskSection]

    public init(sections: [TaskSection] = []) {
        self.sections = TaskStatus.allCases.map { status in
            TaskSection(status: status, entries: sections.first { $0.status == status }?.entries ?? [])
        }
    }

    // MARK: - Reading

    public func entries(in status: TaskStatus) -> [ListEntry] {
        sections[status.index].entries
    }

    /// Every task in a section, folders included, top to bottom.
    public func tasks(in status: TaskStatus) -> [TaskItem] {
        entries(in: status).flatMap { entry -> [TaskItem] in
            switch entry {
            case .task(let task): [task]
            case .folder(let folder): folder.tasks
            }
        }
    }

    public func task(_ id: UUID) -> TaskItem? {
        guard let location = locate(id) else { return nil }
        switch sections[location.section].entries[location.entry] {
        case .task(let task): return task
        case .folder(let folder): return location.task.map { folder.tasks[$0] }
        }
    }

    public func folder(_ id: UUID) -> Folder? {
        guard let location = locate(id), location.task == nil,
              case .folder(let folder) = sections[location.section].entries[location.entry]
        else { return nil }
        return folder
    }

    /// The section a task or folder is in.
    public func status(of id: UUID) -> TaskStatus? {
        locate(id).map { sections[$0.section].status }
    }

    public func status(of container: Container) -> TaskStatus? {
        switch container {
        case .section(let status): status
        case .folder(let id): folder(id) == nil ? nil : status(of: id)
        }
    }

    /// What directly holds a task or folder.
    public func container(of id: UUID) -> Container? {
        guard let location = locate(id) else { return nil }
        let section = sections[location.section]
        if location.task != nil { return .folder(section.entries[location.entry].id) }
        return .section(section.status)
    }

    public func childIDs(of container: Container) -> [UUID] {
        switch container {
        case .section(let status): entries(in: status).map(\.id)
        case .folder(let id): folder(id)?.tasks.map(\.id) ?? []
        }
    }

    public func folderID(named title: String, in status: TaskStatus) -> UUID? {
        let wanted = Self.matchKey(title)
        return entries(in: status).first { entry in
            if case .folder(let folder) = entry { return Self.matchKey(folder.title) == wanted }
            return false
        }?.id
    }

    public func completedCount(onSameDayAs day: Date, calendar: Calendar = .current) -> Int {
        tasks(in: .done).count { task in
            task.completedAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }
    }

    // MARK: - Changing

    /// Adds one task per non-empty title, in order. Without an index they go to the bottom,
    /// or the top in Done. Returns the new ids.
    @discardableResult
    public mutating func add(
        _ titles: [String],
        to container: Container = .section(.todo),
        at index: Int? = nil,
        now: Date = .now
    ) -> [UUID] {
        guard let status = status(of: container) else { return [] }
        var position = index ?? (status == .done ? 0 : childIDs(of: container).count)
        var ids: [UUID] = []
        for title in titles.map(Self.clean) where !title.isEmpty {
            let task = TaskItem(title: title, createdAt: now, completedAt: status == .done ? now : nil)
            insert(.task(task), into: container, at: position)
            position += 1
            ids.append(task.id)
        }
        return ids
    }

    @discardableResult
    public mutating func addFolder(
        _ title: String = "New Folder",
        to status: TaskStatus,
        at index: Int? = nil,
        now: Date = .now
    ) -> UUID {
        let title = Self.clean(title)
        let folder = Folder(title: title.isEmpty ? "New Folder" : title, createdAt: now)
        insert(.folder(folder), into: .section(status), at: index ?? entries(in: status).count)
        return folder.id
    }

    /// Moves tasks and folders so they land at `index` among the container's current children
    /// (the index counts the moved items where they are now, as a drag-and-drop index does).
    /// Without an index they go to the bottom.
    ///
    /// A folder moved to another section merges into a same-named folder there. A folder aimed
    /// into a folder lands right after it, because folders don't nest.
    public mutating func move(_ ids: [UUID], to container: Container, at index: Int? = nil, now: Date = .now) {
        var container = container
        var index = index
        if case .folder(let target) = container, ids.contains(where: { folder($0) != nil }) {
            guard let location = locate(target) else { return }
            container = .section(sections[location.section].status)
            index = location.entry + 1
        }
        // A moving folder carries its tasks, so tasks inside it don't move separately.
        let moving = ids.filter { id in
            if case .folder(let parent)? = self.container(of: id) { return !ids.contains(parent) }
            return true
        }
        guard !moving.isEmpty, let status = status(of: container) else { return }
        if case .folder(let target) = container, moving.contains(target) { return }

        let movingSet = Set(moving)
        let anchor = index.flatMap { index in
            childIDs(of: container).dropFirst(max(index, 0)).first { !movingSet.contains($0) }
        }
        let removed = moving.compactMap { remove($0) }
        var position = anchor.flatMap { childIDs(of: container).firstIndex(of: $0) } ?? childIDs(of: container).count

        for (entry, oldStatus) in removed {
            let entry = Self.restamp(entry, from: oldStatus, to: status, now: now)
            if case .folder(let folder) = entry, oldStatus != status,
               let existing = folderID(named: folder.title, in: status) {
                let start = status == .done ? 0 : childIDs(of: .folder(existing)).count
                for (offset, task) in folder.tasks.enumerated() {
                    insert(.task(task), into: .folder(existing), at: start + offset)
                }
                continue
            }
            insert(entry, into: container, at: position)
            position += 1
        }
    }

    /// Moves tasks or folders to another section, keeping a task's folder: it goes into the
    /// same-named folder there, which is created if needed. Things land at the bottom, or at the
    /// top in Done so it reads newest first.
    public mutating func setStatus(_ ids: [UUID], to status: TaskStatus, now: Date = .now) {
        let atTop = status == .done
        let index: Int? = atTop ? 0 : nil
        for id in atTop ? ids.reversed() : ids {
            guard let current = self.status(of: id), current != status else { continue }
            if case .folder(let parentID)? = container(of: id), let parent = folder(parentID) {
                let target = folderID(named: parent.title, in: status)
                    ?? addFolder(parent.title, to: status, at: index, now: now)
                move([id], to: .folder(target), at: index, now: now)
            } else {
                move([id], to: .section(status), at: index, now: now)
            }
        }
    }

    /// Puts tasks into a new folder where the first of them was. Returns the folder's id.
    @discardableResult
    public mutating func groupIntoNewFolder(_ ids: [UUID], title: String = "New Folder", now: Date = .now) -> UUID? {
        let taskIDs = ids.filter { task($0) != nil }
        guard let first = taskIDs.first, let location = locate(first) else { return nil }
        let folderID = addFolder(title, to: sections[location.section].status, at: location.entry, now: now)
        move(taskIDs, to: .folder(folderID), now: now)
        return folderID
    }

    /// Replaces a folder with its tasks.
    public mutating func ungroup(_ folderID: UUID) {
        guard let location = locate(folderID), location.task == nil,
              case .folder(let folder) = sections[location.section].entries[location.entry]
        else { return }
        sections[location.section].entries.replaceSubrange(
            location.entry...location.entry,
            with: folder.tasks.map(ListEntry.task)
        )
    }

    public mutating func rename(_ id: UUID, to title: String) {
        let title = Self.clean(title)
        guard !title.isEmpty else { return }
        if let location = locate(id), location.task == nil,
           case .folder(var folder) = sections[location.section].entries[location.entry] {
            folder.title = title
            sections[location.section].entries[location.entry] = .folder(folder)
        } else {
            updateTask(id) { $0.title = title }
        }
    }

    /// Adds a web address to the end of a task's title, unless it's already there.
    public mutating func appendLink(_ url: URL, to taskID: UUID) {
        updateTask(taskID) { task in
            guard !task.title.contains(url.absoluteString) else { return }
            task.title += " " + url.absoluteString
        }
    }

    public mutating func addImages(_ images: [ImageAttachment], to taskID: UUID) {
        updateTask(taskID) { $0.images += images }
    }

    public mutating func removeImage(_ imageID: UUID, from taskID: UUID) {
        updateTask(taskID) { $0.images.removeAll { $0.id == imageID } }
    }

    /// Every image any task refers to.
    public var allImages: [ImageAttachment] {
        TaskStatus.allCases.flatMap { tasks(in: $0) }.flatMap(\.images)
    }

    /// Sets the reminder of tasks, or removes it with nil. Done tasks don't get one.
    public mutating func setReminder(_ date: Date?, for ids: [UUID]) {
        for id in ids where date == nil || status(of: id) != .done {
            updateTask(id) { $0.reminder = date }
        }
    }

    /// Every task with a reminder, soonest first.
    public var tasksWithReminders: [TaskItem] {
        TaskStatus.allCases.flatMap { tasks(in: $0) }
            .filter { $0.reminder != nil }
            .sorted { $0.reminder! < $1.reminder! }
    }

    /// Deletes tasks and folders, including the tasks inside deleted folders.
    public mutating func delete(_ ids: [UUID]) {
        for id in ids { _ = remove(id) }
    }

    /// Appends parsed tasks to the bottom of their sections and folders. Done tasks get no
    /// completion date, since we don't know when they were finished.
    public mutating func appendImported(_ parsed: [ParsedTask], now: Date = .now) {
        for entry in parsed {
            let title = Self.clean(entry.title)
            guard !title.isEmpty else { continue }
            var container = Container.section(entry.status)
            if let folderTitle = entry.folder {
                container = .folder(folderID(named: folderTitle, in: entry.status)
                    ?? addFolder(folderTitle, to: entry.status, now: now))
            }
            insert(.task(TaskItem(title: title, createdAt: now)), into: container, at: .max)
        }
    }

    // MARK: - Internals

    private struct Location {
        var section: Int
        var entry: Int
        /// Index inside the folder at `entry`, when the id is a task in a folder.
        var task: Int?
    }

    private func locate(_ id: UUID) -> Location? {
        for (s, section) in sections.enumerated() {
            for (e, entry) in section.entries.enumerated() {
                switch entry {
                case .task(let task):
                    if task.id == id { return Location(section: s, entry: e) }
                case .folder(let folder):
                    if folder.id == id { return Location(section: s, entry: e) }
                    if let t = folder.tasks.firstIndex(where: { $0.id == id }) {
                        return Location(section: s, entry: e, task: t)
                    }
                }
            }
        }
        return nil
    }

    private mutating func updateTask(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let location = locate(id) else { return }
        switch sections[location.section].entries[location.entry] {
        case .task(var task):
            change(&task)
            sections[location.section].entries[location.entry] = .task(task)
        case .folder(var folder):
            guard let index = location.task else { return }
            change(&folder.tasks[index])
            sections[location.section].entries[location.entry] = .folder(folder)
        }
    }

    private mutating func remove(_ id: UUID) -> (entry: ListEntry, status: TaskStatus)? {
        guard let location = locate(id) else { return nil }
        let status = sections[location.section].status
        guard let taskIndex = location.task else {
            return (sections[location.section].entries.remove(at: location.entry), status)
        }
        guard case .folder(var folder) = sections[location.section].entries[location.entry] else { return nil }
        let task = folder.tasks.remove(at: taskIndex)
        sections[location.section].entries[location.entry] = .folder(folder)
        return (.task(task), status)
    }

    private mutating func insert(_ entry: ListEntry, into container: Container, at index: Int) {
        switch container {
        case .section(let status):
            let entries = sections[status.index].entries
            sections[status.index].entries.insert(entry, at: min(max(index, 0), entries.count))
        case .folder(let id):
            guard let location = locate(id), location.task == nil,
                  case .folder(var folder) = sections[location.section].entries[location.entry]
            else {
                // Never drop anything on the floor.
                return insert(entry, into: .section(.todo), at: .max)
            }
            switch entry {
            case .task(let task):
                folder.tasks.insert(task, at: min(max(index, 0), folder.tasks.count))
                sections[location.section].entries[location.entry] = .folder(folder)
            case .folder:
                sections[location.section].entries.insert(entry, at: location.entry + 1)
            }
        }
    }

    private static func restamp(_ entry: ListEntry, from old: TaskStatus, to new: TaskStatus, now: Date) -> ListEntry {
        guard old != new else { return entry }
        func restamp(_ task: TaskItem) -> TaskItem {
            var task = task
            task.statusChangedAt = now
            task.completedAt = new == .done ? now : nil
            // A finished task needs no reminding.
            if new == .done { task.reminder = nil }
            return task
        }
        switch entry {
        case .task(let task):
            return .task(restamp(task))
        case .folder(var folder):
            folder.tasks = folder.tasks.map(restamp)
            return .folder(folder)
        }
    }

    static func clean(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchKey(_ title: String) -> String {
        clean(title).lowercased()
    }
}
