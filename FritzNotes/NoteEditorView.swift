import SwiftUI

struct NoteEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Note?
    @State private var title: String
    @State private var noteBody: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(note: Note?) {
        self.existing = note
        _title    = State(initialValue: note?.title ?? "")
        _noteBody = State(initialValue: note?.body ?? "")
    }

    private var hasChanges: Bool {
        title != (existing?.title ?? "") || noteBody != (existing?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Titel", text: $title)
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            TextEditor(text: $noteBody)
                .padding(.horizontal, 8)
        }
        .navigationTitle(existing == nil ? "Neue Notiz" : "Notiz bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Speichern").fontWeight(.semibold)
                    }
                }
                .disabled(isSaving || (title.isEmpty && noteBody.isEmpty) || !hasChanges)
            }
        }
        .alert("Fehler", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        isSaving = true
        var note = existing ?? Note()
        note.title = title
        note.body  = noteBody
        do {
            try await store.saveNote(note)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
