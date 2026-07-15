//
//  ClickyServiceConfig.swift
//  Shared endpoint configuration for Worker-backed services.
//

import Foundation

enum ClickyServiceConfig {
    /// Cloudflare Worker base URL for TTS + AssemblyAI token.
    /// Leave the placeholder to run without a Worker (Apple Speech + system TTS).
    static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    static var isWorkerConfigured: Bool {
        !workerBaseURL.contains("your-worker-name")
            && !workerBaseURL.contains("your-subdomain")
            && workerBaseURL.hasPrefix("http")
    }

    static var ttsProxyURL: String { "\(workerBaseURL)/tts" }
    static var transcribeTokenURL: String { "\(workerBaseURL)/transcribe-token" }
}
