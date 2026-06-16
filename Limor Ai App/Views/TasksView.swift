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
    @State private var showNewTask = false
    @State private var section: TaskSection = .tasks
    @State private var editingTag: TagEdit?

    enum TaskSection: String, CaseIterable { case tasks, analytics }
    /// Mirror of SharedStore.tagColorHex so color changes trigger a redraw.
    @State private var tagColorOverrides: [String: String] = SharedStore.tagColorHex
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
            VStack(spacing: 0) {
                // Tasks ↔ Tag breakdown.
                Picker("", selection: $section) {
                    Text(tr("משימות", "Tasks")).tag(TaskSection.tasks)
                    Text(tr("פילוח תגיות", "Tag breakdown")).tag(TaskSection.analytics)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18).padding(.top, 8)
                .limorReadableWidth()

                if section == .analytics {
                    TaskAnalyticsView(tasks: tasks, colorFor: tagColor)
                } else if isRegular {
                    // iPad master-detail: task list on one side, live editor on
                    // the other.
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
        }
        .navigationTitle(tr("משימות", "Tasks"))
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(tr("אוקיי", "OK"), role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task) { newTitle, newTags in
                await updateTask(task, title: newTitle, tags: newTags)
            }
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(existingTags: allTags) { title, tags in await create(title: title, tags: tags) }
        }
        .sheet(item: $editingTag) { item in
            TagEditSheet(tag: item.name, currentColor: tagColor(item.name)) { newName, hex in
                await applyTagEdit(old: item.name, newName: newName, colorHex: hex)
            }
        }
    }

    /// A `List` (not a ScrollView) so open tasks reorder via the native
    /// long-press-and-drag — reliable, and it doesn't fight scrolling. Drag
    /// reorder is only offered on the full open list (no tag filter), where
    /// the order is unambiguous.
    private var listColumn: some View {
        List {
            Group {
                addBox
                if !allTags.isEmpty { tagFilterRow }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))

            if filteredOpen.isEmpty && done.isEmpty && loaded {
                LimorEmptyState(
                    icon: "checklist",
                    title: tr("אין משימות", "No tasks"),
                    subtitle: tr("הוסיפי משימה למעלה, או בקשי מלימור בצ'אט — \"תוסיפי לי משימה\".", "Add a task above, or ask Limor in chat — \"add me a task\"."),
                    iconGradient: LimorGradient.brand
                )
                .padding(.top, 30)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredOpen) { task in
                    taskRow(task)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                }
                .onMove(perform: selectedTag == nil ? moveTask : nil)

                if !done.isEmpty {
                    Text(tr("הושלמו", "Completed"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                        .padding(.top, 8)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 4, trailing: 18))
                    ForEach(done.prefix(20)) { task in
                        taskRow(task)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                            .moveDisabled(true)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .limorReadableWidth()
    }

    /// Reorder within the open list and persist the new order to the backend.
    private func moveTask(from source: IndexSet, to destination: Int) {
        var reordered = open
        reordered.move(fromOffsets: source, toOffset: destination)
        tasks = reordered + done   // keep completed tasks after the open ones
        SharedStore.cacheTasks(tasks)
        let ids = reordered.map(\.id)
        Task { try? await APIClient.shared.reorderTasks(ids: ids) }
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
                    Text(tr("בחר משימה כדי לצפות ולערוך", "Select a task to view and edit"))
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

    /// Tapping opens a modal to enter the title + tags — clearer than the old
    /// inline field (the user found that UX ambiguous).
    private var addBox: some View {
        Button {
            showNewTask = true
        } label: {
            GlassCard {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2).foregroundStyle(.limorIndigo)
                    Text(tr("משימה חדשה…", "New task…"))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.limorMuted)
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Tag filter

    private var tagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: tr("הכול", "All"), active: selectedTag == nil) { selectedTag = nil }
                ForEach(allTags, id: \.self) { tag in
                    filterChip(label: tag, active: selectedTag == tag, color: tagColor(tag)) {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    }
                    .contextMenu {
                        Button { editingTag = TagEdit(name: tag) } label: {
                            Label(tr("ערוך שם וצבע", "Edit name and color"), systemImage: "pencil")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(label: String, active: Bool, color: Color = .limorIndigo, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? .white : color)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(active ? color : color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    /// A manual override if set, else a stable distinct color derived from the
    /// tag name (same tag → same color, so the eye can track it).
    func tagColor(_ tag: String) -> Color {
        if let hex = tagColorOverrides[tag], let c = Color(hexString: hex) { return c }
        return Self.deterministicTagColor(tag)
    }

    static func deterministicTagColor(_ tag: String) -> Color {
        let palette: [Color] = [
            .limorIndigo, .limorViolet, .limorPink, .limorMint, .limorCoral,
            .limorWarning, Color(red: 0.20, green: 0.66, blue: 0.62),
            Color(red: 0.27, green: 0.32, blue: 0.55), Color(red: 0.85, green: 0.45, blue: 0.15),
        ]
        let h = abs(tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[h % palette.count]
    }

    /// Apply a tag rename (across every task that uses it) and/or color change.
    private func applyTagEdit(old: String, newName: String, colorHex: String) async {
        let new = newName.trimmingCharacters(in: .whitespaces)
        var map = SharedStore.tagColorHex
        if !new.isEmpty, new != old {
            for task in tasks where task.tags.contains(old) {
                let newTags = task.tags.map { $0 == old ? new : $0 }
                await updateTask(task, title: task.title, tags: newTags)
            }
            map.removeValue(forKey: old)
            map[new] = colorHex
            if selectedTag == old { selectedTag = new }
        } else {
            map[old] = colorHex
        }
        SharedStore.tagColorHex = map
        tagColorOverrides = map   // trigger redraw with the new colors
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
                                    .foregroundStyle(tagColor(tag))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(tagColor(tag).opacity(0.14)))
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

    /// Create a task from the modal's title + already-parsed tags.
    private func create(title: String, tags: [String]) async {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            let created = try await APIClient.shared.createTask(title: title, tags: tags)
            tasks.insert(created, at: 0)
            SharedStore.cacheTasks(tasks)
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
                        SectionLabel(icon: "checklist", title: tr("המשימות שלי", "My tasks"), tint: .limorIndigo)
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
                            Text(tr("אין משימות פתוחות", "No open tasks")).font(.caption).foregroundStyle(.secondary)
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
                            Text(tr("טוען…", "Loading…")).font(.caption).foregroundStyle(.secondary)
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
                Section(tr("משימה", "Task")) {
                    TextField(tr("כותרת", "Title"), text: $title, axis: .vertical)
                }
                Section(tr("תגיות", "Tags")) {
                    TextField(tr("מופרדות בפסיק", "Comma-separated"), text: $tagsText)
                }
            }
            .navigationTitle(tr("עריכת משימה", "Edit task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("שמור", "Save")) {
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

// MARK: - New task modal

/// Modal for creating a task — title + optional tags. Replaces the old inline
/// field, which read ambiguously.
private struct NewTaskSheet: View {
    let existingTags: [String]
    let onCreate: (String, [String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tagsText = ""
    @State private var selected: Set<String> = []
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var freeTextTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == "،" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// Final tag set — picked existing tags + any typed new ones, deduped.
    private var allTags: [String] {
        var set = selected
        for t in freeTextTags { set.insert(t) }
        return Array(set)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("משימה", "Task")) {
                    TextField(tr("מה צריך לעשות?", "What needs to be done?"), text: $title, axis: .vertical)
                        .focused($titleFocused)
                }
                Section(tr("תגיות", "Tags")) {
                    if !existingTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(existingTags, id: \.self) { tag in
                                    tagChip(tag)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    TextField(tr("תגית חדשה (מופרדות בפסיק)", "New tag (comma-separated)"), text: $tagsText)
                }
            }
            .navigationTitle(tr("משימה חדשה", "New task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("צור", "Create")) {
                        saving = true
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tags = allTags
                        Task { await onCreate(t, tags); dismiss() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium])
        .task { titleFocused = true }
    }

    private func tagChip(_ tag: String) -> some View {
        let isOn = selected.contains(tag)
        let color = TasksView.deterministicTagColor(tag)
        return Button {
            if isOn { selected.remove(tag) } else { selected.insert(tag) }
        } label: {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(tag).font(.caption.weight(.semibold))
            }
            .foregroundStyle(isOn ? .white : color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(isOn ? color : color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag editor (rename + color)

struct TagEdit: Identifiable {
    let id = UUID()
    let name: String
}

/// Edit a tag's name and color. Color is chosen from a swatch palette or a
/// full custom picker. Saving renames the tag across all tasks.
private struct TagEditSheet: View {
    let tag: String
    let currentColor: Color
    let onSave: (String, String) async -> Void   // (newName, colorHex)

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    @State private var saving = false

    private let palette: [Color] = [
        .limorIndigo, .limorViolet, .limorPink, .limorMint, .limorCoral,
        .limorWarning, Color(red: 0.20, green: 0.66, blue: 0.62),
        Color(red: 0.27, green: 0.32, blue: 0.55), Color(red: 0.85, green: 0.45, blue: 0.15),
    ]

    init(tag: String, currentColor: Color, onSave: @escaping (String, String) async -> Void) {
        self.tag = tag
        self.currentColor = currentColor
        self.onSave = onSave
        _name = State(initialValue: tag)
        _color = State(initialValue: currentColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("שם התגית", "Tag name")) {
                    TextField(tr("שם", "Name"), text: $name)
                }
                Section(tr("צבע", "Color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(palette.indices, id: \.self) { i in
                            Circle()
                                .fill(palette[i])
                                .frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(.primary.opacity(color == palette[i] ? 0.6 : 0), lineWidth: 2))
                                .onTapGesture { color = palette[i] }
                        }
                    }
                    .padding(.vertical, 4)
                    ColorPicker(tr("צבע מותאם אישית", "Custom color"), selection: $color, supportsOpacity: false)
                }
                Section {
                    HStack {
                        Text(tr("תצוגה מקדימה", "Preview")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(name.isEmpty ? tag : name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(color.opacity(0.14)))
                    }
                }
            }
            .navigationTitle(tr("עריכת תגית", "Edit tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("ביטול", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("שמור", "Save")) {
                        saving = true
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let hex = color.hexString
                        Task { await onSave(n, hex); dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
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
                        Text(task.done ? tr("החזר לפעילה", "Reopen") : tr("סמן כבוצע", "Mark as done"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(task.done ? .limorMuted : .white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(task.done ? Color.limorMuted.opacity(0.15) : Color.limorSuccess))
                }
                .buttonStyle(.plain)

                field(title: tr("כותרת", "Title")) {
                    TextField(tr("כותרת המשימה", "Task title"), text: $title, axis: .vertical)
                        .font(.body)
                }

                field(title: tr("תגיות", "Tags")) {
                    TextField(tr("מופרדות בפסיק (עבודה, בית…)", "Comma-separated (work, home…)"), text: $tagsText)
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
                        Text(saving ? tr("שומר…", "Saving…") : tr("שמור שינויים", "Save changes")).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
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
                        Text(tr("מחק משימה", "Delete task"))
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

// MARK: - Color ↔ hex (for manual tag colors)

extension Color {
    /// "#RRGGBB" → Color. Returns nil for malformed strings.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    /// "#RRGGBB" for the current resolved color.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
