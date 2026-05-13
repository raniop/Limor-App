import SwiftUI
import UserNotifications

/// First-run onboarding shown after sign-in, before MainTabs. Walks the user
/// through each permission (notifications, location, calendar, contacts,
/// health) one screen at a time so they don't get hit with a stack of
/// system prompts the moment they sign in.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var step: Int = 0
    @State private var permissionStatus: [Step: PermissionState] = [:]

    enum PermissionState { case unknown, granted, denied, working }

    enum Step: Int, CaseIterable, Hashable {
        case welcome, notifications, location, calendar, email, contacts, health, done
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                progressDots
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                TabView(selection: $step) {
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        page(for: s)
                            .tag(s.rawValue)
                            .padding(.horizontal, 26)
                            .padding(.top, 10)
                            .padding(.bottom, 28)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: step)
            }
        }
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.indices, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.limorIndigo : Color.limorMuted.opacity(0.30))
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for s: Step) -> some View {
        switch s {
        case .welcome:
            permissionPage(
                icon: "sparkles",
                tint: .limorIndigo,
                title: "ברוך הבא ללימור",
                body: "כדי שאוכל לעזור לך באמת — להזכיר, לתכנן, לחפש — אצטרך כמה הרשאות. נעבור עליהן יחד, אחת אחת. אתה תחליט מה לאשר.",
                primary: ("נתחיל", { advance() }),
                secondary: nil,
                step: s
            )
        case .notifications:
            permissionPage(
                icon: "bell.fill",
                tint: .limorCoral,
                title: "התראות",
                body: "כדי שאזכיר לך תזכורות בדיוק בזמן — גם כשהאפליקציה סגורה. בלי זה, התזכורות לא יקפצו אליך.",
                primary: ("אפשר התראות", { Task { await requestNotifications() } }),
                secondary: ("אולי אחר כך", { advance() }),
                step: s
            )
        case .location:
            permissionPage(
                icon: "location.fill",
                tint: .limorMint,
                title: "מיקום",
                body: "כדי להראות לך מזג אוויר מדויק לאזור שלך, ולעזור עם המלצות מקומיות. אני לא שומרת מיקום היסטורי.",
                primary: ("אפשר מיקום", { Task { await requestLocation() } }),
                secondary: ("אולי אחר כך", { advance() }),
                step: s
            )
        case .calendar:
            calendarPage(s)
        case .email:
            emailPage(s)
        case .contacts:
            permissionPage(
                icon: "person.2.fill",
                tint: .limorIndigo,
                title: "אנשי קשר",
                body: "כדי לחפש אנשים בשם בעברית או באנגלית כשאתה מבקש ממני 'שלחי לרני'. השמות נשמרים אצלך — אצלי רק אינדקס לחיפוש.",
                primary: ("אפשר גישה לאנשי קשר", { Task { await requestContacts() } }),
                secondary: ("אולי אחר כך", { advance() }),
                step: s
            )
        case .health:
            permissionPage(
                icon: "heart.fill",
                tint: .limorPink,
                title: "בריאות",
                body: "כדי לתת לך טיפים אישיים — אם ישנת מספיק, כמה זזת השבוע, מתי האימון האחרון. הכל קריאה בלבד מאפל הלת'.",
                primary: ("אפשר גישה לבריאות", { Task { await requestHealth() } }),
                secondary: ("אולי אחר כך", { advance() }),
                step: s
            )
        case .done:
            permissionPage(
                icon: "checkmark.circle.fill",
                tint: .limorMint,
                title: "הכל מוכן 🎉",
                body: "אפשר לשנות הרשאות בכל זמן בהגדרות → הרשאות. בוא נתחיל.",
                primary: ("בוא נתחיל", { finish() }),
                secondary: nil,
                step: s
            )
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func permissionPage(
        icon: String,
        tint: Color,
        title: String,
        body: String,
        primary: (String, () -> Void),
        secondary: (String, () -> Void)?,
        step: Step
    ) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 200, height: 200)
                    .blur(radius: 20)
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 130, height: 130)
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.35), radius: 16, y: 8)
            }

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorInk)
                    .multilineTextAlignment(.center)

                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)

            if let state = permissionStatus[step], state != .unknown {
                statusBadge(state, tint: tint)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: primary.1) {
                    Text(primary.0)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(LinearGradient(colors: [tint, tint.opacity(0.85)],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                        )
                        .shadow(color: tint.opacity(0.30), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(permissionStatus[step] == .working)

                if let (label, action) = secondary {
                    Button(action: action) {
                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.limorMuted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func statusBadge(_ state: PermissionState, tint: Color) -> some View {
        Group {
            switch state {
            case .granted:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("אושר")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorSuccess)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.limorSuccess.opacity(0.12)))
            case .denied:
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                    Text("לא אושר — אפשר להפעיל בהגדרות בהמשך")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.limorMuted)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.limorMuted.opacity(0.12)))
            case .working:
                ProgressView().tint(tint)
            case .unknown:
                EmptyView()
            }
        }
    }

    // MARK: - Calendar (Apple vs Google)

    @ViewBuilder
    private func calendarPage(_ s: Step) -> some View {
        let tint = Color.limorViolet
        let state = permissionStatus[s] ?? .unknown
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            iconHero(icon: "calendar", tint: tint)
            VStack(spacing: 12) {
                Text("יומן")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorInk)
                Text("כדי שאדע מה יש לך ביום, להציע זמנים פנויים ולהבין יום עמוס מראש. בחר מאיפה אקרא:")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)

            if state != .unknown { statusBadge(state, tint: tint) }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                primaryButton("יומן של אפל", tint: tint, disabled: state == .working) {
                    Task { await requestAppleCalendar() }
                }
                primaryButton("Google Calendar", tint: .limorIndigo, disabled: state == .working) {
                    Task { await requestGoogleCalendar() }
                }
                primaryButton("Outlook Calendar", tint: .limorMint, disabled: state == .working) {
                    Task { await requestOutlookCalendar() }
                }
                secondaryButton("אולי אחר כך") { advance() }
            }
        }
    }

    private func requestAppleCalendar() async {
        permissionStatus[.calendar] = .working
        let granted = await CalendarManager.shared.requestAccess()
        if granted { SharedStore.calendarSources = [.apple] }
        permissionStatus[.calendar] = granted ? .granted : .denied
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    private func requestGoogleCalendar() async {
        permissionStatus[.calendar] = .working
        do {
            try await GoogleAPIs.ensureScopes([GoogleAPIs.calendarReadOnlyScope])
            SharedStore.calendarSources = [.google]
            permissionStatus[.calendar] = .granted
        } catch {
            permissionStatus[.calendar] = .denied
        }
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    private func requestOutlookCalendar() async {
        permissionStatus[.calendar] = .working
        do {
            try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.calendarReadScope])
            SharedStore.calendarSources = [.microsoft]
            permissionStatus[.calendar] = .granted
        } catch {
            permissionStatus[.calendar] = .denied
        }
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    // MARK: - Email (Gmail or none)

    @ViewBuilder
    private func emailPage(_ s: Step) -> some View {
        let tint = Color.limorCoral
        let state = permissionStatus[s] ?? .unknown
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            iconHero(icon: "envelope.fill", tint: tint)
            VStack(spacing: 12) {
                Text("מייל")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorInk)
                Text("כדי לזהות אוטומטית טיסות, הזמנות ועדכונים חשובים בתיבה שלך. הקריאה היא מ-Gmail בלבד, ואני לא שולחת מיילים בלי אישור.")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)

            if state != .unknown { statusBadge(state, tint: tint) }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                primaryButton("חבר את Gmail", tint: tint, disabled: state == .working) {
                    Task { await requestGmail() }
                }
                primaryButton("חבר את Outlook", tint: .limorIndigo, disabled: state == .working) {
                    Task { await requestOutlookMail() }
                }
                secondaryButton("אני לא משתמש במייל") { advance() }
            }
        }
    }

    private func requestGmail() async {
        permissionStatus[.email] = .working
        do {
            try await GoogleAPIs.ensureScopes([GoogleAPIs.gmailReadOnlyScope])
            SharedStore.emailSources = [.google]
            permissionStatus[.email] = .granted
        } catch {
            permissionStatus[.email] = .denied
        }
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    private func requestOutlookMail() async {
        permissionStatus[.email] = .working
        do {
            try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.mailReadScope])
            SharedStore.emailSources = [.microsoft]
            permissionStatus[.email] = .granted
        } catch {
            permissionStatus[.email] = .denied
        }
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    // MARK: - Reusable bits for the multi-action pages

    private func iconHero(icon: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 200, height: 200)
                .blur(radius: 20)
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 130, height: 130)
            Image(systemName: icon)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.35), radius: 16, y: 8)
        }
    }

    private func primaryButton(_ label: String, tint: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.85)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                )
                .shadow(color: tint.opacity(0.30), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.limorMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission requests

    private func requestNotifications() async {
        permissionStatus[.notifications] = .working
        await PushManager.shared.requestPermissionIfNeeded()
        // Read the real authorization status — a user who tapped "Don't
        // Allow" must see `.denied`, otherwise the onboarding lies and
        // they never realize push is off until something is missed.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionStatus[.notifications] = .granted
        case .denied:
            permissionStatus[.notifications] = .denied
        case .notDetermined:
            permissionStatus[.notifications] = .unknown
        @unknown default:
            permissionStatus[.notifications] = .unknown
        }
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    private func requestLocation() async {
        permissionStatus[.location] = .working
        LocationManager.shared.requestWhenInUseAndStart()
        // Give CoreLocation a beat to flip the auth status.
        try? await Task.sleep(for: .milliseconds(900))
        permissionStatus[.location] = .granted
        try? await Task.sleep(for: .milliseconds(350))
        advance()
    }

    private func requestContacts() async {
        permissionStatus[.contacts] = .working
        let granted = await ContactsManager.shared.requestAccess()
        permissionStatus[.contacts] = granted ? .granted : .denied
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    private func requestHealth() async {
        permissionStatus[.health] = .working
        let granted = await HealthManager.shared.requestAccess()
        permissionStatus[.health] = granted ? .granted : .denied
        try? await Task.sleep(for: .milliseconds(450))
        advance()
    }

    // MARK: - Navigation

    private func advance() {
        let next = step + 1
        guard next < Step.allCases.count else { finish(); return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.3)) { step = next }
    }

    private func finish() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        SharedStore.onboardingCompleted = true
        onFinish()
    }
}
