import SwiftUI

/// Shown when the account has no AI access (not in a company, not approved).
/// Lets the user enter a license code on the spot, or contact the owner.
struct NoAccessView: View {
    var onDismiss: () -> Void

    @State private var code = ""
    @State private var joining = false
    @State private var error: String?
    @State private var joined = false

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44)).foregroundStyle(.limorIndigo)
                Text(joined ? tr("מחובר! ✨", "Connected! ✨") : tr("החשבון לא מחובר", "Account not connected"))
                    .font(.title2.weight(.bold)).foregroundStyle(.limorInk)
                if joined {
                    Text(tr("עכשיו אפשר להשתמש בלימור.", "You can now use Limor."))
                        .font(.subheadline).foregroundStyle(.limorMuted)
                    Button(tr("המשך", "Continue")) { onDismiss() }
                        .buttonStyle(LimorPrimaryButtonStyle())
                } else {
                    Text(tr("כדי להשתמש בלימור צריך קוד רישיון מהארגון שלך, או אישור מהמנהל. הזן את הקוד שקיבלת:", "To use Limor you need a license code from your organization, or approval from your admin. Enter the code you received:"))
                        .font(.subheadline).foregroundStyle(.limorMuted)
                        .multilineTextAlignment(.center)
                    TextField(tr("קוד רישיון", "License code"), text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.limorInk.opacity(0.06)))
                    Button {
                        Task { await join() }
                    } label: {
                        if joining { ProgressView() } else { Text(tr("חיבור", "Connect")).frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(LimorPrimaryButtonStyle())
                    .disabled(joining || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error { Text(error).font(.caption).foregroundStyle(.limorCoral) }
                }
            }
            .padding(24)
        }
        .interactiveDismissDisabled(!joined)
    }

    private func join() async {
        joining = true; error = nil
        defer { joining = false }
        do {
            _ = try await APIClient.shared.joinOrg(licenseCode: code.trimmingCharacters(in: .whitespaces))
            joined = true
        } catch {
            self.error = tr("קוד לא תקין או שאינו פעיל.", "Invalid or inactive code.")
        }
    }
}

/// Owner-only management screen: create companies (a license code is generated
/// automatically) and see how much to charge each one this month. Everything
/// the operator needs, in-app — no terminal.
struct AdminBillingView: View {
    @State private var overview: APIClient.AdminOverview?
    @State private var loading = false
    @State private var newName = ""
    @State private var creating = false
    @State private var createdCode: String?
    @State private var errorMessage: String?
    @State private var users: [APIClient.AdminUser] = []
    @State private var orgToDelete: APIClient.OrgFull?
    @State private var shareItem: ShareItem?
    @State private var copiedId: String?
    @State private var usage: APIClient.UsageBreakdown?

