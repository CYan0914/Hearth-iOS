import Foundation
import UIKit
import Vision

/// Reads text off a photograph on the device.
///
/// On-device rather than a server call, and not only for latency: a photo of a
/// nameplate is a photo of the inside of someone's home, and the fewer of those
/// that leave the phone the better. Only the recognised text is sent to
/// `/scan/classify`, and only if the user proceeds.
///
/// The text is assembled in reading order rather than sorted by confidence,
/// because `classify.py` on the server looks for label/value pairs that sit next
/// to each other ("MODEL NO." followed by the value). Reordering by confidence
/// would separate them.
enum NameplateOCR {

    struct Result {
        /// Lines in reading order, joined by newlines. This is what goes to the
        /// server.
        let text: String
        /// Per-line confidence, kept only to decide whether to warn the user
        /// that the photo was hard to read.
        let averageConfidence: Float
        let lineCount: Int
    }

    enum OCRError: LocalizedError {
        case noTextFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noTextFound:
                return "No text was found in that photo. Get closer to the label, fill the frame, and make sure the light is on it."
            case .failed(let detail):
                return "The photo could not be read (\(detail)). Try taking another one."
            }
        }
    }

    /// Recognises text in `image`. Runs off the main thread; `VNImageRequestHandler`
    /// blocks for as long as the recognition takes, which on a 12 MP photo is a
    /// noticeable fraction of a second.
    static func read(_ image: UIImage) async throws -> Result {
        guard let cgImage = image.cgImage else {
            throw OCRError.failed("unsupported image format")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision returns observations in no guaranteed order. Sorting by
                // position is what turns a jumble of fragments into something
                // with the label sitting next to its value.
                let ordered = observations.sorted { a, b in
                    let ay = a.boundingBox.midY
                    let by = b.boundingBox.midY
                    // Same line (within 1.5% of image height): order left to right.
                    if abs(ay - by) < 0.015 { return a.boundingBox.minX < b.boundingBox.minX }
                    return ay > by
                }

                let lines = ordered.compactMap { $0.topCandidates(1).first }
                guard !lines.isEmpty else {
                    continuation.resume(throwing: OCRError.noTextFound)
                    return
                }

                let text = lines.map(\.string).joined(separator: "\n")
                let average = lines.map(\.confidence).reduce(0, +) / Float(lines.count)
                continuation.resume(returning: Result(
                    text: text,
                    averageConfidence: average,
                    lineCount: lines.count
                ))
            }

            // `.accurate` rather than `.fast`: this runs once per scan, and the
            // server's classifier is sensitive to characters the fast path
            // mangles ("O" for "0", "S" for "5" in model numbers).
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgImageOrientation)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.failed(error.localizedDescription))
            }
        }
    }
}

private extension UIImage {
    /// Vision wants a CGImagePropertyOrientation, not a UIImage.Orientation.
    /// Getting this wrong rotates the text and everything reads as garbage.
    var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
