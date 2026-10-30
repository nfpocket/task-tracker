import Foundation

public struct ParsedTask: Equatable, Sendable {
    public var status: TaskStatus
    public var title: String
    public var folder: String?

    public init(status: TaskStatus, title: String, folder: String? = nil) {
        self.status = status
        self.title = title
        self.folder = folder
    }
}

/// Reads and writes the plain-text list format: a header line per section ("Done:", "Progress:",
/// "Todo:", "Defered", …) followed by one task per line. A line ending in ":" starts a folder,
/// which runs until the next blank line. Indented lines continue the task above them, which is
/// how tasks with several lines are written.
public enum ListText {
    public static func parse(_ text: String) -> [ParsedTask] {
        var status = TaskStatus.todo
        var folder: String?
        var result: [ParsedTask] = []
        var continuesTask = false
        for line in text.components(separatedBy: .newlines) {
            if let header = header(line) {
                status = header
                folder = nil
                continuesTask = false
            } else if let title = taskTitle(line) {
                if continuesTask, line.first == " " || line.first == "\t" {
                    result[result.count - 1].title += "\n" + title
                } else if title.count > 1, title.hasSuffix(":") {
                    folder = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
                    continuesTask = false
                } else {
                    result.append(ParsedTask(status: status, title: title, folder: folder))
                    continuesTask = true
                }
            } else {
                folder = nil
                continuesTask = false
            }
        }
        return result
    }

    /// One title per non-empty line, with list bullets removed.
    public static func titles(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap(taskTitle)
    }

    public static func format(_ list: TaskList) -> String {
        list.sections.compactMap { section in
            guard !section.entries.isEmpty else { return nil }
            // Runs of loose tasks form one block; each folder is its own block.
            var blocks: [[String]] = []
            var looseRun = false
            for entry in section.entries {
                switch entry {
                case .task(let task):
                    let line = indentingExtraLines(task.title)
                    if looseRun { blocks[blocks.count - 1].append(line) } else { blocks.append([line]) }
                    looseRun = true
                case .folder(let folder):
                    blocks.append(["\(folder.title):"] + folder.tasks.map { indentingExtraLines($0.title) })
                    looseRun = false
                }
            }
            let body = blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
            return "\(section.status.title):\n\n\(body)"
        }
        .joined(separator: "\n\n\n")
    }

    private static func indentingExtraLines(_ title: String) -> String {
        title.replacingOccurrences(of: "\n", with: "\n    ")
    }

    static func header(_ line: String) -> TaskStatus? {
        var name = line.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(":") { name.removeLast() }
        switch name.trimmingCharacters(in: .whitespaces) {
        case "done": return .done
        case "progress", "in progress": return .inProgress
        case "todo", "to do": return .todo
        case "deferred", "defered": return .deferred
        default: return nil
        }
    }

    private static func taskTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("```") { return nil }
        let title = trimmed
            .replacing(/^(?:[-*•]\s+)?(?:\[[ xX]\]\s+)?/, with: "")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