    private var tint: Color { .limorIndigo }

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    createCard
                    if let errorMessage {
                        GlassCard { Text(errorMessage).font(.subheadline).foregroundStyle(.limorCoral) }
                    }
                    billingCard
                    usageCard
                    usersCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .navigationTitle(tr("ניהול חברות", "Manage companies"))
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.text]) }
        .confirmationDialog(
            tr("למחוק את \(orgToDelete?.name ?? "החברה")?", "Delete \(orgToDelete?.name ?? "the company")?"),
            isPresented: Binding(get: { orgToDelete != nil }, set: { if !$0 { orgToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("מחק חברה", "Delete company"), role: .destructive) {
                if let org = orgToDelete { Task { await deleteOrg(org) } }
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) { orgToDelete = nil }
        } message: {
            Text(tr("המשתמשים ינותקו מהחברה ויאבדו גישה (אלא אם אושרו אישית). פעולה זו לא הפיכה.", "Users will be disconnected from the company and lose access (unless individually approved). This action cannot be undone."))
        }
    }

    // MARK: Create company

    private var createCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "plus.circle.fill", title: tr("צור חברה חדשה", "Create a new company"), tint: tint)
                HStack(spacing: 8) {
                    TextField(tr("שם החברה", "Company name"), text: $newName)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.limorInk.opacity(0.06)))
                    Button {
                        Task { await create() }
                    } label: {
                        if creating { ProgressView() }
                        else { Text(tr("צור", "Create")).font(.subheadline.weight(.bold)) }
                    }
                    .disabled(creating || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let code = createdCode {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.limorMint)
                        Text(tr("קוד הרישיון: ", "License code: "))
                            .font(.subheadline).foregroundStyle(.limorMuted)
                        + Text(code).font(.subheadline.weight(.bold).monospaced()).foregroundStyle(.limorInk)
                        Spacer()
                        Button { copyCode(code, id: "created") } label: { copyIcon(id: "created") }
                        Button { shareItem = ShareItem(text: shareMessage(code: code)) } label: {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(tint)
                        }
                    }
                    if copiedId == "created" {
                        Text(tr("✓ הקוד הועתק", "✓ Code copied")).font(.caption2.weight(.semibold)).foregroundStyle(.limorMint)
                    }
                    Text(tr("שלח את הקוד הזה לחברה — העובדים יזינו אותו בהגדרות → ארגון/רישיון.", "Send this code to the company — employees enter it in Settings → Organization/License."))
                        .font(.caption2).foregroundStyle(.limorMuted)
                }
            }
        }
    }

    // MARK: Billing list

    private var billingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(icon: "building.2.fill", title: tr("חיוב החודש", "This month's billing"), tint: tint)
                    Spacer()
                    if let o = overview {
                        Text(tr("סה״כ לחיוב $\(String(format: "%.2f", o.total_charge_usd))", "Total to bill $\(String(format: "%.2f", o.total_charge_usd))"))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorInk)
                    }
                }
                Text(tr("🟢 ירוק = לחיוב (העלות שלך × מכפיל) · אפור = העלות שלך בפועל", "🟢 Green = to bill (your cost × multiplier) · Gray = your actual cost"))
                    .font(.caption2).foregroundStyle(.limorMuted)
                if loading && overview == nil {
                    ProgressView().tint(tint).frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if let orgs = overview?.orgs, !orgs.isEmpty {
                    ForEach(orgs) { org in
                        orgRow(org)
                        if org.id != orgs.last?.id { Divider().opacity(0.4) }
                    }
                } else {
                    Text(tr("עוד אין חברות. צור חברה ראשונה למעלה.", "No companies yet. Create your first one above."))
                        .font(.subheadline).foregroundStyle(.limorMuted)
                }
            }
        }
    }

    // MARK: Usage breakdown — what's eating tokens (last 7 days)

    private var usageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(icon: "bolt.fill", title: tr("מה זולל טוקנים (7 ימים)", "What's eating tokens (7 days)"), tint: tint)
                    Spacer()
                    if let u = usage {
                        Text("$\(String(format: "%.2f", u.total_cost)) · $\(String(format: "%.2f", u.total_cost / Double(max(u.days, 1))))\(tr("/יום", "/day"))")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorInk)
                    }
                }
                Text(tr("העלות בפועל שלך מול Anthropic. הפילוח לפי פיצ'ר מתמלא קדימה מרגע ההפעלה.", "Your actual Anthropic cost. The per-feature breakdown fills in going forward from when this shipped."))
                    .font(.caption2).foregroundStyle(.limorMuted)

                if usage == nil {
                    ProgressView().tint(tint).frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if let u = usage {
                    usageSection(tr("לפי פיצ'ר", "By feature"), u.by_feature.map { ($0.feature, $0.cost, $0.calls) })
                    Divider().opacity(0.4)
                    usageSection(tr("לפי מודל", "By model"), u.by_model.map { ($0.model, $0.cost, $0.calls) })
                    Divider().opacity(0.4)
                    usageSection(tr("לפי משתמש", "By user"), u.by_user.map { ($0.email ?? $0.user_id, $0.cost, $0.calls) })
                }
            }
        }
    }

    private func usageSection(_ title: String, _ rows: [(String, Double, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.limorMuted)
            ForEach(Array(rows.prefix(12).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0).font(.subheadline).foregroundStyle(.limorInk).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(row.2)").font(.caption2).foregroundStyle(.limorMuted)
                    Text("$\(String(format: "%.2f", row.1))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.limorInk)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }

    private func orgRow(_ org: APIClient.OrgFull) -> some View {
        HStack(spacing: 8) {
            // Tapping the info opens the company's user breakdown.
            NavigationLink {
                CompanyUsersView(org: org, allOrgs: overview?.orgs ?? [])
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(org.name).font(.subheadline.weight(.bold)).foregroundStyle(.limorInk)
                        Spacer()
                        Text("$\(String(format: "%.2f", org.charge_usd ?? 0))")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorMint)
                    }
                    HStack(spacing: 8) {
                        Label(org.license_code, systemImage: "key.fill")
                            .font(.caption2.monospaced()).foregroundStyle(.limorMuted)
                        Text(tr("· \(org.users ?? 0) משתמשים", "· \(org.users ?? 0) users"))
                            .font(.caption2).foregroundStyle(.limorMuted)
                        Text(tr("· עלות $\(String(format: "%.2f", org.raw_cost_usd ?? 0))", "· cost $\(String(format: "%.2f", org.raw_cost_usd ?? 0))"))
                            .font(.caption2).foregroundStyle(.limorMuted)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.limorMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            // Quick actions stay outside the link so they don't trigger navigation.
            Button { copyCode(org.license_code, id: org.id) } label: {
                copyIcon(id: org.id).font(.caption)
            }.buttonStyle(.plain)
            Button { shareItem = ShareItem(text: shareMessage(code: org.license_code, company: org.name)) } label: {
                Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(tint)
            }.buttonStyle(.plain)
            Button(role: .destructive) { orgToDelete = org } label: {
                Image(systemName: "trash").font(.caption).foregroundStyle(.limorCoral)
            }.buttonStyle(.plain)
        }
    }

    private func deleteOrg(_ org: APIClient.OrgFull) async {
        orgToDelete = nil
        do {
            try await APIClient.shared.adminDeleteOrg(orgId: org.id)
            await load()
        } catch { errorMessage = tr("מחיקת החברה נכשלה.", "Failed to delete the company.") }
    }

    /// Copy a code to the clipboard with a haptic + a transient "✓ הועתק"
    /// confirmation (the doc icon flips to a checkmark for ~1.5s).
    private func copyCode(_ code: String, id: String) {
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedId = id
        Task { try? await Task.sleep(for: .seconds(1.5)); if copiedId == id { copiedId = nil } }
    }

    @ViewBuilder
    private func copyIcon(id: String) -> some View {
        Image(systemName: copiedId == id ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copiedId == id ? .limorMint : tint)
    }

    /// The message the owner shares with a company / user along with the code.
    private func shareMessage(code: String, company: String? = nil) -> String {
        let who = company.map { tr(" עבור \($0)", " for \($0)") } ?? ""
        return tr("קוד הרישיון שלך ללימור\(who): \(code)\nהזן אותו באפליקציה: הגדרות → ארגון/רישיון → חיבור.", "Your Limor license code\(who): \(code)\nEnter it in the app: Settings → Organization/License → Connect.")
    }

    // MARK: Users (who is using / spending what + approve / block)

    /// Individually-approved users (access granted, not part of a company).
    private var approvedUsers: [APIClient.AdminUser] {
        users.filter { $0.org_id == nil && $0.allowed }.sorted { $0.cost_usd > $1.cost_usd }
    }
    /// Accounts with no access yet — not in a company and not approved.
    private var pendingUsers: [APIClient.AdminUser] {
        users.filter { $0.org_id == nil && !$0.allowed }
    }

    private var usersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Individually approved — shown with each one's spend.
                if !approvedUsers.isEmpty {
                    HStack {
                        SectionLabel(icon: "person.badge.shield.checkmark", title: tr("אושרו אישית", "Individually approved"), tint: tint)
                        Spacer()
                        Text("$\(String(format: "%.2f", approvedUsers.reduce(0) { $0 + $1.cost_usd }))")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.limorMint)
                    }
                    ForEach(approvedUsers) { u in userRow(u) }
                    Divider().opacity(0.4)
                }

                // Pending / blocked.
                HStack {
                    SectionLabel(icon: "person.crop.circle.badge.clock", title: tr("ממתינים לאישור", "Awaiting approval"), tint: tint)
                    Spacer()
                    if !pendingUsers.isEmpty {
                        Text("\(pendingUsers.count)")
                            .font(.caption.weight(.bold)).foregroundStyle(.limorCoral)
                    }
                }
                Text(tr("חשבונות שנכנסו אך עדיין חסומים. שייך אותם לחברה או אשר אישית.", "Accounts that signed in but are still blocked. Assign them to a company or approve individually."))
                    .font(.caption2).foregroundStyle(.limorMuted)
                if pendingUsers.isEmpty {
                    Text(tr("אין חשבונות שממתינים לאישור 👍", "No accounts awaiting approval 👍"))
                        .font(.subheadline).foregroundStyle(.limorMuted)
                } else {
                    ForEach(pendingUsers) { u in
                        userRow(u)
                        if u.id != pendingUsers.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private func userRow(_ u: APIClient.AdminUser) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.circle.fill").font(.body).foregroundStyle(.limorMuted)
            Text(u.email ?? u.user_id)
                .font(.subheadline).foregroundStyle(.limorInk).lineLimit(1)
            Spacer(minLength: 6)
            Text("$\(String(format: "%.2f", u.cost_usd))")
                .font(.caption.weight(.semibold)).foregroundStyle(.limorMuted)
            // Menu: assign to a company, approve as an individual, or block.
            Menu {
                if let orgs = overview?.orgs, !orgs.isEmpty {
                    Section(tr("שייך לחברה", "Assign to company")) {
                        ForEach(orgs) { org in
                            Button {
                                Task { await assign(u, orgId: org.id) }
                            } label: {
                                Label(org.name, systemImage: u.org_name == org.name ? "checkmark" : "building.2")
                            }
                        }
                    }
                }
                Button {
                    Task { await approveIndividual(u) }
                } label: { Label(tr("אשר כיחיד (בלי חברה)", "Approve as individual (no company)"), systemImage: "person.badge.shield.checkmark") }
                Button(role: .destructive) {
                    Task { await block(u) }
                } label: { Label(tr("חסום", "Block"), systemImage: "nosign") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body).foregroundStyle(.limorIndigo)
            }
        }
        .padding(.leading, 4)
    }

    private func assign(_ u: APIClient.AdminUser, orgId: String) async {
        do {
            try await APIClient.shared.adminSetUserOrg(userId: u.user_id, orgId: orgId)
            await load()
        } catch { errorMessage = tr("שיוך נכשל.", "Assignment failed.") }
    }

    private func approveIndividual(_ u: APIClient.AdminUser) async {
        do {
            try await APIClient.shared.adminSetUserOrg(userId: u.user_id, orgId: nil)
            try await APIClient.shared.adminSetUserAccess(userId: u.user_id, allowed: true)
            await load()
        } catch { errorMessage = tr("אישור נכשל.", "Approval failed.") }
    }

    private func block(_ u: APIClient.AdminUser) async {
        do {
            try await APIClient.shared.adminSetUserOrg(userId: u.user_id, orgId: nil)
            try await APIClient.shared.adminSetUserAccess(userId: u.user_id, allowed: false)
            await load()
        } catch { errorMessage = tr("חסימה נכשלה.", "Block failed.") }
    }

    // MARK: Actions

    private func load() async {
        loading = true
        errorMessage = nil   // clear any prior error so it doesn't stick
        defer { loading = false }
        do {
            async let ov = APIClient.shared.adminOverview()
            async let us = APIClient.shared.adminUsers()
            async let ub = APIClient.shared.adminUsageBreakdown(days: 7)
            overview = try await ov
            users = try await us
            usage = try? await ub
        }
        catch { errorMessage = tr("טעינה נכשלה — ודא שאתה מחובר עם חשבון הבעלים.", "Loading failed — make sure you're signed in with the owner account.") }
    }

    private func create() async {
        creating = true; errorMessage = nil
        defer { creating = false }
        do {
            let org = try await APIClient.shared.adminCreateOrg(
                name: newName.trimmingCharacters(in: .whitespaces))
            createdCode = org.license_code
            newName = ""
            await load()
        } catch {
            errorMessage = tr("יצירת החברה נכשלה — נסה שוב.", "Failed to create the company — try again.")
        }
    }
}

// MARK: - Company detail (users + per-user spend)

/// Drill-down for one company: every user in it with how much each spends,
/// plus per-user actions (reassign / remove from company).
struct CompanyUsersView: View {
    let org: APIClient.OrgFull
    let allOrgs: [APIClient.OrgFull]

    @State private var users: [APIClient.AdminUser] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var shareItem: ShareItem?
    @State private var copied = false
    @State private var managerEmail: String = ""
    @State private var savingManager = false

    private var tint: Color { .limorIndigo }
    private var total: Double { users.reduce(0) { $0 + $1.cost_usd } }

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerCard
                    managerCard
                    usersCard
                    if let loadError {
                        GlassCard { Text(loadError).font(.subheadline).foregroundStyle(.limorCoral) }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .navigationTitle(org.name)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.text]) }
    }

    private var headerCard: some View {
        GlassCard(tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(org.license_code, systemImage: "key.fill")
                        .font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(.limorInk)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = org.license_code
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? .limorMint : tint)
                    }
                    Button {
                        shareItem = ShareItem(text: tr("קוד הרישיון של \(org.name): \(org.license_code)\nהזן באפליקציה: הגדרות → ארגון/רישיון.", "License code for \(org.name): \(org.license_code)\nEnter it in the app: Settings → Organization/License."))
                    } label: {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(tint)
                    }
                }
                HStack {
                    Text(tr("\(users.count) משתמשים", "\(users.count) users")).font(.caption).foregroundStyle(.limorMuted)
                    Spacer()
                    Text(tr("לחיוב: $\(String(format: "%.2f", total * (org.price_multiplier ?? 1.5)))", "To bill: $\(String(format: "%.2f", total * (org.price_multiplier ?? 1.5)))"))
                        .font(.subheadline.weight(.bold)).foregroundStyle(.limorMint)
                }
                Text(tr("עלות גולמית $\(String(format: "%.2f", total)) · מכפיל ×\(String(format: "%.1f", org.price_multiplier ?? 1.5))", "Raw cost $\(String(format: "%.2f", total)) · multiplier ×\(String(format: "%.1f", org.price_multiplier ?? 1.5))"))
                    .font(.caption2).foregroundStyle(.limorMuted)
            }
        }
    }

    private var usersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "person.2.fill", title: tr("משתמשים", "Users"), tint: tint)
                if loading && users.isEmpty {
                    ProgressView().tint(tint).frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if users.isEmpty {
                    Text(tr("עדיין אין משתמשים בחברה הזו. שלח להם את קוד הרישיון.", "No users in this company yet. Send them the license code."))
                        .font(.subheadline).foregroundStyle(.limorMuted)
                } else {
                    ForEach(users.sorted { $0.cost_usd > $1.cost_usd }) { u in
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill").foregroundStyle(.limorMuted)
                            Text(u.email ?? u.user_id).font(.subheadline).foregroundStyle(.limorInk).lineLimit(1)
                            if isManager(u) {
                                Text(tr("מנהל", "Manager"))
                                    .font(.caption2.weight(.bold)).foregroundStyle(.limorIndigo)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.limorIndigo.opacity(0.14)))
                            }
                            Spacer(minLength: 6)
                            Text("$\(String(format: "%.2f", u.cost_usd))")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.limorMuted)
                            Menu {
                                if let email = u.email, !email.isEmpty {
                                    Button {
                                        Task { await setAsManager(email) }
                                    } label: {
                                        Label(isManager(u) ? tr("מנהל החברה ✓", "Company manager ✓") : tr("הגדר כמנהל החברה", "Set as company manager"),
                                              systemImage: "person.badge.key.fill")
                                    }
                                }
                                Section(tr("העבר לחברה", "Move to company")) {
                                    ForEach(allOrgs.filter { $0.id != org.id }) { other in
                                        Button(other.name) { Task { await move(u, to: other.id) } }
                                    }
                                }
                                Button(role: .destructive) {
                                    Task { await remove(u) }
                                } label: { Label(tr("הסר מהחברה", "Remove from company"), systemImage: "person.badge.minus") }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.limorIndigo)
                            }
                        }
                        if u.id != users.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private var managerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(icon: "person.badge.key.fill", title: tr("מנהל החברה", "Company manager"), tint: tint)
                Text(tr("מי שתגדיר כאן יוכל לראות באפליקציה שלו את החיוב של החברה הזו בלבד (סה״כ ופירוק לפי משתמש) — בלי גישה לחברות אחרות.", "Whoever you set here will be able to see this company's billing in their own app (total and per-user breakdown) — with no access to other companies."))
                    .font(.caption2).foregroundStyle(.limorMuted)
                HStack(spacing: 8) {
                    TextField(tr("מייל המנהל", "Manager's email"), text: $managerEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.limorInk.opacity(0.06)))
                    Button {
                        Task { await saveManager() }
                    } label: {
                        if savingManager { ProgressView() } else { Text(tr("שמור", "Save")).font(.subheadline.weight(.bold)) }
                    }
                    .disabled(savingManager)
                }
            }
        }
    }

    private func isManager(_ u: APIClient.AdminUser) -> Bool {
        let m = managerEmail.trimmingCharacters(in: .whitespaces).lowercased()
        return !m.isEmpty && (u.email ?? "").lowercased() == m
    }

    /// Set a user as the company manager straight from the ⋯ menu — handy when
    /// they signed up with Apple's hidden relay email that's hard to type.
    private func setAsManager(_ email: String) async {
        do {
            try await APIClient.shared.adminSetCompanyManager(orgId: org.id, email: email)
            managerEmail = email
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { loadError = tr("הגדרת המנהל נכשלה.", "Failed to set the manager.") }
    }

    private func saveManager() async {
        savingManager = true; defer { savingManager = false }
        do {
            try await APIClient.shared.adminSetCompanyManager(
                orgId: org.id, email: managerEmail.trimmingCharacters(in: .whitespaces))
        } catch { loadError = tr("שמירת המנהל נכשלה.", "Failed to save the manager.") }
    }

    private func load() async {
        loading = true; loadError = nil; defer { loading = false }
        managerEmail = org.admin_email ?? ""
        do {
            let all = try await APIClient.shared.adminUsers()
            users = all.filter { $0.org_id == org.id }
        } catch { loadError = tr("טעינה נכשלה.", "Loading failed.") }
    }

    private func move(_ u: APIClient.AdminUser, to orgId: String) async {
        try? await APIClient.shared.adminSetUserOrg(userId: u.user_id, orgId: orgId)
        await load()
    }

    private func remove(_ u: APIClient.AdminUser) async {
        try? await APIClient.shared.adminSetUserOrg(userId: u.user_id, orgId: nil)
        await load()
    }
}

