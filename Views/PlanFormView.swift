import SwiftUI

/// A recurring chore the user writes themselves.
///
/// Create only, and that is a fact about the API rather than a shortcut here:
/// there is no `PATCH /plans/{id}` and no `DELETE /plans/{id}`. A plan's interval
/// is fixed once created, and the way to stop one is "Don't ask again" on one of
/// its tasks, which retires the plan server-side. The footer says so, because a
/// user who cannot find the edit button will otherwise conclude the app is
/// broken rather than that the reminder is permanent by design.
struct PlanFormView: View {
    let asset: Asset
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var intervalDays = 90
    @State private var customInterval = 90
    @State private var usesCustomInterval = false
    @State private var priority = "normal"
    @State private var instructions = ""
    @State private var startsOn = Date()
    @State private var hasStartDate = false

    @State private var isSaving = false
    @State private var error: String?

    /// The intervals worth offering as one tap. Anything else is reachable
    /// through Custom, and the server accepts 1...3650.
    private static let presets: [(label: String, days: Int)] = [
        ("Weekly", 7),
        ("Every 2 weeks", 14),
        ("Monthly", 30),
        ("Every 3 months", 90),
        ("Every 6 months", 180),
        ("Yearly", 365),
    ]

    /// The server's own `priority` literal. "Whenever" rather than "Low" because
    /// that is what the word means to a person deciding how urgent a chore is.
    private static let priorities: [(id: String, label: String)] = [
        ("low", "Whenever"),
        ("normal", "Normal"),
        ("high", "Important"),
        ("safety", "Safety"),
    ]

    private var effectiveInterval: Int {
        usesCustomInterval ? customInterval : intervalDays
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { ErrorBanner(message: error) }
                }

                Section {
                    TextField("Drain the water heater", text: $title)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("What needs doing")
                } footer: {
                    Text("Shown on your Today list and in every reminder. Name it the way you would say it out loud.")
                }

                Section("How often") {
                    ForEach(Self.presets, id: \.days) { preset in
                        Button {
                            usesCustomInterval = false
                            intervalDays = preset.days
                        } label: {
                            HStack {
                                Text(preset.label).foregroundStyle(.primary)
                                Spacer()
                                if !usesCustomInterval && intervalDays == preset.days {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.ember)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    Button {
                        usesCustomInterval = true
                    } label: {
                        HStack {
                            Text("Custom").foregroundStyle(.primary)
                            Spacer()
                            if usesCustomInterval {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.ember)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    if usesCustomInterval {
                        Stepper("Every \(customInterval) days", value: $customInterval, in: 1...3650)
                    }
                }

                Section("How urgent") {
                    Picker("Priority", selection: $priority) {
                        ForEach(Self.priorities, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section {
                    Toggle("I know the first date", isOn: $hasStartDate)
                    if hasStartDate {
                        DatePicker("First due", selection: $startsOn, displayedComponents: .date)
                    }
                } header: {
                    Text("When it starts")
                } footer: {
                    // The default is the server's, and it is the right one: it
                    // anchors to the purchase date when there is one, so a
                    // fridge bought in March is not asked for its first filter
                    // change the day it is entered.
                    Text(hasStartDate
                         ? "The next one follows from here."
                         : "Leave this alone and Hearth works the first date out from when you bought it.")
                }

                Section("Notes") {
                    TextField("Torque the element to 45 Nm", text: $instructions, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("A reminder cannot be edited after it is saved. To stop it, open one of its tasks and choose Skip, then Don't ask again.")
                }
            }
            .navigationTitle("New reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await HearthAPI.createPlan(HearthAPI.PlanCreate(
                    assetId: asset.id,
                    title: trimmedTitle,
                    instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    intervalDays: effectiveInterval,
                    nextDueOn: hasStartDate ? Self.dayFormatter.string(from: startsOn) : nil,
                    priority: priority
                ))
                await onCreated()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension String {
    /// Blank strings become nil so an unused field is an absent key rather than
    /// an empty value the server would store and later render as a blank row.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
