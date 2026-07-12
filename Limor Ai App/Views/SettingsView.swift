import AuthenticationServices
import EventKit
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var lang: LanguageManager
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
    // Account linking (sign in with either provider, same account).
    @State private var linkingGoogle = false
    @State private var linkSuccess: String?
    /// Source image loaded from PhotosPicker, awaiting the user's crop
    /// confirmation. Stored as IdentifiedImage rather than UIImage so the
    /// `.sheet(item:)` modifier sees a *stable* identifier across renders
    /// — wrapping the UIImage in a fresh IdentifiedImage(UUID()) on every
    /// body evaluation made SwiftUI think each render was a *new* sheet
    /// to present, and the cropper opened-and-closed in a tight loop.
    @State private var photoPendingCrop: IdentifiedImage?

    // Organization / B2B license.
    @State private var currentOrg: APIClient.OrgInfo?
    @State private var myUsage: APIClient.MyUsage?
    @State private var licenseDraft: String = ""
    @State private var joiningOrg = false
    @State private var orgError: String?
    @State private var myCompany: APIClient.CompanyBilling?

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
                        languageCard
                        // Company management + billing sit right under Language.
                        if isOwner { ownerAdminCard }
                        if myCompany != nil { companyManagerCard }
                        usageCard
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
                        organizationCard
                        permissionsCard
                        linkAccountsCard
                        accountCard
                        buildFooter
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                    .limorReadableWidth()
                }
            }
            .navigationTitle(tr("הגדרות", "Settings"))
            .navigationBarTitleDisplayMode(.large)
            .task {
                nameDraft = auth.displayName ?? ""
                await refreshPermissions()
                await loadCrmStatus()
                currentOrg = try? await APIClient.shared.getMyOrg()
                myCompany = try? await APIClient.shared.getMyCompany()
                myUsage = try? await APIClient.shared.myUsage()
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
            .sheet(item: $photoPendingCrop) { wrapper in
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
            .alert(tr("שגיאה", "Error"), isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(tr("אוקיי", "OK"), role: .cancel) {}
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
                    Text(tr("איך לימור פונה אליך", "How Limor addresses you"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                    HStack(spacing: 8) {
                        TextField(tr("השם שלך", "Your name"), text: $nameDraft)
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
                                Text(tr("שמור", "Save"))
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
                        Text(tr("מה לימור יודעת עליי", "What Limor knows about me"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text(tr("הצג, ערוך או הסר פרטים שלימור זוכרת", "View, edit, or remove details Limor remembers"))
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
                        Text(tr("המשפחה שלי", "My family"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text(tr("קשר בני משפחה לאנשי הקשר שלך", "Link family members to your contacts"))
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
                        Text(tr("חיבור ל-CRM", "CRM connection"))
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
        guard let status = crmStatus else { return tr("טוען…", "Loading…") }
        if status.connected {
            if let phone = status.phone_number, !phone.isEmpty { return tr("מחובר · \(phone)", "Connected · \(phone)") }
            return tr("מחובר", "Connected")
        }
        return tr("לא מחובר · נדרש Face ID", "Not connected · Face ID required")
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
                reason: tr("אימות נדרש לפתיחת חיבור ה-CRM", "Authentication required to open the CRM connection")
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
                        Text(tr("התראות יומיות", "Daily notifications"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorInk)
                        Text(tr("בוקר טוב, סיכום ערב, ופיד יומי", "Good morning, evening recap, and daily feed"))
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
                SectionLabel(icon: "rectangle.connected.to.line.below", title: tr("מקורות נתונים", "Data sources"))

                Text(tr("אפשר לבחור כמה מקורות במקביל — לימור תאחד את הכל.", "You can select several sources at once — Limor will combine them all."))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                MultiSourcePicker(
                    title: tr("יומן", "Calendar"),
                    iconName: "calendar",
                    options: [
                        .init(value: .apple,     label: tr("אפל (iOS Calendar)", "Apple (iOS Calendar)"), description: tr("כולל כל היומנים שחיברת ב-iOS", "Includes every calendar you've connected in iOS")),
                        .init(value: .google,    label: "Google Calendar", description: tr("דורש חיבור Google + אישור scope", "Requires a Google connection + scope approval")),
                        .init(value: .microsoft, label: "Outlook / Office 365", description: tr("דורש חיבור Microsoft + אישור scope", "Requires a Microsoft connection + scope approval")),
                    ],
                    selection: $calendarSources
                )

                Divider().padding(.vertical, 4)

                MultiSourcePicker(
                    title: tr("מייל", "Mail"),
                    iconName: "envelope",
                    options: [
                        .init(value: .google,    label: "Gmail", description: tr("דורש חיבור Google + אישור scope", "Requires a Google connection + scope approval")),
                        .init(value: .microsoft, label: "Outlook / Office 365", description: tr("דורש חיבור Microsoft + אישור scope", "Requires a Microsoft connection + scope approval")),
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
                SectionLabel(icon: "rectangle.stack.badge.plus", title: tr("כפתור מהיר בתחתית", "Quick button at the bottom"))

                Text(tr("אפשר להצמיד קיצור דרך נוסף לסרגל התחתון, ליד \"הפיד שלי\".", "You can pin an extra shortcut to the bottom bar, next to \"My feed\"."))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                VStack(spacing: 6) {
                    customTabRow(value: nil, label: tr("ללא", "None"), icon: "minus.circle")
                    customTabRow(value: .shoppingList, label: tr("רשימת קניות", "Shopping list"), icon: "cart.fill")
                    customTabRow(value: .meetings, label: tr("פגישות", "Meetings"), icon: "calendar")
                }
            }
        }
    }

    /// The app owner sees an extra entry to the company-management screen.
    /// Must match OWNER_EMAIL on the backend.
    private var isOwner: Bool {
        (auth.email ?? "").lowercased() == "ranioph@gmail.com"
    }

    /// Shown to a user who manages a company — opens their company's billing.
    private var companyManagerCard: some View {
        NavigationLink {
            CompanyManagerView(initial: myCompany)
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "building.2.fill")
                        .font(.title3).foregroundStyle(.limorMint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("החברה שלי — \(myCompany?.name ?? "")", "My company — \(myCompany?.name ?? "")"))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorInk).lineLimit(1)
                        Text(tr("כמה החברה משלמת החודש ופירוק לפי משתמש", "How much the company pays this month and a per-user breakdown"))
                            .font(.caption).foregroundStyle(.limorMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.left").font(.caption.weight(.bold)).foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var ownerAdminCard: some View {
        NavigationLink {
            AdminBillingView()
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.doc.horizontal.fill")
                        .font(.title3).foregroundStyle(.limorIndigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("ניהול חברות וחיוב", "Company & billing management"))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorInk)
                        Text(tr("צור חברות, קודי רישיון, וכמה לגבות החודש", "Create companies, license codes, and how much to charge this month"))
                            .font(.caption).foregroundStyle(.limorMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.left").font(.caption.weight(.bold)).foregroundStyle(.limorMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Organization / B2B license — a company user enters the license code
    /// their company received, so their usage is billed to that company.
    private var organizationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "building.2.fill", title: tr("ארגון / רישיון", "Organization / license"))

                if let org = currentOrg {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.limorMint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("מחובר ל-\(org.name)", "Connected to \(org.name)"))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.limorInk)
                            Text(tr("השימוש שלך מחויב לארגון זה", "Your usage is billed to this organization"))
                                .font(.caption).foregroundStyle(.limorMuted)
                        }
                        Spacer()
                    }
                    Button(role: .destructive) {
                        Task {
                            try? await APIClient.shared.leaveOrg()
                            currentOrg = nil
                        }
                    } label: {
                        Text(tr("ניתוק מהארגון", "Disconnect from organization")).font(.subheadline.weight(.semibold))
                    }
                } else {
                    Text(tr("יש לך קוד רישיון מחברה? הזן אותו כדי לחבר את החשבון לארגון.", "Have a license code from a company? Enter it to connect your account to the organization."))
                        .font(.caption).foregroundStyle(.limorMuted)
                    HStack(spacing: 8) {
                        TextField(tr("קוד רישיון", "License code"), text: $licenseDraft)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.limorInk.opacity(0.06)))
                        Button {
                            Task { await joinOrg() }
                        } label: {
                            if joiningOrg { ProgressView() }
                            else { Text(tr("חיבור", "Connect")).font(.subheadline.weight(.bold)) }
                        }
                        .disabled(joiningOrg || licenseDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let orgError {
                        Text(orgError).font(.caption).foregroundStyle(.limorCoral)
                    }
                }
            }
        }
    }

    private func joinOrg() async {
        joiningOrg = true; orgError = nil
        defer { joiningOrg = false }
        do {
            currentOrg = try await APIClient.shared.joinOrg(
                licenseCode: licenseDraft.trimmingCharacters(in: .whitespaces))
            licenseDraft = ""
        } catch {
            orgError = tr("קוד לא תקין או שאינו פעיל.", "Invalid or inactive code.")
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
                SectionLabel(icon: "list.bullet.rectangle", title: tr("רשימת תזכורות", "Reminders list"))

                Text(tr("לאן לימור תוסיף תזכורות באפליקציית Reminders של אפל.", "Where Limor will add reminders in Apple's Reminders app."))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                if reminderLists.isEmpty {
                    HStack {
                        Text(tr("אין הרשאת תזכורות עדיין", "No Reminders permission yet"))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                        Spacer()
                        Button(tr("בקש הרשאה", "Request permission")) {
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
                                Text(tr("ברירת מחדל של iOS", "iOS default"))
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
        return tr("ברירת מחדל של iOS", "iOS default")
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
                    SectionLabel(icon: "checkmark.shield", title: tr("הרשאות", "Permissions"))
                    Spacer()
                    Button {
                        Task {
                            await SyncManager.shared.syncAll(force: true)
                            await refreshPermissions()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2.weight(.bold))
                            Text(tr("סנכרן עכשיו", "Sync now")).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(LimorGradient.brand))
                    }
                    .buttonStyle(.plain)
                }

                PermissionRow(
                    icon: "calendar",
                    title: tr("יומן (iOS)", "Calendar (iOS)"),
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
                    title: tr("אנשי קשר", "Contacts"),
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
                    title: tr("בריאות", "Health"),
                    granted: permissionSnapshot.health,
                    action: { await requestHealth() }
                )
                PermissionRow(
                    icon: "location.fill",
                    title: tr("מיקום", "Location"),
                    granted: permissionSnapshot.location,
                    action: { LocationManager.shared.requestWhenInUseAndStart() }
                )
                PermissionRow(
                    icon: "bell.fill",
                    title: tr("התראות", "Notifications"),
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
                    Text(tr("בדוק התראות", "Test notifications"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.limorInk)
                    Text(pushDiagnosticStatus ?? tr("שולח התראת בדיקה ומחדש רישום לשרת", "Sends a test notification and re-registers with the server"))
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
            pushDiagnosticStatus = tr("התראות חסומות במערכת. פתח הגדרות → לימור → התראות", "Notifications are blocked in system settings. Open Settings → Limor → Notifications")
            return
        }

        await PushManager.shared.refreshAndUploadToken()

        let content = UNMutableNotificationContent()
        content.title = tr("בדיקת התראות", "Notification test")
        content.body = tr("אם אתה רואה את זה, מערכת ההתראות עובדת ✅", "If you see this, the notification system is working ✅")
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
                ? tr("נשלחה התראה מקומית. הרישום לשרת חודש ✅", "Local notification sent. Server registration refreshed ✅")
                : tr("התראה מקומית נשלחה, אבל אין עדיין FCM token. נסה שוב בעוד רגע.", "Local notification sent, but there's no FCM token yet. Try again in a moment.")
        } catch {
            pushDiagnosticStatus = tr("שגיאה: \(error.localizedDescription)", "Error: \(error.localizedDescription)")
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
            Text(tr("גרסה \(short) (\(build)) · \(BuildInfo.gitSha)", "Version \(short) (\(build)) · \(BuildInfo.gitSha)"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.limorMuted)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var languageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "globe", title: tr("שפה", "Language"))
                Picker("", selection: Binding(
                    get: { lang.lang },
                    set: { lang.lang = $0 }
                )) {
                    ForEach(AppLang.allCases) { l in
                        Text(l.display).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                Text(tr(
                    "משנה את כל האפליקציה — גם הטקסטים וגם מה שלימור כותבת.",
                    "Switches the whole app — both the interface and what Limor writes."
                ))
                .font(.caption).foregroundStyle(.limorMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: What's using my tokens (per-user, own data)

    @ViewBuilder
    private var usageCard: some View {
        if let u = myUsage, !u.by_feature.isEmpty {
            let top = u.by_feature.first!.cost
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(icon: "chart.bar.fill", title: tr("מה משתמש בטוקנים שלך", "What's using your tokens"), tint: .limorIndigo)
                    Text(tr("פירוט לפי פיצ'ר, \(u.days) הימים האחרונים · \(u.total_calls) פעולות AI.", "By feature, last \(u.days) days · \(u.total_calls) AI actions."))
                        .font(.caption2).foregroundStyle(.limorMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(u.by_feature.prefix(8)) { f in
                        let pct = u.total_cost > 0 ? Int((f.cost / u.total_cost * 100).rounded()) : 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(usageFeatureName(f.feature))
                                    .font(.subheadline.weight(.medium)).foregroundStyle(.limorInk)
                                Spacer()
                                Text("\(pct)%").font(.caption.weight(.bold)).foregroundStyle(.limorIndigo)
                                Text("· \(f.calls)").font(.caption2).foregroundStyle(.limorMuted)
                            }
                            ProgressView(value: f.cost, total: max(top, 0.0001))
                                .tint(.limorIndigo)
                        }
                    }
                }
            }
        }
    }

    private func usageFeatureName(_ key: String) -> String {
        switch key {
        case "chat":            return tr("צ'אט", "Chat")
        case "news":            return tr("חדשות", "News")
        case "worldcup":        return tr("מונדיאל", "World Cup")
        case "briefing":        return tr("תקציר מנהלים", "Executive briefing")
        case "recommendations": return tr("טיפ אישי", "Personal tips")
        case "flights":         return tr("טיסות", "Flights")
        case "hotels":          return tr("מלונות", "Hotels")
        case "receipts":        return tr("קבלות", "Receipts")
        case "email_actions":   return tr("מוקד מייל", "Email focus")
        case "feed_suggest":    return tr("הצעות נושאים", "Topic suggestions")
        // Usage rows logged before feature tagging existed (≤ mid-June 2026)
        // have no feature field; the server groups them as "(untagged)".
        // They age out of the 30-day window on their own.
        case "(untagged)":      return tr("שימוש ישן (לפני סיווג)", "Older usage (pre-tagging)")
        default:                return tr("אחר", "Other")
        }
    }

    private var linkAccountsCard: some View {
        let appleLinked = auth.linkedProviders.contains("apple.com")
        let googleLinked = auth.linkedProviders.contains("google.com")
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "link", title: tr("קישור חשבונות", "Link accounts"))

                Text(tr("קשרי גם Apple וגם Google לאותו חשבון — כך תוכלי להתחבר עם כל אחד מהם בכל מכשיר ולהגיע לאותם הנתונים. נוח כשמתחברים במכשיר חדש.", "Link both Apple and Google to the same account — so you can sign in with either one on any device and reach the same data. Handy when signing in on a new device."))
                    .font(.caption).foregroundStyle(.limorMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // Apple
                providerRow(
                    icon: "apple.logo", name: "Apple", linked: appleLinked
                ) {
                    SignInWithAppleButton(.continue) { request in
                        auth.prepareLinkRequest(request)
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            Task { await linkApple(authorization) }
                        case .failure(let err):
                            if (err as NSError).code != ASAuthorizationError.canceled.rawValue {
                                errorMessage = err.localizedDescription
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: 120, height: 34)
                }

                // Google
                providerRow(
                    icon: "g.circle.fill", name: "Google", linked: googleLinked
                ) {
                    Button {
                        Task { await linkGoogle() }
                    } label: {
                        if linkingGoogle {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(tr("קשר", "Link")).font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.limorIndigo)
                    .disabled(linkingGoogle)
                }

                if let linkSuccess {
                    Label(linkSuccess, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private func providerRow<Trailing: View>(
        icon: String, name: String, linked: Bool,
        @ViewBuilder action: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).frame(width: 26)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.limorInk)
            Spacer()
            if linked {
                Label(tr("מקושר", "Linked"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else {
                action()
            }
        }
    }

    private func linkGoogle() async {
        linkingGoogle = true
        defer { linkingGoogle = false }
        do {
            try await auth.linkGoogle()
            linkSuccess = tr("Google קושר בהצלחה ✨", "Google linked successfully ✨")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func linkApple(_ authorization: ASAuthorization) async {
        do {
            try await auth.completeAppleLink(authorization: authorization)
            linkSuccess = tr("Apple קושר בהצלחה ✨", "Apple linked successfully ✨")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var accountCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "person.crop.circle.badge.minus", title: tr("חשבון", "Account"))

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(tr("יציאה", "Sign out")).font(.subheadline.weight(.semibold))
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
                errorMessage = tr("לא הצלחתי לטעון את התמונה.", "I couldn't load the image.")
                photoItem = nil
                return
            }
            photoPendingCrop = IdentifiedImage(image: uiImage.normalizedOrientation())
        } catch {
            errorMessage = error.localizedDescription
            photoItem = nil
        }
    }

    private func uploadCroppedPhoto(_ image: UIImage) async {
        savingPhoto = true
        defer { savingPhoto = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            errorMessage = tr("לא הצלחתי לדחוס את התמונה.", "I couldn't compress the image.")
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
                    Text(tr("מאושר", "Granted"))
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
                        Text(tr("הפעל", "Enable"))
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
