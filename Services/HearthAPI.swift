import Foundation

/// The API surface, one method per endpoint, in the order the product uses them.
///
/// Every request model here is encoded by the synthesized Codable conformance,
/// which omits nil optionals rather than writing `null`. That is load-bearing:
/// the server's Pydantic models are `extra="forbid"` and several fields are
/// non-optional literals (`scope: "once" | "always"`), so a stray `null` is a
/// 422 rather than a default.
///
/// Request bodies are nested types on this enum rather than free-standing, so
/// the shape of what goes over the wire stays next to the call that sends it.
enum HearthAPI {

    // MARK: - Auth

    struct AppleSignIn: Encodable {
        let identityToken: String
        let authorizationCode: String
        let nonce: String
        let fullName: String?
        let timezone: String

        enum CodingKeys: String, CodingKey {
            case nonce, timezone
            case identityToken = "identity_token"
            case authorizationCode = "authorization_code"
            case fullName = "full_name"
        }
    }

    struct Profile: Encodable {
        var displayName: String?
        var timezone: String?
        var quietStartMin: Int?
        var quietEndMin: Int?

        enum CodingKeys: String, CodingKey {
            case timezone
            case displayName = "display_name"
            case quietStartMin = "quiet_start_min"
            case quietEndMin = "quiet_end_min"
        }
    }

    struct AccountDelete: Encodable {
        // A typed confirmation, not a bare DELETE, because the operation is
        // irreversible on the server and then again at Apple.
        let confirm = "DELETE"
    }

    static func signInWithApple(_ body: AppleSignIn) async throws -> SessionResponse {
        try await APIClient.shared.post("/auth/apple", body: body)
    }

    static func logout() async throws -> Ack {
        try await APIClient.shared.post("/auth/logout", as: Ack.self)
    }

