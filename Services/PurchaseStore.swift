import Foundation
import StoreKit

/// StoreKit 2 purchases, and the one rule that shapes this file: the app never
/// decides what the user owns.
///
/// `Transaction.currentEntitlements` is convenient and it is tempting to unlock
/// features from it directly. It cannot be the source of truth -- a jailbroken
/// device, or a StoreKit configuration file in a debug build, will happily
/// report entitlements that were never paid for. So every transaction, whether
/// it arrived from a purchase, a restore, or a background renewal, is handed to
/// the backend and only the backend's answer is applied. StoreKit says a
/// purchase happened; the server says what it means.
@MainActor
final class PurchaseStore: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// The store could not be reached, or returned nothing. Distinct from
        /// "no products configured" so the paywall can say which.
        case failed(String)
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadState: LoadState = .idle

    /// The product currently being bought, so only its row shows a spinner.
    @Published private(set) var purchasingProductID: String?

    /// Set while a restore is walking the entitlement list.
    @Published private(set) var restoring = false

    /// The message shown in the paywall's banner. Cleared at the start of every
    /// attempt so a stale failure does not sit under a fresh purchase.
    @Published var message: String?

    /// Product identifiers, in the order the paywall should show them. Declared
    /// here rather than discovered, so the layout is the same on a device that
    /// cannot reach the store as on one that can.
    static let orderedProductIDs = [
        "com.cyan0914.hearth.pro.monthly",
        "com.cyan0914.hearth.pro.quarterly",
        "com.cyan0914.hearth.pro.yearly",
        "com.cyan0914.hearth.pro.lifetime",
    ]

    private var updatesTask: Task<Void, Never>?

    init() {
        // Renewals, refunds and purchases made on another device all arrive
        // here and nowhere else. Started at launch rather than when the paywall
        // opens, or a user whose subscription renews while the app is closed
        // would never have it verified.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Loading

    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let fetched = try await Product.products(for: Self.orderedProductIDs)
            products = fetched.sorted { a, b in
                let ai = Self.orderedProductIDs.firstIndex(of: a.id) ?? .max
                let bi = Self.orderedProductIDs.firstIndex(of: b.id) ?? .max
                return ai < bi
            }
            loadState = .loaded
            if products.isEmpty {
                // Reachable store, nothing to sell: the products exist in code
                // but not yet in App Store Connect, or the agreement is not
                // active. Worth saying out loud rather than showing an empty
                // sheet.
                loadState = .failed("Subscriptions are not available right now.")
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Purchase

    /// Buy a product. Returns true when the backend confirmed the entitlement.
    ///
    /// The options carry the account binding. Without `appAccountToken` the
    /// transaction is signed by Apple but anonymous, and the server refuses it
    /// -- correctly: a verifiable purchase that belongs to nobody can be
    /// replayed against any account that presents it.
    func purchase(_ product: Product, accountToken: UUID?) async -> Bool {
        guard purchasingProductID == nil, !restoring else { return false }
        message = nil
        purchasingProductID = product.id
        defer { purchasingProductID = nil }

        do {
            var options: Set<Product.PurchaseOption> = []
            if let accountToken { options.insert(.appAccountToken(accountToken)) }
            let result = try await product.purchase(options: options)

            switch result {
            case .success(let verification):
                return await handle(verification)

            case .userCancelled:
                // Not an error. The user changed their mind, and a banner
                // telling them so would be noise.
                return false

            case .pending:
                // Ask-to-Buy, or a payment needing approval. The purchase will
                // arrive through Transaction.updates if it is approved, so
                // there is nothing to wait for here.
                message = "Waiting for approval. Your purchase will unlock as soon as it is approved."
                return false

            @unknown default:
                message = "The purchase could not be completed."
                return false
            }
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Re-verify everything the store says this Apple ID owns.
    ///
    /// This is the "Restore Purchases" path and also what runs at launch on a
    /// new device. It is deliberately the same endpoint as a purchase: a
    /// restore that takes a different code path from a purchase is a restore
    /// that can disagree with it.
    func restore(accountToken: UUID?) async {
        guard !restoring, purchasingProductID == nil else { return }
        message = nil
        restoring = true
        defer { restoring = false }

        var restored = false
        for await result in Transaction.currentEntitlements {
            if await handle(result) { restored = true }
        }
        if !restored {
            message = "No previous purchase was found for this Apple ID."
        }
    }

    // MARK: - Handling

    /// Verify a transaction with the backend and apply only what it returns.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .unverified(_, let error):
            // StoreKit itself could not vouch for this. Nothing to send: the
            // whole point of the backend check is that it starts from a
            // signature Apple stands behind.
            message = "That purchase could not be verified with the App Store."
            _ = error
            return false

        case .verified(let transaction):
            // The raw JWS, not the decoded fields: the server re-derives
            // everything from the signed payload, and a decoded copy would just
            // be the client's word for it.
            //
            // Read off the *result*, not the transaction. `jwsRepresentation`
            // is a member of `VerificationResult`, which is what carries the
            // signature; `Transaction` exposes only `jsonRepresentation` and
            // sending that would hand the server an unsigned blob it is
            // right to reject.
            let jws = result.jwsRepresentation
            guard !jws.isEmpty else {
                message = "The App Store did not return a verifiable receipt."
                return false
            }

            do {
                let response = try await HearthAPI.verifyPurchase(signedTransaction: jws)
                // Finish only after the server has recorded it. Finishing
                // first means a network failure between the two leaves the
                // purchase acknowledged and the account still on free.
                await transaction.finish()
                if response.active {
                    return true
                }
                message = "That purchase is no longer active."
                return false
            } catch {
                // Left unfinished on purpose: Transaction.updates will deliver
                // it again, and the next attempt can succeed.
                message = (error as? APIError)?.errorDescription
                    ?? "The purchase could not be confirmed. Please try again."
                return false
            }
        }
    }
}

// MARK: - Display

extension Product {
    /// The price, already localized by StoreKit. Never formatted from a
    /// hardcoded number: the App Store sets the price per territory, and the
    /// only correct figure is the one it reports.
    var priceText: String { displayPrice }

    var periodText: String {
        guard let period = subscription?.subscriptionPeriod else { return "one time" }
        let count = period.value
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return count == 1 ? "per \(unit)" : "every \(count) \(unit)s"
    }

    /// The headline for a plan row: "Yearly", "Monthly", "Lifetime".
    var planTitle: String {
        switch subscription?.subscriptionPeriod.unit {
        case .year: return "Yearly"
        case .month: return "Monthly"
        case .week: return "Weekly"
        case .day: return "Daily"
        default: return "Lifetime"
        }
    }
}
