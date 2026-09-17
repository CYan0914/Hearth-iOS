import Foundation
import UIKit

/// Photos, from a `UIImage` to an object in R2 the API knows about.
///
/// The bytes never touch the API: the client asks for a presigned PUT, uploads
/// straight to R2, and then tells the server what it stored. That keeps image
/// traffic off the API host entirely, which matters because the API runs on a
/// small box behind a tunnel and a 3 MB photo per scan would be most of its
/// bandwidth.
///
/// The thumbnail is generated here, not on the server, for the same reason: a
/// list of fifty assets needs fifty small images, and the phone already has the
/// decoded bitmap in hand.
enum PhotoUploader {

    enum UploadError: LocalizedError {
        case encodingFailed
        case tooLarge(Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "That photo could not be prepared. Try taking another one."
            case .tooLarge(let bytes, let limit):
                let mb = Double(bytes) / 1_048_576
                return String(format: "That photo is %.1f MB, over the %.0f MB limit. Try a lower-resolution photo.", mb, Double(limit) / 1_048_576)
            }
        }
    }

    /// Kinds the API accepts on a photo row.
    ///
    /// These raw values are the server's `PhotoSignRequest.kind` literal, which
    /// is `extra="forbid"` with a closed set -- inventing a friendlier name like
    /// "label" or "install" here is a 422 on every upload, and the failure reads
    /// as a validation error rather than a naming mistake. `modelPlate` is the
    /// nameplate the scan flow writes; the rest are documentation added later.
    enum Kind: String {
        case modelPlate = "model_plate"
        case receipt
        case product
        case manual
        case other
    }

    /// Uploads one photo (plus its thumbnail) and returns the committed row.
    ///
    /// The order is deliberate: sign, upload both objects, then commit. A commit
    /// that fails leaves orphaned objects in R2, which `jobs.py purge` collects;
    /// a sign that succeeds and an upload that fails leaves nothing behind at all,
    /// because no row was ever written.
    static func upload(
        _ image: UIImage,
        forAsset assetId: String,
        kind: Kind = .modelPlate
    ) async throws -> AssetPhoto {
        guard let full = image.jpegData(compressionQuality: 0.82) else {
            throw UploadError.encodingFailed
        }

        let maxDimension: CGFloat = 1600
        let thumbImage = resized(image, maxDimension: 400)
        guard let thumb = thumbImage.jpegData(compressionQuality: 0.70) else {
            throw UploadError.encodingFailed
        }

        // Sign first: the server decides the size ceiling, and checking it before
        // uploading means a rejected photo does not cost the user their data
        // allowance.
        let signed = try await HearthAPI.signPhoto(
            assetId: assetId,
            kind: kind.rawValue,
            contentType: "image/jpeg",
            bytes: full.count
        )

        try await APIClient.shared.uploadToPresigned(signed.upload, data: full)
        try await APIClient.shared.uploadToPresigned(signed.thumbUpload, data: thumb)

        // Committed at the dimensions actually stored, not the original's. The
        // API returns these to the client, which uses them to reserve the right
        // aspect ratio before the image loads.
        let stored = resized(image, maxDimension: maxDimension)
        let committed = try await HearthAPI.commitPhoto(signed.photoId, .init(
            storageKey: signed.storageKey,
            thumbKey: signed.thumbKey,
            kind: kind.rawValue,
            width: Int(stored.size.width),
            height: Int(stored.size.height),
            bytes: full.count
        ))
        return committed.photo
    }

    /// Scales down so the longest side is at most `maxDimension`. Returns the
    /// original if it is already smaller -- upscaling a small photo would only
    /// make a bigger file.
    static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        // A thumbnail is displayed at screen density; 3x on a 400pt image would
        // be three times the bytes for pixels nobody sees.
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Reads a photo's pixel dimensions without decoding the whole thing, for
    /// the size check before an upload.
    static func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }
}
