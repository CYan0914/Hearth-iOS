import AuthenticationServices
import Combine
import Foundation
import SwiftUI

/// Who is signed in, and everything the app needs about them.
///
/// One object rather than a store per screen: the plan, the asset count and the
/// limit ceilings are read on several screens and must not drift apart, and
/// `GET /me` is the only thing that knows them.
///
/// `ObservableObject` rather than the iOS 17 `@Observable` macro, to hold the
/// iOS 16 deployment target the plan specifies.
///
/// There is no refresh token. Sessions are issued for days at a time
/// (`session_ttl_days`), so a 401 means the session is genuinely gone and the
/// only recovery is a new Sign in with Apple -- which is why the client clears
/// the token and returns to sign-in rather than trying to renew.
@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case signedIn(User)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var counts: MeResponse.Counts?
    @Published private(set) var templateTier: String = "core"

    /// The server's category vocabulary with its display labels, fetched once per
    /// session and shared by every screen that names a category.
    ///
    /// Held here rather than fetched per screen because the labels are not
    /// derivable from the slugs -- "hvac" is "HVAC", "co_detector" is "CO
    /// Detector" -- and a client-side prettifier would print "Hvac" on one screen
    /// and the server's own "HVAC" on another, in the same list.
    @Published private(set) var categories: [CategoryOption] = []

    /// Set when a token is present but `GET /me` failed for a reason that is not
    /// auth (offline, server down). The token is kept -- the user is still signed
    /// in, we just could not confirm it yet -- and the launch screen offers a
    /// retry instead of dropping them at sign-in.
    @Published private(set) var startupError: String?

    var user: User? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var isSignedIn: Bool { user != nil }

    init() {
        // The client reads its token through this closure, so sign-out takes
        // effect on the next request without rebuilding the client. Wired here
        // rather than at a call site so no screen can forget to.
        Task { [weak self] in
            await APIClient.shared.configure(
                tokenProvider: { Keychain.sessionToken() },
                onUnauthorized: { [weak self] in await self?.handleUnauthorized() }
            )
        }
    }

    /// Called once at launch. Distinguishes "no token" from "token but the
    /// server is unreachable", because only the first should show sign-in.
    func restore() async {
        #if DEBUG
        // The screenshot build has no keychain entry and no token to validate,
        // so it seeds the session directly. Routed through the same `apply` and
        // `loadCategories` the real path uses, so the screens it produces are
        // built from the same state a signed-in user would have.
        if DemoMode.isEnabled {
            do {
                apply(try await HearthAPI.me())
                await loadCategories()
            } catch {
                startupError = error.localizedDescription
                state = .signedOut
            }
            return
        }
        #endif
        guard Keychain.sessionToken() != nil else {
            state = .signedOut
            return
        }
        state = .checking
        startupError = nil
        do {
            apply(try await HearthAPI.me())
        } catch let error as APIError where error.requiresSignOut {
            // The client's unauthorized hook already cleared the token.
            state = .signedOut
        } catch {
            // Keep the token. Being offline at launch is not being signed out,
            // and discarding a valid session over a dropped connection would
            // make the user sign in again for no reason.
            startupError = error.localizedDescription
            state = .signedOut
        }
    }

    func retryStartup() async {
        await restore()
    }

    func signedIn(session: SessionResponse) async {
        Keychain.saveSessionToken(session.sessionToken)
        state = .signedIn(session.user)
        // The session response carries the user but not the counts, so one
        // refresh fills in the home screen's numbers.
        await refresh()
    }

    func refresh() async {
        guard isSignedIn else { return }
        do {
            apply(try await HearthAPI.me())
        } catch let error as APIError where error.requiresSignOut {
            await handleUnauthorized()
        } catch {
            // A failed refresh leaves the last known values in place. They are
            // close enough to render, and blanking the home screen because one
            // background call failed is worse than slightly stale counts.
        }
        if categories.isEmpty {
            await loadCategories()
        }
    }

    /// The category vocabulary rarely changes, so this is fetched once and kept
    /// for the session. A failure is not surfaced: the screens that use it fall
    /// back to the slug, which is uglier but not wrong.
    func loadCategories() async {
        guard isSignedIn else { return }
        guard let response = try? await HearthAPI.categories() else { return }
        categories = response.categories
        templateTier = response.templateTier
    }

    /// The server's label for a category slug, or a readable form of the slug if
    /// the vocabulary has not loaded yet.
    func label(for category: String) -> String {
        if let match = categories.first(where: { $0.id == category }) { return match.label }
        return category
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func apply(_ me: MeResponse) {
        state = .signedIn(me.user)
        counts = me.counts
        templateTier = me.templateTier
        startupError = nil
    }

    func signOut() async {
        // Best-effort revoke. A failure here (offline) must not keep the user
        // signed in on this device: the local token is cleared regardless, and
        // an unrevoked session expires on its own.
        _ = try? await HearthAPI.logout()
        clearLocalSession()
    }

    /// Called by the API client when the server rejects the token.
    func handleUnauthorized() async {
        clearLocalSession()
    }

    private func clearLocalSession() {
        Keychain.clearSessionToken()
        counts = nil
        templateTier = "core"
        startupError = nil
        state = .signedOut
        // Dropped with the session: the tier it reports is per-user, and showing
        // the previous account's tier to the next one would misstate what their
        // plan schedules.
        categories = []
    }

    // MARK: - Derived

    /// Whether the user can add another asset. The free plan's asset ceiling is
    /// the only limit enforced before a request, and the add button is disabled
    /// rather than letting the user fill in a form the server will refuse.
    var canAddAsset: Bool {
        guard let limits = user?.limits else { return true }
        return (counts?.assets ?? 0) < limits.maxAssets
    }

    var remainingAssetSlots: Int? {
        guard let limits = user?.limits else { return nil }
        return max(0, limits.maxAssets - (counts?.assets ?? 0))
    }

    /// The IANA name for this device, sent on every sign-in so travel does not
    /// leave the scheduler pushing at the wrong local hour. The server stores
    /// the name, never an offset: Arizona and Hawaii do not observe DST, and a
    /// fixed offset would shift them by an hour every spring.
    static var currentTimeZone: String { TimeZone.current.identifier }
}
