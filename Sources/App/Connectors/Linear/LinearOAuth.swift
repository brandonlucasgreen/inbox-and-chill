import AppKit
import CryptoKit
import Foundation
import Network

/// Linear OAuth 2.0 with PKCE — the one provider where OAuth is viable
/// (PLAN §6.9: GitHub's notifications endpoint rejects OAuth tokens outright;
/// Slack's install page *is* its OAuth flow). Public-client flow, no client
/// secret: the user registers their own OAuth app in Linear (same
/// bring-your-own-app model as Slack) and pastes only the client ID.
///
/// Flow: loopback listener on a fixed port → browser to
/// `linear.app/oauth/authorize` (S256 code challenge + state) → callback
/// delivers the code → exchange at `api.linear.app/oauth/token` → tokens go
/// to the Keychain (`<sourceID>.oauthAccessToken` / `.oauthRefreshToken` /
/// `.oauthExpiresAt`). Access tokens live ~24h; `refresh(...)` renews them.
///
/// The port is fixed (not ephemeral) so the redirect URI the user registers
/// in Linear — `http://localhost:52180/callback` — always matches exactly.
enum LinearOAuth {
    struct Tokens: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    static let callbackPort: UInt16 = 52180
    static var redirectURI: String { "http://localhost:\(callbackPort)/callback" }

    private static let authorizeURL = "https://linear.app/oauth/authorize"
    private static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
    /// Notifications are read AND written through (archive, snooze).
    private static let scope = "read,write"

    enum OAuthError: LocalizedError, CustomStringConvertible {
        case portInUse
        case timedOut
        case stateMismatch
        case denied(String)
        case exchangeFailed(String)
        case badCallback

        var errorDescription: String? {
            switch self {
            case .portInUse:
                return "Port \(callbackPort) is already in use — quit whatever is listening there and try again."
            case .timedOut:
                return "Sign-in timed out after 5 minutes. Try again."
            case .stateMismatch:
                return "The callback didn't match this sign-in attempt (state mismatch); nothing was saved. Try again."
            case .denied(let reason):
                return "Linear denied the authorization: \(reason)"
            case .exchangeFailed(let detail):
                return "Couldn't exchange the code for tokens: \(detail)"
            case .badCallback:
                return "The callback request was malformed; nothing was saved. Try again."
            }
        }
        var description: String { errorDescription ?? "Linear OAuth error" }
    }

    // MARK: - Sign in

    /// Runs the whole interactive flow. Call from the UI; the returned tokens
    /// are the caller's to persist (Keychain).
    static func signIn(clientID: String) async throws -> Tokens {
        let verifier = randomURLSafe(bytes: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(bytes: 24)

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "actor", value: "user"),
        ]

        let server = CallbackServer()
        try await server.start(port: callbackPort)
        defer { Task { await server.stop() } }

        NSWorkspace.shared.open(components.url!)

        let callback = try await server.waitForCallback(timeout: 300)
        if let error = callback["error"] {
            throw OAuthError.denied(callback["error_description"] ?? error)
        }
        guard callback["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = callback["code"], !code.isEmpty else {
            throw OAuthError.badCallback
        }

        return try await exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    /// Renews an expired access token. No browser involved.
    static func refresh(clientID: String, refreshToken: String) async throws -> Tokens {
        try await exchange(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    // MARK: - Keychain persistence

    static func store(_ tokens: Tokens, sourceID: String) {
        Keychain.set(tokens.accessToken, for: "\(sourceID).oauthAccessToken")
        if let refresh = tokens.refreshToken {
            Keychain.set(refresh, for: "\(sourceID).oauthRefreshToken")
        }
        if let expiresAt = tokens.expiresAt {
            Keychain.set(
                String(expiresAt.timeIntervalSince1970),
                for: "\(sourceID).oauthExpiresAt")
        }
    }

    static func clear(sourceID: String) {
        Keychain.delete("\(sourceID).oauthAccessToken")
        Keychain.delete("\(sourceID).oauthRefreshToken")
        Keychain.delete("\(sourceID).oauthExpiresAt")
    }

    static func isConnected(sourceID: String) -> Bool {
        Keychain.get("\(sourceID).oauthAccessToken")?.isEmpty == false
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    private static func exchange(form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthError.exchangeFailed(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.exchangeFailed("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            // OAuth error bodies ({"error": "invalid_grant", ...}) carry no
            // secrets; surfacing a snippet makes misconfig debuggable.
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw OAuthError.exchangeFailed("HTTP \(http.statusCode). \(body)")
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OAuthError.exchangeFailed("unrecognized token response shape")
        }
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: decoded.expires_in.map { Date.now.addingTimeInterval($0) })
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }

    // MARK: - PKCE primitives

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed unexpectedly")
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot loopback HTTP server for the OAuth redirect. Localhost-only,
/// answers exactly one `GET /callback?...`, replies with a tiny "return to
/// the app" page, and shuts down. No auth on purpose — the callback carries
/// an authorization code that is useless without the in-memory PKCE
/// verifier, and `state` binds it to this attempt.
private actor CallbackServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<[String: String], Error>?

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LinearOAuth.OAuthError.portInUse
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.fail(LinearOAuth.OAuthError.portInUse) }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        // Task {} inherits this actor's isolation, so fail() is a plain
        // same-actor call here.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            fail(LinearOAuth.OAuthError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, _, _ in
            guard let self, let data else { return }
            Task { await self.handle(data: data, connection: connection) }
        }
    }

    private func handle(data: Data, connection: NWConnection) {
        // We only care about the request line: "GET /callback?a=b HTTP/1.1".
        guard let head = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\r\n").first,
            head.hasPrefix("GET ")
        else {
            respond(on: connection, body: "Bad request.")
            return
        }
        let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: target),
            components.path == "/callback"
        else {
            respond(on: connection, body: "Not found.")
            return
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }
        respond(
            on: connection,
            body: "Signed in — you can close this tab and return to Inbox & Chill.")
        continuation?.resume(returning: params)
        continuation = nil
    }

    private func respond(on connection: NWConnection, body: String) {
        let html =
            "<!doctype html><meta charset=\"utf-8\"><title>Inbox &amp; Chill</title>"
            + "<body style=\"font: 15px -apple-system, sans-serif; padding: 48px; "
            + "text-align: center\">\(body)</body>"
        let response =
            "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + html
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