    static func me() async throws -> MeResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.me() }
        #endif
        return try await APIClient.shared.get("/me")
    }

    static func updateProfile(_ body: Profile) async throws -> UserEnvelope {
        try await APIClient.shared.patch("/me", body: body)
    }

    /// Returns `apple_revoked`: the server tells Apple to revoke the grant
    /// before deleting locally, and a false here means the local copy is gone
    /// but the user may still see Hearth under Settings > Apple ID. The delete
    /// screen says so instead of claiming a clean removal.
    static func deleteAccount() async throws -> AccountDeleteResponse {
        try await APIClient.shared.delete("/account", body: AccountDelete())
    }

    // MARK: - Purchases

    struct TransactionVerify: Encodable {
        let signedTransaction: String

        enum CodingKeys: String, CodingKey {
            case signedTransaction = "signed_transaction"
        }
    }

    /// Verify a StoreKit transaction and update the account's plan.
    ///
    /// The JWS goes over the wire unmodified. Decoding it here to send fields
    /// would be pointless twice over: the server re-derives all of it from the
    /// signed payload, and a client-supplied "productId" is exactly the value
    /// that must never be trusted.
    static func verifyPurchase(signedTransaction: String) async throws -> PurchaseVerifyResponse {
        try await APIClient.shared.post(
            "/purchases/verify",
            body: TransactionVerify(signedTransaction: signedTransaction)
        )
    }

    static func purchaseProducts() async throws -> PurchaseProductsResponse {
        try await APIClient.shared.get("/purchases/products")
    }

    // MARK: - Exports

    /// What this account may export, and what it would contain.
    ///
    /// Read before the download rather than after, so a free user sees the
    /// paywall instead of a 402 the app has to explain.
    static func exportSummary(category: String? = nil) async throws -> ExportSummary {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.exportSummary() }
        #endif
        return try await APIClient.shared.get("/exports", query: ["category": category])
    }

    /// The inventory document itself.
    ///
    /// `format` is "pdf" or "csv" and is checked against the server's own
    /// answer rather than trusted from the caller: the gate is the server's to
    /// enforce, and a client that only *believes* it is Pro is a client that
    /// shows a button which fails.
    static func downloadInventory(format: String, category: String? = nil) async throws -> DownloadedFile {
        let file = try await APIClient.shared.download(
            "/exports/inventory.\(format)",
            query: ["category": category]
        )
        // The server names the file, and normally that name carries the
        // extension. It is made to here as well because a share sheet handed
        // "hearth-inventory" with no suffix offers the user a file iOS cannot
        // open -- and the format is known, so the fallback costs nothing.
        guard !file.filename.lowercased().hasSuffix(".\(format.lowercased())") else {
            return file
        }
        return DownloadedFile(
            data: file.data,
            filename: "\(file.filename).\(format)",
            contentType: file.contentType
        )
    }

    // MARK: - Scan

    struct ScanRequest: Encodable {
        var ocrText: String?
        var name: String?
        var hintCategory: String?
        var hintBrand: String?

        enum CodingKeys: String, CodingKey {
            case name
            case ocrText = "ocr_text"
            case hintCategory = "hint_category"
            case hintBrand = "hint_brand"
        }
    }

    /// Stateless. Called on the confirm screen, before any asset exists, so the
    /// screen can promise "6 tasks scheduled" from the server's own template
    /// preview rather than a guess that might not match what is created.
    ///
    /// `hintCategory` is how the user's own chip choice re-runs the preview:
    /// sending it overrides the classifier, so the confirm screen's task count
    /// stays honest after they correct the category.
    static func classify(
        ocrText: String? = nil,
        name: String? = nil,
        hintCategory: String? = nil,
        hintBrand: String? = nil
    ) async throws -> ScanResult {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.classify(hintCategory: hintCategory) }
        #endif
        return try await APIClient.shared.post(
            "/scan/classify",
            body: ScanRequest(
                ocrText: ocrText,
                name: name,
                hintCategory: hintCategory,
                hintBrand: hintBrand
            )
        )
    }

    static func categories() async throws -> CategoriesResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.categories() }
        #endif
        return try await APIClient.shared.get("/categories")
    }

    // MARK: - Assets

    struct AssetCreate: Encodable {
        var name: String?
        var category: String?
        var brand: String?
        var model: String?
        var serial: String?
        var upc: String?
        var location: String?
        var purchaseDate: String?
        var purchasePriceCents: Int?
        var retailer: String?
        var warrantyExpiresOn: String?
        var warrantyProvider: String?
        var notes: String?
        var ocrText: String?
        var fromScan: Bool
        /// Idempotency key. A retry that carries the same value returns the
        /// asset created the first time rather than a duplicate. Generated once
        /// per scan session, not once per attempt, which is the whole point.
        var clientRef: String?

        enum CodingKeys: String, CodingKey {
            case name, category, brand, model, serial, upc, location, retailer, notes
            case purchaseDate = "purchase_date"
            case purchasePriceCents = "purchase_price_cents"
            case warrantyExpiresOn = "warranty_expires_on"
            case warrantyProvider = "warranty_provider"
            case ocrText = "ocr_text"
            case fromScan = "from_scan"
            case clientRef = "client_ref"
        }
    }

    /// One PATCH-able field, with the three states the server actually
    /// distinguishes.
    ///
    /// The server reads presence, not difference: `model_dump(exclude_unset=True)`
    /// means an absent key leaves the column alone and a key set to null clears
    /// it. A bare `String?` cannot express that, because the synthesized encoder
    /// omits nil -- so clearing a purchase date or a price would send nothing and
    /// appear to work while changing nothing. That is the failure this type
    /// exists to make impossible.
    enum PatchField<Value: Encodable & Equatable>: Encodable, Equatable {
        case value(Value)
        case clear

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .value(let value): try container.encode(value)
            case .clear: try container.encodeNil()
            }
        }
    }

    /// The server's `AssetUpdate`. Its model is `extra="forbid"`, so a field
    /// that is not in this list is a 422, not a silent ignore -- which is why
    /// there is no `regenerate_schedule` here even though changing the category
    /// does re-run template instantiation. The server decides that from the
    /// category change itself (see `PATCH /assets/{id}`); the client does not
    /// ask for it.
    ///
    /// Every field is optional and nil means absent. Only the fields a user can
    /// actually empty are `PatchField`s -- a name or a category is never cleared.
    struct AssetPatch: Encodable {
        var name: String?
        var category: String?
        var brand: String?
        var model: String?
        var serial: String?
        var upc: String?
        var location: String?
        var retailer: String?
        var warrantyProvider: String?
        var notes: String?
        /// "active" | "archived" | "disposed". The archive path goes through
        /// here when the user wants to retire an asset but keep its history.
        var status: String?
        var purchaseDate: PatchField<String>?
        var purchasePriceCents: PatchField<Int>?
        var warrantyExpiresOn: PatchField<String>?

        enum CodingKeys: String, CodingKey {
            case name, category, brand, model, serial, upc, location, retailer,
                 notes, status
            case purchaseDate = "purchase_date"
            case purchasePriceCents = "purchase_price_cents"
            case warrantyExpiresOn = "warranty_expires_on"
            case warrantyProvider = "warranty_provider"
        }
    }

    /// `status` is the server's own filter and it is a closed set --
    /// `active | archived | disposed | all`. There is no `include_archived`
    /// parameter: FastAPI ignores query keys it does not declare, so sending one
    /// would not fail, it would quietly return only the active assets and look
    /// like the archived ones had been deleted.
    static func assets(status: String = "active") async throws -> AssetListResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.assets(status: status) }
        #endif
        return try await APIClient.shared.get("/assets", query: ["status": status])
    }

    static func createAsset(_ body: AssetCreate) async throws -> AssetCreateResponse {
        try await APIClient.shared.post("/assets", body: body)
    }

    static func asset(_ id: String) async throws -> AssetDetailResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.asset(id) }
        #endif
        return try await APIClient.shared.get("/assets/\(id)")
    }

    /// Returns the schedule the edit produced, not the plan list. Changing the
    /// category re-runs template instantiation server-side, so the response says
    /// what that produced rather than making the client re-read the asset.
    static func updateAsset(_ id: String, _ body: AssetPatch) async throws -> AssetPatchResponse {
        try await APIClient.shared.patch("/assets/\(id)", body: body)
    }

    /// Archives by default. Archiving keeps the repair history, which is the
    /// thing a user deleting an appliance usually did not mean to throw away;
    /// `hard` is only for the delete-account flow and the "erase this" path
    /// behind an explicit second confirmation.
    static func deleteAsset(_ id: String, hard: Bool = false) async throws -> Ack {
        try await APIClient.shared.delete(
            "/assets/\(id)",
            query: ["hard": hard ? "true" : "false"],
            as: Ack.self
        )
    }

    // MARK: - Photos

    struct PhotoSign: Encodable {
        let kind: String
        let contentType: String
        let bytes: Int

        enum CodingKeys: String, CodingKey {
            case kind, bytes
            case contentType = "content_type"
        }
    }

    struct PhotoCommit: Encodable {
        let storageKey: String
        let thumbKey: String
        let kind: String
        let width: Int
        let height: Int
        let bytes: Int

        enum CodingKeys: String, CodingKey {
            case kind, width, height, bytes
            case storageKey = "storage_key"
            case thumbKey = "thumb_key"
        }
    }

    static func signPhoto(assetId: String, kind: String, contentType: String, bytes: Int) async throws -> PhotoSignResponse {
        try await APIClient.shared.post(
            "/assets/\(assetId)/photos:sign",
            body: PhotoSign(kind: kind, contentType: contentType, bytes: bytes)
        )
    }

    static func commitPhoto(_ id: String, _ body: PhotoCommit) async throws -> PhotoCommitResponse {
        try await APIClient.shared.post("/photos/\(id)/commit", body: body)
    }

    static func photos(assetId: String) async throws -> PhotoListResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.photos(assetId: assetId) }
        #endif
        return try await APIClient.shared.get("/assets/\(assetId)/photos")
    }

    static func deletePhoto(_ id: String) async throws -> Ack {
        try await APIClient.shared.delete("/photos/\(id)", as: Ack.self)
    }

    // MARK: - Tasks

    struct TaskAction: Encodable {
        var scope: String?
        var snoozeDays: Int?
        var performedOn: String?
        var costCents: Int?
        var vendor: String?
        var notes: String?
        var createLog: Bool?
        var kind: String?

        enum CodingKeys: String, CodingKey {
            case scope, vendor, notes, kind
            case snoozeDays = "snooze_days"
            case performedOn = "performed_on"
            case costCents = "cost_cents"
            case createLog = "create_log"
        }
    }

    static func tasks(assetId: String? = nil, status: String? = nil) async throws -> TaskListResponse {
        #if DEBUG
        if DemoMode.isEnabled, let assetId {
            return DemoMode.tasks(assetId: assetId, status: status)
        }
        #endif
        return try await APIClient.shared.get("/tasks", query: [
            "asset_id": assetId,
            "status": status,
        ])
    }

    static func upcoming() async throws -> UpcomingResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.upcoming() }
        #endif
        return try await APIClient.shared.get("/tasks/upcoming")
    }

    static func completeTask(_ id: String, _ body: TaskAction) async throws -> TaskActionResponse {
        try await APIClient.shared.post("/tasks/\(id)/complete", body: body)
    }

    static func dismissTask(_ id: String, scope: String = "once") async throws -> DismissResponse {
        try await APIClient.shared.post("/tasks/\(id)/dismiss", body: TaskAction(scope: scope))
    }

    static func snoozeTask(_ id: String, days: Int = 7) async throws -> TaskActionResponse {
        try await APIClient.shared.post("/tasks/\(id)/snooze", body: TaskAction(snoozeDays: days))
    }

    struct PlanCreate: Encodable {
        let assetId: String
        let title: String
        /// The "how" the user writes for themselves. Absent rather than empty
        /// when unused, since the server stores what it is given.
        var instructions: String?
        let intervalDays: Int
        /// The first occurrence, if the user wants one later than today. Absent
        /// means the server starts the cadence from now.
        var nextDueOn: String?
        /// One of `low | normal | high | safety`, a closed set on the server.
        /// Absent takes the server's own default of `normal`.
        var priority: String?

        enum CodingKeys: String, CodingKey {
            case title, instructions, priority
            case assetId = "asset_id"
            case intervalDays = "interval_days"
            case nextDueOn = "next_due_on"
        }
    }

    static func plans(assetId: String? = nil) async throws -> PlanListResponse {
        #if DEBUG
        if DemoMode.isEnabled, let assetId {
            let plans = DemoMode.asset(assetId).plans
            return PlanListResponse(plans: plans, count: plans.count)
        }
        #endif
        return try await APIClient.shared.get("/plans", query: ["asset_id": assetId])
    }

    static func createPlan(_ body: PlanCreate) async throws -> PlanEnvelope {
        try await APIClient.shared.post("/plans", body: body)
    }

    // MARK: - Logs

    /// `title` and `performedOn` are non-optional because the server's
    /// `LogCreate` declares them without defaults -- there is no sensible
    /// server-side answer to "when was this done", so omitting it is a 422
    /// rather than a today-default. Making them required here moves that from a
    /// runtime rejection to a compile error at the call site.
    struct LogCreate: Encodable {
        let title: String
        let performedOn: String
        var kind: String?
        var vendor: String?
        var vendorPhone: String?
        var costCents: Int?
        var currency: String?
        var parts: String?
        var notes: String?
        var warrantyWork: Bool?

        enum CodingKeys: String, CodingKey {
            case title, kind, vendor, currency, parts, notes
            case performedOn = "performed_on"
            case vendorPhone = "vendor_phone"
            case costCents = "cost_cents"
            case warrantyWork = "warranty_work"
        }
    }

    static func logs(assetId: String) async throws -> LogListResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.logs(assetId: assetId) }
        #endif
        return try await APIClient.shared.get("/assets/\(assetId)/logs")
    }

    /// The edit body, which is not `LogCreate`.
    ///
    /// `PATCH /logs/{id}` reads `exclude_unset`, so an absent key leaves the
    /// column alone and an explicit null clears it -- the same three states as
    /// `AssetPatch`, and for the same reason: a user who deletes a cost they
    /// typed by mistake has to be able to. `LogCreate` cannot express that,
    /// because its non-optional `performedOn` and `title` would be resent on
    /// every edit, and its optional fields would omit rather than clear.
    ///
    /// The server also rejects an edit that changes nothing (`nothing_to_update`),
    /// so the caller must send only what actually differs -- which is what
    /// `LogFormView` builds.
    struct LogPatch: Encodable {
        var kind: String?
        var title: String?
        var performedOn: PatchField<String>?
        var vendor: PatchField<String>?
        var vendorPhone: PatchField<String>?
        var costCents: PatchField<Int>?
        var currency: PatchField<String>?
        var parts: PatchField<String>?
        var notes: PatchField<String>?
        var warrantyWork: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, title, currency, notes
            case performedOn = "performed_on"
            case vendorPhone = "vendor_phone"
            case costCents = "cost_cents"
            case parts = "parts"
            case warrantyWork = "warranty_work"
            case vendor = "vendor"
        }
    }

    static func createLog(assetId: String, _ body: LogCreate) async throws -> LogCreateResponse {
        try await APIClient.shared.post("/assets/\(assetId)/logs", body: body)
    }

    static func updateLog(_ id: String, _ body: LogPatch) async throws -> LogCreateResponse {
        try await APIClient.shared.patch("/logs/\(id)", body: body)
    }

    static func deleteLog(_ id: String) async throws -> Ack {
        try await APIClient.shared.delete("/logs/\(id)", as: Ack.self)
    }

    // MARK: - Recalls

    /// The server's own filter, and there is no "include dismissed" flag --
    /// `state` is a closed set (`new | seen | dismissed`) and omitting it means
    /// "everything except dismissed". Asking for dismissed rows specifically is
    /// how the recall screen's dismissed section is populated.
    ///
    /// `includeLow` defaults to true here and on the server, because a
    /// category-only match is still worth showing. The screen labels it as
    /// weaker rather than hiding it: a user standing in front of a dishwasher
    /// with a recall notice in hand is entitled to see why the row appeared.
    static func recallMatches(
        state: String? = nil,
        assetId: String? = nil,
        includeLow: Bool = true
    ) async throws -> RecallMatchListResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.recallMatches(state: state) }
        #endif
        return try await APIClient.shared.get("/recalls/matches", query: [
            "state": state,
            "asset_id": assetId,
            "include_low": includeLow ? nil : "false",
        ])
    }

    static func updateMatch(_ id: String, state: String) async throws -> Ack {
        try await APIClient.shared.patch("/recalls/matches/\(id)", body: MatchState(state: state))
    }

    static func searchRecalls(_ q: String) async throws -> RecallSearchResponse {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.searchRecalls(q) }
        #endif
        return try await APIClient.shared.get("/recalls/search", query: ["q": q])
    }

    private struct MatchState: Encodable { let state: String }

    // MARK: - Devices & notifications

    struct DeviceRegister: Encodable {
        let token: String
        let environment: String
        var appVersion: String?

        enum CodingKeys: String, CodingKey {
            case token, environment
            case appVersion = "app_version"
        }
    }

    static func registerDevice(_ body: DeviceRegister) async throws -> DeviceRegistrationResponse {
        try await APIClient.shared.post("/devices", body: body)
    }

    static func devices() async throws -> DeviceListResponse {
        try await APIClient.shared.get("/devices")
    }

    static func unregisterDevice(_ id: String) async throws -> Ack {
        try await APIClient.shared.delete("/devices/\(id)", as: Ack.self)
    }

    static func notifications(unreadOnly: Bool = false) async throws -> NotificationListResponse {
        try await APIClient.shared.get("/notifications", query: [
            "unread_only": unreadOnly ? "true" : nil,
        ])
    }

    static func markNotificationRead(_ id: String) async throws -> NotificationEnvelope {
        try await APIClient.shared.post("/notifications/\(id)/read")
    }

    static func markAllNotificationsRead() async throws -> Ack {
        try await APIClient.shared.post("/notifications/read-all", as: Ack.self)
    }
}

