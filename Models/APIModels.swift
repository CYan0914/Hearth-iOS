import Foundation

// Wire types for hearth-api. Field names match the server's JSON exactly, so the
// decoder is not configured with a key strategy -- a silent conversion is one
// more place a rename can go unnoticed.
//
// Two shapes of timestamp come back from this backend and they do not look
// alike, because one is a Python `date.isoformat()` and the other is SQLite's
// `datetime('now')`:
//
//   "2026-09-17"           -- a due date, a purchase date, performed_on
//   "2026-09-17 12:34:56"  -- created_at, completed_at, and every other *_at
//
// Foundation's .iso8601 strategy rejects the second (space instead of "T", no
// offset), so it is decoded by hand in HearthDate. Getting this wrong fails
// loudly at decode time rather than silently, but it fails on every screen that
// shows a timestamp, which is most of them.

enum HearthDate {
    private static let dayFormats = ["yyyy-MM-dd"]
    private static let stampFormats = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    ]

    /// Server timestamps are UTC (SQLite's datetime('now')) with no offset in
    /// the string. Parsing them as local time would shift every "3 days ago" by
    /// the user's offset, so the formatter is pinned to UTC.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    static func date(_ raw: String) -> Date? {
        for f in dayFormats + stampFormats {
            if let d = formatter(f).date(from: raw) { return d }
        }
        return nil
    }
}

/// A JSON value of unknown shape.
///
/// `AnyHashable` is not `Codable`, so `object` below cannot be
/// `[String: AnyHashable]` -- the compiler rejects that conformance outright, and
/// it is right to: the type erases exactly the structure the keys of a JSON
/// object are made of. This enum is the smallest thing that can carry any JSON
/// value while staying both `Codable` and `Hashable`, and it is what lets
/// `LenientJSON` accept an object and a string containing one with the same code.
enum JSONValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Order matters. Bool is tried before Int because JSON `true` is not a
        // number, and Int before Double because otherwise every integer would
        // come back as a Double and a round-trip would re-encode `1` as `1.0`.
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Not a JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

/// Decodes a value that may arrive as either a JSON object or a JSON string
/// containing one.
///
/// Exists for `assets.attributes`, where the server stores TEXT and returns it
/// as-is while the write model accepts an object. Rather than pick one and be
/// wrong after a server-side fix, this accepts both and exposes the same
/// dictionary either way.
struct LenientJSON: Codable, Hashable {
    let object: [String: JSONValue]

    init(object: [String: JSONValue] = [:]) { self.object = object }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let direct = try? container.decode([String: JSONValue].self) {
            object = direct
            return
        }
        // The string case: the payload is JSON text inside a JSON string.
        if let text = try? container.decode(String.self),
           let data = text.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            object = parsed
            return
        }
        // Null, empty, or unparseable. Treated as "no attributes" rather than an
        // error: this field is decoration on the asset detail screen, and failing
        // the whole asset decode over it would blank the screen.
        object = [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }

    subscript(key: String) -> JSONValue? { object[key] }

    /// Reads a flag that the server may have stored as a real bool or as a
    /// string, since it round-trips through JSON text.
    func flag(_ key: String) -> Bool? {
        switch object[key] {
        case .bool(let value)?: return value
        case .int(let value)?: return value != 0
        case .string(let value)?: return value == "true" || value == "1"
        default: return nil
        }
    }

    var isEmpty: Bool { object.isEmpty }
}

/// A calendar day with no time component, as the API models due dates.
///
/// Kept as its own type rather than a Date because "due on the 14th" is not an
/// instant: turning it into a Date at midnight and rendering it in a westward
/// timezone displays the 13th.
struct HearthDay: Codable, Hashable, Comparable, CustomStringConvertible {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    var description: String { raw }

    var date: Date? { HearthDate.date(raw) }

    static func < (a: HearthDay, b: HearthDay) -> Bool { a.raw < b.raw }

