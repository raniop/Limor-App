import SwiftUI

// MARK: - Category metadata

/// Hebrew label + icon + tint for each backend `ReceiptInsight.category`.
/// Unknown categories (a future backend addition) fall back to `other`.
enum ExpenseCategoryMeta: String, CaseIterable {
    case groceries, dining, transport, shopping, utilities
    case subscriptions, travel, health, entertainment, other

    static func resolve(_ raw: String) -> ExpenseCategoryMeta {
        ExpenseCategoryMeta(rawValue: raw.lowercased()) ?? .other
    }

    var label: String {
        switch self {
        case .groceries:     return tr("סופר ומזון", "Groceries & Food")
        case .dining:        return tr("מסעדות ובתי קפה", "Restaurants & Cafés")
        case .transport:     return tr("תחבורה ודלק", "Transport & Fuel")
        case .shopping:      return tr("קניות", "Shopping")
        case .utilities:     return tr("חשבונות הבית", "Household Bills")
        case .subscriptions: return tr("מנויים", "Subscriptions")
        case .travel:        return tr("נסיעות וטיולים", "Travel & Trips")
        case .health:        return tr("בריאות", "Health")
        case .entertainment: return tr("פנאי ובילוי", "Leisure & Entertainment")
        case .other:         return tr("אחר", "Other")
        }
    }

    var icon: String {
        switch self {
        case .groceries:     return "cart.fill"
        case .dining:        return "fork.knife"
        case .transport:     return "car.fill"
        case .shopping:      return "bag.fill"
        case .utilities:     return "bolt.fill"
        case .subscriptions: return "arrow.triangle.2.circlepath"
        case .travel:        return "airplane"
        case .health:        return "cross.case.fill"
        case .entertainment: return "ticket.fill"
        case .other:         return "creditcard"
        }
    }

    var tint: Color {
        switch self {
        case .groceries:     return .limorMint
        case .dining:        return .limorCoral
        case .transport:     return .limorIndigo
        case .shopping:      return .limorPink
        case .utilities:     return .limorWarning
        case .subscriptions: return .limorViolet
        case .travel:        return Color(red: 0.20, green: 0.66, blue: 0.62)
        case .health:        return .limorCoral
        case .entertainment: return .limorViolet
        case .other:         return .limorMuted
        }
    }
}

// MARK: - Aggregation

/// Receipts of one calendar month plus the sums the card/detail need.
/// The headline total and category bars are ALWAYS in shekels — the server
/// converts foreign-currency receipts via ECB rates (`amount_ils`). Receipts
/// the server couldn't convert appear as a secondary "+ $56" line and in the
/// list with their original currency.
struct ExpenseMonth: Identifiable {
    let month: Date                 // first instant of the month, local calendar
    let receipts: [ReceiptInsight]  // sorted newest-first

    var id: Date { month }

    static func group(_ receipts: [ReceiptInsight]) -> [ExpenseMonth] {
        let cal = Calendar.current
        let pairs: [(Date, ReceiptInsight)] = receipts.compactMap { r in
            guard let d = r.transactionDate,
                  let start = cal.dateInterval(of: .month, for: d)?.start else { return nil }
            return (start, r)
        }
        return Dictionary(grouping: pairs, by: \.0)
            .map { month, items in
                ExpenseMonth(
                    month: month,
                    receipts: items.map(\.1).sorted {
                        ($0.transactionDate ?? .distantPast) > ($1.transactionDate ?? .distantPast)
                    }
                )
            }
            .sorted { $0.month > $1.month }
    }

    /// The month's headline number — sum of all receipts in shekels.
    var totalILS: Double {
        receipts.compactMap(\.ilsValue).reduce(0, +)
    }

    /// Receipts the server couldn't convert, summed per original currency —
    /// shown as a secondary "+ $56" line so nothing silently disappears.
    var unconvertedTotals: [(currency: String, total: Double)] {
        Dictionary(grouping: receipts.filter { $0.ilsValue == nil }, by: { $0.currency.uppercased() })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.1 > $1.1 }
    }

    /// Per-category shekel sums, largest first (unconvertible receipts are
    /// excluded here — they're surfaced via `unconvertedTotals`).
    var categoryTotals: [(category: ExpenseCategoryMeta, total: Double)] {
        Dictionary(grouping: receipts.filter { $0.ilsValue != nil }, by: { ExpenseCategoryMeta.resolve($0.category) })
            .map { ($0.key, $0.value.compactMap(\.ilsValue).reduce(0, +)) }
            .sorted { $0.1 > $1.1 }
    }

    var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month)
    }
}

