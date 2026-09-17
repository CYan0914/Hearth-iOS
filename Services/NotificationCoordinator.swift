import Combine
import Foundation
import UIKit
import UserNotifications

/// Push permission, the APNs device token, and what to do with a notification
/// the user taps.
///
/// This is the app delegate as well as an observable object, installed with
/// `@UIApplicationDelegateAdaptor`. That combination is deliberate: the APNs
/// device token is only ever delivered to `didRegisterForRemoteNotifications`,
/// so a separate adaptor object would need to hold state and forward it here,
/// and the forwarding is the part that silently breaks.
@MainActor
final class NotificationCoordinator: NSObject, ObservableObject, UIApplicationDelegate {

    /// Called with the hex device token once APNs issues one. Set by the app;
    /// nil until then, and the token is simply dropped if it arrives first.
    var onTokenReceived: ((String) -> Void)?

    /// Set when the user taps a notification, so the UI can route to whatever it
    /// was about. Cleared once consumed.
    @Published var pendingRoute: Route?

    /// Denied permission is not an error state -- it is a choice, and the app
    /// works without it. Published so Settings shows the current truth instead
    /// of offering a switch that does nothing.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    enum Route: Equatable {
        case asset(String)
        case recall(String)
        case tasks
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // APNs hands over raw bytes; the API stores and sends the hex form.
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        onTokenReceived?(hex)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the simulator, which has no APNs. Nothing to do: the
        // in-app notification centre is populated regardless of push.
        print("[Hearth] remote notification registration failed: \(error.localizedDescription)")
    }

    /// Asks once, then registers. Called on sign-in, never at cold launch before
    /// the user has seen what the app is -- a permission prompt with no context
    /// is the one most often denied, and iOS only lets you ask once.
    func requestAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await refreshStatus()
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Deep link into the system settings pane, which is the only place a denied
    /// permission can be re-granted.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Human-readable state for the Settings row.
    var authorizationDescription: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    /// Show the banner while the app is in the foreground.
    ///
    /// A due-date reminder that arrives while the user is already looking at the
    /// app is still information they came for; suppressing it is the default and
    /// the wrong one here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        // The server's payload carries `kind` plus a ref, matching the columns on
        // the notifications table. An unknown kind is dropped rather than routed
        // somewhere plausible -- landing on the wrong screen is worse than
        // landing on the home screen.
        let route: Route?
        switch info["kind"] as? String {
        case "task_due":
            route = .tasks
        case "recall_match":
            route = (info["asset_id"] as? String).map(Route.asset) ?? .tasks
        case "warranty_expiring":
            route = (info["asset_id"] as? String).map(Route.asset)
        default:
            route = nil
        }
        guard let route else { return }
        await MainActor.run { self.pendingRoute = route }
    }
}
