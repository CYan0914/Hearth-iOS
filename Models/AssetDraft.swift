import Foundation

/// What the confirm screen edits, and the request it turns into.
///
/// A separate type from `HearthAPI.AssetCreate` on purpose. That one is the wire
/// shape and has to match the server's `AssetCreate` field for field; this one
/// is what the form binds to and carries things the wire never sees (the human
/// category label, the OCR text kept aside for a re-classification). Collapsing
/// them would mean a text field writing straight into an `Encodable`, and every
/// server-side field addition would become a UI change.
struct AssetDraft: Equatable {
    var name: String = ""
    var category: String = ""
    /// The human name for `category` ("Refrigerator"), shown where changing the
    /// category is not the point. The server sends this on every scan, so it is
    /// never derived from the slug -- "water_heater" has no mechanical
    /// un-slugging that reads well.
    var categoryLabel: String = ""

    var brand: String = ""
    var model: String = ""
    var serial: String = ""
    var location: String = ""

    var notes: String = ""

    /// Kept out of the form but carried through every re-classification: the
    /// server classifies from the text, so losing it between attempts would mean
    /// a category correction silently lost the brand and model with it.
    var ocrText: String?

    init() {}

    /// Seeds from a scan. Every field comes from the classifier, including the
    /// ones it left empty -- an empty field the user can fill in is better than
    /// a field pre-filled with a guess they have to notice and delete.
    init(from result: ScanResult, ocrText: String?) {
        name = result.suggestedName ?? ""
        category = result.category ?? ""
        categoryLabel = result.suggestedCategoryLabel ?? ""
        brand = result.brand?.value ?? ""
        model = result.model?.value ?? ""
        serial = result.serial?.value ?? ""
        self.ocrText = ocrText
    }

    /// Re-seeds from a new classification without discarding what the user
    /// typed over it.
    ///
    /// `keepingCategory` exists because the server's `hint_category` changes
    /// what it returns: after the user picks "Dishwasher" the classification
    /// comes back with that category, and taking `result.category` here would be
    /// redundant but harmless -- whereas taking `result.suggestedName` would
    /// overwrite a name the user may have already corrected. So identity fields
    /// only fill blanks, and the category is explicit.
    mutating func apply(_ result: ScanResult, keepingCategory category: String) {
        self.category = category
        if let label = result.suggestedCategoryLabel, !label.isEmpty {
            categoryLabel = label
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let suggested = result.suggestedName {
            name = suggested
        }
        if brand.isEmpty, let value = result.brand?.value { brand = value }
        if model.isEmpty, let value = result.model?.value { model = value }
        if serial.isEmpty, let value = result.serial?.value { serial = value }
    }

    /// Deletes get sent as empty strings so the server clears the column, but an
    /// untouched field is `nil` so the server leaves it alone. Sending "" for
    /// every blank would wipe a value the classifier filled in server-side on a
    /// later edit -- the two are genuinely different and `AssetUpdate` treats
    /// them differently.
    private func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var payload: HearthAPI.AssetCreate {
        HearthAPI.AssetCreate(
            name: trimmed(name),
            category: trimmed(category),
            brand: trimmed(brand),
            model: trimmed(model),
            serial: trimmed(serial),
            upc: nil,
            location: trimmed(location),
            purchaseDate: nil,
            purchasePriceCents: nil,
            retailer: nil,
            warrantyExpiresOn: nil,
            warrantyProvider: nil,
            notes: trimmed(notes),
            // Sent even though the classifier already saw it: the server stores
            // it on the asset so a later re-classification (or a support
            // question about why it guessed wrong) has the original text. The
            // plan's log-scrubbing rule covers logs, not the user's own row,
            // and `has_ocr_text` exists precisely so this is a supported state.
            ocrText: ocrText,
            fromScan: true,
            clientRef: nil
        )
    }
}
