import SwiftUI

/// The My Home tab: everything in the house.
///
/// Sorted by newest first, as the server returns it. That is the right order for
/// a list that grows by accretion -- the thing just added is the thing most
/// likely to need a correction -- and it is stable, which an alphabetical sort of
/// user-typed names is not.
struct AssetsView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var assets: [Asset] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var search = ""
    @State private var showArchived = false
    @State private var showAdd = false
    @State private var archiving: Asset?
    @State private var pendingDelete: Asset?
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && assets.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if assets.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("My Home")
            .searchable(text: $search, prompt: "Name, brand or model")
            .refreshable { await load() }
            .task {
                await load()
                #if DEBUG
                // The screenshot build pushes an asset without a tap. Done after
                // the list loads so there is a list behind it to pop back to.
                if let id = DemoMode.autoOpenedAssetId { path = [id] }
                #endif
            }
            .navigationDestination(for: String.self) { id in
                AssetDetailView(assetId: id, onChanged: { Task { await load() } })
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Show archived", isOn: $showArchived)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!session.canAddAsset)
                }
            }
            .onChange(of: showArchived) { _ in Task { await load() } }
            .sheet(isPresented: $showAdd) {
                AssetFormView(mode: .add) { await load() }
                    .environmentObject(session)
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.name ?? "this asset")?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive instead", role: .none) {
                    if let asset = pendingDelete { Task { await archive(asset) } }
                }
                Button("Delete permanently", role: .destructive) {
                    if let asset = pendingDelete { Task { await hardDelete(asset) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Archiving keeps the repair history and stops all reminders. Deleting removes everything, including the photos and every logged repair.")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let error {
                ErrorBanner(message: error, retry: { Task { await load() } })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(filtered) { asset in
                NavigationLink(value: asset.id) {
                    AssetRow(asset: asset)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = asset
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Filtered on the device, not the server. The whole list is at most a few
    /// hundred rows (the free plan's ceiling is well under that), so a round trip
    /// per keystroke would add latency to the one interaction that has to feel
    /// instant.
    private var filtered: [Asset] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return assets }
        return assets.filter { asset in
            [asset.name, asset.brand, asset.model, asset.location, asset.serial]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    private var emptyState: some View {
        VStack {
            if search.isEmpty {
                EmptyState(
                    icon: "house",
                    title: "Nothing here yet",
                    message: "Photograph the label on your fridge, furnace or water heater and Hearth will read it and set up its maintenance schedule.",
                    actionTitle: "Add the first one",
                    action: { showAdd = true }
                )
            } else {
                EmptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "Nothing in your home matches \"\(search)\"."
                )
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        error = nil
        do {
            assets = try await HearthAPI.assets(status: showArchived ? "all" : "active").assets
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func archive(_ asset: Asset) async {
        pendingDelete = nil
        do {
            _ = try await HearthAPI.deleteAsset(asset.id, hard: false)
            await load()
            await session.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hardDelete(_ asset: Asset) async {
        pendingDelete = nil
        do {
            _ = try await HearthAPI.deleteAsset(asset.id, hard: true)
            await load()
            await session.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct AssetRow: View {
    let asset: Asset

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if asset.status != "active" {
                    Badge(text: asset.status.capitalized, color: Theme.status(asset.status))
                        .padding(.top, 1)
                } else if let due = asset.nextDue {
                    Text(due.relativeDescription())
                        .font(.caption)
                        .foregroundStyle(due.isPast ? .red : Theme.ember)
                } else if asset.counts.openTasks == 0 {
                    // Said plainly rather than left blank: an asset with no
                    // schedule is a state the user can fix, and the fix is not
                    // discoverable from an empty space.
                    Text("No schedule")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        [asset.brand, asset.model, asset.location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A letter rather than a category glyph or the photo.
    ///
    /// Not the photo: the list is scrolled far more often than read, and a
    /// network image per row leaves it blank for a moment on every launch and
    /// every scroll back up.
    ///
    /// Not an SF Symbol either, which was the first attempt. The category
    /// vocabulary lives on the server and can grow without a client release, so a
    /// symbol map would need a fallback anyway -- and on iOS a symbol name that
    /// does not exist draws nothing at all. A blank 42pt box is not a failure
    /// anyone would notice in review, and this machine has no Xcode to check the
    /// symbol list against. A letter always renders.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Theme.ember.opacity(0.12))
            .frame(width: 42, height: 42)
            .overlay {
                Text(CategoryGlyph.monogram(for: asset.category))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ember)
            }
    }
}

/// The row marker for a category.
///
/// The slug is the server's vocabulary, so this handles anything: two words give
/// two letters ("water_heater" -> WH, "smoke_detector" -> SD), one word gives its
/// first ("refrigerator" -> R). An empty or unexpected value gives a neutral dot
/// rather than a blank.
enum CategoryGlyph {
    static func monogram(for category: String) -> String {
        let words = category
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "·" }
        let initials = words.prefix(2).compactMap { $0.first }
        return initials.count > 1
            ? String(initials).uppercased()
            : String(first.prefix(1)).uppercased()
    }
}
