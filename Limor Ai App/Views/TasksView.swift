import SwiftUI

/// Free-form to-do list (no times, unlike Reminders). Tasks carry free-text
/// tags for grouping/filtering. Backed by `/api/tasks`; Limor can add/complete
/// them via her tools, and the result shows here + in the home card + widget.
struct TasksView: View {
    @State private var tasks: [LimorTask] = []
    @State private var loaded = false
    @State private var newTitle = ""
    @State private var newTags = ""
    @State private var selectedTag: String?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var editingTask: LimorTask?
    @State private var selectedTaskId: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var addFocused: Bool

    private var isRegular: Bool { hSizeClass == .regular }

    private var open: [LimorTask] { tasks.filter { !$0.done } }
    private var done: [LimorTask] { tasks.filter { $0.done } }
    private var allTags: [String] {
        Array(Set(open.flatMap { $0.tags })).sorted()
    }
    private var filteredOpen: [LimorTask] {
        guard let tag = selectedTag else { return open }
        return open.filter { $0.tags.contains(tag) }
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()
            if isRegular {
                // iPad master-detail: task list on one side, live editor on the
                // other.
                HStack(spacing: 0) {
                    listColumn
                        .frame(maxWidth: .infinity)
                    Divider()
                    detailColumn
                        .frame(width: 420)
                }
            } else {
                listColumn
            }
        }
        .navigationTitle("משימות")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .alert("שגיאה", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("אוקיי", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task) { newTitle, newTags in
                await updateTask(task, title: newTitle, tags: newTags)
            }
        }
    }

    private var listColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                addBox
                if !allTags.isEmpty { tagFilterRow }

                if filteredOpen.isEmpty && done.isEmpty && loaded {
                    LimorEmptyState(
                        icon: "checklist",
                        title: "אין משימות",
                        subtitle: "הוסיפי משימה למעלה, או בקשי מלימור בצ'אט — \"תוסיפי לי משימה\".",
                        iconGradient: LimorGradient.brand
                    )
                    .padding(.top, 30)
                } else {
                    ForEach(filteredOpen) { task in
                        taskRow(task)
                    }
                    if !done.isEmpty {
                        Text("הושלמו")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                            .padding(.top, 8)
                        ForEach(done.prefix(20)) { task in
                            taskRow(task)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .limorReadableWidth()
        }
    }

    // MARK: Detail column (iPad)

    @ViewBuilder private var detailColumn: some View {
        ZStack {
            LiquidBackdrop()
            if let id = selectedTaskId, let task = tasks.first(where: { $0.id == id }) {
                TaskDetailPane(
                    task: task,
                    onSave: { t, tags in await updateTask(task, title: t, tags: tags) },
                    onToggleDone: { await toggle(task) },
                    onDelete: {
                        await remove(task)
                        selectedTaskId = nil
                    }
                )
                .id(task.id)   // rebuild the editor when the selection changes
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.limorMuted)
                    Text("בחר משימה כדי לצפות ולערוך")
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                }
            }
        }
    }

    private func updateTask(_ task: LimorTask, title: String, tags: [String]) async {
        do {
            let updated = try await APIClient.shared.updateTask(id: task.id, title: title, tags: tags)
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Add box

    private var addBox: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("משימה חדשה…", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($addFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                    Button {
                        Task { await add() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? Color.limorMuted : Color.limorIndigo)
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                TextField("תגיות (מופרדות בפסיק, אופציונלי)", text: $newTags)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
            }
        }
    }

    // MARK: Tag filter

    private var tagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "הכול", active: selectedTag == nil) { selectedTag = nil }
                ForEach(allTags, id: \.self) { tag in
                    filterChip(label: tag, active: selectedTag == tag) {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(label: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? .white : .limorIndigo)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(active ? Color.limorIndigo : Color.limorIndigo.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Task row

    private func taskRow(_ task: LimorTask) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    Task { await toggle(task) }
                } label: {
                    Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(task.done ? Color.limorSuccess : Color.limorMuted)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(task.done ? .limorMuted : .limorInk)
                        .strikethrough(task.done, color: .limorMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !task.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(task.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.limorViolet)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.limorViolet.opacity(0.12)))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // iPad → select into the side editor; iPhone → edit sheet.
                    if isRegular { selectedTaskId = task.id } else { editingTask = task }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await remove(task) }
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorIndigo, lineWidth: 2)
                .opacity(isRegular && selectedTaskId == task.id ? 1 : 0)
        )
    }

    // MARK: Data

    private func load() async {
        do {
            tasks = try await APIClient.shared.listTasks(status: "all")
            SharedStore.cacheTasks(tasks)
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            loaded = true
        }
    }

    private func parseTags(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "،" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func add() async {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let tags = parseTags(newTags)
        do {
            let created = try await APIClient.shared.createTask(title: title, tags: tags)
            tasks.insert(created, at: 0)
            SharedStore.cacheTasks(tasks)
            newTitle = ""; newTags = ""
            addFocused = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ task: LimorTask) async {
        do {
            let updated = task.done
                ? try await APIClient.shared.reopenTask(id: task.id)
                : try await APIClient.shared.completeTask(id: task.id)
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = updated }
            SharedStore.cacheTasks(tasks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ task: LimorTask) async {
        do {
            try await APIClient.shared.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
            SharedStore.cacheTasks(tasks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Home card

/// Compact home-screen card: open-task count + the first few titles, taps
/// through to the full TasksView.
struct TasksCard: View {
    @State private var tasks: [LimorTask] = []
    @State private var loadedOnce = false

    private var open: [LimorTask] { tasks.filter { !$0.done } }

    var body: some View {
        NavigationLink(destination: TasksView()) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(icon: "checklist", title: "המשימות שלי", tint: .limorIndigo)
                        Spacer()
                        if open.count > 0 {
                            Text("\(open.count)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.limorIndigo)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                        }
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }
                    if open.isEmpty && loadedOnce {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.limorSuccess)
                            Text("אין משימות פתוחות").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !open.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(open.prefix(3)) { task in
                                HStack(spacing: 10) {
                                    Image(systemName: "circle").font(.caption2).foregroundStyle(.limorMuted)
                                    Text(task.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.limorInk)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(.limorIndigo).scaleEffect(0.7)
                            Text("טוען…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { await load() }
    }

    private func load() async {
        // Cached first for instant paint, then refresh from the backend.
        let cached = SharedStore.loadTasks()
        if !cached.isEmpty { tasks = cached }
        if let fresh = try? await APIClient.shared.listTasks(status: "all") {
            tasks = fresh
            SharedStore.cacheTasks(fresh)
        }
        loadedOnce = true
    }
}

// MARK: - Edit sheet

private struct TaskEditSheet: View {
    let task: LimorTask
    let onSave: (String, [String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tagsText: String
    @State private var saving = false

    init(task: LimorTask, onSave: @escaping (String, [String]) async -> Void) {
        self.task = task
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _tagsText = State(initialValue: task.tags.joined(separator: ", "))
    }

    private var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == "،" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("משימה") {
                    TextField("כותרת", text: $title, axis: .vertical)
                }
                Section("תגיות") {
                    TextField("מופרדות בפסיק", text: $tagsText)
                }
            }
            .navigationTitle("עריכת משימה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמור") {
                        saving = true
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tags = parsedTags
                        Task {
                            await onSave(t, tags)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium])
    }
}

// MARK: - iPad detail editor pane

private struct TaskDetailPane: View {
    let task: LimorTask
    let onSave: (String, [String]) async -> Void
    let onToggleDone: () async -> Void
    let onDelete: () async -> Void

    @State private var title: String
    @State private var tagsText: String
    @State private var saving = false

    init(task: LimorTask,
         onSave: @escaping (String, [String]) async -> Void,
         onToggleDone: @escaping () async -> Void,
         onDelete: @escaping () async -> Void) {
        self.task = task
        self.onSave = onSave
        self.onToggleDone = onToggleDone
        self.onDelete = onDelete
        _title = State(initialValue: task.title)
        _tagsText = State(initialValue: task.tags.joined(separator: ", "))
    }

    private var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == "،" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var dirty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != task.title || parsedTags != task.tags
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    Task { await onToggleDone() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: task.done ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                        Text(task.done ? "החזר לפעילה" : "סמן כבוצע")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(task.done ? .limorMuted : .white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(task.done ? Color.limorMuted.opacity(0.15) : Color.limorSuccess))
                }
                .buttonStyle(.plain)

                field(title: "כותרת") {
                    TextField("כותרת המשימה", text: $title, axis: .vertical)
                        .font(.body)
                }

                field(title: "תגיות") {
                    TextField("מופרדות בפסיק (עבודה, בית…)", text: $tagsText)
                        .font(.subheadline)
                }

                if !parsedTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(parsedTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.limorViolet)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.limorViolet.opacity(0.12)))
                        }
                    }
                }

                Button {
                    saving = true
                    Task {
                        await onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), parsedTags)
                        saving = false
                    }
                } label: {
                    HStack { Spacer()
                        Text(saving ? "שומר…" : "שמור שינויים").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer() }
                    .padding(.vertical, 12)
                    .background(Capsule().fill(dirty ? AnyShapeStyle(LimorGradient.brand) : AnyShapeStyle(Color.limorMuted.opacity(0.4))))
                }
                .buttonStyle(.plain)
                .disabled(!dirty || saving)

                Divider().opacity(0.4)

                Button(role: .destructive) {
                    Task { await onDelete() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("מחק משימה")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.limorDanger)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private func field<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.limorMuted)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        }
    }
}
