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
    @FocusState private var addFocused: Bool

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
            }
        }
        .navigationTitle("משימות")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .alert("שגיאה", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("אוקיי", role: .cancel) {} } message: { Text(errorMessage ?? "") }
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
