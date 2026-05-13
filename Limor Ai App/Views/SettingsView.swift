import EventKit
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var nameDraft: String = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var savingName = false
    @State private var calendarSources: Set<DataSource> = SharedStore.calendarSources
    @State private var emailSources: Set<DataSource> = SharedStore.emailSources
    @State private var permissionSnapshot = PermissionSnapshot()
    @State private var errorMessage: String?
    @State private var reminderLists: [EKCalendar] = []
    @State private var selectedReminderListId: String? = SharedStore.remindersListId
    @State private var crmStatus: CrmStatus?
    @State private var crmPushPending = false
    @State private var pushDiagnosticRunning = false
    @State private var pushDiagnosticStatus: String?
    /// Source image loaded from PhotosPicker, awaiting the user's crop
    /// confirmation. Drives the `.sheet` modifier presenting PhotoCropSheet.
    @State private var photoPendingCrop: UIImage?

    /// Selected custom tab kind, mirrored from SharedStore via @AppStorage
    /// so toggling here reactively redraws both this view AND MainTabs.
    @AppStorage("limor.customTabKind", store: SharedStore.appGroupDefaults)
    private var customTabRaw: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        profileCard
                        memoryCard
                        familyCard
                        notificationsCard
                        // Only renders for users whose `crm_enabled` flag is
                        // true in Firestore — hidden entirely for everyone else.
                        if crmStatus?.allowed == true {
                            crmCard
                        }
                        sourcesCard
                        customTabCard
                        remindersListCard
                        permissionsCard
                        accountCard
                        buildFooter
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.large)
            .task {
                nameDraft = auth.displayName ?? ""
                await refreshPermissions()
                await loadCrmStatus()
            }
            .navigationDestination(isPresented: $crmPushPending) {
                if let status = crmStatus, status.allowed {
                    CRMConnectView(status: status) { newStatus in
                        crmStatus = newStatus
                    }
                }
            }
            .onChange(of: auth.displayName) { oldValue, newValue in
                // Backend profile fetch lands asynchronously after `applyAuthState`
                // seeds displayName from Firebase Auth's cached value. When the
                // newer Hebrew name arrives, re-seed the field — but only if the
                // user hasn't started editing (draft still matches the old value).
                if nameDraft == (oldValue ?? "") {
                    nameDraft = newValue ?? ""
                }
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPhotoForCropping(item: newItem) }
            }
            .sheet(item: Binding<IdentifiedImage?>(
                get: { photoPendingCrop.map(IdentifiedImage.init) },
                set: { newValue in photoPendingCrop = newValue?.image }
            )) { wrapper in
                PhotoCropSheet(
                    source: wrapper.image,
                    onCancel: {
                        photoPendingCrop = nil
                        photoItem = nil
                    },
                    onConfirm: { cropped in
                        photoPendingCrop = nil
                        photoItem = nil
                        Task { await uploadCroppedPhoto(cropped) }
                    }
                )
                .interactiveDismissDisabled(true)
            }
            .onChange(of: scenePhase) { _, newPhase in
                // After the user returns from Authenticator / Google sign-in,
                // re-check granted scopes so the permission rows reflect the
                // new state without needing the user to leave Settings.
                if newPhase == .active {
                    Task { await refreshPermissions() }
                }
            }
            .onChange(of: calendarSources) { oldValue, newValue in
                SharedStore.calendarSources = newValue
                let added = newValue.subtracting(oldValue)
                // Removing a source is instant (no OAuth needed). Adding one
                // kicks off OAuth — if that fails we revert the checkbox so
                // the UI doesn't lie about which providers are connected.
                if added.isEmpty {
                    Task { await SyncManager.shared.syncCalendar(force: true) }
                    return
                }
                Task {
                    var failed: Set<DataSource> = []
                    if added.contains(.google) {
                        do { try await GoogleAPIs.ensureScopes([GoogleAPIs.calendarReadOnlyScope]) }
                        catch {
                            failed.insert(.google)
                            errorMessage = error.localizedDescription
                        }
                    }
                    if added.contains(.microsoft) {
                        do { try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.calendarReadScope]) }
                        catch {
                            failed.insert(.microsoft)
                            errorMessage = error.localizedDescription
                        }
                    }
                    if !failed.isEmpty {
                        calendarSources.subtract(failed)
                        // SharedStore is updated by the re-fired onChange.
                    }
                    // Refresh the permissions snapshot so the row below the
                    // picker flips from "הפעל" to "מאושר" without needing the
                    // user to leave Settings and come back.
                    await refreshPermissions()
                    await SyncManager.shared.syncCalendar(force: true)
                }
            }
            .onChange(of: emailSources) { oldValue, newValue in
                SharedStore.emailSources = newValue
                let added = newValue.subtracting(oldValue)
                if added.isEmpty {
                    Task { await SyncManager.shared.syncEmail(force: true) }
                    return
                }
                Task {
                    var failed: Set<DataSource> = []
                    if added.contains(.google) {
                        do { try await GoogleAPIs.ensureScopes([GoogleAPIs.gmailReadOnlyScope]) }
                        catch {
                            failed.insert(.google)
                            errorMessage = error.localizedDescription
                        }
                    }
                    if added.contains(.microsoft) {
                        do { try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.mailReadScope]) }
                        catch {
                            failed.insert(.microsoft)
                            errorMessage = error.localizedDescription
                        }
                    }
                    if !failed.isEmpty {
                        emailSources.subtract(failed)
                    }
                    await refreshPermissions()
                    await SyncManager.shared.syncEmail(force: true)
                }
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

    // MARK: Profile (photo + name)

    private var profileCard: some View {
        GlassCard(padding: 18) {
            VStack(spacing: 14) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    ZStack {
                        ProfileAvatar(photoB64: auth.photoB64, size: 88)

                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.limorIndigo)
                            )
                            .offset(x: 32, y: 32)

                        if savingPhoto {
                            Circle().fill(.black.opacity(0.4)).frame(width: 88, height: 88)
                            ProgressView().tint(.white)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text("איך לימור פונה אליך")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                    HStack(spacing: 8) {
                        TextField("השם שלך", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveName() } }
                        Button {
                            Task { await saveName() }
                        } label: {
                            if savingName {
                                ProgressView().tint(.white)
                                    .frame(width: 20, height: 20)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(LimorGradient.brand))
                            } else {
                                Text("שמור")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(LimorGradient.brand))
                            }
                        }
                        .disabled(savingName || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (auth.displayName ?? ""))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let email = auth.email {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope").font(.caption)
                        Text(email).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Memory — what Limor knows about the user

    private var memoryCard: some View {
        NavigationLink {
            ProfileFactsView()
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.limorViolet.opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: "brain.head.profile")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.limorViolet)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("מה לימור יודעת עליי")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text("הצג, ערוך או הסר פרטים שלימור זוכרת")
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Family — structured contact links

    private var familyCard: some View {
        NavigationLink {
            RelationshipsView()
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.limorPink.opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: "person.2.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.limorPink)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("המשפחה שלי")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text("קשר בני משפחה לאנשי הקשר שלך")
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: CRM (gated, Face-ID-protected)

    private var crmCard: some View {
        Button {
            Task { await openCrmGated() }
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.limorMint.opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: "briefcase.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.limorMint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("חיבור ל-CRM")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text(crmCardSubtitle)
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if crmStatus?.connected == true {
                        Circle().fill(Color.limorSuccess).frame(width: 8, height: 8)
                    }
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.limorMuted)
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var crmCardSubtitle: String {
        guard let status = crmStatus else { return "טוען…" }
        if status.connected {
            if let phone = status.phone_number, !phone.isEmpty { return "מחובר · \(phone)" }
            return "מחובר"
        }
        return "לא מחובר · נדרש Face ID"
    }

    private func loadCrmStatus() async {
        do {
            crmStatus = try await APIClient.shared.crmStatus()
        } catch {
            // Silent — non-allowlisted user just sees no card.
        }
    }

    /// Gate the CRM card behind Face ID / Touch ID / device passcode. Even
    /// authenticated Limor users have to re-prove they're holding the phone
    /// before we expose insurance customer data.
    private func openCrmGated() async {
        do {
            try await BiometricGate.authenticate(
                reason: "אימות נדרש לפתיחת חיבור ה-CRM"
            )
            crmPushPending = true
        } catch BiometricGate.AuthError.canceled {
            // user backed out, no error UI
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Daily notifications

    private var notificationsCard: some View {
        NavigationLink {
            NotificationsSettingsView()
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.limorIndigo.opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: "bell.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.limorIndigo)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("התראות יומיות")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text("בוקר טוב, סיכום ערב, ופיד יומי")
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Sources (Apple / Google)

    private var sourcesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "rectangle.connected.to.line.below", title: "מקורות נתונים")

                Text("אפשר לבחור כמה מקורות במקביל — לימור תאחד את הכל.")
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                MultiSourcePicker(
                    title: "יומן",
                    iconName: "calendar",
                    options: [
                        .init(value: .apple,     label: "אפל (iOS Calendar)", description: "כולל כל היומנים שחיברת ב-iOS"),
                        .init(value: .google,    label: "Google Calendar", description: "דורש חיבור Google + אישור scope"),
                        .init(value: .microsoft, label: "Outlook / Office 365", description: "דורש חיבור Microsoft + אישור scope"),
                    ],
                    selection: $calendarSources
                )

                Divider().padding(.vertical, 4)

                MultiSourcePicker(
                    title: "מייל",
                    iconName: "envelope",
                    options: [
                        .init(value: .google,    label: "Gmail", description: "דורש חיבור Google + אישור scope"),
                        .init(value: .microsoft, label: "Outlook / Office 365", description: "דורש חיבור Microsoft + אישור scope"),
                    ],
                    selection: $emailSources
                )
            }
        }
    }

    // MARK: Custom tab bar slot

    /// Lets the user pin one extra shortcut to the bottom tab bar — useful
    /// for jumping straight into the shopping list or the meetings detail
    /// screen without going through NowView. Backed by `@AppStorage` in
    /// `MainTabs`, so toggling here reactively rebuilds the tab bar.
    private var customTabCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "rectangle.stack.badge.plus", title: "כפתור מהיר בתחתית")

                Text("אפשר להצמיד קיצור דרך נוסף לסרגל התחתון, ליד \"הפיד שלי\".")
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                VStack(spacing: 6) {
                    customTabRow(value: nil, label: "ללא", icon: "minus.circle")
                    customTabRow(value: .shoppingList, label: "רשימת קניות", icon: "cart.fill")
                    customTabRow(value: .meetings, label: "פגישות", icon: "calendar")
                }
            }
        }
    }

    @ViewBuilder
    private func customTabRow(value: CustomTabKind?, label: String, icon: String) -> some View {
        let selected = customTabRaw == (value?.rawValue ?? "")
        Button {
            customTabRaw = value?.rawValue ?? ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.limorIndigo)
                Image(systemName: icon)
                    .foregroundStyle(.limorIndigo)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.limorIndigo.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Reminders list picker

    /// Lets the user pick which Apple Reminders list new Limor reminders go
    /// into. Default = OS-level "Default List" (Settings → Reminders →
    /// Default List). Useful when the device defaults to a Family list and
    /// the user wants reminders in their personal list instead.
    private var remindersListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "list.bullet.rectangle", title: "רשימת תזכורות")

                Text("לאן לימור תוסיף תזכורות באפליקציית Reminders של אפל.")
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                if reminderLists.isEmpty {
                    HStack {
                        Text("אין הרשאת תזכורות עדיין")
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                        Spacer()
                        Button("בקש הרשאה") {
                            Task {
                                _ = await RemindersWriter.shared.requestAccess()
                                await loadReminderLists()
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                    }
                } else {
                    Menu {
                        Button {
                            selectedReminderListId = nil
                            SharedStore.remindersListId = nil
                        } label: {
                            HStack {
                                Text("ברירת מחדל של iOS")
                                if selectedReminderListId == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach(reminderLists, id: \.calendarIdentifier) { cal in
                            Button {
                                selectedReminderListId = cal.calendarIdentifier
                                SharedStore.remindersListId = cal.calendarIdentifier
                            } label: {
                                HStack {
                                    Text(cal.title)
                                    if selectedReminderListId == cal.calendarIdentifier {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(currentListColor)
                                .frame(width: 12, height: 12)
                            Text(currentListLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.limorInk)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.limorMuted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                    }
                }
            }
        }
        .task { await loadReminderLists() }
    }

    private var currentListLabel: String {
        if let id = selectedReminderListId,
           let cal = reminderLists.first(where: { $0.calendarIdentifier == id }) {
            return cal.title
        }
        return "ברירת מחדל של iOS"
    }

    private var currentListColor: Color {
        guard let id = selectedReminderListId,
              let cal = reminderLists.first(where: { $0.calendarIdentifier == id }) else {
            return .limorMuted
        }
        // EKCalendar.cgColor → SwiftUI Color
        return Color(cgColor: cal.cgColor)
    }

    private func loadReminderLists() async {
        reminderLists = await RemindersWriter.shared.availableLists()
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(icon: "checkmark.shield", title: "הרשאות")
                    Spacer()
                    Button {
                        Task {
                            await SyncManager.shared.syncAll(force: true)
                            await refreshPermissions()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2.weight(.bold))
                            Text("סנכרן עכשיו").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(LimorGradient.brand))
                    }
                    .buttonStyle(.plain)
                }

                PermissionRow(
                    icon: "calendar",
                    title: "יומן (iOS)",
                    granted: permissionSnapshot.calendar,
                    action: { await requestCalendar() }
                )
                if calendarSources.contains(.google) {
                    PermissionRow(
                        icon: "calendar.badge.checkmark",
                        title: "Google Calendar",
                        granted: permissionSnapshot.googleCalendar,
                        action: { await connectGoogleCalendar() }
                    )
                }
                if calendarSources.contains(.microsoft) {
                    PermissionRow(
                        icon: "calendar.badge.checkmark",
                        title: "Outlook Calendar",
                        granted: permissionSnapshot.microsoftCalendar,
                        action: { await connectOutlookCalendar() }
                    )
                }
                PermissionRow(
                    icon: "person.crop.circle",
                    title: "אנשי קשר",
                    granted: permissionSnapshot.contacts,
                    action: { await requestContacts() }
                )
                if emailSources.contains(.google) {
                    PermissionRow(
                        icon: "envelope.fill",
                        title: "Gmail",
                        granted: permissionSnapshot.googleGmail,
                        action: { await connectGmail() }
                    )
                }
                if emailSources.contains(.microsoft) {
                    PermissionRow(
                        icon: "envelope.fill",
                        title: "Outlook Mail",
                        granted: permissionSnapshot.microsoftMail,
                        action: { await connectOutlookMail() }
                    )
                }
                PermissionRow(
                    icon: "heart.fill",
                    title: "בריאות",
                    granted: permissionSnapshot.health,
                    action: { await requestHealth() }
                )
                PermissionRow(
                    icon: "location.fill",
                    title: "מיקום",
                    granted: permissionSnapshot.location,
                    action: { LocationManager.shared.requestWhenInUseAndStart() }
                )
                PermissionRow(
                    icon: "bell.fill",
                    title: "התראות",
                    granted: permissionSnapshot.notifications,
                    action: { await requestOrOpenNotificationSettings() }
                )
                pushDiagnosticRow
            }
        }
    }

    /// Re-upload the FCM token to the backend and fire a local notification
    /// 3 seconds later. Lets the user verify end-to-end without having to
    /// wait for a reminder to come due. The re-upload is a side benefit:
    /// it covers the case where the original token registration on first
    /// launch silently failed (network race / auth not ready) and pushes
    /// from the backend never reached this device because Firestore had
    /// no token for the user.
    private var pushDiagnosticRow: some View {
        Button {
            Task { await runPushDiagnostic() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.limorIndigo.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline).foregroundStyle(.limorIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("בדוק התראות")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.limorInk)
                    Text(pushDiagnosticStatus ?? "שולח התראת בדיקה ומחדש רישום לשרת")
                        .font(.caption2)
                        .foregroundStyle(pushDiagnosticStatus == nil ? .limorMuted : .limorInk)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if pushDiagnosticRunning {
                    ProgressView().tint(.limorIndigo)
                } else {
                    Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.limorMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pushDiagnosticRunning)
    }

    private func requestOrOpenNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            await PushManager.shared.requestPermissionIfNeeded()
        case .denied:
            // System dialog has been declined; only iOS Settings can flip it.
            await MainActor.run {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .authorized, .provisional, .ephemeral:
            await PushManager.shared.requestPermissionIfNeeded()
        @unknown default:
            await PushManager.shared.requestPermissionIfNeeded()
        }
    }

    private func runPushDiagnostic() async {
        pushDiagnosticRunning = true
        defer { pushDiagnosticRunning = false }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else {
            pushDiagnosticStatus = "התראות חסומות במערכת. פתח הגדרות → לימור → התראות"
            return
        }

        await PushManager.shared.refreshAndUploadToken()

        let content = UNMutableNotificationContent()
        content.title = "בדיקת התראות"
        content.body = "אם אתה רואה את זה, מערכת ההתראות עובדת ✅"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "limor.diagnostic.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            let hasToken = PushManager.shared.fcmToken != nil
            pushDiagnosticStatus = hasToken
                ? "נשלחה התראה מקומית. הרישום לשרת חודש ✅"
                : "התראה מקומית נשלחה, אבל אין עדיין FCM token. נסה שוב בעוד רגע."
        } catch {
            pushDiagnosticStatus = "שגיאה: \(error.localizedDescription)"
        }
    }

    /// Small build-id footer so we can verify which commit + build the
    /// user is actually running — debugging "I rebuilt but my fix
    /// isn't there" is otherwise blind.
    private var buildFooter: some View {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        // BuildInfo.gitSha is generated at build time by
        // tools/inject-git-sha.rb (Run Script phase before Sources).
        // Reading from a Swift constant rather than Info.plist avoids
        // the race with ProcessInfoPlistFile, which used to silently
        // regenerate the bundled plist *after* our script and wipe
        // the LIMOR_GIT_SHA key that lived there.
        return VStack(spacing: 4) {
            Text("גרסה \(short) (\(build)) · \(BuildInfo.gitSha)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.limorMuted)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var accountCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "person.crop.circle.badge.minus", title: "חשבון")

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("יציאה").font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(.limorDanger)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.limorDanger.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func saveName() async {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != auth.displayName else { return }
        savingName = true
        defer { savingName = false }
        do {
            try await auth.setDisplayName(trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the picked PhotosPicker item into `photoPendingCrop`, which
    /// triggers the PhotoCropSheet via the `.sheet` modifier on body.
    /// We deliberately *don't* upload here — the upload happens in
    /// `uploadCroppedPhoto` once the user confirms their face position.
    private func loadPhotoForCropping(item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                errorMessage = "לא הצלחתי לטעון את התמונה."
                photoItem = nil
                return
            }
            photoPendingCrop = uiImage.normalizedOrientation()
        } catch {
            errorMessage = error.localizedDescription
            photoItem = nil
        }
    }

    private func uploadCroppedPhoto(_ image: UIImage) async {
        savingPhoto = true
        defer { savingPhoto = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            errorMessage = "לא הצלחתי לדחוס את התמונה."
            return
        }
        do {
            try await auth.setProfilePhoto(jpegB64: jpeg.base64EncodedString())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() async {
        permissionSnapshot.calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        permissionSnapshot.contacts = await ContactsManager.shared.hasAccess
        permissionSnapshot.health = await HealthManager.shared.hasAccess
        permissionSnapshot.location = LocationManager.shared.authorizationStatus == .authorizedWhenInUse
            || LocationManager.shared.authorizationStatus == .authorizedAlways
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionSnapshot.notifications = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        let granted = GoogleAPIs.grantedScopes()
        permissionSnapshot.googleCalendar = granted.contains(GoogleAPIs.calendarReadOnlyScope)
        permissionSnapshot.googleGmail    = granted.contains(GoogleAPIs.gmailReadOnlyScope)
        let msGranted = MicrosoftAPIs.grantedScopes()
        permissionSnapshot.microsoftCalendar = msGranted.contains(MicrosoftAPIs.calendarReadScope)
        permissionSnapshot.microsoftMail     = msGranted.contains(MicrosoftAPIs.mailReadScope)
    }

    private func connectGoogleCalendar() async {
        do {
            try await GoogleAPIs.ensureScopes([GoogleAPIs.calendarReadOnlyScope])
            await SyncManager.shared.syncCalendar(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshPermissions()
    }

    private func connectGmail() async {
        do {
            try await GoogleAPIs.ensureScopes([GoogleAPIs.gmailReadOnlyScope])
            await SyncManager.shared.syncEmail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshPermissions()
    }

    private func connectOutlookCalendar() async {
        do {
            try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.calendarReadScope])
            await SyncManager.shared.syncCalendar(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshPermissions()
    }

    private func connectOutlookMail() async {
        do {
            try await MicrosoftAPIs.ensureScopes([MicrosoftAPIs.mailReadScope])
            await SyncManager.shared.syncEmail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshPermissions()
    }

    private func requestCalendar() async {
        _ = await CalendarManager.shared.requestAccess()
        await refreshPermissions()
    }
    private func requestContacts() async {
        _ = await ContactsManager.shared.requestAccess()
        await refreshPermissions()
    }
    private func requestHealth() async {
        _ = await HealthManager.shared.requestAccess()
        await refreshPermissions()
    }
}

// MARK: - Subviews

private struct PermissionSnapshot {
    var calendar: Bool = false
    var contacts: Bool = false
    var health: Bool = false
    var location: Bool = false
    var notifications: Bool = false
    var googleCalendar: Bool = false
    var googleGmail: Bool = false
    var microsoftCalendar: Bool = false
    var microsoftMail: Bool = false
}

/// Thin Identifiable wrapper so `UIImage` can drive a `.sheet(item:)` —
/// SwiftUI requires `Identifiable` and `UIImage` doesn't ship with one.
private struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let granted: Bool
    let action: () async -> Void
    @State private var inFlight = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.limorIndigo.opacity(0.12)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.subheadline).foregroundStyle(.limorIndigo)
            }
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("מאושר")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorSuccess)
            } else {
                Button {
                    Task { inFlight = true; await action(); inFlight = false }
                } label: {
                    if inFlight {
                        ProgressView().tint(.white).frame(width: 16, height: 16)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(LimorGradient.brand))
                    } else {
                        Text("הפעל")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(LimorGradient.brand))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Multi-select replacement for the old single-choice picker — each option
/// has its own checkbox so the user can enable any combination (e.g. both
/// Gmail and Outlook). Tapping a row toggles that single source on/off.
private struct MultiSourcePicker: View {
    let title: String
    let iconName: String
    let options: [Option]
    @Binding var selection: Set<DataSource>

    struct Option: Identifiable {
        var id: DataSource { value }
        let value: DataSource
        let label: String
        let description: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)
            VStack(spacing: 6) {
                ForEach(options) { opt in
                    let isOn = selection.contains(opt.value)
                    Button {
                        if isOn { selection.remove(opt.value) }
                        else    { selection.insert(opt.value) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .foregroundStyle(Color.limorIndigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label).font(.subheadline.weight(.semibold))
                                Text(opt.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isOn ? Color.limorIndigo.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Profile avatar (used here + NowView toolbar)

struct ProfileAvatar: View {
    let photoB64: String?
    var size: CGFloat = 36
    /// Set false to drop the stroke/shadow — useful inside iOS 26 toolbars where
    /// the system already wraps the item in its own Liquid Glass capsule.
    var bordered: Bool = true

    var body: some View {
        Group {
            if let img = decodedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(LimorGradient.brand)
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if bordered {
                Circle().stroke(.white.opacity(0.5), lineWidth: 1)
            }
        }
        .shadow(color: bordered ? Color.limorIndigo.opacity(0.3) : .clear, radius: 6, y: 3)
    }

    private var decodedImage: UIImage? {
        guard let b64 = photoB64, !b64.isEmpty,
              let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - UIImage resize

private extension UIImage {
    func resized(toMaxDimension max: CGFloat) -> UIImage {
        let largest = Swift.max(size.width, size.height)
        if largest <= max { return self }
        let scale = max / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Crops the image to a centered square, in points (after orientation normalization).
    func centerCroppedToSquare() -> UIImage {
        let edge = Swift.min(size.width, size.height)
        let origin = CGPoint(x: (size.width - edge) / 2, y: (size.height - edge) / 2)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        return renderer.image { _ in
            draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }

    /// Returns an `up`-oriented copy. Necessary because PhotosPicker images often
    /// arrive with EXIF rotation that confuses crop math.
    func normalizedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
