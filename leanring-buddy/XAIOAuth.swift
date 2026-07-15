//
//  XAIOAuth.swift
//  xAI OAuth (PKCE) for Grok — SuperGrok / X Premium subscription access
//
//  Mirrors the public shared-client flow used by litellm / OpenClaw:
//  issuer https://auth.x.ai, client_id from xAI's shared OAuth client.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
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

// MARK: - Local loopback callback server (IPv4 127.0.0.1 POSIX)

/// HTTP/1.1 loopback server for OAuth redirects.
/// Binds explicitly to IPv4 `127.0.0.1` (browsers redirect there; NWListener
/// often only shows up as IPv6 `*:port`, which causes empty/failed callbacks).
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
    private var serverFD: Int32 = -1
    private var boundPort: UInt16 = 0
    private var acceptSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<CallbackResult, Error>?
    private let queue = DispatchQueue(label: "so.clicky.xai-oauth.callback")
    private var didFinish = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(preferredPort: UInt16, path: String, expectedState: String) throws {
        self.path = path
        self.expectedState = expectedState
        self.preferredPort = preferredPort
    }

    deinit {
        closeServer()
    }

    /// Starts listening on 127.0.0.1 and returns the redirect URI.
    func start() async throws -> String {
        let portsToTry: [UInt16] = [preferredPort, 0]
        var lastError: Error = XAIOAuthError.serverStartFailed

        for port in portsToTry {
            do {
                let fd = try Self.bindListeningSocket(port: port)
                serverFD = fd
                boundPort = try Self.portOfSocket(fd)
                redirectURI = "http://127.0.0.1:\(boundPort)\(path)"
                startAcceptLoop()
                print("🔐 xAI OAuth callback listening on \(redirectURI)")
                return redirectURI
            } catch {
                lastError = error
                closeServer()
            }
        }

        throw lastError
    }

    func waitForCallback(timeout: TimeInterval) async throws -> CallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(XAIOAuthError.callbackTimeout))
            }
            self.timeoutWorkItem = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    // MARK: - Socket setup

    private static func bindListeningSocket(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw XAIOAuthError.serverStartFailed
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        // Avoid SIGPIPE on send
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Non-blocking accept loop via GCD
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw XAIOAuthError.serverStartFailed
        }

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw XAIOAuthError.serverStartFailed
        }

        return fd
    }

    private static func portOfSocket(_ fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard result == 0 else {
            throw XAIOAuthError.serverStartFailed
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func startAcceptLoop() {
        let fd = serverFD
        guard fd >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        source.setCancelHandler {
            // fd closed in closeServer()
        }
        acceptSource = source
        source.resume()
    }

    private func acceptClients() {
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &len)
                }
            }
            if client < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { return }
                print("⚠️ OAuth accept error: \(err)")
                return
            }
            // Handle each client off the accept path so we can keep listening
            // for probes / favicon until the real OAuth callback arrives.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD: client)
            }
        }
    }

    private func handleClient(clientFD: Int32) {
        defer { close(clientFD) }

        var yes: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Blocking reads with a short timeout for this client only
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while buffer.count < 64 * 1024 {
            let n = read(clientFD, &chunk, chunk.count)
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                print("⚠️ OAuth client read error: \(err)")
                return // ignore probe / failed connections
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            // Header terminator (CRLF or bare LF)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil
                || buffer.range(of: Data("\n\n".utf8)) != nil {
                break
            }
        }

        guard !buffer.isEmpty,
              let requestText = String(data: buffer, encoding: .utf8) else {
            print("⚠️ OAuth ignored empty client connection")
            return
        }

        print("🔐 OAuth callback request (\(buffer.count) bytes):\n\(requestText.prefix(400))")

        let headerSection: String
        if let range = requestText.range(of: "\r\n\r\n") {
            headerSection = String(requestText[..<range.lowerBound])
        } else if let range = requestText.range(of: "\n\n") {
            headerSection = String(requestText[..<range.lowerBound])
        } else {
            headerSection = requestText
        }

        let firstLine = headerSection.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .first
            .map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTML(clientFD: clientFD, status: 400, body: "<h1>Bad request</h1>")
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        // Browsers may request /favicon.ico etc. — ignore, keep waiting.
        guard method == "GET" || method == "HEAD" else {
            sendHTML(clientFD: clientFD, status: 405, body: "<h1>Method not allowed</h1>")
            return
        }

        guard let url = URL(string: target.hasPrefix("http") ? target : "http://127.0.0.1\(target)") else {
            sendHTML(clientFD: clientFD, status: 400, body: "<h1>Bad request</h1>")
            return
        }

        // Accept /callback even if trailing slash differs
        let requestPath = url.path
        guard requestPath == path || requestPath == path + "/" else {
            print("⚠️ OAuth ignored non-callback path: \(requestPath)")
            sendHTML(clientFD: clientFD, status: 404, body: "<h1>Not found</h1>")
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

        // Real OAuth redirect must include code or error (+ state).
        guard result.code != nil || result.error != nil else {
            print("⚠️ OAuth callback path hit without code/error — still waiting")
            sendHTML(clientFD: clientFD, status: 200, body: "<h1>Waiting for OAuth…</h1>")
            return
        }

        // Require matching state when a successful code is returned.
        if result.error == nil {
            guard let state = result.state, state == expectedState else {
                sendHTML(clientFD: clientFD, status: 400, body: "<h1>xAI authorization state mismatch.</h1>")
                finish(.failure(XAIOAuthError.authorizationFailed("state mismatch")))
                return
            }
        }

        if result.error != nil {
            sendHTML(
                clientFD: clientFD,
                status: 200,
                body: "<h1>xAI authorization failed.</h1><p>You can close this tab and return to Clicky.</p>"
            )
        } else {
            sendHTML(
                clientFD: clientFD,
                status: 200,
                body: "<h1>xAI authorization received.</h1><p>You can close this tab and return to Clicky.</p>"
            )
        }

        finish(.success(result))
    }

    private func sendHTML(clientFD: Int32, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Bad Request"
        }
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Clicky xAI</title></head><body>\(body)</body></html>"
        let response =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            html
        let data = Data(response.utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(clientFD, base.advanced(by: offset), data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func finish(_ result: Result<CallbackResult, Error>) {
        queue.async {
            guard !self.didFinish else { return }
            self.didFinish = true
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.closeServer()
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

    private func closeServer() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
    }
}
