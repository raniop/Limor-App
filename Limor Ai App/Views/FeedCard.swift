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

    /// Seconds between auto-advances. Long enough to read a 2-line preview,
    /// short enough that the second-best topic surfaces before the user
    /// scrolls away.
    private static let rotationInterval: TimeInterval = 7

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

    // MARK: - Paged feed

    private var slides: [(topic: FeedTopic, item: FeedItem?)] {
        bundle.topics.map { topic in
            (topic, bundle.items.first { $0.topic_id == topic.id })
        }
    }

    private var pagedFeed: some View {
        let pairs = slides
        return TabView(selection: $currentIndex) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                FeedSlide(topic: pair.topic, item: pair.item) {
                    if let item = pair.item { detailItem = item }
                }
                .tag(index)
                .padding(.horizontal, 2)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pairs.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .frame(height: 210)
        .onReceive(Timer.publish(every: Self.rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            // Don't auto-advance while the detail sheet is open — coming back
            // and seeing a different headline than the one they tapped is
            // disorienting.
            guard detailItem == nil, pairs.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                currentIndex = (currentIndex + 1) % pairs.count
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
            Text("הפיד שלי")
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

// MARK: - Single feed slide (one item visible at a time)

private struct FeedSlide: View {
    let topic: FeedTopic
    let item: FeedItem?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text(topic.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.limorIndigo)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))

                if let item, !item.headline.isEmpty {
                    Text(item.headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.limorInk)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !item.body.isEmpty {
                        Text(item.body)
                            .font(.subheadline)
                            .foregroundStyle(.limorInk.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("עוד לא נטען מידע — לחץ רענון")
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Spacer()
                    Text("פתח לקריאה")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(item == nil ? .limorMuted : .limorIndigo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Bottom inset clears the page-indicator dots that TabView's page
            // style draws inside the same frame.
            .padding(.bottom, 28)
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }
}

// MARK: - Detail sheet (full body + sources)

struct FeedDetailView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.topic_label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorIndigo)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))

                        Text(item.headline)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.limorInk)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.body)
                                .foregroundStyle(.limorInk.opacity(0.85))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !item.sources.isEmpty {
                            Divider().opacity(0.4).padding(.vertical, 4)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("מקורות")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.limorMuted)
                                ForEach(item.sources, id: \.url) { src in
                                    if let url = URL(string: src.url) {
                                        Link(destination: url) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "link.circle.fill")
                                                    .font(.body.weight(.semibold))
                                                Text(src.title)
                                                    .font(.subheadline.weight(.medium))
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                                Spacer(minLength: 8)
                                                Image(systemName: "arrow.up.forward")
                                                    .font(.caption.weight(.bold))
                                            }
                                            .foregroundStyle(.limorIndigo)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(Color.limorIndigo.opacity(0.08))
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        if let when = parseIso(item.generated_at) {
                            Text("עודכן \(relative(when))")
                                .font(.caption2)
                                .foregroundStyle(.limorMuted)
                                .padding(.top, 4)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(item.topic_label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("סגור") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                }
            }
        }
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

    // MARK: - Header (selected pills + counter)

    private var atLimit: Bool { draft.count >= 5 }

    private var counterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(draft.count) מתוך 5")
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

            if atLimit {
                Text("הגעת למקסימום של 5 — הסר נושא כדי להוסיף עוד")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
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
        let disabled = !selected && draft.count >= 5
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if selected {
                draft.removeAll { $0.id == topic.id || $0.label == topic.label }
            } else if draft.count < 5 {
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

