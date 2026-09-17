import SwiftUI

/// Add or edit an asset by hand.
///
/// One view for both, because the fields are identical and the difference is
/// which verb the Save button sends. A scanner is the fast path; this is the one
/// for a lamp that has no nameplate, and it has to exist or the app has a hole
/// where "anything without a label" goes.
struct AssetFormView: View {
    enum Mode {
        case add
        /// Carries the asset so the form opens on its current values, and so the
        /// diff can be computed against them.
        case edit(Asset)
    }

    let mode: Mode
    let onSaved: () async -> Void

    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = ""
    @State private var brand = ""
    @State private var model = ""
    @State private var serial = ""
    @State private var upc = ""
    @State private var location = ""
    @State private var purchaseDate = Date()
    @State private var hasPurchaseDate = false
    @State private var priceText = ""
    @State private var retailer = ""
    @State private var warrantyDate = Date()
    @State private var hasWarrantyDate = false
    @State private var warrantyProvider = ""
    @State private var notes = ""

    @State private var showCategoryPicker = false
    @State private var isSaving = false
    @State private var error: String?

    /// Generated once for the add flow and reused on every retry, so a save that
    /// times out and is tried again returns the asset created the first time
    /// rather than making a second one.
    @State private var clientRef = UUID().uuidString

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var original: Asset? {
        if case .edit(let asset) = mode { return asset }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        ErrorBanner(message: error)
                    }
                }

                Section {
                    TextField("Kitchen fridge", text: $name)
                        .textInputAutocapitalization(.words)
                    Button {
                        showCategoryPicker = true
                    } label: {
                        HStack {
                            Text("Type")
                            Spacer()
                            Text(category.isEmpty ? "Choose" : session.label(for: category))
                                .foregroundStyle(category.isEmpty ? .secondary : .primary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("What it is")
                } footer: {
                    if category.isEmpty {
                        Text("The type decides which maintenance Hearth schedules, so this one matters.")
                    }
                }

                Section("On the label") {
                    TextField("Brand", text: $brand).autocorrectionDisabled()
                    TextField("Model", text: $model).autocorrectionDisabled()
                    TextField("Serial number", text: $serial).autocorrectionDisabled()
                    TextField("UPC or barcode", text: $upc)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                }

                Section("Where it is") {
                    TextField("Kitchen", text: $location)
                        .textInputAutocapitalization(.words)
                }

                purchase

                Section("Warranty") {
                    Toggle("I know the end date", isOn: $hasWarrantyDate)
                    if hasWarrantyDate {
                        DatePicker("Ends", selection: $warrantyDate, displayedComponents: .date)
                        TextField("Provided by", text: $warrantyProvider)
                            .textInputAutocapitalization(.words)
                    }
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if isEditing, let asset = original, asset.category != category, !category.isEmpty {
                    Section {
                        Label(
                            "Changing the type re-checks the schedule. Reminders that no longer apply are retired and new ones are added.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit" : "Add an asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || !canSave)
                }
            }
            .sheet(isPresented: $showCategoryPicker) {
                CategoryPickerView(selected: category) { picked in
                    category = picked
                }
            }
            .onAppear(perform: seed)
        }
    }

    @ViewBuilder
    private var purchase: some View {
        Section("Purchase") {
            Toggle("I know the date", isOn: $hasPurchaseDate)
            if hasPurchaseDate {
                DatePicker("Bought on", selection: $purchaseDate, displayedComponents: .date)
            }
            HStack {
                Text("$")
                TextField("Price", text: $priceText)
                    .keyboardType(.decimalPad)
            }
            TextField("Retailer", text: $retailer)
                .textInputAutocapitalization(.words)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !category.isEmpty
    }

    // MARK: - Data

    private func seed() {
        guard let asset = original else {
            // Adding by hand has no classifier, so the type starts empty and the
            // footer above explains why it has to be filled in.
            return
        }
        name = asset.name
        category = asset.category
        brand = asset.brand ?? ""
        model = asset.model ?? ""
        serial = asset.serial ?? ""
        upc = asset.upc ?? ""
        location = asset.location ?? ""
        retailer = asset.retailer ?? ""
        warrantyProvider = asset.warrantyProvider ?? ""
        notes = asset.notes ?? ""
        if let price = asset.purchasePriceCents {
            priceText = String(format: "%.2f", Double(price) / 100)
        }
        if let purchased = asset.purchaseDate?.date {
            hasPurchaseDate = true
            purchaseDate = purchased
        }
        if let expires = asset.warrantyExpiresOn?.date {
            hasWarrantyDate = true
            warrantyDate = expires
        }
    }

    /// Cents, parsed locale-independently. Sending dollars as a Double would be a
    /// float price on the wire, and `purchase_price_cents` is an integer for a
    /// reason.
    private var priceCents: Int? {
        let cleaned = priceText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let dollars = Double(cleaned), dollars >= 0 else { return nil }
        return Int((dollars * 100).rounded())
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                if isEditing, let asset = original {
                    _ = try await HearthAPI.updateAsset(asset.id, patch(from: asset))
                } else {
                    _ = try await HearthAPI.createAsset(HearthAPI.AssetCreate(
                        name: trimmed(name),
                        category: trimmed(category),
                        brand: trimmed(brand),
                        model: trimmed(model),
                        serial: trimmed(serial),
                        upc: trimmed(upc),
                        location: trimmed(location),
                        purchaseDate: hasPurchaseDate ? Self.dayFormatter.string(from: purchaseDate) : nil,
                        purchasePriceCents: priceCents,
                        retailer: trimmed(retailer),
                        warrantyExpiresOn: hasWarrantyDate ? Self.dayFormatter.string(from: warrantyDate) : nil,
                        warrantyProvider: trimmed(warrantyProvider),
                        notes: trimmed(notes),
                        ocrText: nil,
                        fromScan: false,
                        clientRef: clientRef
                    ))
                }
                await onSaved()
                await session.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Only the fields that actually changed.
    ///
    /// Not an optimisation. The server re-runs template instantiation whenever
    /// `category` or `purchase_date` appear in the PATCH body at all -- it decides
    /// from presence, not from difference -- so sending the full form on every
    /// save would retire and rebuild the schedule every time someone fixed a typo
    /// in the serial number.
    private func patch(from asset: Asset) -> HearthAPI.AssetPatch {
        var patch = HearthAPI.AssetPatch()

        func assign(_ key: WritableKeyPath<HearthAPI.AssetPatch, String?>, _ new: String?, _ old: String?) {
            // Both blank is no change; one blank is a deliberate clear, which the
            // server needs to receive as an explicit empty string rather than as
            // an absent key.
            let normalisedNew = new ?? ""
            let normalisedOld = old ?? ""
            if normalisedNew != normalisedOld {
                patch[keyPath: key] = normalisedNew.isEmpty ? "" : normalisedNew
            }
        }

        assign(\.name, trimmed(name), asset.name)
        if category != asset.category, !category.isEmpty { patch.category = category }
        assign(\.brand, trimmed(brand), asset.brand)
        assign(\.model, trimmed(model), asset.model)
        assign(\.serial, trimmed(serial), asset.serial)
        assign(\.upc, trimmed(upc), asset.upc)
        assign(\.location, trimmed(location), asset.location)
        assign(\.retailer, trimmed(retailer), asset.retailer)
        assign(\.warrantyProvider, trimmed(warrantyProvider), asset.warrantyProvider)
        assign(\.notes, trimmed(notes), asset.notes)

        // These three can be emptied, and an emptied one has to go over the wire
        // as an explicit null -- `PatchField.clear` exists for exactly that.
        let newPurchase = hasPurchaseDate ? Self.dayFormatter.string(from: purchaseDate) : nil
        if newPurchase != asset.purchaseDate?.raw {
            patch.purchaseDate = newPurchase.map { .value($0) } ?? .clear
        }
        if priceCents != asset.purchasePriceCents {
            patch.purchasePriceCents = priceCents.map { .value($0) } ?? .clear
        }
        let newWarranty = hasWarrantyDate ? Self.dayFormatter.string(from: warrantyDate) : nil
        if newWarranty != asset.warrantyExpiresOn?.raw {
            patch.warrantyExpiresOn = newWarranty.map { .value($0) } ?? .clear
        }

        return patch
    }
}
