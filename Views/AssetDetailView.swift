import SwiftUI

/// One asset: what it is, what it needs, and what has been done to it.
///
/// The order on screen is the order of the questions a person actually has --
/// what is this, when does it next need something, what has it cost me -- and the
/// history is at the bottom because it is the part that grows and the part that
/// is read least often.
struct AssetDetailView: View {
    let assetId: String
    /// Called after anything that changes the list behind this screen (a rename,
    /// an archive, a deleted log), so the row it came from is not stale when the
    /// user goes back.
    let onChanged: () -> Void

    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var asset: Asset?
    @State private var plans: [Plan] = []
    @State private var photos: [AssetPhoto] = []
    @State private var logs: [MaintenanceLog] = []
    @State private var costByCurrency: [String: Int] = [:]
    /// The asset's pending tasks, held so a plan can be stopped from here.
    ///
    /// Stopping a plan is not a plan operation and there is no endpoint that
    /// would suggest otherwise: `PATCH /plans/{id}` and `DELETE /plans/{id}` do
    /// not exist. A plan's interval is fixed once created, and the one way to
    /// stop it is to dismiss one of its tasks with `scope: "always"` -- which
    /// deactivates the plan and answers `plan_retired: true`. So the task id,
    /// not the plan id, is what this screen actually needs, and that is why the
    /// card's only action is "stop reminding me" rather than an editor.
    @State private var pendingTasks: [MaintenanceTask] = []

    @State private var isLoading = true
    @State private var error: String?
    @State private var editing = false
    @State private var showLogEntry = false
    @State private var editingLog: MaintenanceLog?
    @State private var showAddPlan = false
    @State private var confirmDelete = false
    /// The plan whose "stop reminding me" is being confirmed.
    @State private var retiringPlan: Plan?
    /// The title, held apart from `retiringPlan` because that is set to nil the
    /// moment the alert is answered -- and the message is still on screen while
    /// it animates away, so reading the name from a nil plan would flash an
    /// empty pair of quotes.
    @State private var retiringTitle = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error {
                    ErrorBanner(message: error, retry: { Task { await load() } })
                }

