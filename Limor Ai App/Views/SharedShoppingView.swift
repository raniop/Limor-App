import SwiftUI

/// The shared shopping list — one list two Limor users (e.g. a couple) both
/// edit. Reached from the shopping screen. Create one to get a share code, or
/// join an existing one with a code. Backed by `SharedShoppingStore`.
struct SharedShoppingView: View {
    @StateObject private var store = SharedShoppingStore.shared
    @State private var draft = ""
    @State private var joinCode = ""
    @State private var loading = true
    @State private var busy = false
    @State private var confirmLeave = false
    @FocusState private var addFocused: Bool

    var body: some View {
        ZStack {
            LiquidBackdrop()
            if let list = store.list {
                connected(list)
            } else if loading {
                ProgressView().tint(.limorIndigo)
            } else {
                setup
            }
        }
        .navigationTitle("רשימה משותפת")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await store.load()
            loading = false
        }
        .toolbar {
            if store.list != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Image(systemName: "person.fill.xmark").foregroundStyle(.limorDanger)
                    }
                }
            }
        }
        .confirmationDialog("לצאת מהרשימה המשותפת?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("צא מהרשימה", role: .destructive) { Task { await store.leave() } }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("הרשימה תיעלם מהמכשיר שלך. אם אתה האחרון שיוצא — היא תימחק לכולם.")
        }
        .alert("שגיאה", isPresented: .init(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button("אוקיי", role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
    }

    // MARK: - Setup (no shared list yet)

    private var setup: some View {
        ScrollView {
            VStack(spacing: 18) {
                LimorEmptyState(
                    icon: "person.2.fill",
                    title: "רשימה משותפת",
                    subtitle: "רשימת קניות אחת שאתה ובן/בת הזוג רואים ועורכים יחד.",
                    iconGradient: LimorGradient.brand
                )
                .padding(.top, 20)

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("צור רשימה משותפת")
                            .font(.headline).foregroundStyle(.limorInk)
                        Text("תקבל קוד קצר לשתף עם מי שתרצה.")
                            .font(.caption).foregroundStyle(.limorMuted)
                        Button {
                            Task { busy = true; await store.create(); busy = false }
                        } label: {
                            HStack { Spacer()
                                Text(busy ? "יוצר…" : "צור רשימה")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Spacer() }
                            .padding(.vertical, 11)
                            .background(Capsule().fill(LimorGradient.brand))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("הצטרף עם קוד")
                            .font(.headline).foregroundStyle(.limorInk)
                        Text("קיבלת קוד ממישהו? הזן אותו כאן.")
                            .font(.caption).foregroundStyle(.limorMuted)
                        HStack(spacing: 10) {
                            TextField("קוד שיתוף", text: $joinCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.body.weight(.semibold).monospaced())
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.limorIndigo.opacity(0.08)))
                            Button {
                                Task {
                                    busy = true
                                    _ = await store.join(code: joinCode)
                                    busy = false
                                }
                            } label: {
                                Text("הצטרף").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(Capsule().fill(LimorGradient.brand))
                            }
                            .buttonStyle(.plain)
                            .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Connected (have a shared list)

    private func connected(_ list: SharedShoppingList) -> some View {
        VStack(spacing: 0) {
            codeBanner(list)
            addBar
            if store.items.isEmpty {
                Spacer()
                LimorEmptyState(
                    icon: "cart",
                    title: "הרשימה ריקה",
                    subtitle: "הוסיפו פריטים — שניכם תראו אותם מיד.",
                    iconGradient: LimorGradient.brand
                )
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.openItems) { row($0) }
                        if !store.doneItems.isEmpty {
                            HStack {
                                Text("סומנו").font(.caption.weight(.bold)).foregroundStyle(.limorMuted)
                                Spacer()
                                Button("נקה סומנו") { Task { await store.clearCompleted() } }
                                    .font(.caption.weight(.semibold)).foregroundStyle(.limorIndigo)
                            }
                            .padding(.horizontal, 4).padding(.top, 6)
                            ForEach(store.doneItems) { row($0) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 32)
                }
            }
        }
    }

    private func codeBanner(_ list: SharedShoppingList) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill").foregroundStyle(.limorIndigo)
            VStack(alignment: .leading, spacing: 1) {
                Text("קוד שיתוף").font(.caption2).foregroundStyle(.limorMuted)
                Text(list.code).font(.headline.monospaced().weight(.bold)).foregroundStyle(.limorInk)
            }
            Spacer()
            Text("\(list.members.count) חברים")
                .font(.caption2.weight(.semibold)).foregroundStyle(.limorMuted)
            ShareLink(item: "הצטרף לרשימת הקניות שלי בלימור עם הקוד: \(list.code)") {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.limorIndigo)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.limorIndigo)
            TextField("הוסף פריט (למשל: חלב)", text: $draft)
                .submitLabel(.done)
                .focused($addFocused)
                .onSubmit(add)
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("הוסף", action: add)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(LimorGradient.brand))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func row(_ item: ShoppingItem) -> some View {
        HStack(spacing: 12) {
            Button { Task { await store.toggle(item.id) } } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.completed ? Color.limorSuccess : Color.limorMuted)
            }
            .buttonStyle(.plain)
            Text(item.name)
                .font(.body)
                .foregroundStyle(item.completed ? .limorMuted : .limorInk)
                .strikethrough(item.completed, color: .limorMuted)
            Spacer()
            Button { Task { await store.remove(item.id) } } label: {
                Image(systemName: "trash").font(.subheadline).foregroundStyle(.limorMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        draft = ""
        Task { await store.add(name) }
    }
}