    /// "in 3 days" / "tomorrow" / "4 days late", computed against the local day.
    func relativeDescription(from today: Date = Date()) -> String {
        guard let d = date else { return raw }
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: today),
                                      to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let n where n > 1 && n < 7: return "In \(n) days"
        case let n where n < -1: return "\(abs(n)) days late"
        default: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var isPast: Bool {
        guard let d = date else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
}

// MARK: - Auth

struct SessionResponse: Codable {
    let sessionToken: String
    let expiresAt: String?
    let isNewUser: Bool
    let user: User

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
        case isNewUser = "is_new_user"
        case user
    }
}

struct User: Codable, Identifiable, Hashable {
    let id: String
    let email: String?
    let emailVerified: Bool
    let displayName: String?
    let timezone: String?
    let quietStartMin: Int?
    let quietEndMin: Int?
    let plan: String
    let createdAt: String?
    let limits: Limits

    enum CodingKeys: String, CodingKey {
        case id, email, timezone, plan, limits
        case emailVerified = "email_verified"
        case displayName = "display_name"
        case quietStartMin = "quiet_start_min"
        case quietEndMin = "quiet_end_min"
        case createdAt = "created_at"
    }

    /// Quiet hours default to 20:00-08:00 when unset, matching the server's own
    /// window, so a user who never opens Settings still sees the times the app
    /// actually uses rather than a blank.
    var quietWindow: (start: Int, end: Int) {
        (quietStartMin ?? 20 * 60, quietEndMin ?? 8 * 60)
    }
}

struct Limits: Codable, Hashable {
    let maxAssets: Int
    let photosPerAsset: Int
    let logEntries: Int
    let templateTier: String
    let exports: [String]

    enum CodingKeys: String, CodingKey {
        case exports
        case maxAssets = "max_assets"
        case photosPerAsset = "photos_per_asset"
        case logEntries = "log_entries"
        case templateTier = "template_tier"
    }
}

struct MeResponse: Codable {
    let user: User
    let counts: Counts
    let templateTier: String

    enum CodingKeys: String, CodingKey {
        case user, counts
        case templateTier = "template_tier"
    }

    struct Counts: Codable, Hashable {
        let assets: Int
        let openTasks: Int
        let recallMatches: Int

        enum CodingKeys: String, CodingKey {
            case assets
            case openTasks = "open_tasks"
            case recallMatches = "recall_matches"
        }
    }
}

// MARK: - Assets

struct Asset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    /// "scan" | "user" | "template" -- where the category came from, so a
    /// re-classification can tell a guess from something the user chose.
    let categorySource: String?
    let brand: String?
    let brandNorm: String?
    let model: String?
    let serial: String?
    let upc: String?
    let location: String?
    let purchaseDate: HearthDay?
    let purchasePriceCents: Int?
    let retailer: String?
    let warrantyExpiresOn: HearthDay?
    let warrantyProvider: String?
    let notes: String?
    let status: String
    let createdAt: String?
    let updatedAt: String?
    let counts: Counts
    let nextDue: HearthDay?
    /// Whether the raw OCR text was kept. The text itself is never sent to the
    /// client -- it is noise once classification is done, and it can contain a
    /// serial the user would rather not have in a list response.
    let hasOcrText: Bool
    /// Category-specific toggles (a fridge with no water line, a home with no
    /// AC). Changing these re-runs template instantiation server-side.
    ///
    /// `LenientJSON` because the wire shape is inconsistent: the column is TEXT
    /// holding a JSON string, and the API returns it verbatim while accepting an
    /// object on write.
    let attributes: LenientJSON?

    enum CodingKeys: String, CodingKey {
        case id, name, category, brand, model, serial, upc, location, retailer,
             notes, status, counts, attributes
        case categorySource = "category_source"
        case brandNorm = "brand_norm"
        case purchaseDate = "purchase_date"
        case purchasePriceCents = "purchase_price_cents"
        case warrantyExpiresOn = "warranty_expires_on"
        case warrantyProvider = "warranty_provider"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case nextDue = "next_due"
        case hasOcrText = "has_ocr_text"
    }

    struct Counts: Codable, Hashable {
        let photos: Int
        let openTasks: Int
        let logs: Int

        enum CodingKeys: String, CodingKey {
            case photos, logs
            case openTasks = "open_tasks"
        }
    }

    var warrantyIsActive: Bool {
        guard let w = warrantyExpiresOn, let d = w.date else { return false }
        return d >= Calendar.current.startOfDay(for: Date())
    }
}

