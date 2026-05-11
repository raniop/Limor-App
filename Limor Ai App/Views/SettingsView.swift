import EventKit
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var nameDraft: String = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var savingName = false
    @State private var calendarSource: DataSource = SharedStore.calendarSource
    @State private var emailSource: DataSource = SharedStore.emailSource
    @State private var permissionSnapshot = PermissionSnapshot()
    @State private var errorMessage: String?
    @State private var reminderLists: [EKCalendar] = []
    @State private var selectedReminderListId: String? = SharedStore.remindersListId

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        profileCard
                        memoryCard
                        sourcesCard
                        remindersListCard
                        permissionsCard
                        accountCard
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
                Task { await loadAndSavePhoto(item: newItem) }
            }
            .onChange(of: calendarSource) { _, newValue in
                SharedStore.calendarSource = newValue
                if newValue == .google {
                    Task {
                        do { try await GoogleAPIs.ensureScopes([GoogleAPIs.calendarReadOnlyScope]) }
                        catch { errorMessage = error.localizedDescription }
                        await SyncManager.shared.syncCalendar(force: true)
                    }
                }
            }
            .onChange(of: emailSource) { _, newValue in
                SharedStore.emailSource = newValue
                if newValue == .google {
                    Task {
                        do { try await GoogleAPIs.ensureScopes([GoogleAPIs.gmailReadOnlyScope]) }
                        catch { errorMessage = error.localizedDescription }
                        await SyncManager.shared.syncEmail(force: true)
                    }
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

    // MARK: Sources (Apple / Google)

    private var sourcesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "rectangle.connected.to.line.below", title: "מקורות נתונים")

                SourcePicker(
                    title: "יומן",
                    iconName: "calendar",
                    options: [
                        .init(value: .apple,  label: "אפל (iOS Calendar)", description: "כולל כל היומנים שחיברת ב-iOS"),
                        .init(value: .google, label: "Google Calendar", description: "דורש חיבור Google + אישור scope"),
                    ],
                    disabled: [],
                    selection: $calendarSource
                )

                Divider().padding(.vertical, 4)

                SourcePicker(
                    title: "מייל",
                    iconName: "envelope",
                    options: [
                        .init(value: .none,   label: "כבוי", description: "לימור לא קוראת מיילים"),
                        .init(value: .google, label: "Gmail", description: "דורש חיבור Google + אישור scope"),
                    ],
                    disabled: [],
                    selection: $emailSource
                )
            }
        }
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
                if calendarSource == .google {
                    PermissionRow(
                        icon: "calendar.badge.checkmark",
                        title: "Google Calendar",
                        granted: permissionSnapshot.googleCalendar,
                        action: { await connectGoogleCalendar() }
                    )
                }
                PermissionRow(
                    icon: "person.crop.circle",
                    title: "אנשי קשר",
                    granted: permissionSnapshot.contacts,
                    action: { await requestContacts() }
                )
                if emailSource == .google {
                    PermissionRow(
                        icon: "envelope.fill",
                        title: "Gmail",
                        granted: permissionSnapshot.googleGmail,
                        action: { await connectGmail() }
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
                    action: { await PushManager.shared.requestPermissionIfNeeded() }
                )
            }
        }
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

    private func loadAndSavePhoto(item: PhotosPickerItem) async {
        savingPhoto = true
        defer { savingPhoto = false; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                errorMessage = "לא הצלחתי לטעון את התמונה."
                return
            }
            // Center-crop to a square so the avatar always fills the circle,
            // then downscale for upload. Honors EXIF orientation.
            let normalized = uiImage.normalizedOrientation()
            let cropped = normalized.centerCroppedToSquare()
            let resized = cropped.resized(toMaxDimension: 256)
            guard let jpeg = resized.jpegData(compressionQuality: 0.7) else {
                errorMessage = "לא הצלחתי לדחוס את התמונה."
                return
            }
            let b64 = jpeg.base64EncodedString()
            try await auth.setProfilePhoto(jpegB64: b64)
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

private struct SourcePicker: View {
    let title: String
    let iconName: String
    let options: [Option]
    let disabled: Set<DataSource>
    @Binding var selection: DataSource

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
                    Button {
                        if !disabled.contains(opt.value) { selection = opt.value }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selection == opt.value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(disabled.contains(opt.value) ? Color.limorMuted : Color.limorIndigo)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(opt.label).font(.subheadline.weight(.semibold))
                                    if disabled.contains(opt.value) {
                                        Text("בקרוב")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.limorWarning))
                                    }
                                }
                                Text(opt.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selection == opt.value ? Color.limorIndigo.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled.contains(opt.value))
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
