import SwiftUI

struct NoteEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Note?
    @State private var title: String
    @State private var draft: Note
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showFreeText: Bool = false
    @FocusState private var focusedTaskID: Int?
    @FocusState private var freeTextFocused: Bool

    private var freeText: String {
        draft.body.components(separatedBy: "\n")
            .filter { ChecklistParser.parse(line: $0) == nil }
            .joined(separator: "\n")
    }

    private var freeTextBinding: Binding<String> {
        Binding(
            get: { freeText },
            set: { newValue in
                let checklistLines = draft.body.components(separatedBy: "\n")
                    .filter { ChecklistParser.parse(line: $0) != nil }
                if checklistLines.isEmpty {
                    draft.body = newValue
                } else if newValue.isEmpty {
                    draft.body = checklistLines.joined(separator: "\n")
                } else {
                    draft.body = newValue + "\n" + checklistLines.joined(separator: "\n")
                }
            }
        )
    }

    init(note: Note?) {
        self.existing = note
        _title = State(initialValue: note?.title ?? "")
        _draft = State(initialValue: note ?? Note())
    }

    private var hasChanges: Bool {
        title != (existing?.title ?? "") || draft.body != (existing?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Titel", text: $title)
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let hasTasks = !draft.checklistItems.isEmpty
                    let showText = !hasTasks || !freeText.isEmpty || showFreeText
                    if showText {
                        TextEditor(text: freeTextBinding)
                            .frame(minHeight: hasTasks ? 100 : 200)
                            .padding(.horizontal, 4)
                            .focused($freeTextFocused)
                    }
                    if hasTasks {
                        if showText { Divider() }
                        checklistSection
                    }
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
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
                .disabled(isSaving || (title.isEmpty && draft.body.isEmpty) || !hasChanges)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    addNewTask()
                } label: {
                    Label("Aufgabe", systemImage: "checklist")
                }
                Button {
                    addFreeText()
                } label: {
                    Label("Text", systemImage: "text.alignleft")
                }
                Spacer()
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

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aufgaben")
                    .font(.headline)
                Spacer()
                Text("\(draft.doneTasks)/\(draft.totalTasks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    addNewTask()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }

            ForEach(draft.checklistItems) { item in
                ChecklistRow(
                    item: item,
                    focus: $focusedTaskID,
                    onToggle: { draft.toggleTask(at: item.lineIndex) },
                    onTextChange: { newText in draft.updateTaskText(at: item.lineIndex, to: newText) },
                    onDelete: { draft.removeTask(at: item.lineIndex) }
                )
            }
        }
    }

    private func addNewTask() {
        draft.appendTask("")
        DispatchQueue.main.async {
            focusedTaskID = draft.checklistItems.last?.id
        }
    }

    private func addFreeText() {
        showFreeText = true
        focusedTaskID = nil
        DispatchQueue.main.async {
            freeTextFocused = true
        }
    }

    private func save() async {
        isSaving = true
        var note = existing ?? Note()
        note.title = title
        note.body  = draft.body
        do {
            try await store.saveNote(note)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem
    @FocusState.Binding var focus: Int?
    let onToggle: () -> Void
    let onTextChange: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String

    init(item: ChecklistItem, focus: FocusState<Int?>.Binding, onToggle: @escaping () -> Void, onTextChange: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self._focus = focus
        self.onToggle = onToggle
        self.onTextChange = onTextChange
        self.onDelete = onDelete
        _text = State(initialValue: item.text)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            TextField("Aufgabe", text: $text)
                .focused($focus, equals: item.id)
                .strikethrough(item.isDone, color: .secondary)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .onChange(of: text) { _, newValue in onTextChange(newValue) }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