struct AssetListResponse: Codable {
    let assets: [Asset]
    let total: Int
}

/// The 201 body from POST /assets. `schedule` is the whole point of the product:
/// it is what lets the confirm screen say "6 tasks scheduled" without a second
/// request. It is null on an idempotent replay, because nothing was scheduled.
struct AssetCreateResponse: Codable {
    let asset: Asset
    let schedule: Schedule?
    let duplicate: Bool?
}

struct Schedule: Codable, Hashable {
    let plansCreated: Int
    let tasksScheduled: Int
    let nextDue: HearthDay?
    let titles: [String]?

    enum CodingKeys: String, CodingKey {
        case titles
        case plansCreated = "plans_created"
        case tasksScheduled = "tasks_scheduled"
        case nextDue = "next_due"
    }
}

struct AssetDetailResponse: Codable {
    let asset: Asset
    let plans: [Plan]
}

/// The PATCH reply, which is not the detail shape.
///
/// `GET /assets/{id}` and `PATCH /assets/{id}` disagree: the read returns
/// `plans`, the write returns `schedule` plus how many plans it retired. Decoding
/// a successful save against `AssetDetailResponse` would fail on the missing
/// `plans` key and report a contract error after the write had already landed --
/// the worst shape of bug, because the change is saved and the screen says it was
/// not.
struct AssetPatchResponse: Codable {
    let asset: Asset
    let schedule: Schedule?
    let plansRetired: Int?

    enum CodingKeys: String, CodingKey {
        case asset, schedule
        case plansRetired = "plans_retired"
    }
}

/// A recurring chore on one asset.
///
/// The same row arrives in two widths and this type has to decode both:
///
///   `GET /plans`        -> `dict(row)`, the whole `maintenance_plans` table
///   `GET /assets/{id}`  -> eight named columns, without `asset_id`,
///                          `anchor_date`, `instructions` or `source`
///
/// So those four are optional. Making them required would fail to decode the
/// asset detail screen -- the screen the whole asset tab is built on -- while
/// `/plans` worked fine, which is exactly the kind of split that looks like a
/// server bug until someone reads the two queries side by side.
struct Plan: Codable, Identifiable, Hashable {
    let id: String
    let assetId: String?
    /// Null for plans the user wrote themselves; set when the knowledge base
    /// seeded it. The distinction is what lets a later template update skip
    /// anything a person typed.
    let templateId: String?
    let title: String
    let instructions: String?
    let intervalDays: Int
    let anchorDate: HearthDay?
    let nextDueOn: HearthDay
    let priority: String
    let safetyNote: String?
    /// SQLite has no boolean, so this arrives as 0/1. Decoded as an Int and
    /// surfaced through `isActive` rather than taught to the decoder, because a
    /// Bool here would silently accept `2`.
    let active: Int
    /// Absent from the detail response, where every plan is active by
    /// construction. Only `source`'s absence costs anything, so the fallback is
    /// the conservative one: a plan of unknown origin is treated as the user's
    /// own and left alone.
    let source: String?
    let assetName: String?

    enum CodingKeys: String, CodingKey {
        case id, title, instructions, priority, active, source
        case assetId = "asset_id"
        case templateId = "template_id"
        case intervalDays = "interval_days"
        case anchorDate = "anchor_date"
        case nextDueOn = "next_due_on"
        case safetyNote = "safety_note"
        case assetName = "asset_name"
    }

    var isActive: Bool { active != 0 }
    /// `!= "template"` rather than `== "user"`: the detail response omits
    /// `source`, and an unknown origin has to read as "not ours to change"
    /// rather than "ours". The two differ only for a plan with no `source`, and
    /// guessing wrong in that direction updates nothing instead of overwriting
    /// something the user wrote.
    var isUserCreated: Bool { source != "template" }
    var cadenceLabel: String { cadence(intervalDays) }
    var isSafety: Bool { priority == "safety" }
}

