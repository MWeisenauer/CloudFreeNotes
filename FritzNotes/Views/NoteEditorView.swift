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
    @State private var dragTaskID: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var rowStep: CGFloat = 36

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

            VStack(alignment: .leading, spacing: 8) {
                ForEach(draft.checklistItems) { item in
                    ChecklistRow(
                        item: item,
                        focus: $focusedTaskID,
                        isDragging: dragTaskID == item.id,
                        onToggle: { draft.toggleTask(at: item.lineIndex) },
                        onTextChange: { newText in draft.updateTaskText(at: item.lineIndex, to: newText) },
                        onDelete: { draft.removeTask(at: item.lineIndex) },
                        onDragChanged: { dy in
                            if dragTaskID == nil { dragTaskID = item.id }
                            dragOffset = dy
                        },
                        onDragEnded: { dy in
                            let steps = Int((dy / rowStep).rounded())
                            draft.moveTask(at: item.lineIndex, by: steps)
                            dragTaskID = nil
                            dragOffset = 0
                        }
                    )
                    .offset(y: dragTaskID == item.id ? dragOffset : 0)
                    .zIndex(dragTaskID == item.id ? 1 : 0)
                }
            }
            // Zeilenhoehe plus Abstand – daraus ergibt sich, um wie viele Plaetze
            // eine gezogene Aufgabe wandert.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let count = max(draft.checklistItems.count, 1)
                rowStep = (height + 8) / CGFloat(count)
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
    let isDragging: Bool
    let onToggle: () -> Void
    let onTextChange: (String) -> Void
    let onDelete: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var text: String

    init(item: ChecklistItem,
         focus: FocusState<Int?>.Binding,
         isDragging: Bool,
         onToggle: @escaping () -> Void,
         onTextChange: @escaping (String) -> Void,
         onDelete: @escaping () -> Void,
         onDragChanged: @escaping (CGFloat) -> Void,
         onDragEnded: @escaping (CGFloat) -> Void) {
        self.item = item
        self._focus = focus
        self.isDragging = isDragging
        self.onToggle = onToggle
        self.onTextChange = onTextChange
        self.onDelete = onDelete
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        _text = State(initialValue: item.text)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Griff ganz links, der Muelleimer bleibt ganz rechts – so weit
            // auseinander wie die Zeile es zulaesst.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
                // .global ist wichtig: Der Griff sitzt in der Zeile, die sich beim
                // Ziehen mitbewegt. Im lokalen Raum schrumpft die gemeldete Strecke
                // dadurch mit, und die Zeile laeuft dem Finger hinterher.
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { onDragEnded($0.translation.height) }
                )
                .accessibilityLabel("Aufgabe verschieben")

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
                // Nach dem Loeschen oder Verschieben rutschen die Zeilen und SwiftUI
                // verwendet die Ansichten wieder; ohne das hier bliebe der alte Text stehen.
                .onChange(of: item.text) { _, newValue in
                    if newValue != text { text = newValue }
                }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDragging ? Color.secondary.opacity(0.15) : Color.clear)
        )
    }
}
