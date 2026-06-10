import Foundation

struct Note: Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var modifiedDate: Date = Date()
    var remoteFilename: String = ""

    var displayTitle: String { title.isEmpty ? "Neue Notiz" : title }

    var preview: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first(where: { !$0.isEmpty && ChecklistParser.parse(line: $0) == nil }) ?? ""
    }
}

// MARK: - Checklist

struct ChecklistItem: Identifiable, Equatable {
    var text: String
    var isDone: Bool
    var lineIndex: Int
    var id: Int { lineIndex }
}

enum ChecklistParser {
    static let openPrefix = "- [ ] "
    static let donePrefix = "- [x] "

    static func parse(line: String) -> (isDone: Bool, text: String)? {
        let chars = Array(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard chars.count >= 5,
              chars[0] == "-", chars[1] == " ", chars[2] == "[", chars[4] == "]" else {
            return nil
        }
        let isDone: Bool
        switch chars[3] {
        case " ":      isDone = false
        case "x", "X": isDone = true
        default:       return nil
        }
        var textStart = 5
        if textStart < chars.count && chars[textStart] == " " { textStart += 1 }
        return (isDone, String(chars[textStart...]))
    }
}

extension Note {
    var checklistItems: [ChecklistItem] {
        body.components(separatedBy: "\n").enumerated().compactMap { idx, line in
            guard let parsed = ChecklistParser.parse(line: line) else { return nil }
            return ChecklistItem(text: parsed.text, isDone: parsed.isDone, lineIndex: idx)
        }
    }

    var totalTasks: Int { checklistItems.count }
    var doneTasks: Int { checklistItems.filter(\.isDone).count }

    mutating func toggleTask(at lineIndex: Int) {
        var lines = body.components(separatedBy: "\n")
        guard lineIndex < lines.count, let parsed = ChecklistParser.parse(line: lines[lineIndex]) else { return }
        let prefix = parsed.isDone ? ChecklistParser.openPrefix : ChecklistParser.donePrefix
        lines[lineIndex] = prefix + parsed.text
        body = lines.joined(separator: "\n")
    }

    mutating func updateTaskText(at lineIndex: Int, to newText: String) {
        var lines = body.components(separatedBy: "\n")
        guard lineIndex < lines.count, let parsed = ChecklistParser.parse(line: lines[lineIndex]) else { return }
        let prefix = parsed.isDone ? ChecklistParser.donePrefix : ChecklistParser.openPrefix
        lines[lineIndex] = prefix + newText
        body = lines.joined(separator: "\n")
    }

    mutating func appendTask(_ text: String = "") {
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        body += ChecklistParser.openPrefix + text
    }

    mutating func removeTask(at lineIndex: Int) {
        var lines = body.components(separatedBy: "\n")
        guard lineIndex < lines.count, ChecklistParser.parse(line: lines[lineIndex]) != nil else { return }
        lines.remove(at: lineIndex)
        body = lines.joined(separator: "\n")
    }
}
