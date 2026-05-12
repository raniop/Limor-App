import SwiftUI
import UIKit

struct RemindersView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var reminders: [Reminder] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingNew = false
    /// When non-nil, the edit sheet is open for this reminder — same
    /// `NewReminderSheet` UI, just pre-filled with the current task +
    /// due time so the user can tweak either.
    @State private var editingReminder: Reminder?

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let successHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView(showsIndicators: false) {
                    if reminders.isEmpty && !isLoading {
                        VStack {
                            Spacer(minLength: 40)
                            LimorEmptyState(
                                icon: "bell.badge",
                                title: "אין תזכורות פעילות",
                                subtitle: "לחצי על + למעלה כדי להוסיף תזכורת חדשה, או בקשי מלימור בצ'אט.",
                                iconGradient: LimorGradient.brand
                            )
                        }
                    } else {
                        VStack(spacing: 14) {
                            heroNext
                            ForEach(sections, id: \.title) { section in
                                ReminderSection(
                                    section: section,
                                    onComplete: { r in await complete(r) },
                                    onDelete: { r in await remove(r) },
                                    onSnooze: { r, m in await snooze(r, minutes: m) },
                                    onEdit: { r in editingReminder = r }
                                )
                            }

                            if !completed.isEmpty {
                                ReminderSection(
                                    section: .init(
                                        title: "הושלמו",
                                        icon: "checkmark.seal.fill",
                                        tint: .limorSuccess,
                                        reminders: Array(completed.prefix(20))
                                    ),
                                    onComplete: { _ in },
                                    onDelete: { r in await remove(r) },
                                    onSnooze: { _, _ in },
                                    onEdit: { _ in },
                                    showActions: false
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("תזכורות")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: RecurringRemindersView()) {
                        Image(systemName: "alarm")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.limorIndigo)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.limorIndigo.opacity(0.12)))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(LimorGradient.brand))
                            .shadow(color: Color.limorIndigo.opacity(0.4), radius: 10, y: 4)
                    }
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
            .sheet(isPresented: $showingNew) {
                NewReminderSheet(initial: nil) { task, dueAt in
                    await create(task: task, dueAt: dueAt)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingReminder) { r in
                NewReminderSheet(initial: r) { task, dueAt in
                    await update(r, task: task, dueAt: dueAt)
                }
                .presentationDetents([.medium, .large])
            }
            .alert("שגיאה", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("אוקיי", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Sections

    struct Section {
        let title: String
        let icon: String
        let tint: Color
        let reminders: [Reminder]
    }

    private var pending: [Reminder] {
        reminders.filter { $0.status == .pending }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private var completed: [Reminder] {
        reminders.filter { $0.status == .completed }
            .sorted { ($0.completed_at ?? "") > ($1.completed_at ?? "") }
    }

    private var heroNext: some View {
        Group {
            if let next = pending.first {
                HeroCountdownCard(reminder: next)
            } else {
                EmptyView()
            }
        }
    }

    private var sections: [Section] {
        let now = Date()
        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600 - 1)
        let endOfWeek = now.addingTimeInterval(7 * 24 * 3600)

        let overdue = pending.filter { $0.isOverdue }
        let next30 = pending.filter { !$0.isOverdue && $0.dueDate.timeIntervalSince(now) <= 30 * 60 }
        let today = pending.filter { !$0.isOverdue && $0.dueDate > now.addingTimeInterval(30 * 60) && $0.dueDate <= endOfToday }
        let thisWeek = pending.filter { $0.dueDate > endOfToday && $0.dueDate <= endOfWeek }
        let later = pending.filter { $0.dueDate > endOfWeek }

        return [
            Section(title: "🔥 דחוף — באיחור", icon: "exclamationmark.triangle.fill", tint: .limorDanger, reminders: overdue),
            Section(title: "⚡ ב־30 הדקות הקרובות", icon: "bolt.fill", tint: .limorWarning, reminders: next30),
            Section(title: "📅 היום", icon: "calendar", tint: .limorIndigo, reminders: today),
            Section(title: "🗓️ השבוע", icon: "calendar.badge.clock", tint: .limorViolet, reminders: thisWeek),
            Section(title: "📦 בעתיד", icon: "tray", tint: .limorMuted, reminders: later),
        ].filter { !$0.reminders.isEmpty }
    }

    // MARK: Backend ops

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let raw = try await APIClient.shared.listReminders(token: auth.token ?? "")
            reminders = Self.dedupePendingDuplicates(raw)
            // Mirror chat-created reminders to iOS Reminders too (idempotent).
            await RemindersWriter.shared.mirrorAll(reminders)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Hide pending reminders that have the same task + due-minute as an
    /// earlier-created one. Backend safety net — the chat backend has been
    /// observed to create the same reminder twice for a single user
    /// message (Claude calling the create_reminder tool more than once
    /// per response). Until that's fixed server-side, this keeps the
    /// list visually clean. Completed reminders pass through unchanged
    /// so the user can still see their history.
    private static func dedupePendingDuplicates(_ list: [Reminder]) -> [Reminder] {
        let sortedByCreated = list.sorted { $0.created_at < $1.created_at }
        var seen: Set<String> = []
        var keep: Set<String> = []
        for r in sortedByCreated {
            if r.status == .completed {
                keep.insert(r.id)
                continue
            }
            let normalized = r.task
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let dueMinute = Int(r.dueDate.timeIntervalSince1970 / 60)
            let key = "\(normalized)|\(dueMinute)"
            if seen.insert(key).inserted {
                keep.insert(r.id)
            }
        }
        // Preserve the server's original order — the API decides the
        // sort, this filter just drops duplicates.
        return list.filter { keep.contains($0.id) }
    }

    private func create(task: String, dueAt: Date) async {
        successHaptic.notificationOccurred(.success)
        do {
            let created = try await APIClient.shared.createReminder(token: auth.token ?? "", task: task, dueAt: dueAt)
            // Insert immediately into the local list — no extra round-trip needed.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                reminders.insert(created, at: 0)
            }
            // Mirror to iOS Reminders.app (best-effort, in background).
            Task {
                await RemindersWriter.shared.writeIfNeeded(
                    reminderId: created.id, task: created.task, dueAt: created.dueDate
                )
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Optimistic complete: flip the status locally + haptic immediately, then
    /// fire the network request in the background. Rolls back on failure.
    private func complete(_ r: Reminder) async {
        successHaptic.notificationOccurred(.success)
        applyLocalUpdate(id: r.id) { current in
            Reminder(
                id: current.id,
                task: current.task,
                due_at: current.due_at,
                status: .completed,
                created_at: current.created_at,
                completed_at: ISO8601DateFormatter.limor.string(from: Date()),
                msUntilDue: current.msUntilDue,
                isOverdue: false
            )
        }
        do {
            _ = try await APIClient.shared.completeReminder(token: auth.token ?? "", id: r.id)
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    private func snooze(_ r: Reminder, minutes: Int) async {
        lightImpact.impactOccurred()
        let newDue = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        applyLocalUpdate(id: r.id) { current in
            Reminder(
                id: current.id,
                task: current.task,
                due_at: ISO8601DateFormatter.limor.string(from: newDue),
                status: current.status,
                created_at: current.created_at,
                completed_at: current.completed_at,
                msUntilDue: newDue.timeIntervalSinceNow * 1000,
                isOverdue: false
            )
        }
        do {
            _ = try await APIClient.shared.snoozeReminder(token: auth.token ?? "", id: r.id, minutes: minutes)
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// Optimistic edit: patch the local copy + ship the change to
    /// backend in the background. Rolls back on failure (full reload).
    /// Only the fields the user actually changed get sent — keeps the
    /// payload tiny and avoids accidentally clobbering server-side
    /// fields we didn't touch.
    private func update(_ original: Reminder, task: String, dueAt: Date) async {
        lightImpact.impactOccurred()
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskChanged = trimmedTask != original.task && !trimmedTask.isEmpty
        let dueChanged = abs(dueAt.timeIntervalSince(original.dueDate)) > 30
        guard taskChanged || dueChanged else { return }

        applyLocalUpdate(id: original.id) { current in
            Reminder(
                id: current.id,
                task: taskChanged ? trimmedTask : current.task,
                due_at: dueChanged ? ISO8601DateFormatter.limor.string(from: dueAt) : current.due_at,
                status: current.status,
                created_at: current.created_at,
                completed_at: current.completed_at,
                msUntilDue: dueChanged ? dueAt.timeIntervalSinceNow * 1000 : current.msUntilDue,
                isOverdue: dueChanged ? dueAt < Date() : current.isOverdue
            )
        }
        do {
            _ = try await APIClient.shared.updateReminder(
                id: original.id,
                task: taskChanged ? trimmedTask : nil,
                dueAt: dueChanged ? dueAt : nil
            )
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    private func remove(_ r: Reminder) async {
        lightImpact.impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            reminders.removeAll { $0.id == r.id }
        }
        do {
            try await APIClient.shared.deleteReminder(token: auth.token ?? "", id: r.id)
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// Replace a reminder in the local array with an updated version, animated.
    private func applyLocalUpdate(id: String, _ transform: (Reminder) -> Reminder) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        let updated = transform(reminders[idx])
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            reminders[idx] = updated
        }
    }
}

// MARK: - Hero Countdown

private struct HeroCountdownCard: View {
    let reminder: Reminder

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(reminder.isOverdue ? LimorGradient.warm : LimorGradient.brand)
                .shadow(color: (reminder.isOverdue ? Color.limorCoral : Color.limorIndigo).opacity(0.35), radius: 22, y: 12)

            Circle()
                .fill(.white.opacity(0.15))
                .frame(width: 200, height: 200)
                .offset(x: 100, y: -60)
                .blur(radius: 20)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(reminder.isOverdue ? "באיחור" : "התזכורת הקרובה",
                          systemImage: reminder.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(reminder.dueDate, style: .time)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                .foregroundStyle(.white.opacity(0.95))

                Text(reminder.task)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                    Text(reminder.dueDate, style: .relative)
                        .monospacedDigit()
                }
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 170)
    }
}

// MARK: - Section

private struct ReminderSection: View {
    let section: RemindersView.Section
    let onComplete: (Reminder) async -> Void
    let onDelete: (Reminder) async -> Void
    let onSnooze: (Reminder, Int) async -> Void
    let onEdit: (Reminder) -> Void
    var showActions: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: section.icon).font(.subheadline.weight(.semibold))
                Text(section.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(section.reminders.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(section.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(section.tint.opacity(0.15)))
            }
            .foregroundStyle(section.tint)
            .padding(.horizontal, 4)
            .padding(.top, 6)

            VStack(spacing: 8) {
                ForEach(section.reminders) { r in
                    ReminderCard(
                        reminder: r,
                        showActions: showActions,
                        onComplete: { await onComplete(r) },
                        onSnooze: { m in await onSnooze(r, m) },
                        onDelete: { await onDelete(r) },
                        onEdit: { onEdit(r) }
                    )
                }
            }
        }
    }
}

// MARK: - Card

private struct ReminderCard: View {
    let reminder: Reminder
    let showActions: Bool
    let onComplete: () async -> Void
    let onSnooze: (Int) async -> Void
    let onDelete: () async -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showActions {
                Button {
                    Task { await onComplete() }
                } label: {
                    Image(systemName: "circle")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(reminder.isOverdue ? Color.limorDanger : Color.limorIndigo)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.limorSuccess)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.task)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .strikethrough(reminder.status == .completed)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2)
                    Text(reminder.dueDate, style: .relative)
                        .font(.caption.monospacedDigit())
                    Text("•").font(.caption)
                    Text(reminder.dueDate, style: .time).font(.caption.monospacedDigit())
                }
                .foregroundStyle(reminder.isOverdue ? Color.limorDanger : .secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.4), lineWidth: 0.5)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await onDelete() }
            } label: { Label("מחק", systemImage: "trash") }
        }
        .contextMenu {
            if showActions {
                Button { onEdit() } label: {
                    Label("ערוך", systemImage: "pencil")
                }
                Button {
                    Task { await onComplete() }
                } label: { Label("סמן כבוצע", systemImage: "checkmark") }
                Menu {
                    Button("10 דקות") { Task { await onSnooze(10) } }
                    Button("30 דקות") { Task { await onSnooze(30) } }
                    Button("שעה") { Task { await onSnooze(60) } }
                    Button("3 שעות") { Task { await onSnooze(180) } }
                } label: { Label("דחה ל…", systemImage: "alarm") }
            }
            Button(role: .destructive) {
                Task { await onDelete() }
            } label: { Label("מחק", systemImage: "trash") }
        }
        // Single tap opens the edit sheet — bare scrolls still scroll
        // because the swipe action and context menu both intercept
        // long-press; this leaves room for the tap intent.
        .onTapGesture {
            if showActions { onEdit() }
        }
    }
}

