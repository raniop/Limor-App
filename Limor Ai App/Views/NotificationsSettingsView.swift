import SwiftUI

/// Manage daily notification preferences — a master toggle plus a per-preset
/// toggle + time picker. Saves to backend on every change (debounced).
struct NotificationsSettingsView: View {
    @State private var doc: NotificationPrefsDoc = NotificationPrefsDoc(
        master_enabled: true,
        prefs: NotificationKind.allCases.map {
            NotificationPref(kind: $0, enabled: false, hour: 8, minute: 0, last_sent_date: nil)
        }
    )
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    masterCard
                    ForEach(Array(doc.prefs.enumerated()), id: \.element.kind) { index, _ in
                        presetCard(index: index)
                            .opacity(doc.master_enabled ? 1 : 0.55)
                            .disabled(!doc.master_enabled)
                    }
                    footerText
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }

            if loading {
                ProgressView().scaleEffect(1.2)
            }
        }
        .navigationTitle("התראות יומיות")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("שגיאה", isPresented: .init(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("אוקיי", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    // MARK: - Cards

    private var masterCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.limorIndigo.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: "bell.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.limorIndigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("התראות פעילות")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Text(doc.master_enabled ? "הקבלת התראות יומיות מופעלת" : "כל ההתראות מושתקות")
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { doc.master_enabled },
                set: { newValue in
                    doc.master_enabled = newValue
                    scheduleSave()
                }
            ))
            .labelsHidden()
            .tint(.limorIndigo)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorIndigo.opacity(0.20), lineWidth: 0.6)
        )
    }

    private func presetCard(index: Int) -> some View {
        let pref = doc.prefs[index]
        let style = displayStyle(for: pref.kind)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(style.tint.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: style.icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(style.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text(style.subtitle)
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { doc.prefs[index].enabled },
                    set: { newValue in
                        doc.prefs[index].enabled = newValue
                        scheduleSave()
                    }
                ))
                .labelsHidden()
                .tint(style.tint)
            }

            if pref.enabled {
                Divider().opacity(0.4)
                HStack {
                    Text("שעת שליחה")
                        .font(.subheadline)
                        .foregroundStyle(.limorInk)
                    Spacer()
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { date(hour: pref.hour, minute: pref.minute) },
                            set: { newDate in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                doc.prefs[index].hour = comps.hour ?? 8
                                doc.prefs[index].minute = comps.minute ?? 0
                                scheduleSave()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorMuted.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var footerText: some View {
        Text("שעות בעיתוי מקומי (Asia/Jerusalem). אם השרת לא היה זמין בשעה שנקבעה — ההתראה תישלח ברגע שניתן באותו יום.")
            .font(.caption2)
            .foregroundStyle(.limorMuted)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    // MARK: - Helpers

    private func date(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    private struct DisplayStyle {
        let title: String
        let subtitle: String
        let icon: String
        let tint: Color
    }

    private func displayStyle(for kind: NotificationKind) -> DisplayStyle {
        switch kind {
        case .morning_brief:
            return DisplayStyle(
                title: "בוקר טוב",
                subtitle: "מה ביומן היום ותזכורות פתוחות",
                icon: "sun.max.fill",
                tint: .limorWarning
            )
        case .evening_recap:
            return DisplayStyle(
                title: "סיכום ערב",
                subtitle: "צעדים, יומן מחר ותזכורות פתוחות",
                icon: "moon.fill",
                tint: .limorViolet
            )
        case .feed_digest:
            return DisplayStyle(
                title: "הפיד של הבוקר",
                subtitle: "הכותרות העיקריות מהפיד שלך",
                icon: "newspaper.fill",
                tint: .limorIndigo
            )
        }
    }

    // MARK: - Networking

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            doc = try await APIClient.shared.notificationPrefs()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Debounce saves so dragging the time-picker doesn't fire a POST per
    /// minute. Flushes 400ms after the last change.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await persist()
        }
    }

    private func persist() async {
        saving = true
        defer { saving = false }
        do {
            doc = try await APIClient.shared.saveNotificationPrefs(doc)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
