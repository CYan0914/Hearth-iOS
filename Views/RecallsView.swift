import SwiftUI

/// Safety notices: which of the user's things are affected, and a way to look
/// up anything else.
///
/// Two things share this screen because they answer one question. The list is
/// personal -- a join of the user's assets against the CPSC corpus, written
/// nightly. The search below it is the whole public corpus, unscoped, because a
/// person standing in front of an appliance should be able to look it up whether
/// or not the matcher happened to catch it.
struct RecallsView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var matches: [RecallMatch] = []
    @State private var dismissed: [RecallMatch] = []
    @State private var showDismissed = false
    @State private var isLoading = true
    @State private var error: String?
    @State private var busyId: String?

    @State private var query = ""
    @State private var searchResults: [RecallSearchHit] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showingSearch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    if let error {
                        ErrorBanner(message: error, retry: { Task { await load() } })
                    }

                    if isLoading && matches.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if matches.isEmpty {
                        emptyState
                    } else {
                        matchesSection
                    }

                    if !dismissed.isEmpty { dismissedSection }

                    searchSection
                }
                .padding(Theme.gutter)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recalls")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Nothing recalled")
                        .font(.headline)
                }
                // Said plainly rather than implied, because "no matches" and "no
                // matches yet" are different states and the user cannot tell them
                // apart from an empty list.
                Text("None of your things match a recall from the Consumer Product Safety Commission. Hearth checks the whole database every night.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var matchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About your things")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(matches) { match in
                MatchCard(
                    match: match,
                    isBusy: busyId == match.id,
                    onDismiss: { Task { await setState(match, "dismissed") } },
                    onSeen: { Task { await setState(match, "seen") } },
                    onRead: { Task { await markSeen(match) } }
                )
            }
        }
    }

    private var dismissedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showDismissed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Dismissed (\(dismissed.count))")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: showDismissed ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }

            if showDismissed {
                ForEach(dismissed) { match in
                    MatchCard(
                        match: match,
                        isBusy: busyId == match.id,
                        onDismiss: nil,
                        onSeen: { Task { await setState(match, "new") } },
                        onRead: nil
                    )
                }
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Look something up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Brand, model, or what it is", text: $query)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        if isSearching { ProgressView().controlSize(.small) }
                    }

                    if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !searchResults.isEmpty {
                        Divider()
                        ForEach(searchResults) { hit in
                            SearchHitRow(hit: hit)
                            if hit.id != searchResults.last?.id { Divider() }
                        }
                    } else if showingSearch && !isSearching && searchError == nil {
                        Text("Nothing in the database matches that.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !showingSearch {
                        Text("Searches every recall the CPSC has published, whether or not it matched one of your things.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// Two calls, both of which the screen needs. Dismissed rows are a separate
    /// request because the server's default filter is "everything except
    /// dismissed" -- there is no flag to ask for both, and the `state` parameter
    /// is a closed set rather than a boolean.
    private func load() async {
        error = nil
        do {
            async let open = HearthAPI.recallMatches()
            async let closed = HearthAPI.recallMatches(state: "dismissed")
            let (o, c) = try await (open, closed)
            matches = o.matches
            dismissed = c.matches
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        await session.refresh()
    }

    /// Marks a match read, one row at a time and only when the user acts on it.
    ///
    /// Not done in bulk on load: the state exists so the list can show what
    /// arrived since the last visit, and clearing it for every row the moment
    /// the screen opens would spend one request per match to destroy the only
    /// thing it records.
    private func markSeen(_ match: RecallMatch) async {
        guard match.state == "new" else { return }
        _ = try? await HearthAPI.updateMatch(match.id, state: "seen")
        if let index = matches.firstIndex(where: { $0.id == match.id }) {
            matches[index].state = "seen"
        }
    }

    private func setState(_ match: RecallMatch, _ state: String) async {
        busyId = match.id
        defer { busyId = nil }
        do {
            _ = try await HearthAPI.updateMatch(match.id, state: state)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server requires two characters; below that this would be a 422
        // dressed up as a failed search.
        guard q.count >= 2 else {
            searchResults = []
            showingSearch = false
            searchError = q.isEmpty ? nil : "Type at least two characters."
            return
        }
        isSearching = true
        searchError = nil
        showingSearch = true
        defer { isSearching = false }
        do {
            let response = try await HearthAPI.searchRecalls(q)
            searchResults = response.results
        } catch {
            searchResults = []
            searchError = error.localizedDescription
        }
    }
}

// MARK: - Cards

private struct MatchCard: View {
    let match: RecallMatch
    let isBusy: Bool
    /// nil on an already-dismissed row, where the action would be a no-op.
    let onDismiss: (() -> Void)?
    let onSeen: () -> Void
    /// Fired when the user opens the official notice, which is the point at
    /// which they have actually read it. nil on a dismissed row.
    let onRead: (() -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.recall.title)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(match.assetName ?? "One of your things")
                            .font(.caption)
                            .foregroundStyle(Theme.ember)
                    }
                    Spacer(minLength: 0)
                    if match.state == "new" {
                        Badge(text: "New", color: Theme.ember)
                    }
                    if match.recall.hazardHigh {
                        Badge(text: "Hazard", color: .red)
                    }
                    if match.isLowConfidence {
                        // The row is shown rather than hidden, and labelled rather
                        // than shown as a warning. A category-only match is
                        // genuinely weaker evidence, and a user who understands
                        // why can dismiss it with confidence instead of wondering
                        // whether they are ignoring something important.
                        Badge(text: "Possible", color: .secondary)
                    }
                }

                if let hazard = match.recall.hazard, !hazard.isEmpty {
                    Text(hazard)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let remedy = match.recall.remedy, !remedy.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What to do")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(remedy)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The reason, in the server's own words. "We matched your fridge
                // because a recall names both Samsung and refrigerators" is a
                // claim the user can check -- and one they can reject with
                // confidence when it is wrong.
                Text(match.why)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 6) {
                    if let date = match.recall.date {
                        Text(date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let urlString = match.recall.url, let url = URL(string: urlString) {
                        Button("Read the notice") {
                            onRead?()
                            openURL(url)
                        }
                        .font(.caption.weight(.medium))
                    }
                    Spacer(minLength: 0)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else if let onDismiss {
                        Button("Not mine") { onDismiss() }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Put back") { onSeen() }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 1)
            }
        }
    }
}

private struct SearchHitRow: View {
    let hit: RecallSearchHit

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(hit.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if hit.hazardHigh { Badge(text: "Hazard", color: .red) }
            }
            if let category = hit.category, !category.isEmpty {
                Text(category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let hazard = hit.hazard, !hazard.isEmpty {
                Text(hazard)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let date = hit.date {
                    Text(date).font(.caption2).foregroundStyle(.secondary)
                }
                if let urlString = hit.url, let url = URL(string: urlString) {
                    Button("Read the notice") { openURL(url) }
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
