import SwiftUI

/// User-curated news feed card on NowView. Shows ONE topic at a time on a
/// page view that auto-advances every few seconds; tapping a slide opens a
/// dedicated detail sheet with the full body + sources.
struct FeedCard: View {
    @Binding var bundle: FeedBundle
    var onRefresh: () async -> Void
    var onSaveTopics: ([FeedTopic]) async -> Void

    @State private var currentIndex: Int = 0
    @State private var showingTopicEditor = false
    @State private var refreshing = false
    @State private var detailItem: FeedItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if bundle.topics.isEmpty {
                emptyState
            } else {
                pagedFeed
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassBackground(cornerRadius: 24, tint: nil)
        .sheet(isPresented: $showingTopicEditor) {
            FeedTopicEditor(
                topics: bundle.topics,
                onSave: { newTopics in
                    Task { await onSaveTopics(newTopics) }
                }
            )
            .presentationDetents([.large])
            // Sheets present in a fresh UIHostingController and don't always
            // inherit layoutDirection from the presenter — re-apply here so
            // the navbar back button + toolbar buttons flip correctly.
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .sheet(item: $detailItem) { item in
            FeedDetailView(item: item)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .onChange(of: bundle.topics.map(\.id)) { _, _ in
            if currentIndex >= bundle.topics.count { currentIndex = 0 }
        }
    }

    // MARK: - Vertical topic list

    /// Pair every topic with its current synthesised item (if any).
    private var slides: [(topic: FeedTopic, item: FeedItem?)] {
        bundle.topics.map { topic in
            (topic, bundle.items.first { $0.topic_id == topic.id })
        }
    }

    /// New design: vertical stack — one row per topic, with its top headline
    /// + a short lead. Replaces the paged carousel because users were
    /// missing topics behind the swipe gesture and never realised there was
    /// more than one.
    private var pagedFeed: some View {
        VStack(spacing: 10) {
            ForEach(Array(slides.enumerated()), id: \.offset) { _, pair in
                FeedTopicRow(topic: pair.topic, item: pair.item) {
                    if let item = pair.item { detailItem = item }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "newspaper.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LinearGradient(
                    colors: [Color.limorIndigo, Color.limorViolet],
                    startPoint: .leading, endPoint: .trailing
                ))
            Text("חדשות אחרונות")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)

            Spacer()

            if let when = bundle.generated_at, let parsed = parseIso(when) {
                Text(relative(parsed))
                    .font(.caption2)
                    .foregroundStyle(.limorMuted)
            }

            Button {
                Task {
                    refreshing = true
                    await onRefresh()
                    refreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.limorIndigo)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.limorIndigo.opacity(0.10)))
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshing)
            }
            .buttonStyle(.plain)
            .disabled(refreshing || bundle.topics.isEmpty)

            Menu {
                Button {
                    showingTopicEditor = true
                } label: {
                    Label("ערוך נושאים", systemImage: "slider.horizontal.3")
                }
                Button {
                    Task {
                        refreshing = true
                        await onRefresh()
                        refreshing = false
                    }
                } label: {
                    Label("רענן עכשיו", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.limorMuted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.limorMuted.opacity(0.12)))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(.limorMuted)
            Text("בחר עד 5 נושאים שיעניינו אותך\nולימור תעדכן אותך עליהם.")
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
                .multilineTextAlignment(.center)
            Button {
                showingTopicEditor = true
            } label: {
                Text("בחר נושאים")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Color.limorIndigo, Color.limorViolet],
                        startPoint: .leading, endPoint: .trailing
                    )))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Date helpers

    private func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Topic row (vertical newspaper layout)

/// One row per user topic. Renders the topic chip + headline + a short
/// lead. Tapping the whole row opens the topic detail screen (full
/// multi-article list). Loading / no-content states get their own
/// minimal treatment so the row height stays predictable.
private struct FeedTopicRow: View {
    let topic: FeedTopic
    let item: FeedItem?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                accentBar
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(topic.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorIndigo)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                        Spacer(minLength: 0)
                        if item != nil {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.limorMuted)
                        }
                    }

                    if let item, !item.headline.isEmpty {
                        Text(item.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.limorInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.caption)
                                .foregroundStyle(.limorInk.opacity(0.7))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("עוד אין עדכון — נסה לרענן")
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }

    /// Slim indigo strip on the leading edge — visual rhythm between
    /// rows, also doubles as a "tap target" affordance.
    private var accentBar: some View {
        Capsule()
            .fill(item == nil ? Color.limorMuted.opacity(0.3) : Color.limorIndigo)
            .frame(width: 3)
    }
}