// MARK: - Company manager view (a customer who manages their own company)

/// Read-only billing for the company the signed-in user manages: total to pay
/// this month + per-user breakdown. No other companies, no admin powers.
struct CompanyManagerView: View {
    var initial: APIClient.CompanyBilling?

    @State private var company: APIClient.CompanyBilling?
    @State private var loading = false

    private var tint: Color { .limorIndigo }
    private var c: APIClient.CompanyBilling? { company ?? initial }

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let c {
                        GlassCard(tint: tint) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(c.name).font(.headline.weight(.bold)).foregroundStyle(.limorInk)
                                Text(tr("לתשלום החודש", "Due this month")).font(.caption).foregroundStyle(.limorMuted)
                                Text("$\(String(format: "%.2f", c.total_charge_usd))")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundStyle(.limorMint)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel(icon: "person.2.fill", title: tr("פירוק לפי משתמש", "Per-user breakdown"), tint: tint)
                                if c.users.isEmpty {
                                    Text(tr("אין עדיין שימוש החודש.", "No usage yet this month.")).font(.subheadline).foregroundStyle(.limorMuted)
                                } else {
                                    ForEach(c.users) { u in
                                        HStack {
                                            Image(systemName: "person.circle.fill").foregroundStyle(.limorMuted)
                                            Text(u.email ?? "—").font(.subheadline).foregroundStyle(.limorInk).lineLimit(1)
                                            Spacer()
                                            Text("$\(String(format: "%.2f", u.charge_usd))")
                                                .font(.subheadline.weight(.semibold)).foregroundStyle(.limorMuted)
                                        }
                                        if u.id != c.users.last?.id { Divider().opacity(0.4) }
                                    }
                                }
                            }
                        }
                    } else if loading {
                        ProgressView().tint(tint).frame(height: 200)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .navigationTitle(tr("החברה שלי", "My company"))
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        company = try? await APIClient.shared.getMyCompany()
    }
}

// MARK: - Sharing

/// Identifiable wrapper so `.sheet(item:)` can drive the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// UIActivityViewController bridge. Presented via `.sheet`, so on iPad it
/// shows as a proper sheet instead of the mis-anchored ShareLink popover.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
