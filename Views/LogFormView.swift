import SwiftUI

/// A repair or service record, created or edited.
///
/// One screen for both. The fields are identical and the difference is which
/// verb Save sends -- and, on an edit, that Save sends a diff rather than the
/// whole form. The server rejects a PATCH that changes nothing
/// (`nothing_to_update`), so resending a full form on a screen where the user
/// fixed one character would fail for the times they only opened it to look.
struct LogFormView: View {
    let asset: Asset
    /// nil when recording something new.
    let existing: MaintenanceLog?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind = "repair"
    @State private var title = ""
    @State private var performedOn = Date()
    @State private var vendor = ""
    @State private var vendorPhone = ""
    @State private var costText = ""
    @State private var currency = "USD"
    @State private var parts = ""
    @State private var notes = ""
    @State private var warrantyWork = false

    @State private var isSaving = false
    @State private var showDelete = false
    @State private var error: String?

    /// The server's `LogCreate.kind` literal, which is closed and
    /// `extra="forbid"`. The labels are the words a person would use; the ids
    /// are the only strings the server accepts.
    private static let kinds: [(id: String, label: String)] = [
        ("repair", "Repair"),
        ("service", "Service visit"),
        ("diy", "Did it myself"),
        ("install", "Installation"),
        ("inspection", "Inspection"),
    ]

    /// The server's `CURRENCY` literal. A closed set: a code it does not list is
    /// a 422, not an unknown currency it will store.
    private static let currencies = ["USD", "CAD", "GBP", "EUR", "AUD"]

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { ErrorBanner(message: error) }
                }

                Section {
                    TextField("Replaced the water filter", text: $title)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("What was done")
                }

                Section("When") {
                    DatePicker("Date", selection: $performedOn, in: ...Date(), displayedComponents: .date)
                }

                Section("Who") {
                    Picker("Type", selection: $kind) {
                        ForEach(Self.kinds, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    // the vendor fields only mean something for work someone else
                    // did, but hiding them would make the form jump around while
                    // the user is deciding.
                    TextField("Company", text: $vendor)
                        .textInputAutocapitalization(.words)
                    TextField("Their phone", text: $vendorPhone)
                        .keyboardType(.phonePad)
                }

                Section {
                    HStack {
                        Picker("", selection: $currency) {
                            ForEach(Self.currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 92)
                        TextField("0.00", text: $costText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Covered by warranty", isOn: $warrantyWork)
                } header: {
                    Text("Cost")
                } footer: {
                    // The currency picker is not decoration. The API totals costs
                    // per currency and never across them, so a record filed under
                    // the wrong one does not just mislabel a row -- it lands in a
                    // total that is not money in any country.
                    Text("Totals are kept per currency. Leave the amount blank if you would rather not record it.")
                }

                Section("Parts") {
                    TextField("Part number, brand, where you bought it", text: $parts, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Notes") {
                    TextField("What you would want to know next time", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDelete = true
                        } label: {
                            Text("Delete this record")
                        }
                    } footer: {
                        Text("Deleting the record does not undo the chore. The repair still happened and the schedule still moved on.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit record" : "Log a repair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Delete this record?", isPresented: $showDelete) {
                Button("Delete", role: .destructive) { Task { await remove() } }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("It will be removed from this asset's history. This cannot be undone.")
            }
            .onAppear(perform: seed)
        }
    }

    // MARK: - Data

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func seed() {
        guard let log = existing else { return }
        kind = log.kind
        title = log.title
        performedOn = log.performedOn.date ?? Date()
        vendor = log.vendor ?? ""
        vendorPhone = log.vendorPhone ?? ""
        currency = log.currency ?? "USD"
        parts = log.parts ?? ""
        notes = log.notes ?? ""
        warrantyWork = log.warrantyWork
        if let cost = log.costCents {
            costText = String(format: "%.2f", Double(cost) / 100)
        }
    }

    /// Cents, parsed locale-independently. `Double` because the field is one:
    /// a user typing "45.5" means forty-five fifty, and the server's column is
    /// an integer of cents for a reason -- a sum of prices in binary floating
    /// point is eventually wrong by a penny.
    private var costCents: Int? {
        let cleaned = costText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let dollars = Double(cleaned), dollars >= 0 else { return nil }
        return Int((dollars * 100).rounded())
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                if let existing {
                    try await patch(existing)
                } else {
                    _ = try await HearthAPI.createLog(assetId: asset.id, HearthAPI.LogCreate(
                        title: trimmedTitle,
                        performedOn: Self.dayFormatter.string(from: performedOn),
                        kind: kind,
                        vendor: vendor.nilIfEmpty,
                        vendorPhone: vendorPhone.nilIfEmpty,
                        costCents: costCents,
                        currency: currency,
                        parts: parts.nilIfEmpty,
                        notes: notes.nilIfEmpty,
                        warrantyWork: warrantyWork
                    ))
                }
                await onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Only what changed, and a field emptied on purpose goes as an explicit
    /// null rather than being dropped.
    ///
    /// The `nothing_to_update` rejection is why this is a diff rather than a
    /// full form, and `PatchField.clear` is why an emptied vendor or cost is not
    /// silently ignored: the encoder omits nil, so a bare optional would send
    /// nothing and the old value would survive a save that looked like it worked.
    private func patch(_ log: MaintenanceLog) async throws {
        var body = HearthAPI.LogPatch()

        func assign(
            _ key: WritableKeyPath<HearthAPI.LogPatch, HearthAPI.PatchField<String>?>,
            _ new: String?,
            _ old: String?
        ) {
            if (new ?? "") != (old ?? "") {
                body[keyPath: key] = new.map { .value($0) } ?? .clear
            }
        }

        if kind != log.kind { body.kind = kind }
        assign(\.title, title.nilIfEmpty, Optional(log.title))

        let newDate = Self.dayFormatter.string(from: performedOn)
        if newDate != log.performedOn.raw { body.performedOn = .value(newDate) }

        assign(\.vendor, vendor.nilIfEmpty, log.vendor)
        assign(\.vendorPhone, vendorPhone.nilIfEmpty, log.vendorPhone)
        assign(\.parts, parts.nilIfEmpty, log.parts)
        assign(\.notes, notes.nilIfEmpty, log.notes)

        if costCents != log.costCents {
            body.costCents = costCents.map { .value($0) } ?? .clear
        }
        // Currency is only worth sending if an amount is moving with it, or if
        // the user is correcting the currency of a record that already has a
        // cost -- changing the currency of an empty record changes no total.
        if currency != (log.currency ?? "USD"), costCents != nil || log.costCents != nil {
            body.currency = .value(currency)
        }
        if warrantyWork != log.warrantyWork { body.warrantyWork = warrantyWork }

        // Nothing differs. The server would answer 400, and the honest thing is
        // to close rather than to report an error for an edit the user did not
        // make.
        guard !body.isEmptyPatch else {
            dismiss()
            return
        }
        _ = try await HearthAPI.updateLog(log.id, body)
    }

    private func remove() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await HearthAPI.deleteLog(existing?.id ?? "")
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension HearthAPI.LogPatch {
    /// Whether any field is actually set. Encoded rather than tracked by hand so
    /// a field added above cannot be forgotten here.
    var isEmptyPatch: Bool {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Unencodable means something is wrong with the model, not that the
            // patch is empty -- sending it lets the server say so.
            return false
        }
        return object.isEmpty
    }
}
