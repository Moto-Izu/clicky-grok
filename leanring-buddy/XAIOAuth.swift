//
//  XAIOAuth.swift
//  xAI OAuth (PKCE) for Grok — SuperGrok / X Premium subscription access
//
//  Mirrors the public shared-client flow used by litellm / OpenClaw:
//  issuer https://auth.x.ai, client_id from xAI's shared OAuth client.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum XAIOAuthError: LocalizedError {
    case discoveryFailed(String)
    case authorizationFailed(String)
    case loginRequired
    case tokenExchangeFailed(String)
    case invalidTokenResponse
    case callbackTimeout
    case serverStartFailed
    case keychainFailed(String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let detail):
            return "xAI OAuth discovery failed: \(detail)"
        case .authorizationFailed(let detail):
            return "xAI authorization failed: \(detail)"
        case .loginRequired:
            return "Sign in with xAI (Grok) to continue."
        case .tokenExchangeFailed(let detail):
            return "xAI token exchange failed: \(detail)"
        case .invalidTokenResponse:
            return "xAI returned an invalid token response."
        case .callbackTimeout:
            return "Timed out waiting for xAI login. Try again."
        case .serverStartFailed:
            return "Could not start local OAuth callback server."
        case .keychainFailed(let detail):
            return "Keychain error: \(detail)"
        }
    }
}

/// Thread-safe store for tokens obtained via xAI OAuth (PKCE).
@MainActor
final class XAIOAuthAuthenticator: ObservableObject {
    static let shared = XAIOAuthAuthenticator()

    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let issuer = "https://auth.x.ai"
    static let discoveryURL = URL(string: "\(issuer)/.well-known/openid-configuration")!
    static let apiBase = "https://api.x.ai/v1"
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    private static let preferredCallbackPort: UInt16 = 56121
    private static let callbackPath = "/callback"
    private static let expirySkewSeconds: TimeInterval = 120
    private static let callbackTimeoutSeconds: TimeInterval = 180
    private static let keychainService = "so.clicky.xai-oauth"
    private static let keychainAccount = "auth"

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoggingIn = false
    @Published var lastErrorMessage: String?

    private var cachedAuth: AuthRecord?
    private var loginTask: Task<Void, Never>?
    private let session: URLSession

