import AuthenticationServices
import Combine
import CryptoKit
import Foundation

/// Turns an Apple authorization into a Hearth session.
///
/// Drives `SignInWithAppleButton` rather than presenting its own
/// `ASAuthorizationController`. The button is required to render Apple's logo,
/// wording and corner radius, and it already owns the presentation -- so doing
/// the work in the button's own two callbacks keeps one state machine instead of
/// two, and avoids tap-through overlays that look right and behave wrong.
///
/// The nonce dance is the part that is easy to get wrong and impossible to debug
/// from the error: Apple signs the SHA-256 of the nonce into the identity token,
/// and the server verifies against the raw value we send it. So the hashed form
/// goes to Apple (`prepare`) and the raw form goes to hearth-api (`exchange`).
/// Swapping them produces an `invalid_nonce` that reads like a server bug.
final class AppleSignInCoordinator: ObservableObject {
    private var rawNonce: String?

    /// Wire this to the button's `onRequest`. Called before Apple shows its
    /// sheet, which is the only moment the nonce can be set.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        rawNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Wire this to the button's `onCompletion`. Returns the Hearth session, or
    /// throws `SignInError.cancelled` if the user dismissed the sheet.
    func exchange(_ result: Result<ASAuthorization, Error>) async throws -> SessionResponse {
        let authorization: ASAuthorization
        switch result {
        case .success(let value):
            authorization = value
        case .failure(let error):
            throw Self.map(error)
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw SignInError.message("Apple returned an unexpected credential.")
        }
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let codeData = credential.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8)
        else {
            throw SignInError.message("Apple did not return a usable credential.")
        }

        let nonce = rawNonce ?? ""
        defer { rawNonce = nil }

        // Apple sends the name only on the very first authorization for this app
        // and never again. Formatted here rather than on the server because the
        // server has no locale to format it with; dropping it loses it for good.
        let fullName: String? = credential.fullName.flatMap { components in
            let name = PersonNameComponentsFormatter().string(from: components)
            return name.isEmpty ? nil : name
        }

        return try await HearthAPI.signInWithApple(.init(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            nonce: nonce,
            fullName: fullName,
            timezone: TimeZone.current.identifier
        ))
    }

    /// 32 bytes from the system CSPRNG, hex-encoded. `SecRandomCopyBytes` is what
    /// `SystemRandomNumberGenerator` wraps, so this is the entropy Apple expects
    /// without pulling in a dependency.
    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Cannot happen on a device with a working keychain, and there is no
            // safe fallback: a predictable nonce defeats replay protection.
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `ASAuthorizationError.canceled` is the user changing their mind. It gets
    /// its own case so callers can swallow it instead of showing a banner for
    /// something the user chose.
    static func map(_ error: Error) -> Error {
        guard let authError = error as? ASAuthorizationError else { return error }
        switch authError.code {
        case .canceled:
            return SignInError.cancelled
        case .failed:
            return SignInError.message("Apple could not complete the sign-in. Try again.")
        case .invalidResponse:
            return SignInError.message("Apple returned an invalid response. Try again.")
        case .notHandled:
            return SignInError.message("Apple could not handle the request. Try again.")
        case .unknown:
            return SignInError.message("Sign in with Apple failed. Check that you are signed in to iCloud in Settings.")
        @unknown default:
            return SignInError.message("Sign in with Apple failed.")
        }
    }
}

enum SignInError: LocalizedError, Equatable {
    /// The user dismissed the Apple sheet. Callers swallow it; it exists so a
    /// cancellation is not reported to the user as a failure.
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .message(let text): return text
        }
    }
}
