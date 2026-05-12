import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var minSplashElapsed = false
    @State private var contentReady = false
    @State private var onboardingCompleted = SharedStore.onboardingCompleted
    @State private var notificationPrefsAsked = SharedStore.notificationPrefsAsked
    @State private var introCompleted = SharedStore.introCompleted

    /// Show the splash until BOTH conditions hold:
    ///   1. Minimum animation time has elapsed (so the brand entrance shows).
    ///   2. Either the user is signed-out (no data to preload) OR the home
    ///      screen's snapshot has landed (or we hit the timeout).
    /// This way the home screen never appears empty + flicker as cards fill in.
    private var showSplash: Bool {
        if !minSplashElapsed { return true }
        if auth.state == .loading { return true }
        if auth.state == .signedIn && !contentReady { return true }
        return false
    }

    var body: some View {
        ZStack {
            if !showSplash {
                content
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                SplashView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.5), value: showSplash)
        .task {
            await auth.bootstrap()
            // Minimum splash time so the entrance animation is always seen.
            try? await Task.sleep(for: .milliseconds(1600))
            minSplashElapsed = true
        }
        .task(id: auth.state) {
            switch auth.state {
            case .signedIn:
                // Preload the home-screen snapshot + insights so MainTabs
                // appears with content already in place. Hard cap at 4s so a
                // slow network never strands the user on the splash.
                await preloadHomeContent()
                contentReady = true
                // Heavier syncs trigger system permission prompts (calendar,
                // contacts, health). Defer them until the user has walked
                // through OnboardingView — otherwise the first run hits them
                // with a stack of prompts the moment they sign in.
                if onboardingCompleted {
                    Task { await SyncManager.shared.syncAll() }
                }
            case .signedOut:
                contentReady = true     // nothing to preload
            case .loading:
                break
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-sync whenever the app comes back to the foreground (throttled
            // per type inside SyncManager) — keeps Gmail/insights fresh without
            // the user pressing anything.
            //
            // *Important*: skip while the user is still walking through
            // onboarding. Each iOS permission dialog (location, calendar, …)
            // briefly takes the app to .inactive and bounces it back to
            // .active when the user dismisses the dialog. Without this guard,
            // approving location triggers syncAll, which then fires Calendar
            // + Contacts + Health permission requests on top of the user
            // before they've reached those screens.
            if newPhase == .active, auth.state == .signedIn, onboardingCompleted {
                Task { await SyncManager.shared.syncAll() }
            }
        }
    }

    /// Fetch the home-screen snapshot + insights and cache them in SharedStore
    /// so NowView reads from cache on first appear, with no loading skeleton.
    /// Bounded by a 4s timeout — better to flash a near-empty home screen than
    /// keep the user staring at the splash on a slow connection.
    /// Also warms the chat history cache in the background so the Chat tab
    /// opens instantly without the visible "empty → fill → scroll-down jump".
    private func preloadHomeContent() async {
        let coords = SharedStore.lastCoordinate
        let token = auth.token ?? ""
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let snap = try? await APIClient.shared.now(
                    token: token,
                    lat: coords?.lat,
                    lng: coords?.lng
                ), let data = try? JSONEncoder().encode(snap) {
                    SharedStore.cacheLastNow(data)
                }
            }
            // Fire-and-forget chat history warm-up — independent of the
            // 4s now() timeout, can finish later. ChatView's .task will
            // still re-fetch on tab entry, but if this lands first the
            // cache is already fresh.
            group.addTask {
                if let history = try? await APIClient.shared.chatHistory(token: token) {
                    await MainActor.run {
                        SharedStore.chatHistoryCache = history.messages
                        SharedStore.chatUsageCache = history.usage
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
            }
            await group.next()
            group.cancelAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch auth.state {
        case .signedIn:
            if !onboardingCompleted {
                OnboardingView {
                    onboardingCompleted = true
                    // Now that the user picked their permissions, kick off the
                    // background syncs that we deferred during onboarding.
                    Task { await SyncManager.shared.syncAll() }
                }
                .transition(.opacity)
            } else if !notificationPrefsAsked {
                NotificationPrefsOnboardingView {
                    notificationPrefsAsked = true
                }
                .transition(.opacity)
            } else if !introCompleted {
                LimorIntroChatView {
                    introCompleted = true
                }
                .transition(.opacity)
                .task { await reconcileIntroCompletion() }
            } else {
                MainTabs()
            }
        case .signedOut:
            SignInView()
        case .loading:
            SplashView()  // edge case — splashDone but auth still loading
        }
    }

    /// The local `introCompleted` flag can be stale (fresh install, reset
    /// device). The server's `intro_completed_at` is the source of truth —
    /// if it's set, skip the intro chat for returning users.
    private func reconcileIntroCompletion() async {
        guard !SharedStore.introCompleted else { return }
        if let resp = try? await APIClient.shared.profileFacts(),
           resp.intro_completed_at != nil {
            SharedStore.introCompleted = true
            await MainActor.run { introCompleted = true }
        }
    }
}

// MARK: - Splash

private struct SplashView: View {
    @State private var animateLogo = false
    @State private var animateText = false
    @State private var dotsActive = false

    var body: some View {
        ZStack {
            // Soft pastel base — pale lavender that lets the colorful logo pop.
            // Must match UILaunchScreen color so there's no flash on transition.
            Color.splashBase.ignoresSafeArea()

            // Subtle radial bloom right behind the logo.
            RadialGradient(
                colors: [Color.limorViolet.opacity(0.18), .clear],
                center: .center,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()
            .blur(radius: 40)

            // Top decorative blob — pastel pink wash.
            Circle()
                .fill(Color.limorPink.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: -140, y: -260)
                .ignoresSafeArea()

            // Bottom decorative blob — pastel mint wash.
            Circle()
                .fill(Color.limorMint.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: 120, y: 300)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                logoMark

                tagline

                Spacer()

                dots
                    .padding(.bottom, 72)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
                animateLogo = true
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.18)) {
                animateText = true
            }
            // Dot anim must start in a separate runloop pass for delayed
            // .repeatForever animations to register correctly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                dotsActive = true
            }
        }
    }

    private var logoMark: some View {
        ZStack {
            // Soft outer glow — keeps the logo from looking pasted-on.
            Circle()
                .fill(Color.limorViolet.opacity(0.14))
                .frame(width: 240, height: 240)
                .blur(radius: 44)

            LimorLogoMark(size: 156)
                .shadow(color: Color.limorIndigo.opacity(0.18), radius: 22, y: 12)
        }
        .scaleEffect(animateLogo ? 1 : 0.55)
        .opacity(animateLogo ? 1 : 0)
    }

    private var tagline: some View {
        VStack(spacing: 6) {
            Text("לימור")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.limorInk)
                .shadow(color: Color.limorIndigo.opacity(0.10), radius: 12, y: 4)

            Text("העוזרת האישית החכמה שלך")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.limorMuted)
        }
        .opacity(animateText ? 1 : 0)
        .offset(y: animateText ? 0 : 18)
    }

    private var dots: some View {
        HStack(spacing: 9) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.limorIndigo.opacity(0.55))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dotsActive ? 1.4 : 0.6)
                    .opacity(dotsActive ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: dotsActive
                    )
            }
        }
        .opacity(animateText ? 1 : 0)
    }
}

