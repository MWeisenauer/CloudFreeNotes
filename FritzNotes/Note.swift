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
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
