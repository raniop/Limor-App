import SwiftUI
import UserNotifications

/// Onboarding step that picks which daily push notifications the user
/// wants. Shown once, between permissions onboarding (which grants the
/// iOS push permission itself) and the meet-Limor intro chat. Settings
/// → "התראות יומיות" remains the long-term place to tune.
///
/// Only renders if the user actually granted push permission upstream
/// — otherwise the picks here can't fire anyway, so the view
/// short-circuits to `onCompleted` and the user moves on.
struct NotificationPrefsOnboardingView: View {
    var onCompleted: () -> Void

    /// Defaults shown the first time: morning brief + evening recap on,
    /// feed digest off. Same defaults the server falls back to if the
    /// user never opens the screen.
    @State private var doc: NotificationPrefsDoc = NotificationPrefsDoc(
        master_enabled: true,
        prefs: [
            NotificationPref(kind: .morning_brief, enabled: true,  hour: 7,  minute: 30, last_sent_date: nil),
            NotificationPref(kind: .evening_recap, enabled: true,  hour: 20, minute: 30, last_sent_date: nil),
            NotificationPref(kind: .feed_digest,   enabled: false, hour: 8,  minute: 0,  last_sent_date: nil),
        ],
        // Keep the protective night-quiet default (23:00→07:00) through the
        // initial save so new users start with it on.
        quiet_start: 23,
        quiet_end: 7
    )
    @State private var saving = false
    @State private var errorMessage: String?
    /// nil while we're checking iOS authorization status, true once we
    /// know the user granted notifications and we should render the
    /// picker. When the check comes back denied we skip via onCompleted
    /// without ever flipping this true.
    @State private var shouldShow: Bool?

    var body: some View {
        ZStack {
            // Keep the soft brand backdrop visible during the auth-status
            // check so the screen doesn't flash an empty white frame
            // between OnboardingView and the next step (intro chat).
            LiquidBackdrop()

            if shouldShow == true {
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        ForEach(Array(doc.prefs.enumerated()), id: \.element.kind) { index, _ in
                            presetCard(index: index)
                        }
                        footerText
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 32)
                    .padding(.bottom, 100)
                }

                VStack {
                    Spacer()
                    continueButton
                        .padding(.horizontal, 22)
                        .padding(.bottom, 28)
                }
            }
        }
        .task {
            // Skip the picker entirely when the user denied / deferred the
            // push prompt in OnboardingView. The defaults here can't fire
            // without iOS permission, and surfacing a settings page that
            // has no effect feels broken. Settings → התראות יומיות is
            // still available later if they enable notifications in iOS.
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                shouldShow = true
            default:
                SharedStore.notificationPrefsAsked = true
                onCompleted()
            }
        }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(tr("אוקיי", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.limorIndigo, Color.limorViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 54, height: 54)
                    Image(systemName: "bell.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("איזה התראות תרצה לקבל?", "Which notifications would you like?"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Text(tr("בחר עכשיו, תוכל לשנות מתי שתרצה.", "Pick now — you can change this anytime."))
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presetCard(index: Int) -> some View {
        let pref = doc.prefs[index]
        let style = displayStyle(for: pref.kind)
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(style.tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: style.icon)
                    .font(.body.weight(.bold))
                    .foregroundStyle(style.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(style.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Text(timeText(hour: pref.hour, minute: pref.minute))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.limorMuted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.limorMuted.opacity(0.12)))
                }
                Text(style.subtitle)
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { doc.prefs[index].enabled },
                set: { doc.prefs[index].enabled = $0 }
            ))
            .labelsHidden()
            .tint(style.tint)
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
        Text(tr("את השעות והפעלה/כיבוי תוכל לכוון בכל זמן ב-הגדרות → התראות יומיות.", "You can adjust times and turn these on or off anytime in Settings → Daily notifications."))
            .font(.caption2)
            .foregroundStyle(.limorMuted)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
    }

    private var continueButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if saving { ProgressView().tint(.white).scaleEffect(0.8) }
                Text(tr("המשך", "Continue"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LimorGradient.brand)
            )
            .shadow(color: Color.limorIndigo.opacity(0.35), radius: 14, y: 8)
        }
        .disabled(saving)
    }

    private func timeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
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
                title: tr("בוקר טוב", "Good morning"),
                subtitle: tr("מה ביומן היום ותזכורות פתוחות", "Today's calendar and open reminders"),
                icon: "sun.max.fill",
                tint: .limorWarning
            )
        case .evening_recap:
            return DisplayStyle(
                title: tr("סיכום ערב", "Evening recap"),
                subtitle: tr("צעדים, יומן מחר ותזכורות פתוחות", "Steps, tomorrow's calendar, and open reminders"),
                icon: "moon.fill",
                tint: .limorViolet
            )
        case .feed_digest:
            return DisplayStyle(
                title: tr("חדשות הבוקר", "Morning news"),
                subtitle: tr("הכותרות העיקריות מהפיד שלך", "The top headlines from your feed"),
                icon: "newspaper.fill",
                tint: .limorIndigo
            )
        }
    }

    // MARK: - Save

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            // Persist to backend. Failures are surfaced but we still let the
            // user proceed — the server has a sensible default and they can
            // re-tune from Settings.
            _ = try await APIClient.shared.saveNotificationPrefs(doc)
            SharedStore.notificationPrefsAsked = true
            onCompleted()
        } catch {
            errorMessage = error.localizedDescription
            // Still let them continue so they're not stranded if the server
            // hiccups on first launch — defaults apply.
            SharedStore.notificationPrefsAsked = true
            onCompleted()
        }
    }
}
