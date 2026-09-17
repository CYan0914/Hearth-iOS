import Foundation

/// Everything that can go wrong talking to hearth-api, in the terms the UI
/// actually needs to react to.
///
/// The server's handled failures come back as
/// `{"detail": {"error": "asset_limit_reached", ...}}` while framework failures
/// (422 body validation, 404 unknown route) come back as `{"detail": "..."}`, so
/// the code is optional and a bare status has to be a fallback rather than an
/// error in itself.
enum APIError: LocalizedError, Equatable {
    case unauthorized
    case notFound
    case conflict(String)
    case limitReached(code: String, message: String?, limit: Int?)
    case rateLimited(retryAfter: Int?)
    case server(status: Int, code: String?)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your session expired. Sign in again to continue."
        case .notFound:
            return "That item no longer exists. Pull to refresh."
        case .conflict(let code):
            return code == "duplicate" ? "Already saved." : "That conflicts with something already saved."
        case .limitReached(_, let message, let limit):
            if let message { return message }
            if let limit { return "You have reached the limit of \(limit) on the free plan." }
            return "You have reached a limit on the free plan."
        case .rateLimited:
            return "Too many requests just now. Try again in a moment."
        case .server(let status, let code):
            // The code is more useful than the number for the ones the server
            // names, but a 5xx with no code is common enough (proxy errors) that
            // the status still has to be shown.
            return code.map { "Server error: \($0)" } ?? "Server error (\(status)). Try again."
        case .transport(let message):
            return message
        case .decoding(let detail):
            // Wording matters: this is a bug in the app or a contract change,
            // not something the user did, and saying so prevents a pointless retry.
            return "Unexpected response from the server (\(detail)). Please report this."
        }
    }

    /// True when trying the exact same request again could plausibly work.
    /// Drives whether an error banner offers a Retry button, so it must be
    /// false for the errors that are deterministic.
    var isRetryable: Bool {
        switch self {
        case .transport, .server, .rateLimited: return true
        case .unauthorized, .notFound, .conflict, .limitReached, .decoding: return false
        }
    }

    /// True when the only fix is signing in again. The session store watches for
    /// this to clear a dead token rather than letting every screen fail in turn.
    var requiresSignOut: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