/// Turns a day count into the words a person would use. Shared by plans, task
/// templates and the scan preview so the same interval never reads two ways in
/// two screens -- 90 days is "Every 3 months" everywhere or nowhere.
///
/// The ranges (90/91/92) exist because the seed templates use calendar-ish
/// values: a quarterly plan is stored as 91 days in some rows and 90 in others.
func cadence(_ intervalDays: Int) -> String {
    switch intervalDays {
    case 1, 2: return "Daily"
    case 7: return "Weekly"
    case 14: return "Every 2 weeks"
    case 30, 31: return "Monthly"
    case 60, 61, 62: return "Every 2 months"
    case 90, 91, 92: return "Every 3 months"
    case 180, 182, 183: return "Every 6 months"
    case 365, 366: return "Yearly"
    default: return "Every \(intervalDays) days"
    }
}

// MARK: - Scan

struct CategoryOption: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let templateCount: Int

    enum CodingKeys: String, CodingKey {
        case id, label
        case templateCount = "template_count"
    }
}

/// One row of `template_preview`: what would be scheduled if the user confirms.
struct TemplatePreviewItem: Codable, Hashable, Identifiable {
    let templateId: String
    let title: String
    let intervalDays: Int
    let priority: String
    let safetyNote: String?
    let tier: String

    var id: String { templateId }

    enum CodingKeys: String, CodingKey {
        case title, priority, tier
        case templateId = "template_id"
        case intervalDays = "interval_days"
        case safetyNote = "safety_note"
    }

    var isSafety: Bool { priority == "safety" }

    var cadenceLabel: String { cadence(intervalDays) }
}

/// One field the classifier read off the plate.
///
/// The server returns `{value, source, confidence}` for brand, model and serial
/// rather than bare strings, so the confirm screen can mark a value it guessed
/// weakly and let the user correct just that field. `source` is which rule
/// matched ("label", "pattern", ...) and is shown only in the debug row.
struct ClassifiedField: Codable, Hashable {
    let value: String?
    let source: String?
    let confidence: Double?

    var isEmpty: Bool { (value ?? "").isEmpty }
}

struct ScanResult: Codable {
    let category: String?
    let categoryCandidates: [String]?
    let brand: ClassifiedField?
    let model: ClassifiedField?
    let serial: ClassifiedField?
    /// The classifier's overall confidence in the category, 0...1.
    let confidence: Double?
    let suggestedCategoryLabel: String?
    let suggestedName: String?
    let templatePreview: [TemplatePreviewItem]
    let tasksPreviewCount: Int
    /// Non-empty only when classification failed. The confirm screen shows these
    /// as chips so an unreadable plate still ends in one tap, not a dead end.
    let categoryOptions: [CategoryOption]

    enum CodingKeys: String, CodingKey {
        case category, brand, model, serial, confidence
        case categoryCandidates = "category_candidates"
        case suggestedCategoryLabel = "suggested_category_label"
        case suggestedName = "suggested_name"
        case templatePreview = "template_preview"
        case tasksPreviewCount = "tasks_preview_count"
        case categoryOptions = "category_options"
    }

    /// Below this the confirm screen pre-selects the chip row instead of the
    /// guess, because a wrong category silently schedules the wrong maintenance
    /// and the user has no way to tell it was wrong.
    var isConfident: Bool { (confidence ?? 0) >= 0.5 }
}

// MARK: - Tasks

struct MaintenanceTask: Codable, Identifiable, Hashable {
    let id: String
    let assetId: String
    let planId: String?
    let title: String
    let dueOn: HearthDay
    let status: String
    let priority: String
    let completedAt: String?
    let logId: String?
    let assetName: String?
    let overdue: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, overdue
        case assetId = "asset_id"
        case planId = "plan_id"
        case dueOn = "due_on"
        case completedAt = "completed_at"
        case logId = "log_id"
        case assetName = "asset_name"
    }

    var isSafety: Bool { priority == "safety" }
}

