import SwiftUI

/// Browse, edit, and delete what Limor knows about the user. Seeded
/// by the intro chat and extended at runtime by Limor's
/// `remember_about_user` tool.
struct ProfileFactsView: View {
    @State private var facts: [ProfileFact] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var editing: ProfileFact?
    @State private var deleting: ProfileFact?
    @State private var addingFact = false

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if loading && facts.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in skeletonRow }
                    } else if facts.isEmpty {
                        emptyState
                    } else {
                        ForEach(facts) { fact in
                            row(fact: fact)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        }
        .navigationTitle(tr("מה לימור יודעת", "What Limor Knows"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingFact = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { fact in
            FactEditor(initial: fact) { newLabel, newValue in
                await save(id: fact.id, label: newLabel, value: newValue)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $addingFact) {
            FactEditor(initial: nil) { newLabel, newValue in
                await add(label: newLabel, value: newValue)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
        .alert(tr("למחוק את העובדה?", "Delete this fact?"), isPresented: .init(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button(tr("מחק", "Delete"), role: .destructive) {
                if let f = deleting { Task { await delete(id: f.id) } }
                deleting = nil
            }
            Button(tr("בטל", "Cancel"), role: .cancel) { deleting = nil }
        } message: {
            if let f = deleting {
                Text("\(f.label): \(f.value)")
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("\(facts.count) פרטים", "\(facts.count) facts"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorIndigo)
            Text(tr("לימור משתמשת במידע הזה כדי לדבר איתך אישית. אפשר לערוך או להסיר בכל עת.", "Limor uses this to talk to you personally. You can edit or remove anything anytime."))
                .font(.caption)
                .foregroundStyle(.limorMuted)
        }
    }

    private func row(fact: ProfileFact) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(fact.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                    sourceBadge(fact.source)
                }
                Text(fact.value)
                    .font(.body)
                    .foregroundStyle(.limorInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Menu {
                Button {
                    editing = fact
                } label: {
                    Label(tr("ערוך", "Edit"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleting = fact
                } label: {
                    Label(tr("מחק", "Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.limorMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.limorMuted.opacity(0.12)))
            }
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

    @ViewBuilder
    private func sourceBadge(_ source: ProfileFact.Source) -> some View {
        let label: String = {
            switch source {
            case .intro: return tr("מההיכרות", "From intro")
            case .chat:  return tr("מהשיחה", "From chat")
            case .manual: return tr("ידני", "Manual")
            }
        }()
        Text(label)
            .font(.caption2)
            .foregroundStyle(.limorMuted)
    }

    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.limorMuted.opacity(0.18))
                .frame(width: 60, height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.limorMuted.opacity(0.15))
                .frame(height: 16)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.limorMuted)
            Text(tr("עוד אין מידע שמור.", "Nothing saved yet."))
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp = try await APIClient.shared.profileFacts()
            facts = resp.facts.sorted { $0.added_at > $1.added_at }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func add(label: String, value: String) async {
        do {
            let fact = try await APIClient.shared.addProfileFact(label: label, value: value)
            facts.insert(fact, at: 0)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(id: String, label: String, value: String) async {
        do {
            try await APIClient.shared.updateProfileFact(id: id, label: label, value: value)
            if let idx = facts.firstIndex(where: { $0.id == id }) {
                facts[idx].label = label
                facts[idx].value = value
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await APIClient.shared.deleteProfileFact(id: id)
            facts.removeAll { $0.id == id }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Editor sheet (add or edit)

private struct FactEditor: View {
    let initial: ProfileFact?
    var onSave: (_ label: String, _ value: String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var value: String = ""
    @State private var saving = false
    @FocusState private var labelFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("קטגוריה", "Category"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.limorMuted)
                            TextField(tr("לדוגמה: תחביב, משפחה, יום הולדת", "e.g. hobby, family, birthday"), text: $label)
                                .focused($labelFocused)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.regularMaterial)
                                )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("פרט", "Detail"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.limorMuted)
                            TextField(tr("מה לימור צריכה לזכור?", "What should Limor remember?"), text: $value, axis: .vertical)
                                .lineLimit(2...6)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.regularMaterial)
                                )
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(initial == nil ? tr("הוסף פרט", "Add Fact") : tr("ערוך פרט", "Edit Fact"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("בטל", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text(tr("שמור", "Save")).font(.body.weight(.semibold))
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            label = initial?.label ?? ""
            value = initial?.value ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                labelFocused = initial == nil
            }
        }
    }

    private var canSave: Bool {
        !saving &&
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        await onSave(
            label.trimmingCharacters(in: .whitespacesAndNewlines),
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}