// MARK: - Topic hub (Limor's synthesis + a multi-article list)

/// Acts as a "topic page": Limor's synthesised lead at the top, then a
/// fetched list of distinct articles within the topic's domain. Articles
/// come from `GET /api/feed/topic/:id/articles`, which has its own 30-min
/// cache server-side. Tapping an article opens the publisher externally.
struct FeedDetailView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    @State private var articles: [TopicArticle] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var loadError: String?
    @State private var lastUpdated: Date?

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        leadSummaryCard
                        articlesSection
                        if let lastUpdated {
                            Text("עודכן \(relative(lastUpdated))")
                                .font(.caption2)
                                .foregroundStyle(.limorMuted)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(item.topic_label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("סגור") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorIndigo)
                            .rotationEffect(.degrees(refreshing ? 360 : 0))
                            .animation(refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshing)
                    }
                    .disabled(refreshing)
                }
            }
        }
        .task { await load(force: false) }
    }

    // MARK: - Loading

    private func load(force: Bool) async {
        if force { refreshing = true } else if articles.isEmpty { loading = true }
        defer {
            refreshing = false
            loading = false
        }
        do {
            let resp = try await APIClient.shared.topicArticles(topicId: item.topic_id, force: force)
            articles = resp.articles
            lastUpdated = parseIso(resp.generated_at) ?? Date()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Lead synthesis card

    private var leadSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                Text("סיכום של לימור")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.limorIndigo)

            Text(item.headline)
                .font(.title3.weight(.bold))
                .foregroundStyle(.limorInk)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(.limorInk.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.limorIndigo.opacity(0.10),
                        Color.limorViolet.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
    }

    // MARK: - Articles list

    @ViewBuilder
    private var articlesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("כתבות בנושא")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                if !articles.isEmpty {
                    Text("\(articles.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.limorMuted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.limorMuted.opacity(0.15)))
                }
                Spacer()
            }

            if loading && articles.isEmpty {
                ForEach(0..<4, id: \.self) { _ in skeletonCard }
            } else if let loadError, articles.isEmpty {
                errorCard(message: loadError)
            } else if articles.isEmpty {
                emptyCard
            } else {
                ForEach(articles) { article in
                    if let url = URL(string: article.source.url) {
                        Link(destination: url) {
                            articleCard(article: article, url: url)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func articleCard(article: TopicArticle, url: URL) -> some View {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        return VStack(alignment: .leading, spacing: 8) {
            if !host.isEmpty {
                Text(host)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .textCase(.lowercase)
            }
            Text(article.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !article.summary.isEmpty {
                Text(article.summary)
                    .font(.caption)
                    .foregroundStyle(.limorInk.opacity(0.7))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Spacer()
                Text("פתח את הכתבה")
                    .font(.caption.weight(.semibold))
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.limorIndigo)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.limorMuted.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.limorMuted.opacity(0.15))
                .frame(width: 80, height: 10)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.limorMuted.opacity(0.20))
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.limorMuted.opacity(0.12))
                .frame(width: 220, height: 12)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .redacted(reason: .placeholder)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("לא הצלחתי לטעון כתבות")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text(message)
                .font(.caption)
                .foregroundStyle(.limorMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorDanger.opacity(0.10))
        )
    }

    private var emptyCard: some View {
        Text("עוד אין כתבות בנושא הזה. נסה לרענן.")
            .font(.subheadline)
            .foregroundStyle(.limorMuted)
            .padding(.vertical, 12)
    }

    private func parseIso(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Topic editor sheet (Apple-News-style drill-down)

private struct FeedTopicEditor: View {
    let topics: [FeedTopic]
    let onSave: ([FeedTopic]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft: [FeedTopic]

    init(topics: [FeedTopic], onSave: @escaping ([FeedTopic]) -> Void) {
        self.topics = topics
        self.onSave = onSave
        _draft = State(initialValue: topics)
    }

    var body: some View {
        NavigationStack {
            FeedBrowseList(
                title: "בחר נושאים",
                subtitle: "טאפ על קטגוריה כדי לדפדף, או חפש בעצמך",
                nodes: FeedNode.root,
                draft: $draft,
                isRoot: true
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("בטל") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("שמור") {
                        onSave(draft)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(draft.isEmpty ? .limorMuted : .limorIndigo)
                    .disabled(draft.isEmpty && topics.isEmpty)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

// MARK: - Browse list (recursive — used at every level)

private struct FeedBrowseList: View {
    let title: String
    let subtitle: String?
    let nodes: [FeedNode]
    @Binding var draft: [FeedTopic]
    var isRoot: Bool = false

    @State private var search: String = ""
    @State private var liveResults: [FeedTopic] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Counter visible at every level so the user knows their
                    // 5-topic budget no matter how deep they drill.
                    if !draft.isEmpty {
                        counterRow
                    }
                    // Pills only at root — sub-pages already feel busy with
                    // the per-row icons, and the user manages selections from
                    // the root anyway.
                    if isRoot, !draft.isEmpty {
                        selectedPills
                    }

                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                    if !trimmedSearch.isEmpty {
                        searchResultsSection
                    } else {
                        nodesSection
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
    }

    // MARK: - Per-root limit helpers

    /// Limit applies per top-level category (sports, news, tech, …). Picking
    /// 5 sports teams + 5 tech topics + 5 news topics is fine; what we
    /// disallow is 6 of the SAME root category.
    static let perRootLimit = 5

    static func rootCategoryId(of id: String) -> String {
        String(id.split(separator: ".").first ?? Substring(id))
    }

    static func rootCategoryLabel(for rootId: String) -> String {
        FeedNode.root.first(where: { $0.id == rootId })?.label ?? rootId
    }

    /// When drilled into a category (`isRoot == false`), all nodes in this
    /// list share the same root prefix. That root is what the counter and
    /// at-limit hint refer to.
    private var contextualRootId: String? {
        guard !isRoot else { return nil }
        return nodes.first.map { Self.rootCategoryId(of: $0.id) }
    }

    private var contextualRootCount: Int {
        guard let rootId = contextualRootId else { return draft.count }
        return draft.filter { Self.rootCategoryId(of: $0.id) == rootId }.count
    }

    private var atLimit: Bool {
        contextualRootId != nil && contextualRootCount >= Self.perRootLimit
    }

    // MARK: - Header (selected pills + counter)

    private var counterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(counterText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(atLimit ? .red : .limorIndigo)
                Spacer(minLength: 16)
                Button("נקה הכל") { draft.removeAll() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorMuted)
            }
            // Without an explicit max-width here, the HStack inside a
            // .leading-aligned VStack would size to its content and the
            // padding wouldn't separate it from the screen edges.
            .frame(maxWidth: .infinity)

            if atLimit, let rootId = contextualRootId {
                Text("הגעת למקסימום של \(Self.perRootLimit) ב\(Self.rootCategoryLabel(for: rootId)) — הסר נושא כדי להוסיף עוד")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var counterText: String {
        if let rootId = contextualRootId {
            return "\(contextualRootCount) מתוך \(Self.perRootLimit) ב\(Self.rootCategoryLabel(for: rootId))"
        }
        return "\(draft.count) נבחרו · עד \(Self.perRootLimit) לכל קטגוריה"
    }

    private var selectedPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft) { topic in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        draft.removeAll { $0.id == topic.id }
                    } label: {
                        HStack(spacing: 6) {
                            Text(topic.label).font(.caption.weight(.semibold)).lineLimit(1)
                            Image(systemName: "xmark.circle.fill").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Color.limorIndigo, Color.limorViolet],
                            startPoint: .leading, endPoint: .trailing
                        )))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Search bar (root only)

    private var searchPlaceholder: String {
        isRoot ? "חפש כל נושא — הפועל, אפל, מלחמה…" : "חפש ב\(title)"
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(searchFocused ? .limorIndigo : .limorMuted)
            TextField(searchPlaceholder, text: $search)
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: search) { _, newValue in scheduleSearch(newValue) }
            if searching {
                ProgressView().scaleEffect(0.7)
            } else if !search.isEmpty {
                Button {
                    search = ""
                    liveResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.limorMuted)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(
                searchFocused ? Color.limorIndigo : Color.limorMuted.opacity(0.2),
                lineWidth: searchFocused ? 1.2 : 0.5
            )
        )
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsSection: some View {
        if isRoot {
            rootSearchResults
        } else {
            localSearchResults
        }
    }

    /// Root-level search uses the LLM `/api/feed/suggest` endpoint so the user
    /// can ask for any topic, even one not in the static catalog.
    @ViewBuilder
    private var rootSearchResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            if searching {
                ForEach(0..<3, id: \.self) { _ in skeletonRow }
            } else if liveResults.isEmpty {
                Text("לא נמצאו וריאציות. נסה ניסוח אחר או דפדף בקטגוריות.")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            } else {
                Text("הצעות לפי החיפוש שלך")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 20)
                ForEach(liveResults) { topic in
                    leafRow(label: topic.label, icon: "sparkles", tint: .limorIndigo, topic: topic)
                }
            }
        }
    }

    /// Sub-level search filters the current subtree's leaves locally — keeps
    /// drilling-in focused on the category the user is browsing.
    @ViewBuilder
    private var localSearchResults: some View {
        let matches = filteredLocalLeaves(trimmedSearch)
        VStack(alignment: .leading, spacing: 10) {
            if matches.isEmpty {
                Text("לא נמצא ב\(title). נסה ניסוח אחר או חזור וחפש מהראשי.")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            } else {
                Text("\(matches.count) תוצאות ב\(title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 20)
                ForEach(matches) { node in
                    if let topic = node.topic {
                        leafRow(label: node.label, icon: node.icon, tint: node.tint, topic: topic)
                    }
                }
            }
        }
    }

    /// Walks the current `nodes` tree and returns leaves whose label or
    /// underlying query contains `query` (case-insensitive substring).
    private func filteredLocalLeaves(_ query: String) -> [FeedNode] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        func walk(_ list: [FeedNode]) -> [FeedNode] {
            list.flatMap { n -> [FeedNode] in
                if n.isLeaf {
                    let labelMatch = n.label.lowercased().contains(q)
                    let queryMatch = n.topic?.query.lowercased().contains(q) ?? false
                    return (labelMatch || queryMatch) ? [n] : []
                }
                return walk(n.children)
            }
        }
        return walk(nodes)
    }

    private var skeletonRow: some View {
        HStack(spacing: 14) {
            Circle().fill(Color.limorMuted.opacity(0.18)).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.limorMuted.opacity(0.18)).frame(height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color.limorMuted.opacity(0.10)).frame(width: 100, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sub-level search is local-only — no network call needed.
        guard isRoot else {
            liveResults = []
            searching = false
            return
        }
        if trimmed.count < 2 {
            liveResults = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            do {
                let results = try await APIClient.shared.suggestFeedTopics(query: trimmed)
                if Task.isCancelled { return }
                await MainActor.run {
                    liveResults = results
                    searching = false
                }
            } catch {
                await MainActor.run { searching = false }
            }
        }
    }

    // MARK: - Categories / nodes list

    @ViewBuilder
    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle, isRoot {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            ForEach(nodes) { node in
                if node.isLeaf, let topic = node.topic {
                    leafRow(label: node.label, icon: node.icon, tint: node.tint, topic: topic)
                } else {
                    NavigationLink {
                        FeedBrowseList(
                            title: node.label,
                            subtitle: node.subtitle,
                            nodes: node.children,
                            draft: $draft
                        )
                    } label: {
                        categoryRow(node: node)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Row variants

    private func categoryRow(node: FeedNode) -> some View {
        HStack(spacing: 14) {
            iconBubble(icon: node.icon, tint: node.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorInk)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(.limorMuted)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 16)
    }

    private func leafRow(label: String, icon: String, tint: Color, topic: FeedTopic) -> some View {
        let selected = draft.contains { $0.id == topic.id || $0.label == topic.label }
        // Disable based on this leaf's own root category, not the global
        // count — so picking 5 sports topics doesn't grey out tech/news.
        let leafRoot = Self.rootCategoryId(of: topic.id)
        let countInLeafRoot = draft.filter { Self.rootCategoryId(of: $0.id) == leafRoot }.count
        let disabled = !selected && countInLeafRoot >= Self.perRootLimit
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if selected {
                draft.removeAll { $0.id == topic.id || $0.label == topic.label }
            } else if countInLeafRoot < Self.perRootLimit {
                draft.append(topic)
            }
        } label: {
            HStack(spacing: 14) {
                iconBubble(icon: icon, tint: tint)
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.limorInk)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selected ? .limorMint : .limorIndigo)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.limorMint.opacity(0.10))
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    private func iconBubble(icon: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 40, height: 40)
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

