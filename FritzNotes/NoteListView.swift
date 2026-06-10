import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var searchText = ""
    @State private var showNewNote = false

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return store.notes }
        return store.notes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView("Lade Notizen…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.notes.isEmpty {
                    ContentUnavailableView(
                        "Keine Notizen",
                        systemImage: "note.text",
                        description: Text("Tippe auf das Stift-Symbol um eine neue Notiz hinzuzufügen.")
                    )
                } else if filteredNotes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filteredNotes) { note in
                            NavigationLink(destination: NoteEditorView(note: note)) {
                                NoteRowView(note: note)
                            }
                        }
                        .onDelete(perform: deleteNotes)
                    }
                }
            }
            .navigationTitle("Notizen")
            .searchable(text: $searchText, prompt: "Notizen durchsuchen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewNote = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await store.loadNotes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .sheet(isPresented: $showNewNote) {
                NavigationStack {
                    NoteEditorView(note: nil)
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .task {
                if store.notes.isEmpty && store.errorMessage == nil {
                    await store.loadNotes()
                }
            }
        }
    }

    private func deleteNotes(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredNotes[$0] }
        Task {
            for note in toDelete {
                do {
                    try await store.deleteNote(note)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct NoteRowView: View {
    let note: Note

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: note.modifiedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if note.totalTasks > 0 {
                    Label("\(note.doneTasks)/\(note.totalTasks)", systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(note.doneTasks == note.totalTasks ? Color.accentColor : .secondary)
                }
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
