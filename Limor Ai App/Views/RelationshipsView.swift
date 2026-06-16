import SwiftUI

/// "המשפחה שלי" — structured links between the user and specific iOS
/// contacts. Each entry has a relation kind (spouse, child, parent, …)
/// and a custom Hebrew label so Limor can resolve "התקשר לבת זוגי"
/// without guessing.
struct RelationshipsView: View {
    @State private var relationships: [Relationship] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var addingFlow: AddFlow?
    @State private var deleting: Relationship?

    /// Drives the multi-step add flow:
    ///   1. relation kind picker
    ///   2. contact picker (CNContactPickerViewController)
    ///   3. confirm + save with the user's chosen label
    enum AddFlow: Identifiable {
        case pickKind
        case pickContact(Relationship.Kind, String)         // label picked
        case confirm(Relationship.Kind, String, ContactPicker.PickedContact)

        var id: String {
            switch self {
            case .pickKind: return "kind"
            case .pickContact: return "contact"
            case .confirm: return "confirm"
            }
        }
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if loading && relationships.isEmpty {
                        ForEach(0..<2, id: \.self) { _ in skeletonRow }
                    } else if relationships.isEmpty {
                        emptyState
                    } else {
                        ForEach(relationships) { rel in
                            row(for: rel)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        }
        .navigationTitle(tr("המשפחה שלי", "My Family"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingFlow = .pickKind
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $addingFlow) { flow in
            sheet(for: flow)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .alert(tr("למחוק את הקשר?", "Delete this relationship?"), isPresented: .init(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button(tr("מחק", "Delete"), role: .destructive) {
                if let r = deleting { Task { await delete(id: r.id) } }
                deleting = nil
            }
            Button(tr("בטל", "Cancel"), role: .cancel) { deleting = nil }
        } message: {
            if let r = deleting {
                Text("\(r.relation_label): \(r.contact_name)")
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("\(relationships.count) קשרים", "\(relationships.count) relationships"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorIndigo)
            Text(tr("קשר אנשים מאנשי הקשר שלך לתפקיד שלהם בחיים שלך, ולימור תזהה אותם בצ'אט (\"התקשר לבת זוגי\", \"מה הטלפון של אבא?\").", "Link people from your contacts to their role in your life, and Limor will recognize them in chat (\"call my partner\", \"what's Dad's number?\")."))
                .font(.caption)
                .foregroundStyle(.limorMuted)
        }
    }

    private func row(for rel: Relationship) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.limorIndigo.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: rel.relation.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorIndigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rel.relation_label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.limorIndigo)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                Text(rel.contact_name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorInk)
                if let phone = rel.contact_phone, !phone.isEmpty {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                }
            }
            Spacer()
            Menu {
                Button(role: .destructive) {
                    deleting = rel
                } label: {
                    Label(tr("הסר", "Remove"), systemImage: "trash")
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

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            Circle().fill(Color.limorMuted.opacity(0.15)).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.limorMuted.opacity(0.18)).frame(width: 70, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(Color.limorMuted.opacity(0.15)).frame(height: 16)
            }
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
            Image(systemName: "person.2.crop.square.stack")
                .font(.title2)
                .foregroundStyle(.limorMuted)
            Text(tr("עדיין לא קישרת אף אחד.", "You haven't linked anyone yet."))
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
            Text(tr("לחץ על + כדי להוסיף קשר.", "Tap + to add a relationship."))
                .font(.caption)
                .foregroundStyle(.limorMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Add flow

    @ViewBuilder
    private func sheet(for flow: AddFlow) -> some View {
        switch flow {
        case .pickKind:
            kindPickerSheet
        case .pickContact(let kind, let label):
            ContactPicker { picked in
                addingFlow = .confirm(kind, label, picked)
            }
            .ignoresSafeArea()
        case .confirm(let kind, let label, let picked):
            confirmSheet(kind: kind, label: label, picked: picked)
        }
    }

    private var kindPickerSheet: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Relationship.Kind.allCases, id: \.self) { kind in
                            Button {
                                addingFlow = .pickContact(kind, kind.defaultLabel)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.limorIndigo.opacity(0.15))
                                            .frame(width: 42, height: 42)
                                        Image(systemName: kind.icon)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.limorIndigo)
                                    }
                                    Text(kind.defaultLabel)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.limorInk)
                                    Spacer()
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.limorMuted)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(tr("איזה סוג קשר?", "What kind of relationship?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("בטל", "Cancel")) { addingFlow = nil }
                }
            }
        }
    }

    private func confirmSheet(
        kind: Relationship.Kind,
        label: String,
        picked: ContactPicker.PickedContact
    ) -> some View {
        ConfirmRelationshipSheet(
            kind: kind,
            initialLabel: label,
            picked: picked,
            onCancel: { addingFlow = nil },
            onSave: { finalLabel in
                await save(kind: kind, label: finalLabel, picked: picked)
                addingFlow = nil
            }
        )
    }

    // MARK: - Networking

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            relationships = try await APIClient.shared.relationships()
                .sorted { $0.added_at > $1.added_at }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(
        kind: Relationship.Kind,
        label: String,
        picked: ContactPicker.PickedContact
    ) async {
        do {
            let saved = try await APIClient.shared.addRelationship(
                relation: kind,
                relationLabel: label,
                contactIdentifier: picked.identifier,
                contactName: picked.displayName,
                contactPhone: picked.primaryPhone
            )
            relationships.insert(saved, at: 0)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await APIClient.shared.deleteRelationship(id: id)
            relationships.removeAll { $0.id == id }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Confirm sheet (lets the user tweak the Hebrew label before saving)

private struct ConfirmRelationshipSheet: View {
    let kind: Relationship.Kind
    let initialLabel: String
    let picked: ContactPicker.PickedContact
    var onCancel: () -> Void
    var onSave: (String) async -> Void

    @State private var label: String = ""
    @State private var saving = false
    @FocusState private var labelFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        contactCard
                        labelField
                    }
                    .padding(20)
                }
            }
            .navigationTitle(tr("אישור קשר", "Confirm Relationship"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("בטל", "Cancel")) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            saving = true
                            defer { saving = false }
                            await onSave(label.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } label: {
                        if saving { ProgressView() }
                        else { Text(tr("שמור", "Save")).font(.body.weight(.semibold)) }
                    }
                    .disabled(saving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            label = initialLabel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                labelFocused = false
            }
        }
    }

    private var contactCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.limorIndigo.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: kind.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.limorIndigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(picked.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorInk)
                if let phone = picked.primaryPhone, !phone.isEmpty {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("איך לקרוא לקשר?", "What should we call this relationship?"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorMuted)
            TextField(tr("לדוגמה: בת זוגי, אבא, אחותי הגדולה", "e.g. my partner, Dad, my older sister"), text: $label)
                .focused($labelFocused)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                )
            Text(tr("לימור תשתמש בתווית הזאת כדי לזהות את הקשר בצ'אט.", "Limor will use this label to recognize the relationship in chat."))
                .font(.caption2)
                .foregroundStyle(.limorMuted)
        }
    }
}