// MARK: - New Reminder Sheet

private struct NewReminderSheet: View {
    /// When non-nil the sheet runs in EDIT mode — pre-fills the task
    /// and due time from the existing reminder and changes the title +
    /// save-button copy. Same form, two callers.
    let initial: Reminder?
    let onSubmit: (String, Date) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var task: String
    @State private var dueAt: Date
    @State private var isSubmitting = false

    init(initial: Reminder?, onSubmit: @escaping (String, Date) async -> Void) {
        self.initial = initial
        self.onSubmit = onSubmit
        _task = State(initialValue: initial?.task ?? "")
        _dueAt = State(initialValue: initial?.dueDate ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(icon: "text.alignright", title: "מה לזכור?")
                            TextField("לדוגמה: להתקשר לאמא", text: $task, axis: .vertical)
                                .lineLimit(2...5)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.regularMaterial)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(.white.opacity(0.5), lineWidth: 0.5)
                                )
                                .font(.body.weight(.medium))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(icon: "calendar.badge.clock", title: "מתי?")

                            HStack(spacing: 8) {
                                QuickPick(label: "+10 דקות") { dueAt = Date().addingTimeInterval(10*60) }
                                QuickPick(label: "+שעה") { dueAt = Date().addingTimeInterval(3600) }
                                QuickPick(label: "+3 שעות") { dueAt = Date().addingTimeInterval(3*3600) }
                                QuickPick(label: "מחר") {
                                    var c = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
                                    c.hour = 9; c.minute = 0
                                    dueAt = Calendar.current.date(from: c) ?? Date().addingTimeInterval(86400)
                                }
                            }

                            // Allow past times when editing — useful for
                            // fixing a misparsed "quarter to 4" that
                            // landed in the future as "quarter to 5".
                            DatePicker("", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.graphical)
                                .environment(\.locale, Locale(identifier: "he_IL"))
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.regularMaterial)
                                )
                        }

                        Button {
                            Task {
                                isSubmitting = true
                                await onSubmit(task.trimmingCharacters(in: .whitespacesAndNewlines), dueAt)
                                isSubmitting = false
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Image(systemName: initial == nil ? "bell.badge.fill" : "checkmark.circle.fill")
                                Text(initial == nil ? "שמור תזכורת" : "עדכן תזכורת")
                            }
                        }
                        .buttonStyle(.limorPrimary)
                        .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                        .padding(.top, 6)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(initial == nil ? "תזכורת חדשה" : "עריכת תזכורת")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                        .foregroundStyle(.limorMuted)
                }
            }
        }
    }
}

private struct QuickPick: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorIndigo)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                .overlay(Capsule().stroke(Color.limorIndigo.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