// MARK: - Small response envelopes

/// The server's `{"ok": true, ...}` replies. `ok` is optional so a 204 or an
/// endpoint that answers with something else still decodes.
struct Ack: Codable {
    let ok: Bool?
    let hard: Bool?
    let marked: Int?
    let scope: String?
    let planRetired: Bool?
    let dueOn: HearthDay?
    let mergedIntoExisting: Bool?
    let id: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case ok, hard, marked, scope, id, state
        case planRetired = "plan_retired"
        case dueOn = "due_on"
        case mergedIntoExisting = "merged_into_existing"
    }
}

struct UserEnvelope: Codable { let user: User }
struct PlanEnvelope: Codable { let plan: Plan }
struct PlanListResponse: Codable { let plans: [Plan]; let count: Int? }
struct DeviceListResponse: Codable { let devices: [Device]; let count: Int }
struct NotificationEnvelope: Codable { let notification: AppNotification }
struct CategoriesResponse: Codable {
    let categories: [CategoryOption]
    let templateTier: String

    enum CodingKeys: String, CodingKey {
        case categories
        case templateTier = "template_tier"
    }
}
struct AccountDeleteResponse: Codable {
    let ok: Bool
    let appleRevoked: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case appleRevoked = "apple_revoked"
    }
}

struct DismissResponse: Codable {
    let ok: Bool
    let scope: String
    let planNextDue: HearthDay?
    let planRetired: Bool?
    let mergedIntoExisting: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, scope
        case planNextDue = "plan_next_due"
        case planRetired = "plan_retired"
        case mergedIntoExisting = "merged_into_existing"
    }
}