    private struct AuthRecord: Codable {
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var tokenType: String
        var tokenEndpoint: String
        var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case tokenType = "token_type"
            case tokenEndpoint = "token_endpoint"
            case expiresAt = "expires_at"
        }
    }

    private struct Discovery: Codable {
        let authorizationEndpoint: String
        let tokenEndpoint: String

        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.cachedAuth = Self.loadFromKeychain()
        self.isAuthenticated = cachedAuth != nil
    }

    /// Returns a valid access token, refreshing if needed.
    func getAccessToken() async throws -> String {
        if let auth = cachedAuth, !Self.isExpired(auth) {
            return auth.accessToken
        }

        if let auth = cachedAuth, !auth.refreshToken.isEmpty {
            let refreshed = try await refreshTokens(auth)
            return refreshed.accessToken
        }

        throw XAIOAuthError.loginRequired
    }

    /// Opens the browser for PKCE login and stores tokens in the Keychain.
    func login(force: Bool = false) async throws {
        if isLoggingIn { return }
        isLoggingIn = true
        lastErrorMessage = nil
        defer { isLoggingIn = false }

        if !force, let auth = cachedAuth {
            if !Self.isExpired(auth) {
                isAuthenticated = true
                return
            }
            if !auth.refreshToken.isEmpty {
                do {
                    _ = try await refreshTokens(auth)
                    return
                } catch {
                    // Fall through to full login
                }
            }
        }

        let discovery = try await discover()
        let (verifier, challenge) = Self.pkcePair()
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let callbackServer = try LocalOAuthCallbackServer(
            preferredPort: Self.preferredCallbackPort,
            path: Self.callbackPath,
            expectedState: state
        )
        let redirectURI = try await callbackServer.start()

        var components = URLComponents(string: discovery.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]

        guard let authorizeURL = components.url else {
            throw XAIOAuthError.authorizationFailed("invalid authorize URL")
        }

        NSWorkspace.shared.open(authorizeURL)

        let callbackResult: LocalOAuthCallbackServer.CallbackResult
        do {
            callbackResult = try await callbackServer.waitForCallback(
                timeout: Self.callbackTimeoutSeconds
            )
        } catch {
            throw error
        }

        if let error = callbackResult.error {
            let description = callbackResult.errorDescription ?? error
            throw XAIOAuthError.authorizationFailed(description)
        }

        guard let code = callbackResult.code, !code.isEmpty else {
            throw XAIOAuthError.authorizationFailed("no authorization code returned")
        }

        let tokenPayload = try await exchangeToken(
            endpoint: discovery.tokenEndpoint,
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": Self.clientID,
                "code_verifier": verifier,
            ]
        )

        let auth = try Self.buildAuthRecord(from: tokenPayload, tokenEndpoint: discovery.tokenEndpoint)
        try Self.saveToKeychain(auth)
        cachedAuth = auth
        isAuthenticated = true
        print("✅ xAI OAuth login succeeded")
    }

    func logout() {
        cachedAuth = nil
        isAuthenticated = false
        Self.deleteFromKeychain()
        lastErrorMessage = nil
    }

    // MARK: - Discovery / token HTTP

    private func discover() async throws -> Discovery {
        var request = URLRequest(url: Self.discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XAIOAuthError.discoveryFailed(body)
        }
        let discovery = try JSONDecoder().decode(Discovery.self, from: data)
        try Self.validateXAIEndpoint(discovery.authorizationEndpoint)
        try Self.validateXAIEndpoint(discovery.tokenEndpoint)
        return discovery
    }

    private func exchangeToken(endpoint: String, body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else {
            throw XAIOAuthError.tokenExchangeFailed("bad token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = body
            .map { key, value in
                let encKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encVal = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encKey)=\(encVal)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw XAIOAuthError.tokenExchangeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(bodyText)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIOAuthError.invalidTokenResponse
        }
        return json
    }

    private func refreshTokens(_ auth: AuthRecord) async throws -> AuthRecord {
        let endpoint = auth.tokenEndpoint.isEmpty
            ? (try await discover()).tokenEndpoint
            : auth.tokenEndpoint
        try Self.validateXAIEndpoint(endpoint)

        let payload = try await exchangeToken(
            endpoint: endpoint,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": auth.refreshToken,
                "client_id": Self.clientID,
            ]
        )

        var refreshed = try Self.buildAuthRecord(
            from: payload,
            tokenEndpoint: endpoint,
            fallbackRefreshToken: auth.refreshToken
        )
        // Preserve previous refresh token if server omits a new one
        if refreshed.refreshToken.isEmpty {
            refreshed.refreshToken = auth.refreshToken
        }
        try Self.saveToKeychain(refreshed)
        cachedAuth = refreshed
        isAuthenticated = true
        return refreshed
    }

    // MARK: - Helpers

    private static func buildAuthRecord(
        from payload: [String: Any],
        tokenEndpoint: String,
        fallbackRefreshToken: String? = nil
    ) throws -> AuthRecord {
        guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty else {
            throw XAIOAuthError.invalidTokenResponse
        }
        let refreshToken = (payload["refresh_token"] as? String) ?? fallbackRefreshToken ?? ""
        guard !refreshToken.isEmpty else {
            throw XAIOAuthError.invalidTokenResponse
        }
        let expiresIn = (payload["expires_in"] as? Int)
            ?? (payload["expires_in"] as? Double).map { Int($0) }
            ?? 3600
        return AuthRecord(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: payload["id_token"] as? String,
            tokenType: (payload["token_type"] as? String) ?? "Bearer",
            tokenEndpoint: tokenEndpoint,
            expiresAt: Date().timeIntervalSince1970 + TimeInterval(expiresIn)
        )
    }

    private static func isExpired(_ auth: AuthRecord) -> Bool {
        Date().timeIntervalSince1970 >= auth.expiresAt - expirySkewSeconds
    }

    private static func validateXAIEndpoint(_ urlString: String) throws {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "x.ai" || host.hasSuffix(".x.ai") else {
            throw XAIOAuthError.discoveryFailed("unexpected endpoint: \(urlString)")
        }
    }

    private static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifierData = Data(bytes)
        let verifier = base64URLEncode(verifierData)
        let challengeDigest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(challengeDigest))
        return (verifier, challenge)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private static func saveToKeychain(_ auth: AuthRecord) throws {
        let data = try JSONEncoder().encode(auth)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XAIOAuthError.keychainFailed("save status \(status)")
        }
    }

    private static func loadFromKeychain() -> AuthRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthRecord.self, from: data)
    }

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Local loopback callback server (NWListener)