                if isLoading && asset == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let asset {
                    header(asset)
                    identity(asset)
                    scheduleSection(asset)
                    historySection(asset)
                    photosSection(asset)
                    dangerZone(asset)
                }
            }
            .padding(Theme.gutter)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(asset?.name ?? "Asset")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editing = true
                    } label: {
                        Label("Edit details", systemImage: "pencil")
                    }
                    Button {
                        showAddPlan = true
                    } label: {
                        Label("Add a reminder", systemImage: "calendar.badge.plus")
                    }
                    Button {
                        showLogEntry = true
                    } label: {
                        Label("Log a repair", systemImage: "wrench.and.screwdriver")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let asset {
                AssetFormView(mode: .edit(asset)) { await load(); onChanged() }
                    .environmentObject(session)
            }
        }
        .sheet(isPresented: $showAddPlan) {
            if let asset {
                PlanFormView(asset: asset) { await load() }
            }
        }
        .sheet(isPresented: $showLogEntry) {
            if let asset {
                LogFormView(asset: asset, existing: nil) { await load() }
            }
        }
        .sheet(item: $editingLog) { log in
            if let asset {
                LogFormView(asset: asset, existing: log) { await load() }
            }
        }
        .alert("Stop this reminder?", isPresented: .init(
            get: { retiringPlan != nil },
            set: { if !$0 { retiringPlan = nil } }
        )) {
            Button("Stop it", role: .destructive) { Task { await retire() } }
            Button("Keep it", role: .cancel) { retiringPlan = nil }
        } message: {
            Text("“\(retiringTitle)” will not come round again, and any other times it was due are cleared. What you have already logged stays.")
        }
        .alert("Delete this permanently?", isPresented: $confirmDelete) {
            Button("Archive instead") { Task { await remove(hard: false) } }
            Button("Delete everything", role: .destructive) { Task { await remove(hard: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archiving keeps the repair history and stops every reminder. Deleting removes the asset, its photos and its entire history, and cannot be undone.")
        }
    }

    // MARK: - Header

    private func header(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let next = asset.nextDue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(Theme.ember)
                    Text("Next: \(next.relativeDescription().lowercased())")
                        .font(.headline)
                    Spacer()
                }
                Text(next.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text("No reminders set up")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            if !asset.warrantyIsActive, let expires = asset.warrantyExpiresOn {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("Warranty ended \(expires.relativeDescription(from: Date()).lowercased())")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if asset.warrantyIsActive, let expires = asset.warrantyExpiresOn {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Under warranty until \(expires.raw)")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Identity

    private func identity(_ asset: Asset) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                // The server's own label, not a prettified slug: it is the same
                // string the scan screen and the category picker show.
                Row(label: "Type", value: session.label(for: asset.category))
                if let brand = asset.brand, !brand.isEmpty { Row(label: "Brand", value: brand) }
                if let model = asset.model, !model.isEmpty { Row(label: "Model", value: model) }
                if let serial = asset.serial, !serial.isEmpty { Row(label: "Serial", value: serial) }
                if let upc = asset.upc, !upc.isEmpty { Row(label: "UPC", value: upc) }
                if let location = asset.location, !location.isEmpty { Row(label: "Location", value: location) }
                if let purchased = asset.purchaseDate {
                    Row(label: "Bought", value: purchased.raw)
                }
                if let price = asset.purchasePriceCents {
                    Row(label: "Price", value: Money.format(price))
                }
                if let retailer = asset.retailer, !retailer.isEmpty {
                    Row(label: "Retailer", value: retailer)
                }
                if let provider = asset.warrantyProvider, !provider.isEmpty {
                    Row(label: "Warranty by", value: provider)
                }
                if let notes = asset.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Button("Edit details") { editing = true }
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    // MARK: - Schedule

    private func scheduleSection(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Schedule").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddPlan = true
                } label: {
                    Image(systemName: "plus")
                }
                .font(.subheadline)
            }

            if plans.isEmpty {
                Card {
                    Text("Nothing recurring is set up for this. Add a reminder and Hearth will tell you when it comes round.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(plans) { plan in
                        // A plan whose next occurrence has not been materialised
                        // yet gets no action rather than a dead button: there is
                        // no task to dismiss, so there is nothing to retire it
                        // with. The scheduler fills the rolling horizon, so this
                        // is a brief state, not a permanent one.
                        PlanCard(
                            plan: plan,
                            canStop: taskId(for: plan) != nil,
                            isBusy: busy,
                            onStop: {
                                retiringTitle = plan.title
                                retiringPlan = plan
                            }
                        )
                    }
                }

                Text("A reminder cannot be edited after it is saved. Stop it and add a new one if the interval was wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - History

    private func historySection(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showLogEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .font(.subheadline)
            }

            if !costByCurrency.isEmpty {
                // The one number on this screen that is not about time. It is
                // shown per currency because the API sums that way and collapsing
                // two currencies into one figure would produce a total that is
                // simply wrong.
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spent on this")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(costByCurrency.sorted { $0.key < $1.key }
                            .map { Money.format($0.value, currency: $0.key) }
                            .joined(separator: " + "))
                            .font(.headline)
                    }
                }
            }

            if logs.isEmpty {
                Card {
                    Text("No repairs or services recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(logs) { log in
                        LogCard(log: log)
                            .contentShape(Rectangle())
                            .onTapGesture { editingLog = log }
                    }
                }
            }
        }
    }

    // MARK: - Photos

    private func photosSection(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            if photos.isEmpty {
                Card {
                    Text("No photos yet. Add one the next time you have the label or the receipt in front of you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photo in
                            PhotoThumb(photo: photo)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Danger zone

    private func dangerZone(_ asset: Asset) -> some View {
        VStack(spacing: 8) {
            if asset.status == "archived" {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Archived")
                            .font(.subheadline.weight(.semibold))
                        Text("This asset is hidden from your home and sends no reminders. Its history is still here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text(asset.status == "archived" ? "Delete permanently" : "Archive or delete")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
    }

    // MARK: - Loading

    /// Everything about one asset in four calls, in parallel. They are
    /// independent reads and doing them in sequence would make the screen take
    /// four round trips to appear.
    private func load() async {
        error = nil
        async let detail = HearthAPI.asset(assetId)
        async let photoList = HearthAPI.photos(assetId: assetId)
        async let logList = HearthAPI.logs(assetId: assetId)
        // Pending only, which is the server's default for this route and the
        // only status a dismiss can act on.
        async let taskList = HearthAPI.tasks(assetId: assetId)

        do {
            let (d, p, l, t) = try await (detail, photoList, logList, taskList)
            asset = d.asset
            plans = d.plans
            photos = p.photos
            logs = l.logs
            costByCurrency = l.costByCurrency ?? [:]
            pendingTasks = t.tasks
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// The pending task of a given plan, if one is materialised.
    ///
    /// A plan can have several pending rows inside the rolling horizon; which
    /// one is dismissed does not matter, because `scope: "always"` retires the
    /// plan itself and clears the rest.
    private func taskId(for plan: Plan) -> String? {
        pendingTasks.first { $0.planId == plan.id }?.id
    }

    /// Stops a recurring reminder, which the API expresses as dismissing one of
    /// its tasks rather than as deleting the plan.
    private func retire() async {
        guard let plan = retiringPlan, let taskId = taskId(for: plan) else {
            retiringPlan = nil
            return
        }
        retiringPlan = nil
        busy = true
        defer { busy = false }
        do {
            let response = try await HearthAPI.dismissTask(taskId, scope: "always")
            await load()
            await session.refresh()
            onChanged()
            if response.planRetired == false {
                // The server did not retire it, which means this occurrence was
                // skipped and the plan is still live. Saying "stopped" here
                // would be a lie the user only discovers weeks later.
                error = "That reminder was skipped once, but it is still scheduled. Open it from Home and choose “Don’t ask again”."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(hard: Bool) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await HearthAPI.deleteAsset(assetId, hard: hard)
            await session.refresh()
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct PlanCard: View {
    let plan: Plan
    /// False when no task of this plan is materialised yet, which leaves nothing
    /// for `dismiss` to act on.
    let canStop: Bool
    let isBusy: Bool
    let onStop: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(plan.cadenceLabel)
                        Text("·")
                        Text("Next \(plan.nextDueOn.relativeDescription().lowercased())")
                            .foregroundStyle(plan.nextDueOn.isPast ? .red : .secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if plan.isSafety, let note = plan.safetyNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }

                    if canStop {
                        Button("Stop reminding me") { onStop() }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .disabled(isBusy)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if plan.isSafety { Badge(text: "Safety", color: .red) }
                // Marks a chore the user wrote rather than one the knowledge base
                // seeded, so it is clear which ones change when the templates do.
                if plan.isUserCreated { Badge(text: "Yours", color: Theme.ember) }
            }
        }
    }
}

private struct LogCard: View {
    let log: MaintenanceLog

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(log.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let cost = log.costCents {
                        Text(Money.format(cost, currency: log.currency))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(log.performedOn.raw)
                    Text("·")
                    Text(log.kind.capitalized)
                    if let vendor = log.vendor, !vendor.isEmpty {
                        Text("·")
                        Text(vendor).lineLimit(1)
                    }
                    if log.warrantyWork {
                        Badge(text: "Warranty", color: .green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let notes = log.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 1)
                }
            }
        }
    }
}

private struct PhotoThumb: View {
    let photo: AssetPhoto

    var body: some View {
        AsyncImage(url: URL(string: photo.thumbUrl ?? photo.url ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .frame(width: 96, height: 96)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Money, from the integer cents the API stores.
///
/// Cents rather than a Double, everywhere, because a sum of prices in binary
/// floating point is eventually wrong by a penny in a number a user is showing
/// to an insurer.
enum Money {
    static func format(_ cents: Int, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        // No decimals when they are zero: "$450" reads better than "$450.00" in a
        // list, and every price on this screen came from a human typing a round
        // number.
        formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(currency) \(cents / 100)"
    }
}