/// A thin wrapper over URLSession: encode, send, decode, and turn every failure
/// into an `APIError`.
///
/// Deliberately has no caching, no retry policy, and no reachability polling.
/// The views own retry (a button the user presses) because a silent retry of a
/// POST /assets is how you get a duplicate asset the user did not ask for. The
/// one exception is `client_ref` idempotency on asset creation, which the server
/// enforces rather than the client retrying blindly.
actor APIClient {
    static let shared = APIClient()

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Supplied by the session store so this type does not reach into the
    /// Keychain on every call. A closure rather than a stored token because the
    /// token changes on sign-in and sign-out without the client being rebuilt.
    private var tokenProvider: (@Sendable () -> String?)?

    /// Called when the server rejects a token. The store clears the session and
    /// the root view falls back to sign-in.
    private var onUnauthorized: (@Sendable () async -> Void)?

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HearthAPIBase") as? String ?? ""
        // A literal "$(HEARTH_API_BASE)" means xcodebuild did not substitute the
        // build setting. Failing here with the real cause beats a confusing
        // "unsupported URL" on the first request.
        if configured.isEmpty || configured.hasPrefix("$(") {
            fatalError("""
                HearthAPIBase is not configured. Set the HEARTH_API_BASE build \
                setting in project.yml (or pass it on the xcodebuild command line).
                Got: \(configured.isEmpty ? "(empty)" : configured)
                """)
        }
        guard let url = URL(string: configured) else {
            fatalError("HearthAPIBase is not a valid URL: \(configured)")
        }
        self.baseURL = url

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // Long enough for a classify call against a cold OCR path, short enough
        // that a stalled request does not leave a spinner up on a moving train.
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    func configure(
        tokenProvider: @escaping @Sendable () -> String?,
        onUnauthorized: @escaping @Sendable () async -> Void
    ) {
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
    }

    /// The one place the base URL is read, so a staging override in a test or a
    /// preview does not need a second code path.
    var apiHost: String { baseURL.absoluteString }

    // MARK: - Verbs

    // Each verb has a no-body and a with-body form rather than one signature
    // with a defaulted body. Swift does not infer a generic parameter from a
    // default argument, so a single `delete<B: Encodable>` with
    // `body: B? = nil` fails to compile at every call site that omits it.

    func get<R: Decodable>(_ path: String, query: [String: String?] = [:], as type: R.Type = R.self) async throws -> R {
        try await send(method: "GET", path: path, query: query, body: nil, as: R.self)
    }

    func post<R: Decodable>(_ path: String, as type: R.Type = R.self) async throws -> R {
        try await send(method: "POST", path: path, query: [:], body: nil, as: R.self)
    }

    func post<B: Encodable, R: Decodable>(_ path: String, body: B, as type: R.Type = R.self) async throws -> R {
        try await send(method: "POST", path: path, query: [:], body: encode(body), as: R.self)
    }

    func patch<B: Encodable, R: Decodable>(_ path: String, body: B, as type: R.Type = R.self) async throws -> R {
        try await send(method: "PATCH", path: path, query: [:], body: encode(body), as: R.self)
    }

    func delete<R: Decodable>(_ path: String, query: [String: String?] = [:], as type: R.Type = R.self) async throws -> R {
        try await send(method: "DELETE", path: path, query: query, body: nil, as: R.self)
    }

    /// DELETE with a body. Only `/account` needs this: it carries a typed
    /// confirmation so a mis-routed request cannot trigger an irreversible
    /// delete.
    func delete<B: Encodable, R: Decodable>(_ path: String, body: B, as type: R.Type = R.self) async throws -> R {
        try await send(method: "DELETE", path: path, query: [:], body: encode(body), as: R.self)
    }

    /// Encoding happens in the verbs, not in `send`, so that `send` takes plain
    /// `Data?` and the no-body verbs have nothing to infer.
    private func encode<B: Encodable>(_ body: B) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            // A request model that will not encode is a programming error, so it
            // is named rather than reported as a network problem.
            throw APIError.decoding("could not encode \(B.self)")
        }
    }

    /// Uploads bytes straight to R2 with the headers the presign produced.
    ///
    /// Not part of `send` because it is the one request that leaves the API host:
    /// it talks to R2, carries no bearer token, and its errors are S3 XML rather
    /// than the API's envelope. A 403 here means the presign expired, which the
    /// caller retries by asking for a fresh one, not by re-uploading the same URL.
    func uploadToPresigned(_ upload: PresignedUpload, data: Data) async throws {
        guard let url = URL(string: upload.url) else {
            throw APIError.transport("The upload URL was malformed.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method
        for (key, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = data
        request.timeoutInterval = 60

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("The upload did not return a response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                // 403 is the expired-or-mismatched-signature case. Surfaced as a
                // transport error so the caller's retry path (re-sign, re-upload)
                // is the same as for a dropped connection.
                if http.statusCode == 403 {
                    throw APIError.transport("The upload link expired. Retrying with a fresh one.")
                }
                throw APIError.server(status: http.statusCode, code: "upload_failed")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport("The photo could not be uploaded. Check your connection.")
        }
    }

    // MARK: - The single request path

    private func send<R: Decodable>(
        method: String,
        path: String,
        query: [String: String?],
        body: Data?,
        as type: R.Type
    ) async throws -> R {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.transport("Could not build a request for \(path).")
        }
        let items = query.compactMap { key, value -> URLQueryItem? in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }

        guard let url = components.url else {
            throw APIError.transport("Could not build a request for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = tokenProvider?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(Self.message(for: error))
        } catch {
            throw APIError.transport("Something went wrong reaching the server.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server did not return a response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let apiError = Self.mapError(status: http.statusCode, data: data, headers: http)
            if apiError.requiresSignOut, let onUnauthorized {
                await onUnauthorized()
            }
            throw apiError
        }

        // A 204 or a bodiless 200 happens on the deletes. Decoding from `{}`
        // rather than short-circuiting means `Ack` -- whose every field is
        // optional -- comes back as all-nil, and a type that genuinely needs
        // fields still fails loudly instead of returning a hollow value.
        let payload = data.isEmpty ? Data("{}".utf8) : data

        do {
            return try decoder.decode(R.self, from: payload)
        } catch let error as DecodingError {
            throw APIError.decoding(Self.describe(error))
        } catch {
            throw APIError.decoding("unreadable response")
        }
    }

    private static func mapError(status: Int, data: Data, headers: HTTPURLResponse) -> APIError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        let code = body?.detail?.code
        let message: String? = {
            if case .code(_, let m, _) = body?.detail { return m }
            return nil
        }()
        let limit: Int? = {
            if case .code(_, _, let l) = body?.detail { return l }
            return nil
        }()

        switch status {
        case 401:
            return .unauthorized
        case 403:
            // The API returns 403 for a valid token that may not touch the
            // resource (someone else's asset id). Treating it as 401 would sign
            // the user out over a stale link, so it is a plain server error.
            return .server(status: status, code: code ?? "forbidden")
        case 404:
            return .notFound
        case 409:
            return .conflict(code ?? "duplicate")
        case 402, 413:
            return .limitReached(code: code ?? "limit_reached", message: message, limit: limit)
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(status: status, code: code)
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "You are offline. Changes will not be saved until you reconnect."
        case .timedOut:
            return "The server took too long to respond. Try again."
        case .networkConnectionLost:
            return "The connection dropped. Try again."
        case .cannotFindHost, .cannotConnectToHost:
            return "Cannot reach Hearth right now. Try again in a moment."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "The secure connection to Hearth failed."
        default:
            return "Something went wrong reaching the server."
        }
    }

    /// DecodingError's own description names the coding path, which is the part
    /// that identifies the field that broke. `localizedDescription` does not.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "\(path(context.codingPath)) is not \(type)"
        case .valueNotFound(let type, let context):
            return "null \(path(context.codingPath)) where \(type) expected"
        case .dataCorrupted(let context):
            return "malformed at \(path(context.codingPath))"
        @unknown default:
            return "unreadable response"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let joined = codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "(root)" : joined
    }
}
