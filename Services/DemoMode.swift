#if DEBUG
import Foundation
import UIKit

/// Screenshot mode: seeded data, served from memory, no network.
///
/// App Store Connect requires screenshots for the 6.9" iPhone and the iPad, this
/// project is built on a Windows machine with no Xcode, and the only machine
/// that can run the app is a GitHub runner. A runner has no hardware, no photo
/// library, and no way to complete Sign in with Apple -- so without this, every
/// screenshot would be a sign-in screen, and the three interesting screens would
/// be unreachable.
///
/// The whole file is inside `#if DEBUG`, so nothing here compiles into a Release
/// build, and it is inert unless `-HearthDemo` is passed as a launch argument,
/// which nothing but the screenshot job does.
///
/// The honest cost, and the reason this is one file rather than branches
/// sprinkled through the views: a reader of this repository can see data that
/// exists only for marketing. That is the trade the CI route makes. The fixtures
/// are the app's own vocabulary rather than invention -- the maintenance
/// templates, the category labels and the recall are copied from
/// `002_templates_seed.sql`, `CATEGORY_LABELS` and the CPSC record for recall
/// 25126, so a screenshot cannot show a screen the real product could not
/// produce.
///
/// Dates are computed from `Date()` at launch rather than hardcoded, so the
/// screenshots do not decay into "3 years late" the way a frozen fixture would.
enum DemoMode {

    // MARK: - Activation

    static let launchArgument = "-HearthDemo"
    static let screenArgument = "-HearthDemoScreen"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Which screen the screenshot job asked for. The app has no deep links, so
    /// this is how one build produces five different screenshots.
    enum Screen: String {
        case today, assets, detail, scan, recalls
    }