/// "₪1,234.50" — grouped number with a currency symbol (code prefix for
/// currencies we don't have a symbol for).
func expenseAmountText(_ amount: Double, currency: String) -> String {
    let symbol: String
    switch currency.uppercased() {
    case "ILS", "NIS": symbol = "₪"
    case "USD":        symbol = "$"
    case "EUR":        symbol = "€"
    case "GBP":        symbol = "£"
    default:           symbol = "\(currency.uppercased()) "
    }
    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    let whole = amount == amount.rounded()
    nf.minimumFractionDigits = whole ? 0 : 2
    nf.maximumFractionDigits = whole ? 0 : 2
    let value = nf.string(from: NSNumber(value: amount)) ?? String(format: "%.0f", amount)
    return "\(symbol)\(value)"
}

// MARK: - Home card

/// "הוצאות החודש" — current-month total + top categories, tapping opens
/// the full breakdown. Rendered by NowView only when receipts exist.
struct ExpensesCard: View {
    let month: ExpenseMonth

    private var tint: Color { HomeCardKind.expenses.tint }

    /// "הוצאות החודש" for the running month; when the newest receipts are
    /// from an earlier month (no charges yet this month), name that month
    /// so the number isn't misattributed.
    private var headerTitle: String {
        let cal = Calendar.current
        if cal.isDate(month.month, equalTo: Date(), toGranularity: .month) {
            return tr("הוצאות החודש", "This month's expenses")
        }
        return tr("הוצאות \(month.monthTitle)", "\(month.monthTitle) expenses")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(icon: HomeCardKind.expenses.icon, title: headerTitle, tint: tint)
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorMuted)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(expenseAmountText(month.totalILS, currency: "ILS"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.limorInk)
                    if let extra = month.unconvertedTotals.first {
                        Text("+ \(expenseAmountText(extra.total, currency: extra.currency))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.limorMuted)
                    }
                }

                Text(tr("\(month.receipts.count) קבלות שנמצאו במייל", "\(month.receipts.count) receipts found in email"))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)