struct TaskListResponse: Codable {
    let tasks: [MaintenanceTask]
    let count: Int
    let today: String?
}

struct UpcomingResponse: Codable {
    let today: String
    let counts: [String: Int]
    let nextDue: HearthDay?
    let buckets: [String: [MaintenanceTask]]

    enum CodingKeys: String, CodingKey {
        case today, counts, buckets
        case nextDue = "next_due"
    }

    /// Fixed order, so the home screen does not reshuffle between refreshes.
    /// Safety and overdue belong at the top; "later" is deliberately absent --
    /// a six-month-out chore on the home screen is noise that buries the
    /// overdue one.
    static let bucketOrder = ["overdue", "today", "this_week", "this_month"]
    static let bucketTitles: [String: String] = [
        "overdue": "Overdue",
        "today": "Today",
        "this_week": "This week",
        "this_month": "This month",
        "later": "Later",
    ]
}

struct TaskActionResponse: Codable {
    let task: MaintenanceTask?
    let logId: String?
    let planNextDue: HearthDay?
    let ok: Bool?

    enum CodingKeys: String, CodingKey {
        case task, ok
        case logId = "log_id"
        case planNextDue = "plan_next_due"
    }
}

// MARK: - Logs

struct MaintenanceLog: Codable, Identifiable, Hashable {
    let id: String
    let assetId: String
    let taskId: String?
    let kind: String
    let performedOn: HearthDay
    let title: String
    let vendor: String?
    let vendorPhone: String?
    let costCents: Int?
    let currency: String?
    let parts: String?
    let notes: String?
    let warrantyWork: Bool
    let assetName: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, vendor, parts, notes, currency
        case assetId = "asset_id"
        case taskId = "task_id"
        case performedOn = "performed_on"
        case vendorPhone = "vendor_phone"
        case costCents = "cost_cents"
        case warrantyWork = "warranty_work"
        case assetName = "asset_name"
        case createdAt = "created_at"
    }
}

struct LogListResponse: Codable {
    let assetId: String
    let assetName: String?
    let logs: [MaintenanceLog]
    let count: Int
    let costByCurrency: [String: Int]?
    let lastPerformedOn: HearthDay?

    enum CodingKeys: String, CodingKey {
        case logs, count
        case assetId = "asset_id"
        case assetName = "asset_name"
        case costByCurrency = "cost_by_currency"
        case lastPerformedOn = "last_performed_on"
    }
}

struct LogCreateResponse: Codable {
    let log: MaintenanceLog
}

// MARK: - Recalls

struct Recall: Codable, Hashable {
    let number: String
    let date: String?
    let title: String
    let hazard: String?
    let hazardHigh: Bool
    let remedy: String?
    let url: String?
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case number, date, title, hazard, remedy, url
        case hazardHigh = "hazard_high"
        case imageUrl = "image_url"
    }
}

struct RecallMatch: Codable, Identifiable, Hashable {
    let id: String
    let assetId: String
    let assetName: String?
    let recallId: String
    let confidence: String
    let matchedOn: String
    let why: String
    let score: Double?
    /// "new" | "seen" | "dismissed". The one field on this row the client may
    /// write; confidence, `matchedOn` and `score` are re-derived by every match
    /// pass, so letting the UI set them would make the screen disagree with the
    /// matcher on the next job run.
    var state: String
    let notifiedAt: String?
    let createdAt: String?
    let recall: Recall

    enum CodingKeys: String, CodingKey {
        case id, confidence, why, score, state, recall
        case assetId = "asset_id"
        case assetName = "asset_name"
        case recallId = "recall_id"
        case matchedOn = "matched_on"
        case notifiedAt = "notified_at"
        case createdAt = "created_at"
    }

    /// "low" confidence matches are stored but never pushed, because a
    /// category-only match would alert every dishwasher owner about every
    /// dishwasher recall. The UI says so rather than hiding the row.
    var isLowConfidence: Bool { confidence == "low" }
}

struct RecallMatchListResponse: Codable {
    let matches: [RecallMatch]
    let count: Int
}

