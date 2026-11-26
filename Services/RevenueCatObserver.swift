import Foundation
import StoreKit

#if canImport(RevenueCat)
import RevenueCat
#endif

/// RevenueCat in observer mode: it watches, it never touches.
///
/// The purchase flow stays exactly as it is -- StoreKit 2 in `PurchaseStore`,
/// verification against hearth-api, plan from the server's `entitlements` table.
/// This type only does three things:
///
///   1. Tells RevenueCat who the user is (`logIn`), so its charts attribute
///      revenue to the right person rather than to anonymous device ids.
///   2. Tells it when the client finished something (`syncPurchases`), so a
///      renewal the backend verified shows up in its dashboard.
///   3. Offers a read of the `pro` entitlement for display only. It is never
///      consulted to unlock anything -- the server is the only authority.
///
/// Everything here is a no-op without the SDK: `#if canImport` guards every
/// call, so a build that has not resolved the package behaves exactly like
/// today. That also keeps the simulator compile green on runners that cannot
/// reach the package registry.
///
/// The `pro` identifier must match the Entitlement identifier in the RevenueCat
/// dashboard, which deliberately mirrors the backend plan name.
@MainActor
enum RevenueCatObserver {

    static let entitlementID = "pro"

    /// Called once at launch, before any sign-in. Anonymous: the user id is
    /// attached later via `identify`, once the backend says who they are.
    static func configure() {
        #if canImport(RevenueCat)
        Purchases.configure(
            with: .builder(withAPIKey: RevenueCatKey.apiKey)
                .with(purchasesAreCompletedBy: .myApp, storeKitVersion: .storeKit2)
        )
        #endif
    }

    /// Bind RevenueCat's anonymous id to the backend's user id.
    ///
    /// The backend id is the stable one: it survives reinstalls via Sign in
    /// with Apple, while a bare RC anonymous id would fragment one person into
    /// several rows every time they reinstall. Safe to call on every sign-in --
    /// identifying the same id twice is a no-op server-side.
    static func identify(userID: String) async {
        #if canImport(RevenueCat)
        do {
            _ = try await Purchases.shared.logIn(userID)
        } catch {
            // Telemetry only. RevenueCat failing must never surface: the plan
            // comes from the backend, so there is nothing the user can act on.
            print("[Hearth] RevenueCat identify failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Drop the binding on sign-out, so the next account on this device does
    /// not inherit the previous one's attribution.
    static func reset() async {
        #if canImport(RevenueCat)
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            print("[Hearth] RevenueCat reset failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Push locally-finished transactions to RevenueCat.
    ///
    /// Called after the backend confirms a purchase or a restore: the
    /// transaction is finished at that point, which is exactly when there is
    /// something for the observer to see. Renewals that arrive via
    /// `Transaction.updates` go through the same `handle` path in
    /// `PurchaseStore`, so they are picked up without a second call site.
    static func notifyPurchaseCompleted() async {
        #if canImport(RevenueCat)
        do {
            _ = try await Purchases.shared.syncPurchases()
        } catch {
            print("[Hearth] RevenueCat sync failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Whether RevenueCat *believes* the user holds the `pro` entitlement.
    ///
    /// Display only -- a faster "thank you" on the paywall, a badge, a debug
    /// row. Never gates content: the server's `plan` is the only authority,
    /// and this value can lag it by a sync interval.
    static var isProAccordingToRevenueCat: Bool {
        get async {
            #if canImport(RevenueCat)
            do {
                let info = try await Purchases.shared.customerInfo()
                return info.entitlements[entitlementID]?.isActive == true
            } catch {
                return false
            }
            #else
            return false
            #endif
        }
    }
}

/// The public SDK key. `appl_…` is publishable by design: it identifies the app
/// to RevenueCat's API the way a bundle id does, and confers no access to
/// anything. Kept in its own file (not Info.plist, not project.yml) so the
/// next key rotation is a one-line diff in one place.
///
/// If the SDK is absent this still compiles, because nothing references
/// `Purchases` outside `#if canImport` guards.
private enum RevenueCatKey {
    static let apiKey = "appl_DTfdDXvAZNYMBBljQgSWWtJnDJU"
}
