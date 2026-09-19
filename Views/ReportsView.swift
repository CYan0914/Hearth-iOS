import SwiftUI

/// The insurance inventory: the export the paywall actually sells.
///
/// This screen exists because the paywall leads with it. Selling a document the
/// app cannot produce is the kind of gap a reviewer finds and a user finds
/// later, standing in a flooded basement. So the screen states what the
/// document will contain *before* it is generated, and the download happens on
/// the device into the system share sheet -- the file is the user's, and the
/// next thing they do with it is email it to somebody.
///
/// Free accounts see the same screen with the same counts and a locked PDF row.
/// Hiding the report from them would hide the reason to upgrade; showing them a
/// button that 402s would be worse. The row is present, says what it is, and
/// opens the paywall.
struct ReportsView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var summary: ExportSummary?
    @State private var loading = true
    @State private var failure: String?
    @State private var preparing: String?
    @State private var exported: ExportedDocument?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if loading && summary == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure, summary == nil {
                    failureState(failure)
                } else if let summary {
                    content(summary)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showPaywall) {
                PaywallView().environmentObject(session)
            }
            .sheet(item: $exported) { document in
                ShareSheet(items: [document.url])
            }
        }
    }

    // MARK: - Sections

    private func content(_ summary: ExportSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(summary)
                if let failure {
                    ErrorBanner(message: failure)
                }
                formats(summary)
                footnote
            }
            .padding(20)
        }
    }

    private func header(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Home inventory")
                .font(.title3.weight(.semibold))
            Text("A record of everything you have entered, with values, serial numbers, warranties and photos. The document an insurer asks for after a loss.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                stat("Items", "\(summary.items)")
                if let value = summary.valueText {
                    stat("Documented value", value)
                }
            }
            .padding(.top, 2)

            if summary.truncated {
                // Said before the download, not discovered inside the file.
                Label(
                    "This report covers part of your inventory, not all of it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    @ViewBuilder
    private func formats(_ summary: ExportSummary) -> some View {
        VStack(spacing: 10) {
            ForEach(summary.formats) { format in
                formatRow(format, summary: summary)
            }
        }
    }

    private func formatRow(_ format: ExportSummary.ExportFormat, summary: ExportSummary) -> some View {
        let busy = preparing == format.format
        let locked = !format.available
        return Button {
            if locked {
                showPaywall = true
            } else {
                Task { await download(format.format) }
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: format.format == "pdf" ? "doc.richtext" : "tablecells")
                    .font(.title3)
                    .foregroundStyle(locked ? Color.secondary : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: format.format))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(locked ? Color.secondary : Color.primary)
                    Text(detail(for: format.format))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if busy {
                    ProgressView()
                } else if locked {
                    // A lock, not a price: the paywall owns pricing, and a
                    // second copy of it here would be a second thing to keep
                    // in step with the store.
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(preparing != nil)
        .opacity(preparing != nil && !busy ? 0.5 : 1)
    }

    private func title(for format: String) -> String {
        format == "pdf" ? "Insurance inventory (PDF)" : "Inventory spreadsheet (CSV)"
    }

    private func detail(for format: String) -> String {
        if format == "pdf" {
            return "Everything, with photos and serial numbers, laid out to hand to an adjuster."
        }
        return "The same records as rows, for a spreadsheet or a moving checklist."
    }

    private var footnote: some View {
        Text("Reports are generated on demand from what you have entered. Updating an item and exporting again produces a current document.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            summary = try await HearthAPI.exportSummary()
            failure = nil
        } catch {
            failure = (error as? APIError)?.errorDescription
                ?? "The report could not be prepared."
        }
    }

    private func download(_ format: String) async {
        preparing = format
        failure = nil
        defer { preparing = nil }

        do {
            let file = try await HearthAPI.downloadInventory(format: format)
            // Written to a temporary file because the share sheet works in URLs
            // and there is no way to hand it bytes. `.temporaryDirectory` rather
            // than Documents: this is a copy the user is about to send
            // somewhere, and a second copy left behind in the container is one
            // more thing to explain in the privacy label.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try? FileManager.default.removeItem(at: url)
            try file.data.write(to: url, options: .atomic)
            exported = ExportedDocument(url: url)
        } catch let error as APIError {
            failure = error.errorDescription
            // A 402 means the plan changed under the user -- a subscription
            // that lapsed on another device, or a downgrade. The screen is
            // showing a stale entitlement, so it is re-read rather than
            // retried: the same request would fail the same way.
            if case .limitReached = error {
                await session.refresh()
                await load()
            }
        } catch {
            failure = "The report could not be saved."
        }
    }
}

/// The file handed to the share sheet, with an identity so `.sheet(item:)`
/// presents once per download rather than once per view update.
struct ExportedDocument: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
}

/// UIActivityViewController, because the destination is a mail client or Files
/// and SwiftUI has no view that reaches both.
///
/// Presented inside a `.sheet`, so on iPad it is already modal. The popover
/// anchor is still set when one exists: a `UIPopoverPresentationController`
/// with no source view raises rather than degrading, and that crash only shows
/// up on the device family no simulator run exercises.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        guard let popover = controller.popoverPresentationController else { return }
        if popover.sourceView == nil {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
    }
}
