import SwiftUI

/// Marking a task done, and in the same breath writing the repair-history entry.
///
/// The two are one screen because they are one event. A separate "add a log
/// entry" form would mean the history only ever gets filled in by users who go
/// looking for it, and the history is the thing that gets handed to an insurer
/// or a buyer years later -- it is worth one extra field on a screen the user is
/// already on.
///
/// Everything but the date is optional. The friction of this screen is what
/// decides whether the history exists at all, so the required set is the set the
/// server requires and nothing more.
struct CompleteTaskSheet: View {
    let task: MaintenanceTask
    let onAction: (CompleteAction) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var performedOn = Date()
    @State private var kind: LogKind = .service
    @State private var vendor = ""
    @State private var costText = ""
    @State private var notes = ""
    @State private var showDetails = false
    @State private var isWorking = false
    @State private var snoozeDays = 7

    /// The server's `kind` literal. Required rather than optional on this screen
    /// because "did it myself" versus "paid someone" is the single most useful
    /// distinction in a repair history and the server cannot infer it.
    enum LogKind: String, CaseIterable, Identifiable {
        case service
        case repair
        case diy
        case inspection
        case install

        var id: String { rawValue }

        var label: String {
            switch self {
            case .service: return "Service"
            case .repair: return "Repair"
            case .diy: return "Did it myself"
            case .inspection: return "Inspection"
            case .install: return "Installation"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.title)
                        .font(.headline)
                    if let asset = task.assetName {
                        Text(asset).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    DatePicker("Done on", selection: $performedOn, displayedComponents: .date)
                    Picker("Kind", selection: $kind) {
                        ForEach(LogKind.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("When")
                }

                if showDetails {
                    Section {
                        TextField("Who did it", text: $vendor)
                            .autocorrectionDisabled()
                        HStack {
                            Text("$")
                            TextField("0", text: $costText)
                                .keyboardType(.decimalPad)
                        }
                        TextField("Parts, notes", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                    } header: {
                        Text("Details")
                    } footer: {
                        Text("Optional, but this is the part that makes the history worth keeping.")
                    }
                } else {
                    Button("Add cost, vendor or notes") {
                        withAnimation { showDetails = true }
                    }
                    .font(.subheadline)
                }

                Section {
                    Button {
                        run(.snooze(days: snoozeDays))
                    } label: {
                        HStack {
                            Label("Not yet", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Picker("", selection: $snoozeDays) {
                                Text("1 week").tag(7)
                                Text("2 weeks").tag(14)
                                Text("1 month").tag(30)
                                Text("3 months").tag(90)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Pushes this one reminder back without touching the schedule.")
                }
            }
            .navigationTitle("Mark as done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { run(.complete(payload)) }
                        .disabled(isWorking)
                }
            }
        }
    }

    /// Cents, not dollars. The API takes an integer of cents (`cost_cents`, with
    /// a ceiling of 10^11), and sending "12.50" as a float would round somewhere
    /// and one day be wrong by a penny in a total the user is showing an
    /// insurance company. Parsed with a locale-independent separator so a decimal
    /// comma in a European locale does not drop the cents.
    private var costCents: Int? {
        let cleaned = costText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let dollars = Double(cleaned) else { return nil }
        return Int((dollars * 100).rounded())
    }

    private var payload: HearthAPI.TaskAction {
        HearthAPI.TaskAction(
            // The default, and the only value this sheet sends. It is spelled out
            // because `scope` has no server-side default in the Swift model.
            scope: "once",
            snoozeDays: nil,
            performedOn: Self.dayFormatter.string(from: performedOn),
            costCents: costCents,
            vendor: trimmed(vendor),
            notes: trimmed(notes),
            createLog: true,
            kind: kind.rawValue
        )
    }

    private func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `due_on` and `performed_on` are calendar days, not instants. Formatting in
    /// UTC would be wrong here -- a user in California marking something done at
    /// 6pm would have it recorded as the next day -- so this is the device's own
    /// calendar, and the server stores the string as given.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func run(_ action: CompleteAction) {
        isWorking = true
        Task {
            await onAction(action)
            isWorking = false
            dismiss()
        }
    }
}