    static var screen: Screen {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: screenArgument), i + 1 < args.count,
              let requested = Screen(rawValue: args[i + 1]) else { return .today }
        return requested
    }

    /// The tab the app opens on.
    static var initialTab: Int {
        switch screen {
        case .assets, .detail: return 1
        case .recalls: return 2
        default: return 0
        }
    }

    /// Whether the scan sheet opens by itself, for the screenshot of the confirm
    /// step. Tapping through the camera picker on a runner is not possible.
    static var opensScanOnLaunch: Bool { screen == .scan }

    /// The asset the My Home tab pushes on top of itself.
    static var autoOpenedAssetId: String? {
        screen == .detail ? Seeds.fridgeId : nil
    }

    // MARK: - Dates

    /// A calendar day, as the API models due dates: `2026-09-18`.
    private static func day(_ offset: Int) -> HearthDay {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return HearthDay(dayFormatter.string(from: date))
    }

    /// A server timestamp, which is UTC with no offset -- see `HearthDate`.
    private static func stamp(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return stampFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // MARK: - The account

    static func me() -> MeResponse {
        MeResponse(
            user: user,
            counts: .init(
                assets: Seeds.assets.count,
                openTasks: Seeds.tasks.count,
                recallMatches: 1
            ),
            templateTier: "all"
        )
    }

    /// On the paid tier, because the home has seven things in it and the free
    /// ceiling is three. Every screen reads its numbers from here, so the
    /// screenshot set cannot show a list that the Settings tab contradicts.
    static let user = User(
        id: "us_demo",
        email: "k7m2q4x9vt@privaterelay.appleid.com",
        emailVerified: true,
        displayName: "Alex",
        timezone: TimeZone.current.identifier,
        quietStartMin: 20 * 60,
        quietEndMin: 8 * 60,
        plan: "pro",
        createdAt: stamp(daysAgo: 240),
        limits: Limits(
            maxAssets: 10_000,
            photosPerAsset: 100,
            logEntries: 10_000,
            templateTier: "all",
            exports: ["csv", "pdf"]
        ),
        // A fixed, well-formed UUID so the profile decodes as a real one does.
        // The screenshot build never opens a purchase sheet, but a token here
        // keeps the demo user structurally identical to a signed-in one.
        appAccountToken: "00000000-0000-4000-8000-000000000000"
    )

    // MARK: - Endpoints

    static func categories() -> CategoriesResponse {
        let counts: [(String, Int)] = [
            ("hvac", 3), ("refrigerator", 3), ("water_heater", 3), ("smoke_detector", 3),
            ("dishwasher", 2), ("washer", 2), ("dryer", 2), ("oven_range", 2),
            ("co_detector", 2), ("fire_extinguisher", 2),
            ("sump_pump", 1), ("plumbing", 1), ("water_softener", 1), ("water_filter", 1),
            ("gutter", 1), ("roof", 1), ("deck", 1), ("irrigation", 1), ("lawn_mower", 1),
            ("generator", 1), ("vacuum", 1), ("small_appliance", 1), ("electronics", 1),
            ("freezer", 1), ("microwave", 1),
            ("garbage_disposal", 0), ("furniture", 0), ("tools", 0), ("other", 0),
        ]
        return CategoriesResponse(
            categories: counts.map { CategoryOption(id: $0.0, label: Labels.of($0.0), templateCount: $0.1) },
            templateTier: "all"
        )
    }

    /// `status` is accepted and ignored: nothing in the demo home is archived,
    /// so "active" and "all" are the same list.
    static func assets(status: String) -> AssetListResponse {
        AssetListResponse(assets: Seeds.assets, total: Seeds.assets.count)
    }

    static func asset(_ id: String) -> AssetDetailResponse {
        let asset = Seeds.assets.first { $0.id == id } ?? Seeds.assets[0]
        return AssetDetailResponse(asset: asset, plans: Seeds.plans(for: asset.id))
    }

    static func photos(assetId: String) -> PhotoListResponse {
        // Empty on purpose. A placeholder that failed to load would be a worse
        // screenshot than an honest "no photos yet" card, and bundling stock
        // photographs of someone's kitchen would be inventing evidence.
        PhotoListResponse(photos: [], count: 0, urlTtl: 3600)
    }

    static func logs(assetId: String) -> LogListResponse {
        let asset = Seeds.assets.first { $0.id == assetId }
        let rows = Seeds.logs.filter { $0.assetId == assetId }
        var totals: [String: Int] = [:]
        for row in rows {
            guard let cents = row.costCents else { continue }
            totals[row.currency ?? "USD", default: 0] += cents
        }
        return LogListResponse(
            assetId: assetId,
            assetName: asset?.name,
            logs: rows,
            count: rows.count,
            costByCurrency: totals.isEmpty ? nil : totals,
            lastPerformedOn: rows.map(\.performedOn).max()
        )
    }

    static func tasks(assetId: String, status: String?) -> TaskListResponse {
        let rows = Seeds.tasks.filter { $0.task.assetId == assetId }.map(\.task)
        return TaskListResponse(tasks: rows, count: rows.count, today: day(0).raw)
    }

    static func upcoming() -> UpcomingResponse {
        var buckets: [String: [MaintenanceTask]] = [:]
        var counts: [String: Int] = [:]
        for key in UpcomingResponse.bucketOrder + ["later"] {
            // Sorted by due date within a bucket, which is the order the server
            // returns and the only order that makes sense for a chore list.
            let rows = Seeds.tasks
                .filter { $0.bucket == key }
                .sorted { $0.task.dueOn < $1.task.dueOn }
                .map(\.task)
            buckets[key] = rows
            counts[key] = rows.count
        }
        return UpcomingResponse(
            today: day(0).raw,
            counts: counts,
            nextDue: Seeds.tasks.map(\.task.dueOn).min(),
            buckets: buckets
        )
    }

    /// The recall screen loads twice -- once for open matches, once for the
    /// dismissed section -- and `state` is the only thing telling them apart.
    /// Returning the same row for both would put one recall on screen twice.
    /// Omitting `state` means "everything except dismissed", which is the server's
    /// own rule.
    static func recallMatches(state: String?) -> RecallMatchListResponse {
        guard state == nil else { return RecallMatchListResponse(matches: [], count: 0) }
        return RecallMatchListResponse(matches: [Seeds.recallMatch], count: 1)
    }

    static func searchRecalls(_ query: String) -> RecallSearchResponse {
        RecallSearchResponse(query: query, count: 0, results: [])
    }

    /// The report summary for the demo home.
    ///
    /// Counted from the same seed the asset list uses, so the Reports screen and
    /// the list cannot disagree in a screenshot -- which is exactly the kind of
    /// mismatch a store screenshot would show off.
    static func exportSummary() -> ExportSummary {
        let priced = Seeds.assets.compactMap(\.purchasePriceCents)
        return ExportSummary(
            available: ["csv", "pdf"],
            items: Seeds.assets.count,
            truncated: false,
            valueCents: priced.reduce(0, +),
            formats: [
                ExportSummary.ExportFormat(
                    format: "pdf", path: "/v1/exports/inventory.pdf", available: true),
                ExportSummary.ExportFormat(
                    format: "csv", path: "/v1/exports/inventory.csv", available: true),
            ]
        )
    }

    // MARK: - The scan flow

    /// What the nameplate OCR would have returned for `sampleNameplate()`. The
    /// classifier is a fixture too, so this is never read -- it exists so the
    /// demo follows the same code path as the real app rather than skipping it.
    static let sampleOCRText = """
        LG
        REFRIGERATOR
        MODEL NO.  LRFXS2503S
        SERIAL NO. 812KRMZ1P294
        120V 60Hz 3.5A
        MADE IN KOREA
        """

    static func classify(hintCategory: String?) -> ScanResult {
        let category = hintCategory ?? "refrigerator"
        var preview = Seeds.refrigeratorPreview
        if let hint = hintCategory, hint != "refrigerator" {
            // A chip tap re-runs the preview server-side; here it just swaps the
            // card over to that category's templates so the flow stays honest.
            preview = Seeds.preview(for: hint)
        }
        return ScanResult(
            category: category,
            categoryCandidates: ["refrigerator", "freezer"],
            brand: ClassifiedField(value: "LG", source: "label", confidence: 0.94),
            model: ClassifiedField(value: "LRFXS2503S", source: "label", confidence: 0.91),
            serial: ClassifiedField(value: "812KRMZ1P294", source: "label", confidence: 0.88),
            confidence: 0.86,
            suggestedCategoryLabel: Labels.of(category),
            suggestedName: "LG Refrigerator",
            templatePreview: preview,
            tasksPreviewCount: preview.count,
            categoryOptions: []
        )
    }

    /// A nameplate, drawn rather than shipped.
    ///
    /// A bundled JPEG would be one more binary in the repository that exists
    /// only for screenshots, and this is legible enough at the size the confirm
    /// step renders it (150pt tall, full width). It is never OCR'd -- see
    /// `sampleOCRText` -- because Vision adds a way for the run to fail without
    /// changing what the screenshot shows.
    static func sampleNameplate() -> UIImage {
        let size = CGSize(width: 1000, height: 700)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.17, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // A lighter rule around the edge, the way an etched plate reads.
            UIColor(white: 0.34, alpha: 1).setStroke()
            let border = UIBezierPath(rect: CGRect(x: 22, y: 22, width: size.width - 44, height: size.height - 44))
            border.lineWidth = 3
            border.stroke()

            let lines: [(String, CGFloat, Bool)] = [
                ("LG", 62, true),
                ("REFRIGERATOR", 26, false),
                ("", 14, false),
                ("MODEL NO.    LRFXS2503S", 34, false),
                ("SERIAL NO.   812KRMZ1P294", 34, false),
                ("120V  60Hz  3.5A", 30, false),
                ("MADE IN KOREA", 24, false),
            ]

            var y: CGFloat = 62
            for (text, points, bold) in lines {
                guard !text.isEmpty else { y += points; continue }
                let font = bold
                    ? UIFont.systemFont(ofSize: points, weight: .bold)
                    : UIFont.monospacedSystemFont(ofSize: points, weight: .regular)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(white: 0.94, alpha: 1),
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let bounds = string.boundingRect(
                    with: CGSize(width: size.width - 120, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin, context: nil
                )
                string.draw(at: CGPoint(x: 62, y: y + (points - bounds.height) / 2))
                y += points + 22
            }
        }
    }

    // MARK: - Seeds

    private enum Labels {
        /// Copied from `normalization.CATEGORY_LABELS`, because the client is
        /// forbidden from prettifying slugs -- that is the server's vocabulary
        /// and the two would drift.
        static func of(_ slug: String) -> String {
            switch slug {
            case "refrigerator": return "Refrigerator"
            case "freezer": return "Freezer"
            case "dishwasher": return "Dishwasher"
            case "washer": return "Washing Machine"
            case "dryer": return "Dryer"
            case "hvac": return "HVAC System"
            case "water_heater": return "Water Heater"
            case "oven_range": return "Oven / Range"
            case "microwave": return "Microwave"
            case "small_appliance": return "Small Appliance"
            case "vacuum": return "Vacuum"
            case "garbage_disposal": return "Garbage Disposal"
            case "smoke_detector": return "Smoke Detector"
            case "co_detector": return "CO Detector"
            case "fire_extinguisher": return "Fire Extinguisher"
            case "sump_pump": return "Sump Pump"
            case "generator": return "Generator"
            case "water_softener": return "Water Softener"
            case "water_filter": return "Water Filtration"
            case "gutter": return "Gutters"
            case "roof": return "Roof"
            case "deck": return "Deck"
            case "lawn_mower": return "Lawn Mower"
            case "irrigation": return "Irrigation"
            case "plumbing": return "Plumbing"
            case "electronics": return "Electronics"
            case "furniture": return "Furniture"
            case "tools": return "Tools"
            default: return "Other"
            }
        }
    }

    private enum Seeds {
        static let fridgeId = "as_demo_fridge"
        static let rangeId = "as_demo_range"
        static let dishwasherId = "as_demo_dishwasher"
        static let dryerId = "as_demo_dryer"
        static let hvacId = "as_demo_hvac"
        static let heaterId = "as_demo_heater"
        static let smokeId = "as_demo_smoke"

        /// Ordered as `GET /assets` returns them: newest first, which is the
        /// order the kitchen, then the laundry and the basement, then the smoke
        /// detectors were added.
        static let assets: [Asset] = [
            asset(smokeId, "Smoke Detectors", "smoke_detector", brand: "Kidde",
                  model: "i9050", location: "Whole home", nextDue: day(14),
                  source: "user", openTasks: 2, logs: 1, addedDaysAgo: 12),
            asset(heaterId, "Rheem Water Heater", "water_heater", brand: "Rheem",
                  model: "XE50T10H45U0", location: "Basement", nextDue: day(0),
                  source: "scan", openTasks: 2, logs: 1, addedDaysAgo: 47),
            asset(hvacId, "Carrier Furnace", "hvac", brand: "Carrier",
                  model: "59TP6B", location: "Basement", nextDue: day(23),
                  source: "scan", openTasks: 3, logs: 2, addedDaysAgo: 96,
                  attributes: ["has_ac": .bool(true)]),
            asset(dryerId, "Whirlpool Dryer", "dryer", brand: "Whirlpool",
                  model: "WED5000DW", location: "Laundry Room", nextDue: day(-2),
                  source: "scan", openTasks: 2, logs: 1, addedDaysAgo: 104),
            asset(dishwasherId, "Whirlpool Dishwasher", "dishwasher", brand: "Whirlpool",
                  model: "WDT750SAKZ", location: "Kitchen", nextDue: day(3),
                  source: "scan", openTasks: 1, logs: 0, addedDaysAgo: 141),
            asset(rangeId, "LG Electric Range", "oven_range", brand: "LG",
                  model: "LDE4413ST", location: "Kitchen", nextDue: day(40),
                  source: "scan", openTasks: 1, logs: 0, addedDaysAgo: 143),
            asset(fridgeId, "LG Refrigerator", "refrigerator", brand: "LG",
                  model: "LRFXS2503S", location: "Kitchen", nextDue: day(0),
                  source: "scan", openTasks: 2, logs: 3, addedDaysAgo: 148,
                  attributes: ["has_water_line": .bool(true)],
                  warrantyDaysAhead: 412),
        ]

        private static func asset(
            _ id: String,
            _ name: String,
            _ category: String,
            brand: String,
            model: String,
            location: String,
            nextDue: HearthDay,
            source: String,
            openTasks: Int,
            logs: Int,
            addedDaysAgo: Int,
            attributes: [String: JSONValue]? = nil,
            warrantyDaysAhead: Int? = nil
        ) -> Asset {
            Asset(
                id: id,
                name: name,
                category: category,
                categorySource: source,
                brand: brand,
                brandNorm: brand.lowercased(),
                model: model,
                serial: nil,
                upc: nil,
                location: location,
                purchaseDate: day(-addedDaysAgo),
                purchasePriceCents: nil,
                retailer: nil,
                warrantyExpiresOn: warrantyDaysAhead.map { day($0) },
                warrantyProvider: warrantyDaysAhead == nil ? nil : "\(brand) Care",
                notes: nil,
                status: "active",
                createdAt: stamp(daysAgo: addedDaysAgo),
                updatedAt: stamp(daysAgo: min(addedDaysAgo, 6)),
                counts: .init(photos: 0, openTasks: openTasks, logs: logs),
                nextDue: nextDue,
                hasOcrText: source == "scan",
                attributes: attributes.map { LenientJSON(object: $0) }
            )
        }

        // MARK: Tasks
        //
        // Titles, instructions and intervals are the rows in
        // `002_templates_seed.sql`; the due dates are relative to today, so
        // every bucket on the Today screen is populated and the screenshot does
        // not go stale.

        static let tasks: [SeededTask] = [
            task("tk_vent", dryerId, "Whirlpool Dryer", "Clean the dryer vent duct",
                 "dryer.vent", day(-2), "safety"),
            task("tk_filter", fridgeId, "LG Refrigerator", "Replace the fridge water filter",
                 "refrigerator.water_filter", day(0), "normal"),
            task("tk_tpr", heaterId, "Rheem Water Heater", "Test the temperature-pressure relief valve",
                 "water_heater.tpr", day(0), "safety"),
            task("tk_dw", dishwasherId, "Whirlpool Dishwasher", "Clean the dishwasher filter basket",
                 "dishwasher.filter", day(3), "normal"),
            task("tk_coils", fridgeId, "LG Refrigerator", "Vacuum the condenser coils",
                 "refrigerator.coils", day(6), "normal"),
            task("tk_smoke", smokeId, "Smoke Detectors", "Test smoke detectors",
                 "smoke_detector.test", day(14), "safety"),
            task("tk_condensate", hvacId, "Carrier Furnace", "Clear the AC condensate drain line",
                 "hvac.condensate", day(23), "high"),
            task("tk_hvacfilter", hvacId, "Carrier Furnace", "Replace HVAC filter",
                 "hvac.filter", day(27), "normal"),
            task("tk_hood", rangeId, "LG Electric Range", "Clean the range hood filter",
                 "oven_range.hood", day(40), "normal"),
            task("tk_lint", dryerId, "Whirlpool Dryer", "Deep-clean the lint trap housing",
                 "dryer.lint", day(45), "high"),
            task("tk_flush", heaterId, "Rheem Water Heater", "Flush the water heater tank",
                 "water_heater.flush", day(58), "high"),
            task("tk_batteries", smokeId, "Smoke Detectors", "Replace smoke detector batteries",
                 "smoke_detector.batteries", day(95), "safety"),
            task("tk_hvacservice", hvacId, "Carrier Furnace", "Schedule professional HVAC service",
                 "hvac.service", day(120), "normal"),
        ]

        /// Wraps the wire type with the bucket the server would have computed,
        /// so `upcoming()` does not reimplement the boundary rules.
        struct SeededTask {
            let task: MaintenanceTask
            let bucket: String
        }

        private static func task(
            _ id: String, _ assetId: String, _ assetName: String, _ title: String,
            _ templateId: String, _ due: HearthDay, _ priority: String
        ) -> SeededTask {
            let delta = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: due.date ?? Date())
            ).day ?? 0

            let bucket: String
            switch delta {
            case ..<0: bucket = "overdue"
            case 0: bucket = "today"
            case 1...7: bucket = "this_week"
            case 8...31: bucket = "this_month"
            default: bucket = "later"
            }

            return SeededTask(
                task: MaintenanceTask(
                    id: id,
                    assetId: assetId,
                    planId: "pl_\(templateId)",
                    title: title,
                    dueOn: due,
                    status: "pending",
                    priority: priority,
                    completedAt: nil,
                    logId: nil,
                    assetName: assetName,
                    overdue: bucket == "overdue"
                ),
                bucket: bucket
            )
        }

        // MARK: Plans

        static func plans(for assetId: String) -> [Plan] {
            let rows: [(String, String, String, Int, String, String?)] = {
                switch assetId {
                case fridgeId:
                    return [
                        ("pl_refrigerator.coils", "Vacuum the condenser coils", "refrigerator.coils", 180, "normal", nil),
                        ("pl_refrigerator.water_filter", "Replace the fridge water filter", "refrigerator.water_filter", 180, "normal", nil),
                        ("pl_refrigerator.seal", "Check door gaskets and clean the drain", "refrigerator.seal", 180, "low", nil),
                    ]
                case hvacId:
                    return [
                        ("pl_hvac.condensate", "Clear the AC condensate drain line", "hvac.condensate", 180, "high", nil),
                        ("pl_hvac.filter", "Replace HVAC filter", "hvac.filter", 90, "normal", nil),
                        ("pl_hvac.service", "Schedule professional HVAC service", "hvac.service", 365, "normal", nil),
                    ]
                case dryerId:
                    return [
                        ("pl_dryer.vent", "Clean the dryer vent duct", "dryer.vent", 90, "safety", VentNote),
                        ("pl_dryer.lint", "Deep-clean the lint trap housing", "dryer.lint", 90, "high", nil),
                    ]
                case heaterId:
                    return [
                        ("pl_water_heater.tpr", "Test the temperature-pressure relief valve", "water_heater.tpr", 365, "safety", TPRNote),
                        ("pl_water_heater.flush", "Flush the water heater tank", "water_heater.flush", 365, "high", nil),
                    ]
                case smokeId:
                    return [
                        ("pl_smoke_detector.test", "Test smoke detectors", "smoke_detector.test", 180, "safety", nil),
                        ("pl_smoke_detector.batteries", "Replace smoke detector batteries", "smoke_detector.batteries", 365, "safety", nil),
                    ]
                case dishwasherId:
                    return [("pl_dishwasher.filter", "Clean the dishwasher filter basket", "dishwasher.filter", 30, "normal", nil)]
                case rangeId:
                    return [("pl_oven_range.hood", "Clean the range hood filter", "oven_range.hood", 90, "normal", nil)]
                default:
                    return []
                }
            }()

            return rows.map { id, title, template, interval, priority, note in
                // `next_due_on` is the task that is actually pending, so the plan
                // list and the Today screen agree -- two screens showing
                // different dates for one chore is the kind of thing a reviewer
                // notices.
                let next = tasks.first { $0.task.planId == id }?.task.dueOn ?? day(interval)
                return Plan(
                    id: id,
                    assetId: assetId,
                    templateId: template,
                    title: title,
                    instructions: nil,
                    intervalDays: interval,
                    anchorDate: day(-interval),
                    nextDueOn: next,
                    priority: priority,
                    safetyNote: note,
                    active: 1,
                    source: "template",
                    assetName: nil
                )
            }
        }

        private static let VentNote = "Lint buildup in a dryer duct is a leading cause of house fires. This is the single highest-value task in this list."
        private static let TPRNote = "A failed TPR valve on a water heater can cause a catastrophic tank rupture. If the valve does not discharge when tested, have it replaced immediately."

        // MARK: Logs

        static let logs: [MaintenanceLog] = [
            log("lg_1", fridgeId, 5, "Replaced the water filter", "diy", 4999, nil),
            log("lg_2", fridgeId, 8, "Vacuumed the condenser coils", "diy", nil, nil),
            log("lg_3", fridgeId, 11, "Replaced the water filter", "repair", 4499, "Home Depot"),
            log("lg_4", hvacId, 3, "Replaced the air filter (16x25x1)", "diy", 2199, nil),
            log("lg_5", hvacId, 9, "Annual furnace tune-up", "service", 18900, "Peterson Heating & Air"),
            log("lg_6", heaterId, 7, "Flushed the tank and checked the anode rod", "service", 16500, "Ridgeline Plumbing"),
            log("lg_7", dryerId, 4, "Cleared the vent duct and the exterior flapper", "diy", nil, nil),
            log("lg_8", smokeId, 12, "Replaced all nine detectors", "diy", 13491, nil),
        ]

        private static func log(
            _ id: String, _ assetId: String, _ daysAgo: Int, _ title: String,
            _ kind: String, _ cents: Int?, _ vendor: String?
        ) -> MaintenanceLog {
            MaintenanceLog(
                id: id,
                assetId: assetId,
                taskId: nil,
                kind: kind,
                performedOn: day(-daysAgo),
                title: title,
                vendor: vendor,
                vendorPhone: nil,
                costCents: cents,
                currency: cents == nil ? nil : "USD",
                parts: nil,
                notes: nil,
                warrantyWork: false,
                assetName: nil,
                createdAt: stamp(daysAgo: daysAgo)
            )
        }

        // MARK: Recall

        /// The real record: CPSC recall 25126, published 2025-02-06. Copied
        /// rather than invented, because a fabricated recall in a screenshot is
        /// a claim about a real agency's data.
        static let recallMatch = RecallMatch(
            id: "rm_demo_1",
            assetId: rangeId,
            assetName: "LG Electric Range",
            recallId: "25126",
            confidence: "high",
            matchedOn: "brand+category",
            why: "Same brand and same kind of product",
            score: 0.9,
            state: "new",
            notifiedAt: stamp(daysAgo: 1),
            createdAt: stamp(daysAgo: 1),
            recall: Recall(
                number: "25126",
                date: "2025-02-06",
                title: "LG Recalls Electric Ranges Due to Fire Hazard",
                hazard: "Front-mounted knobs on the recalled ranges can be activated by accidental contact by humans or pets, posing a fire hazard.",
                hazardHigh: true,
                remedy: "Consumers should contact LG for a free warning label and placement instructions. The label reminds consumers to use the Lock Out/Control Lock function on the range control panel to disable activation of the heating elements when the range is not in use. Consumers are cautioned to keep children and pets away from the knobs, and to check the range knobs to ensure they are off before leaving home or going to bed.",
                url: "https://www.cpsc.gov/Recalls/2025/LG-Recalls-Electric-Ranges-Due-to-Fire-Hazard",
                imageUrl: "https://www.cpsc.gov/s3fs-public/range-1.png"
            )
        )

        // MARK: Scan preview

        static let refrigeratorPreview = preview(for: "refrigerator")

        static func preview(for category: String) -> [TemplatePreviewItem] {
            let rows: [(String, String, String, Int, String, String?)] = {
                switch category {
                case "refrigerator":
                    return [
                        ("refrigerator.coils", "Vacuum the condenser coils", "core", 180, "normal", nil),
                        ("refrigerator.water_filter", "Replace the fridge water filter", "core", 180, "normal", nil),
                        ("refrigerator.seal", "Check door gaskets and clean the drain", "core", 180, "low", nil),
                    ]
                case "hvac":
                    return [
                        ("hvac.filter", "Replace HVAC filter", "core", 90, "normal", nil),
                        ("hvac.condensate", "Clear the AC condensate drain line", "core", 180, "high", nil),
                        ("hvac.service", "Schedule professional HVAC service", "pro", 365, "normal", nil),
                    ]
                case "dryer":
                    return [
                        ("dryer.vent", "Clean the dryer vent duct", "core", 90, "safety",
                         "Lint buildup in a dryer duct is a leading cause of house fires."),
                        ("dryer.lint", "Deep-clean the lint trap housing", "core", 90, "high", nil),
                    ]
                case "water_heater":
                    return [
                        ("water_heater.flush", "Flush the water heater tank", "core", 365, "high", nil),
                        ("water_heater.tpr", "Test the temperature-pressure relief valve", "core", 365, "safety",
                         "A failed TPR valve can cause a catastrophic tank rupture."),
                        ("water_heater.anode", "Inspect or replace the anode rod", "pro", 365, "normal", nil),
                    ]
                case "dishwasher":
                    return [
                        ("dishwasher.filter", "Clean the dishwasher filter basket", "core", 30, "normal", nil),
                        ("dishwasher.seal", "Inspect the door seal and check for leaks", "core", 180, "high", nil),
                    ]
                default:
                    return []
                }
            }()
            return rows.map {
                TemplatePreviewItem(
                    templateId: $0.0, title: $0.1, intervalDays: $0.3,
                    priority: $0.4, safetyNote: $0.5, tier: $0.2
                )
            }
        }
    }
}
#endif
