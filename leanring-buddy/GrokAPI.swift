//
//  GrokAPI.swift
//  xAI Grok chat/completions client (OpenAI-compatible) with vision + SSE streaming.
//  Auth via xAI OAuth bearer token (not a static API key).
//

import Foundation

/// Grok API helper with streaming for progressive text display.
@MainActor
class GrokAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(
        model: String = "grok-4",
        apiBase: String = XAIOAuthAuthenticator.apiBase
    ) {
        self.apiURL = URL(string: "\(apiBase)/chat/completions")!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStart = !Self.hasStartedTLSWarmup
        if shouldStart { Self.hasStartedTLSWarmup = true }
        Self.tlsWarmupLock.unlock()
        guard shouldStart else { return }

        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let warmupURL = components.url else { return }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    private func buildMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        messages.append([
            "role": "system",
            "content": systemPrompt,
        ])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            let mediaType = detectImageMediaType(for: image.data)
            contentBlocks.append([
                "type": "text",
                "text": image.label,
            ])
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mediaType);base64,\(image.data.base64EncodedString())",
                ],
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt,
        ])
        messages.append(["role": "user", "content": contentBlocks])
        return messages
    }

    /// Streaming vision chat. Calls `onTextChunk` with accumulated text as deltas arrive.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let accessToken = try await XAIOAuthAuthenticator.shared.getAccessToken()
        var request = makeAPIRequest(accessToken: accessToken)

        let messages = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": 1024,
            "messages": messages,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Grok streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GrokAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            // Surface login needed when OAuth token is rejected
            if httpResponse.statusCode == 401 {
                throw XAIOAuthError.loginRequired
            }
            throw NSError(
                domain: "GrokAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let first = choices.first else {
                continue
            }

            // OpenAI-compatible delta
            if let delta = first["delta"] as? [String: Any],
               let textChunk = delta["content"] as? String {
                accumulatedResponseText += textChunk
                let current = accumulatedResponseText
                await onTextChunk(current)
                continue
            }

            // Some gateways put full message content in non-delta form
            if let message = first["message"] as? [String: Any],
               let textChunk = message["content"] as? String {
                accumulatedResponseText = textChunk
                let current = accumulatedResponseText
                await onTextChunk(current)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let accessToken = try await XAIOAuthAuthenticator.shared.getAccessToken()
        var request = makeAPIRequest(accessToken: accessToken)

        let messages = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": messages,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Grok request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw XAIOAuthError.loginRequired
            }
            throw NSError(
                domain: "GrokAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "GrokAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
