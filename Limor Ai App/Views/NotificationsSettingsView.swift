import AVFoundation
import SwiftUI
import UserNotifications

/// Manage daily notification preferences — a master toggle plus a per-preset
/// toggle + time picker. Server-side presets (morning_brief etc.) save to
/// backend on every change (debounced). The "meetings tomorrow" card at
/// the bottom is a LOCAL notification — scheduled via UNUserNotificationCenter
/// without any backend dependency.
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
    /// Holds the preview player so it isn't deallocated mid-sound.
    @State private var soundPreviewPlayer: AVAudioPlayer?

    // Local-only "tomorrow's meetings" notification — fired on-device, not
    // via the backend. Backed directly by SharedStore so the user's pick
    // survives reinstalls and is readable by other parts of the app.
    @State private var meetingsNotifEnabled: Bool = SharedStore.meetingsNotifEnabled
    @State private var meetingsNotifHour: Int = SharedStore.meetingsNotifHour
    @State private var meetingsNotifMinute: Int = SharedStore.meetingsNotifMinute

    // Local-only "2 hours before" heads-up for meetings + reminders,
    // scheduled on-device by LeadTimeNotifier. Defaults to ON.
    @State private var leadNotifEnabled: Bool = SharedStore.leadTimeNotifEnabled
    // "Time to leave" departure alerts for meetings with an address.
    @State private var departureNotifEnabled: Bool = SharedStore.departureNotifEnabled

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    masterCard
                    soundCard
                    ForEach(Array(doc.prefs.enumerated()), id: \.element.kind) { index, _ in
                        presetCard(index: index)
                            .opacity(doc.master_enabled ? 1 : 0.55)
                            .disabled(!doc.master_enabled)
                    }
                    localSectionHeader
                    meetingsLocalCard
                    leadNotifCard
                    departureNotifCard
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

    // MARK: - Local "tomorrow's meetings" notification (on-device, no backend)

    private var localSectionHeader: some View {
        HStack {
            Text("התראות מקומיות")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.limorMuted)
            Spacer()
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    private var meetingsLocalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.limorIndigo.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: "calendar.badge.clock")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("הפגישות של מחר")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text("התראה אחת בערב עם הפגישות שלך ליום הבא")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { meetingsNotifEnabled },
                    set: { newValue in
                        meetingsNotifEnabled = newValue
                        SharedStore.meetingsNotifEnabled = newValue
                        Task {
                            if newValue {
                                // First-time enable — ask iOS for permission.
                                // No-op if already granted/denied.
                                _ = try? await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                            }
                            await MeetingsNotifier.reschedule()
                        }
                    }
                ))
                .labelsHidden()
                .tint(.limorIndigo)
            }

            if meetingsNotifEnabled {
                Divider().opacity(0.4)
                HStack {
                    Text("שעת שליחה")
                        .font(.subheadline)
                        .foregroundStyle(.limorInk)
                    Spacer()
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { date(hour: meetingsNotifHour, minute: meetingsNotifMinute) },
                            set: { newDate in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                meetingsNotifHour = c.hour ?? 21
                                meetingsNotifMinute = c.minute ?? 0
                                SharedStore.meetingsNotifHour = meetingsNotifHour
                                SharedStore.meetingsNotifMinute = meetingsNotifMinute
                                Task { await MeetingsNotifier.reschedule() }
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

    private var leadNotifCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.limorIndigo.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "clock.badge.exclamationmark.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("שעתיים לפני")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text("התראה שעתיים לפני כל פגישה ותזכורת · אפשר לדחות בשעה")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { leadNotifEnabled },
                    set: { newValue in
                        leadNotifEnabled = newValue
                        SharedStore.leadTimeNotifEnabled = newValue
                        Task {
                            if newValue {
                                _ = try? await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                            }
                            await LeadTimeNotifier.reschedule()
                        }
                    }
                ))
                .labelsHidden()
                .tint(.limorIndigo)
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

    private var departureNotifCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.limorIndigo.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "car.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("זמן לצאת")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text("לפגישה עם כתובת — התראה מתי לצאת לפי זמן הנסיעה בפועל")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { departureNotifEnabled },
                    set: { newValue in
                        departureNotifEnabled = newValue
                        SharedStore.departureNotifEnabled = newValue
                        Task {
                            if newValue {
                                _ = try? await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                            }
                            await DepartureNotifier.reschedule(force: true)
                        }
                    }
                ))
                .labelsHidden()
                .tint(.limorIndigo)
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

    // MARK: Sound picker (global)

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.limorIndigo.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: "bell.badge.waveform.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("צליל ההתראות")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text("הצליל שיתנגן בכל ההתראות מלימור — תזכורות, פגישות והתראות יומיות")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(2)
                }
                Spacer()
            }
            Divider().opacity(0.4)
            soundOptionRow(sound: nil, label: "ברירת מחדל")
            ForEach(ReminderSound.allCases) { s in
                soundOptionRow(sound: s, label: s.displayName)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorMuted.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func soundOptionRow(sound: ReminderSound?, label: String) -> some View {
        let selected = doc.sound == sound?.fileName
        return Button {
            selectSound(sound)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? Color.limorIndigo : Color.limorMuted)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.limorInk)
                Spacer()
                if sound != nil {
                    Image(systemName: "play.circle")
                        .font(.body)
                        .foregroundStyle(.limorMuted)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
                title: "חדשות הבוקר",
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
            // Mirror the server's chosen sound locally so on-device
            // notifications (lead-time, meetings) match the push sound.
            SharedStore.notificationSoundName = doc.sound
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Apply a sound selection: update the doc + local mirror, save to the
    /// backend (so push uses it), re-arm local schedules so the change takes
    /// effect immediately, and play a short preview.
    private func selectSound(_ sound: ReminderSound?) {
        doc.sound = sound?.fileName
        SharedStore.notificationSoundName = sound?.fileName
        scheduleSave()
        Task {
            await MeetingsNotifier.reschedule()
            await LeadTimeNotifier.reschedule()
            await RecurringRemindersScheduler.reschedule()
        }
        if let sound { playPreview(sound) }
    }

    private func playPreview(_ sound: ReminderSound) {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            soundPreviewPlayer = try AVAudioPlayer(contentsOf: url)
            soundPreviewPlayer?.play()
        } catch {
            print("[sound] preview failed: \(error.localizedDescription)")
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