struct RecallSearchResponse: Codable {
    let query: String
    let count: Int
    let results: [RecallSearchHit]
}

struct RecallSearchHit: Codable, Identifiable, Hashable {
    let recallId: String
    let number: String
    let date: String?
    let title: String
    let hazard: String?
    let hazardHigh: Bool
    let remedy: String?
    let url: String?
    let imageUrl: String?
    let category: String?

    var id: String { recallId }

    enum CodingKeys: String, CodingKey {
        case number, date, title, hazard, remedy, url, category
        case recallId = "recall_id"
        case hazardHigh = "hazard_high"
        case imageUrl = "image_url"
    }
}

// MARK: - Photos

struct AssetPhoto: Codable, Identifiable, Hashable {
    let id: String
    let assetId: String
    let kind: String
    let contentType: String?
    let bytes: Int?
    let width: Int?
    let height: Int?
    let createdAt: String?
    let url: String?
    let thumbUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, bytes, width, height, url
        case assetId = "asset_id"
        case contentType = "content_type"
        case createdAt = "created_at"
        case thumbUrl = "thumb_url"
    }
}

struct PhotoListResponse: Codable {
    let photos: [AssetPhoto]
    let count: Int
    let urlTtl: Int?

    enum CodingKeys: String, CodingKey {
        case photos, count
        case urlTtl = "url_ttl"
    }
}

struct PhotoSignResponse: Codable {
    let photoId: String
    let storageKey: String
    let thumbKey: String
    let kind: String
    let contentType: String
    let upload: PresignedUpload
    let thumbUpload: PresignedUpload

    enum CodingKeys: String, CodingKey {
        case kind, upload
        case photoId = "photo_id"
        case storageKey = "storage_key"
        case thumbKey = "thumb_key"
        case contentType = "content_type"
        case thumbUpload = "thumb_upload"
    }
}

struct PresignedUpload: Codable, Hashable {
    let key: String
    let url: String
    let method: String
    let headers: [String: String]
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case key, url, method, headers
        case expiresIn = "expires_in"
    }
}

struct PhotoCommitResponse: Codable {
    let photo: AssetPhoto
    let duplicate: Bool?
}

// MARK: - Devices & notifications

struct DeviceRegistrationResponse: Codable {
    let device: Device
    let created: Bool
}

struct Device: Codable, Identifiable, Hashable {
    let id: String
    let environment: String
    let appVersion: String?
    let createdAt: String?
    let lastSeenAt: String?
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, environment, disabled
        case appVersion = "app_version"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct AppNotification: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let body: String?
    let refTable: String?
    let refId: String?
    let scheduledFor: String?
    let createdAt: String?
    let readAt: String?
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, read
        case refTable = "ref_table"
        case refId = "ref_id"
        case scheduledFor = "scheduled_for"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct NotificationListResponse: Codable {
    let notifications: [AppNotification]
    let count: Int
    let unread: Int
}

// MARK: - Errors

/// The API's error envelope is `{"detail": {"error": "..."}}` for handled
/// failures and a bare `{"detail": "..."}` for framework ones (422 validation,
/// 404 route). Both shapes appear, so both are decoded.
struct APIErrorBody: Codable {
    let detail: Detail?

    enum Detail: Codable {
        case code(String, message: String?, limit: Int?)
        case text(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .text(s)
                return
            }
            let k = try decoder.container(keyedBy: Keys.self)
            let code = (try? k.decode(String.self, forKey: .error)) ?? "unknown_error"
            let message = try? k.decode(String.self, forKey: .message)
            let limit = try? k.decode(Int.self, forKey: .limit)
            self = .code(code, message: message, limit: limit)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .code(let code, let message, let limit):
                var k = encoder.container(keyedBy: Keys.self)
                try k.encode(code, forKey: .error)
                try k.encodeIfPresent(message, forKey: .message)
                try k.encodeIfPresent(limit, forKey: .limit)
            }
        }

        private enum Keys: String, CodingKey { case error, message, limit }

        var code: String {
            switch self {
            case .text(let s): return s
            case .code(let c, _, _): return c
            }
        }
    }
}
