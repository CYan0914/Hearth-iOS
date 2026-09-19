import SwiftUI
import UserNotifications

@main
struct HearthApp: App {
    @StateObject private var session = SessionStore()

    /// Held at the app level, not inside the paywall, because its `init` is what
    /// starts the `Transaction.updates` listener. A store created when the
    /// paywall opens only hears about renewals that happen while the user is
    /// looking at the paywall -- which is to say, almost none of them.
    @StateObject private var purchases = PurchaseStore()

    /// The notification coordinator is also the app delegate, because the APNs
    /// device token is only ever delivered to a delegate method. `@StateObject`
    /// would compile and never receive one.
    @UIApplicationDelegateAdaptor(NotificationCoordinator.self) private var notifications

    @Environment(\.scenePhase) private var scenePhase

    /// Held here rather than in the coordinator because the token is only useful
    /// once there is a session to attach it to, and the coordinator does not
    /// know about sessions.
    @State private var deviceToken: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(notifications)
                .environmentObject(purchases)
                .task {
                    notifications.onTokenReceived = { token in
                        deviceToken = token
                        Task { await registerDevice(token) }
                    }
                    await session.restore()
                    await notifications.refreshStatus()
                    // The second of two ask sites: a stored session also signs in
                    // on launch without going through the change below. Both need
                    // the demo guard, or the alert lands on the capture anyway.
                    guard !Self.suppressPermissionPrompt else { return }
                    if session.isSignedIn { notifications.requestAuthorization() }
                }
                .onChange(of: session.isSignedIn) { signedIn in
                    // Push is requested here rather than at launch: the user has
                    // just signed in and knows what the app is for, which is the
                    // only moment the prompt gets a fair hearing. iOS only asks
                    // once.
                    guard signedIn else { return }
                    guard !Self.suppressPermissionPrompt else { return }
                    notifications.requestAuthorization()
                    if let token = deviceToken {
                        Task { await registerDevice(token) }
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            // Counts and due dates move while the app is backgrounded -- the
            // scheduler materializes tasks overnight. Refreshing on the way in is
            // cheaper than polling and is exactly when staleness would be seen.
            if phase == .active, session.isSignedIn {
                Task { await session.refresh() }
            }
        }
    }

    /// POST /devices. Re-sent on every launch and every sign-in, because there is
    /// no way for the client to know whether the last registration survived: a
    /// reinstall can change the token, and the server may have reassigned it to
    /// another account on this handset.
    private func registerDevice(_ token: String) async {
        guard session.isSignedIn else { return }
        do {
            _ = try await HearthAPI.registerDevice(.init(
                token: token,
                environment: Self.apnsEnvironment,
                appVersion: Bundle.main.shortVersion
            ))
        } catch {
            // Not surfaced. A failed device registration costs push delivery,
            // which the in-app notification centre still covers, and interrupting
            // the user with something they cannot act on is worse than a silent
            // retry on the next launch.
            print("[Hearth] device registration failed: \(error.localizedDescription)")
        }
    }

    /// True only in the screenshot build.
    ///
    /// The run signs in twice -- once when `restore` seeds the demo session,
    /// once when it publishes the state -- and there are two `requestAuthorization`
    /// sites to match. A system alert over the first screen would land on the
    /// capture, and the prompt is one-shot per install, so the run would also
    /// spend it on a screen nobody sees.
    private static var suppressPermissionPrompt: Bool {
        #if DEBUG
        return DemoMode.isEnabled
        #else
        return false
        #endif
    }

    /// Must match the entitlement the build was signed with, not the build
    /// configuration: a debug build signed against a distribution profile talks
    /// to production APNs. `#if DEBUG` is the closest the code can get, and it
    /// is correct for every configuration this project produces.
    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
