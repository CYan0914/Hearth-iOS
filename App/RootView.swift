import SwiftUI

/// Routes on session state. The only screen that decides what the app is showing.
///
/// Three states, not two: `.checking` exists because a stored token has to be
/// validated against `GET /me` before the app can know whether to show the home
/// screen or sign-in, and flashing sign-in at a signed-in user on every launch
/// is the kind of small wrongness that makes an app feel broken.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var notifications: NotificationCoordinator

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                LaunchView()
            case .signedOut:
                SignInView()
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.22), value: session.state)
        .tint(Theme.ember)
    }
}

/// The signed-in shell.
struct MainTabView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var notifications: NotificationCoordinator

    @State private var selection: Tab = .today
    @State private var showScan = false
    @State private var unread = 0

    /// The screenshot job cannot tap, so the tab it wants and the sheet it wants
    /// are chosen before the first frame. Everything below this is the ordinary
    /// app.
    init() {
        #if DEBUG
        if DemoMode.isEnabled {
            _selection = State(initialValue: Tab(index: DemoMode.initialTab))
            _showScan = State(initialValue: DemoMode.opensScanOnLaunch)
        }
        #endif
    }

    enum Tab: Hashable {
        case today, assets, recalls, settings

        init(index: Int) {
            switch index {
            case 1: self = .assets
            case 2: self = .recalls
            case 3: self = .settings
            default: self = .today
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Today", systemImage: "checklist") }
                .tag(Tab.today)

            AssetsView()
                .tabItem { Label("My Home", systemImage: "house") }
                .tag(Tab.assets)

            RecallsView()
                .tabItem { Label("Recalls", systemImage: "exclamationmark.shield") }
                .tag(Tab.recalls)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .bottomTrailing) {
            // The scan button floats over every tab: photographing a nameplate
            // is the app's one irreplaceable action, and putting it behind a tab
            // or a nav bar menu would be the wrong trade.
            scanButton
        }
        .sheet(isPresented: $showScan) {
            ScanFlowView()
                .environmentObject(session)
        }
        .onChange(of: notifications.pendingRoute) { route in
            guard let route else { return }
            switch route {
            case .tasks:
                selection = .today
            case .recall:
                selection = .recalls
            case .asset:
                selection = .assets
            }
            // Consumed, so returning to the app later does not re-route.
            notifications.pendingRoute = nil
        }
    }

    private var scanButton: some View {
        Button {
            showScan = true
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Theme.ember, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 76)
        .accessibilityLabel("Scan a nameplate")
    }
}

/// Shown while a stored token is being validated.
///
/// If validation failed for a reason that is not auth, the failure is reported
/// here with a retry rather than silently dropping to sign-in -- the user is
/// still signed in, the network just is not.
struct LaunchView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(spacing: 18) {
            HearthMark(size: 68)
            Text("Hearth").font(.title2.weight(.semibold))

            if let error = session.startupError {
                VStack(spacing: 14) {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        Task { await session.retryStartup() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Sign in instead") {
                        Task { await session.signOut() }
                    }
                    .font(.subheadline)
                }
                .padding(.top, 6)
                .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// The app's mark, drawn rather than shipped as an image so it scales cleanly at
/// any size and needs no @2x/@3x variants.
struct HearthMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            // The arch: a hearth opening.
            RoundedRectangle(cornerRadius: size * 0.21)
                .stroke(Theme.hearth.opacity(0.85), lineWidth: size * 0.055)
            // The flame.
            FlameShape()
                .fill(
                    LinearGradient(
                        colors: [Theme.emberSoft, Theme.ember],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.30, height: size * 0.44)
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

/// A teardrop: pointed at the top, round at the bottom. One shape with a slight
/// lean, which is enough to read as fire at 24pt.
struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        path.move(to: CGPoint(x: cx + w * 0.10, y: rect.minY))
        // Right side, widening as it falls.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.66),
            control1: CGPoint(x: cx + w * 0.34, y: rect.minY + h * 0.24),
            control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.42)
        )
        // Rounded base.
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h * 0.66),
            control1: CGPoint(x: rect.maxX, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY)
        )
        // Left side back up to the tip.
        path.addCurve(
            to: CGPoint(x: cx + w * 0.10, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.42),
            control2: CGPoint(x: cx + w * 0.10, y: rect.minY + h * 0.24)
        )
        path.closeSubpath()
        return path
    }
}
