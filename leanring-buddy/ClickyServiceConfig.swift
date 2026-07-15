//
//  ClickyServiceConfig.swift
//  Shared endpoint / agent configuration.
//

import Foundation

enum ClickyServiceConfig {
    // MARK: - Cloudflare Worker (optional TTS / AssemblyAI)

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

    // MARK: - Local Hermes Agent (brain + computer use)

    /// Path to the `hermes` CLI. Empty string = auto-detect (~/.local/bin/hermes, PATH).
    static let hermesBinary = ""

    /// Session name for `hermes chat --continue` (conversation continuity).
    static let hermesSessionName = "clicky"

    /// Toolsets Hermes may use. `computer_use` requires `hermes computer-use install`.
    /// `vision` helps when we attach a screenshot as eyes.
    static let hermesToolsets = "computer_use,vision,browser,web,terminal,file,skills"

    /// Max tool-calling iterations for one push-to-talk utterance.
    static let hermesMaxTurns = 40

    /// Bypass Hermes approval prompts so non-interactive computer_use can run.
    /// Set false if you want Hermes to require confirmations (needs a TTY).
    static let hermesYolo = true

    /// Optional cwd for Hermes (nil = inherit Clicky's cwd).
    static let hermesWorkingDirectory: String? = nil

    /// Directory for temporary screenshots passed to Hermes as --image.
    static var hermesImageTempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clicky-hermes", isDirectory: true)
    }
}