                let top = month.categoryTotals.prefix(3)
                if !top.isEmpty {
                    let maxTotal = top.first?.total ?? 1
                    VStack(spacing: 8) {
                        ForEach(Array(top), id: \.category) { entry in
                            categoryRow(entry.category, total: entry.total, fraction: maxTotal > 0 ? entry.total / maxTotal : 0)
                        }
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: ExpenseCategoryMeta, total: Double, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(category.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(category.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    Spacer()
                    Text(expenseAmountText(total, currency: "ILS"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(category.tint.opacity(0.15))
                        Capsule()
                            .fill(category.tint)
                            .frame(width: max(6, geo.size.width * fraction))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

// MARK: - Detail screen

/// Full expense breakdown: month switcher (the backend keeps ~3 months of
/// receipts), category bars, and the receipt list itself.
struct ExpensesDetailView: View {
    @State private var receipts: [ReceiptInsight]
    @State private var selectedMonthId: Date?
    @State private var editingReceipt: ReceiptInsight?
    /// Receipt the user swiped to delete — drives the confirmation dialog.
    @State private var pendingDelete: ReceiptInsight?
    @State private var deleteError: String?

    init(receipts: [ReceiptInsight]) {
        _receipts = State(initialValue: receipts)
    }

    private var months: [ExpenseMonth] { ExpenseMonth.group(receipts) }
    private var selected: ExpenseMonth? {
        months.first { $0.id == selectedMonthId } ?? months.first
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if months.count > 1 {
                    monthPicker
                }
                if let month = selected {
                    totalCard(month)
                    breakdownCard(month)
                    receiptsCard(month)
                } else {
                    GlassCard {
                        Text(tr("עוד לא נמצאו קבלות במייל. אחרי הסנכרון הבא לימור תחפש שוב.", "No receipts found in your email yet. Limor will look again after the next sync."))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(LiquidBackdrop().ignoresSafeArea())
        .navigationTitle(tr("הוצאות", "Expenses"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editingReceipt) { receipt in
            EditReceiptSheet(receipt: receipt) { updatedBundle in
                if let updated = updatedBundle?.receipts {
                    receipts = updated
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .confirmationDialog(
            tr("למחוק את החשבונית?", "Delete this receipt?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { receipt in
            Button(tr("מחק את \(receipt.vendor)", "Delete \(receipt.vendor)"), role: .destructive) {
                let target = receipt
                pendingDelete = nil
                Task { await performDelete(target) }
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { receipt in
            Text(tr("\(receipt.vendor) · \(receipt.amountDisplay). קבלה שנמחקת לא תחזור גם אחרי סריקת מייל מחודשת.", "\(receipt.vendor) · \(receipt.amountDisplay). A deleted receipt won't come back even after a fresh email scan."))
        }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button(tr("אוקיי", "OK"), role: .cancel) {}
        } message: { Text(deleteError ?? "") }
    }

    private func performDelete(_ receipt: ReceiptInsight) async {
        // Optimistic removal — the row disappears immediately; a failure
        // rolls back via the returned bundle / error alert.
        let before = receipts
        withAnimation(.easeInOut(duration: 0.25)) {
            receipts.removeAll { $0.id == receipt.id }
        }
        do {
            let bundle = try await APIClient.shared.deleteReceipt(id: receipt.id)
            if let updated = bundle.receipts { receipts = updated }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            receipts = before
            deleteError = error.localizedDescription
        }
    }

    private var monthPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months) { month in
                    let isSelected = month.id == selected?.id
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedMonthId = month.id }
                    } label: {
                        Text(month.monthTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.white : .limorInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(isSelected ? HomeCardKind.expenses.tint : Color.limorInk.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func totalCard(_ month: ExpenseMonth) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(month.monthTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                Text(expenseAmountText(month.totalILS, currency: "ILS"))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorInk)
                ForEach(month.unconvertedTotals, id: \.currency) { extra in
                    Text(tr("+ \(expenseAmountText(extra.total, currency: extra.currency)) במטבע נוסף", "+ \(expenseAmountText(extra.total, currency: extra.currency)) in another currency"))
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                }
                Text(tr("\(month.receipts.count) קבלות שזוהו אוטומטית מהמייל", "\(month.receipts.count) receipts detected automatically from email"))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
            }
        }
    }

    private func breakdownCard(_ month: ExpenseMonth) -> some View {
        let totals = month.categoryTotals
        let maxTotal = totals.first?.total ?? 1
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "chart.pie.fill", title: tr("פירוק לפי קטגוריה", "Breakdown by category"), tint: HomeCardKind.expenses.tint)
                ForEach(totals, id: \.category) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.category.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.category.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.category.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.limorInk)
                                Spacer()
                                Text(expenseAmountText(entry.total, currency: "ILS"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.limorMuted)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(entry.category.tint.opacity(0.15))
                                    Capsule()
                                        .fill(entry.category.tint)
                                        .frame(width: max(6, geo.size.width * entry.total / max(maxTotal, 1)))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    private func receiptsCard(_ month: ExpenseMonth) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(icon: "list.bullet", title: tr("כל הקבלות", "All receipts"), tint: HomeCardKind.expenses.tint)
                    Spacer()
                    Text(tr("לחיצה על קבלה — עריכה", "Tap a receipt to edit"))
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                }
                ForEach(month.receipts) { receipt in
                    SwipeToDeleteRow(onDelete: { pendingDelete = receipt }) {
                        Button {
                            editingReceipt = receipt
                        } label: {
                            receiptRow(receipt)
                        }
                        .buttonStyle(.plain)
                    }
                    if receipt.id != month.receipts.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func receiptRow(_ receipt: ReceiptInsight) -> some View {
        let category = ExpenseCategoryMeta.resolve(receipt.category)
        return HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(category.tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(category.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.vendor)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let desc = receipt.description, !desc.isEmpty {
                        Text(desc).lineLimit(1)
                        Text("·")
                    }
                    Text(dayText(receipt))
                }
                .font(.caption)
                .foregroundStyle(.limorMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Foreign receipts lead with the shekel value (that's what the
                // totals count); the original amount stays underneath.
                if receipt.currency.uppercased() != "ILS", let ils = receipt.ilsValue {
                    Text(expenseAmountText(ils, currency: "ILS"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Text(receipt.amountDisplay)
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                } else {
                    Text(receipt.amountDisplay)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.limorInk)
                }
            }
        }
    }

    private func dayText(_ receipt: ReceiptInsight) -> String {
        guard let d = receipt.transactionDate else { return "" }
        let f = DateFormatter()
        f.locale = AppLangBox.current.locale
        f.dateFormat = tr("d בMMMM", "MMMM d")
        return f.string(from: d)
    }
}

// MARK: - Swipe-to-delete row

/// List-style swipe-to-delete for rows living inside a ScrollView (where
/// SwiftUI's `.swipeActions` doesn't work — it's List-only). Dragging the
/// row rightward reveals a red trash area; releasing past the threshold
/// fires `onDelete` (the caller shows a confirmation dialog before actually
/// deleting). The row always springs back, so a cancelled confirmation
/// leaves the UI clean.
private struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    @State private var offsetX: CGFloat = 0
    private let threshold: CGFloat = 70

    var body: some View {
        content
            .offset(x: offsetX)
            .background(alignment: .leading) {
                if offsetX > 4 {
                    HStack {
                        Image(systemName: "trash.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(min(1, Double(offsetX / threshold)))
                        Spacer()
                    }
                    .padding(.leading, 14)
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.limorDanger.opacity(min(0.95, Double(offsetX / threshold))))
                    )
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        // Horizontal intent only — vertical drags keep scrolling.
                        guard abs(h) > abs(v) else { return }
                        // Rightward reveal, rubber-banded past the threshold.
                        offsetX = max(0, min(h, threshold * 1.6))
                    }
                    .onEnded { value in
                        let past = offsetX >= threshold
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            offsetX = 0
                        }
                        if past {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onDelete()
                        }
                    }
            )
    }
}

// MARK: - Edit sheet

/// Edit/delete one extracted receipt. Changes persist server-side as
/// overrides, so the next email re-extraction can't undo them. `onDone`
/// receives the updated bundle (nil when nothing changed / demo mode).
struct EditReceiptSheet: View {
    let receipt: ReceiptInsight
    var onDone: (InsightsBundle?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vendor: String
    @State private var amountText: String
    @State private var currency: String
    @State private var category: ExpenseCategoryMeta
    @State private var descriptionText: String
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private static let currencyOptions = ["ILS", "USD", "EUR", "GBP", "THB"]

    init(receipt: ReceiptInsight, onDone: @escaping (InsightsBundle?) -> Void) {
        self.receipt = receipt
        self.onDone = onDone
        _vendor = State(initialValue: receipt.vendor)
        _amountText = State(initialValue: receipt.amount == receipt.amount.rounded()
            ? String(format: "%.0f", receipt.amount)
            : String(format: "%.2f", receipt.amount))
        _currency = State(initialValue: receipt.currency.uppercased())
        _category = State(initialValue: ExpenseCategoryMeta.resolve(receipt.category))
        _descriptionText = State(initialValue: receipt.description ?? "")
    }

    private var currencies: [String] {
        Self.currencyOptions.contains(currency)
            ? Self.currencyOptions
            : Self.currencyOptions + [currency]
    }

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(tr("פרטי הקבלה", "Receipt details")) {
                    TextField(tr("בית עסק", "Vendor"), text: $vendor)
                    HStack {
                        TextField(tr("סכום", "Amount"), text: $amountText)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $currency) {
                            ForEach(currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    TextField(tr("תיאור (לא חובה)", "Description (optional)"), text: $descriptionText)
                }
                Section(tr("קטגוריה", "Category")) {
                    Picker(tr("קטגוריה", "Category"), selection: $category) {
                        ForEach(ExpenseCategoryMeta.allCases, id: \.self) { c in
                            Label(c.label, systemImage: c.icon).tag(c)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(tr("מחיקת הקבלה", "Delete receipt"))
                            Spacer()
                        }
                    }
                } footer: {
                    Text(tr("קבלה שנמחקת לא תחזור גם אחרי סריקת מייל מחודשת.", "A deleted receipt won't come back even after a fresh email scan."))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(tr("עריכת קבלה", "Edit receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(tr("שמירה", "Save")) { Task { await save() } }
                            .font(.body.weight(.semibold))
                            .disabled(vendor.trimmingCharacters(in: .whitespaces).isEmpty || parsedAmount == nil)
                    }
                }
            }
            .confirmationDialog(tr("למחוק את הקבלה?", "Delete this receipt?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(tr("מחיקה", "Delete"), role: .destructive) { Task { await deleteReceipt() } }
                Button(tr("ביטול", "Cancel"), role: .cancel) {}
            }
        }
    }

    private func save() async {
        guard let amount = parsedAmount, amount > 0 else { return }
        if DemoMode.isOn { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            let bundle = try await APIClient.shared.updateReceipt(
                id: receipt.id,
                vendor: vendor.trimmingCharacters(in: .whitespaces),
                amount: amount,
                currency: currency,
                category: category.rawValue,
                description: descriptionText.trimmingCharacters(in: .whitespaces)
            )
            onDone(bundle)
            dismiss()
        } catch {
            errorMessage = tr("השמירה נכשלה — נסו שוב (\(error.localizedDescription))", "Save failed — please try again (\(error.localizedDescription))")
        }
    }

    private func deleteReceipt() async {
        if DemoMode.isOn { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            let bundle = try await APIClient.shared.deleteReceipt(id: receipt.id)
            onDone(bundle)
            dismiss()
        } catch {
            errorMessage = tr("המחיקה נכשלה — נסו שוב (\(error.localizedDescription))", "Delete failed — please try again (\(error.localizedDescription))")
        }
    }
}
