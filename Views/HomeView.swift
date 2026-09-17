import SwiftUI

/// The Today tab: what needs doing, in the order it needs doing.
///
/// Everything here comes from `GET /tasks/upcoming`, which buckets server-side.
/// The bucketing is not recomputed on the client on purpose -- "this week" has to
/// mean the same thing in the app as it did in the notification that brought the
/// user here, and two implementations of that rule would eventually disagree.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var upcoming: UpcomingResponse?
    @State private var isLoading = true
    @State private var error: String?
    @State private var completing: MaintenanceTask?
    @State private var busyTaskId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    if let error {
                        ErrorBanner(message: error, retry: { Task { await load() } })
                            .padding(.horizontal, Theme.gutter)
                    }

                    summary

                    if isLoading && upcoming == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if bucketKeys.isEmpty {
                        EmptyState(
                            icon: "checkmark.seal",
                            title: "Nothing due",
                            message: "Your home is up to date. Photograph another appliance and Hearth will set up its schedule right away."
                        )
                    } else {
                        ForEach(bucketKeys, id: \.self) { key in
                            bucket(key)
                        }
                    }

                    if let later = upcoming?.counts["later"], later > 0 {
                        // Counted, never listed. A chore due in five months on
                        // the screen the user opens every day is noise that
                        // buries the one that is late.
                        Text(later == 1
                             ? "1 more task due later."
                             : "\(later) more tasks due later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.gutter)
                    }
                }
                .padding(.vertical, Theme.gutter)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $completing) { task in
                CompleteTaskSheet(task: task) { action in
                    await apply(action, to: task)
                }
                .environmentObject(session)
            }
        }
    }

    // MARK: - Pieces

    /// Overdue first, and only the buckets that have something in them.
    private var bucketKeys: [String] {
        guard let buckets = upcoming?.buckets else { return [] }
        return UpcomingResponse.bucketOrder.filter { !(buckets[$0]?.isEmpty ?? true) }
    }

    @ViewBuilder
    private var summary: some View {
        let counts = upcoming?.counts ?? [:]
        let overdue = counts["overdue"] ?? 0
        let today = counts["today"] ?? 0

        if overdue > 0 || today > 0 {
            HStack(spacing: 10) {
                if overdue > 0 {
                    SummaryPill(count: overdue, label: overdue == 1 ? "overdue" : "overdue", tint: .red)
                }
                if today > 0 {
                    SummaryPill(count: today, label: today == 1 ? "due today" : "due today", tint: Theme.ember)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private func bucket(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UpcomingResponse.bucketTitles[key] ?? key.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(key == "overdue" ? .red : .secondary)
                .padding(.horizontal, Theme.gutter)

            VStack(spacing: 8) {
                ForEach(upcoming?.buckets[key] ?? []) { task in
                    TaskRow(
                        task: task,
                        isBusy: busyTaskId == task.id,
                        onDismissAlways: { Task { await apply(.dismissAlways, to: task) } }
                    )
                        .contentShape(Rectangle())
                        .onTapGesture { completing = task }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await dismiss(task) }
                            } label: {
                                Label("Skip", systemImage: "xmark")
                            }
                            Button {
                                Task { await snooze(task, days: 7) }
                            } label: {
                                Label("Snooze", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(.orange)
                        }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    // MARK: - Actions

    private func load() async {
        error = nil
        do {
            upcoming = try await HearthAPI.upcoming()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Applied against the server, then the whole screen is re-fetched rather
    /// than patched locally. Completing a task advances its plan and can create
    /// the next occurrence, so the local copy of "what is due" is wrong the
    /// moment the write lands -- guessing at it would eventually show a task
    /// that no longer exists.
    private func apply(_ action: CompleteAction, to task: MaintenanceTask) async {
        busyTaskId = task.id
        defer { busyTaskId = nil }
        do {
            switch action {
            case .complete(let body):
                _ = try await HearthAPI.completeTask(task.id, body)
            case .snooze(let days):
                _ = try await HearthAPI.snoozeTask(task.id, days: days)
            case .dismissOnce:
                _ = try await HearthAPI.dismissTask(task.id, scope: "once")
            case .dismissAlways:
                _ = try await HearthAPI.dismissTask(task.id, scope: "always")
            }
            await load()
            await session.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func snooze(_ task: MaintenanceTask, days: Int) async {
        await apply(.snooze(days: days), to: task)
    }

    private func dismiss(_ task: MaintenanceTask) async {
        // "once" rather than a sheet: the swipe is a deliberate gesture and the
        // common case is "not this month", which the next occurrence covers. The
        // permanent version lives in the row's context menu, where it takes a
        // second deliberate action to reach.
        await apply(.dismissOnce, to: task)
    }
}

/// What the complete sheet decided.
enum CompleteAction {
    case complete(HearthAPI.TaskAction)
    case snooze(days: Int)
    case dismissOnce
    case dismissAlways
}

// MARK: - Row

private struct TaskRow: View {
    let task: MaintenanceTask
    let isBusy: Bool
    let onDismissAlways: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                statusDot

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(Theme.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)

                    if let asset = task.assetName, !asset.isEmpty {
                        Text(asset)
                            .font(Theme.cardMeta)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Text(task.dueOn.relativeDescription())
                            .font(.caption)
                            .foregroundStyle(task.overdue ? .red : .secondary)
                        if task.isSafety {
                            Badge(text: "Safety", color: .red)
                        }
                    }
                    .padding(.top, 1)
                }

                Spacer(minLength: 0)

                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
            }
        }
        .contextMenu {
            // The permanent version of the swipe action. It retires the plan, so
            // it is behind a long press rather than reachable by a gesture the
            // user might make by accident.
            Button(role: .destructive) {
                onDismissAlways()
            } label: {
                Label("Stop reminding me about this", systemImage: "bell.slash")
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(task.overdue ? Color.red : Theme.ember.opacity(0.85))
            .frame(width: 7, height: 7)
            .padding(.top, 6)
    }
}

private struct SummaryPill: View {
    let count: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.headline)
                .foregroundStyle(tint)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: Capsule())
    }
}