/// Minimal HTTP/1.1 server that accepts a single OAuth redirect on 127.0.0.1.
final class LocalOAuthCallbackServer {
    struct CallbackResult {
        let code: String?
        let state: String?
        let error: String?
        let errorDescription: String?
    }

    private(set) var redirectURI: String = ""
    private let path: String
    private let expectedState: String
    private let preferredPort: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CallbackResult, Error>?
    private let queue = DispatchQueue(label: "so.clicky.xai-oauth.callback")
    private var didFinish = false

    init(preferredPort: UInt16, path: String, expectedState: String) throws {
        self.path = path
        self.expectedState = expectedState
        self.preferredPort = preferredPort
    }

    /// Starts listening and returns the exact redirect URI (with bound port).
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        let portsToTry: [NWEndpoint.Port] = [
            NWEndpoint.Port(rawValue: preferredPort),
            .any,
        ].compactMap { $0 }

        var lastError: Error?
        for port in portsToTry {
            do {
                let listener = try NWListener(using: parameters, on: port)
                self.listener = listener
                break
            } catch {
                lastError = error
            }
        }
        guard let listener else {
            throw lastError ?? XAIOAuthError.serverStartFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener.port {
                        self.redirectURI = "http://127.0.0.1:\(port.rawValue)\(self.path)"
                    }
                    guard !settled else { return }
                    settled = true
                    continuation.resume()
                case .failed(let error):
                    guard !settled else { return }
                    settled = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: self.queue)
        }

        if redirectURI.isEmpty {
            redirectURI = "http://127.0.0.1:\(preferredPort)\(path)"
        }
        return redirectURI
    }

    func waitForCallback(timeout: TimeInterval) async throws -> CallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(XAIOAuthError.callbackTimeout))
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                self.finish(.failure(error))
                return
            }

            var next = buffer
            if let data { next.append(data) }

            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = next.subdata(in: next.startIndex..<range.lowerBound)
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                self.respond(connection: connection, requestHeaders: headerText)
                return
            }

            if isComplete {
                connection.cancel()
                self.finish(.failure(XAIOAuthError.authorizationFailed("empty callback")))
                return
            }

            self.receive(on: connection, buffer: next)
        }
    }

    private func respond(connection: NWConnection, requestHeaders: String) {
        let firstLine = requestHeaders.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        // e.g. GET /callback?code=...&state=... HTTP/1.1
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTML(connection: connection, status: 400, body: "<h1>Bad request</h1>")
            finish(.failure(XAIOAuthError.authorizationFailed("malformed callback request")))
            return
        }

        let target = String(parts[1])
        guard let url = URL(string: "http://127.0.0.1\(target)"),
              url.path == path else {
            sendHTML(connection: connection, status: 404, body: "<h1>Not found</h1>")
            finish(.failure(XAIOAuthError.authorizationFailed("unexpected callback path")))
            return
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        let result = CallbackResult(
            code: value("code"),
            state: value("state"),
            error: value("error"),
            errorDescription: value("error_description")
        )

        if result.state != expectedState {
            sendHTML(connection: connection, status: 400, body: "<h1>xAI authorization state mismatch.</h1>")
            finish(.failure(XAIOAuthError.authorizationFailed("state mismatch")))
            return
        }

        if result.error != nil {
            sendHTML(connection: connection, status: 200, body: "<h1>xAI authorization failed.</h1><p>You can close this tab.</p>")
        } else {
            sendHTML(connection: connection, status: 200, body: "<h1>xAI authorization received.</h1><p>You can close this tab and return to Clicky.</p>")
        }

        finish(.success(result))
    }

    private func sendHTML(connection: NWConnection, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let html = "<!DOCTYPE html><html><body>\(body)</body></html>"
        let response =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            html
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<CallbackResult, Error>) {
        queue.async {
            guard !self.didFinish else { return }
            self.didFinish = true
            self.listener?.cancel()
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
