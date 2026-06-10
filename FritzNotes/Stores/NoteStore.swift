import Foundation
import Combine

@MainActor
class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadNotes() async {
        let settings = FTPSSettings.load()
        guard settings.isConfigured else {
            errorMessage = "Bitte zuerst die FTPS-Einstellungen konfigurieren."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            notes = try await NoteService(settings: settings).fetchAllNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func saveNote(_ note: Note) async throws {
        var mutable = note
        if mutable.remoteFilename.isEmpty {
            mutable.remoteFilename = "\(mutable.id.uuidString).txt"
        }
        mutable.modifiedDate = Date()
        let settings = FTPSSettings.load()
        try await NoteService(settings: settings).uploadNote(mutable)
        if let idx = notes.firstIndex(where: { $0.remoteFilename == mutable.remoteFilename }) {
            notes[idx] = mutable
        } else {
            notes.insert(mutable, at: 0)
        }
        notes.sort { $0.modifiedDate > $1.modifiedDate }
    }

    func deleteNote(_ note: Note) async throws {
        guard !note.remoteFilename.isEmpty else {
            notes.removeAll { $0.id == note.id }
            return
        }
        let settings = FTPSSettings.load()
        try await NoteService(settings: settings).deleteNote(filename: note.remoteFilename)
        notes.removeAll { $0.remoteFilename == note.remoteFilename }
    }
}