// MARK: - Main tabs

/// User-selectable extra tab pinned to the bottom bar. Mirrors a subset of
/// HomeCardKind — anything that's also a worthwhile "I want to jump
/// straight here" destination. Persisted via SharedStore.customTabKind.
enum CustomTabKind: String, CaseIterable, Identifiable {
    case shoppingList = "shopping"
    case meetings = "meetings"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shoppingList: return "קניות"
        case .meetings:     return "פגישות"
        }
    }

    var icon: String {
        switch self {
        case .shoppingList: return "cart.fill"
        case .meetings:     return "calendar"
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var router: AppRouter
    @AppStorage("limor.customTabKind", store: SharedStore.appGroupDefaults)
    private var customTabRaw: String = ""

    private var customTab: CustomTabKind? {
        CustomTabKind(rawValue: customTabRaw)
    }

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
        appearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    /// Custom binding that routes every tab tap through `handleTabTap`
    /// — that's how we detect a re-tap on the Chat tab and convert it
    /// into a scroll-to-bottom nonce instead of iOS's default
    /// scroll-to-top behavior on the inner ScrollView.
    private var tabSelection: Binding<AppRouter.Tab> {
        Binding(
            get: { router.selectedTab },
            set: { router.handleTabTap($0) }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            NowView()
                .tabItem { Label("הפיד שלי", systemImage: "sparkles") }
                .tag(AppRouter.Tab.now)
            if let custom = customTab {
                customTabContent(custom)
                    .tabItem { Label(custom.title, systemImage: custom.icon) }
                    .tag(AppRouter.Tab.custom)
            }
            RemindersView()
                .tabItem { Label("תזכורות", systemImage: "bell.fill") }
                .tag(AppRouter.Tab.reminders)
            ChatView()
                .tabItem { Label("צ'אט", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppRouter.Tab.chat)
            SettingsView()
                .tabItem { Label("הגדרות", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .tint(.limorIndigo)
    }

    @ViewBuilder
    private func customTabContent(_ kind: CustomTabKind) -> some View {
        NavigationStack {
            switch kind {
            case .shoppingList: ShoppingListView()
            case .meetings:     MeetingsListView()
            }
        }
    }
}
