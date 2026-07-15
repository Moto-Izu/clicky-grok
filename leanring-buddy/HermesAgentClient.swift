//
//  HermesAgentClient.swift
//  leanring-buddy
//
//  Invokes the local Hermes Agent CLI so Clicky can act as Hermes' eyes
//  (screenshots + voice) and mouth (TTS + overlay), while Hermes (+ cua-driver)
//  owns planning and computer use.
//

import Foundation

struct HermesAgentClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs a single turn against a local Hermes Agent process.
@MainActor
final class HermesAgentClient {
    private static let sessionIDDefaultsKey = "clickyHermesSessionId"

    /// Absolute or PATH-resolved hermes binary.
    var hermesBinary: String
    /// Comma-separated Hermes toolsets (must include computer_use for GUI ops).
    var toolsets: String
    /// Max tool-calling iterations for one user utterance.
    var maxTurns: Int
    /// When true, pass --yolo so computer_use can run without TTY approvals.
    var yolo: Bool
    /// Working directory for the agent (optional).
    var workingDirectory: String?

    /// Last known Hermes session id (resumed with --resume).
    private(set) var sessionID: String? {
        didSet {
            if let sessionID, !sessionID.isEmpty {
                UserDefaults.standard.set(sessionID, forKey: Self.sessionIDDefaultsKey)
            }
        }
    }

    init(
        hermesBinary: String = ClickyServiceConfig.hermesBinary,
        toolsets: String = ClickyServiceConfig.hermesToolsets,
        maxTurns: Int = ClickyServiceConfig.hermesMaxTurns,
        yolo: Bool = ClickyServiceConfig.hermesYolo,
        workingDirectory: String? = ClickyServiceConfig.hermesWorkingDirectory
    ) {
        self.hermesBinary = hermesBinary
        self.toolsets = toolsets
        self.maxTurns = maxTurns
        self.yolo = yolo
        self.workingDirectory = workingDirectory
        // Load prior session for --resume (not --continue name, which errors if missing)
        let stored = UserDefaults.standard.string(forKey: Self.sessionIDDefaultsKey)
        self.sessionID = (stored?.isEmpty == false) ? stored : nil
    }

    /// Clears stored session so the next turn starts a fresh Hermes conversation.
    func resetSession() {
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionIDDefaultsKey)
    }

    /// Sends `userPrompt` with optional screenshot path(s). Returns spoken reply text.
    func runTurn(
        userPrompt: String,
        imagePaths: [String] = [],
        systemContext: String = ""
    ) async throws -> (text: String, duration: TimeInterval, sessionID: String?) {
        let start = Date()

        var fullPrompt = ""
        if !systemContext.isEmpty {
            fullPrompt += systemContext.trimmingCharacters(in: .whitespacesAndNewlines)
            fullPrompt += "\n\n---\n\n"
        }
        fullPrompt += userPrompt

        // First attempt: resume stored session if any.
        // On "No session found" / empty / resume errors → retry without resume.
        do {
            let result = try await invokeHermes(
                prompt: fullPrompt,
                imagePath: imagePaths.first,
                resumeSessionID: sessionID
            )
            let duration = Date().timeIntervalSince(start)
            if let newID = result.sessionID, !newID.isEmpty {
                sessionID = newID
            }
            return (text: result.text, duration: duration, sessionID: sessionID)
        } catch {
            let message = error.localizedDescription.lowercased()
            let shouldRetryFresh = message.contains("no session")
                || message.contains("not found")
                || message.contains("empty reply")
            guard shouldRetryFresh, sessionID != nil else { throw error }

            print("⚠️ Hermes resume failed (\(error.localizedDescription)); starting a new session")
            resetSession()
            let result = try await invokeHermes(
                prompt: fullPrompt,
                imagePath: imagePaths.first,
                resumeSessionID: nil
            )
            let duration = Date().timeIntervalSince(start)
            if let newID = result.sessionID, !newID.isEmpty {
                sessionID = newID
            }
            return (text: result.text, duration: duration, sessionID: sessionID)
        }
    }

    // MARK: - Invoke

    private func invokeHermes(
        prompt: String,
        imagePath: String?,
        resumeSessionID: String?
    ) async throws -> (text: String, sessionID: String?) {
        let resolvedBinary = try resolveHermesBinary()

        var args: [String] = [
            "chat",
            "-q", prompt,
            "-Q",
            "--max-turns", String(maxTurns),
            "--source", "clicky",
        ]

        // IMPORTANT: do NOT use `--continue <name>`.
        // That flag resumes a *named* session; if missing, Hermes prints
        // "No session found matching '…'" and exits — which Clicky was reading as TTS.
        if let resumeSessionID, !resumeSessionID.isEmpty {
            args += ["--resume", resumeSessionID]
        }

        if !toolsets.isEmpty {
            args += ["-t", toolsets]
        }
        if let imagePath, !imagePath.isEmpty {
            args += ["--image", imagePath]
        }
        if yolo {
            args.append("--yolo")
        }

        print("🤖 Hermes: \(resolvedBinary) … resume=\(resumeSessionID ?? "new") tools=\(toolsets)")

        let (stdout, stderr, exitCode) = try await runProcess(
            executable: resolvedBinary,
            arguments: args,
            workingDirectory: workingDirectory
        )

        let combined = stdout + "\n" + stderr
        if Self.looksLikeMissingSession(combined) {
            throw HermesAgentClientError(message: "No session found")
        }

        let newSessionID = Self.extractSessionID(from: combined)
        let reply = Self.extractReplyText(stdout: stdout, stderr: stderr)

        if exitCode != 0 && reply.isEmpty {
            let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HermesAgentClientError(
                message: "Hermes failed (exit \(exitCode)): \(detail.prefix(500))"
            )
        }

        if reply.isEmpty {
            throw HermesAgentClientError(message: "Hermes returned an empty reply.")
        }

        // Reject nonsense that used to get spoken aloud
        if Self.looksLikeMissingSession(reply) || reply.lowercased().contains("use 'hermes sessions") {
            throw HermesAgentClientError(message: "No session found")
        }

        print("🤖 Hermes reply: \(reply.prefix(160))…")
        return (text: reply, sessionID: newSessionID)
    }

    // MARK: - Process

    private func resolveHermesBinary() throws -> String {
        let candidates = [
            hermesBinary,
            "/Users/motos/.local/bin/hermes",
            NSString(string: "~/.local/bin/hermes").expandingTildeInPath,
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]

        let fileManager = FileManager.default
        for path in candidates where !path.isEmpty {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/hermes"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        throw HermesAgentClientError(
            message: "hermes binary not found. Install Hermes or set ClickyServiceConfig.hermesBinary."
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory, !workingDirectory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            var env = ProcessInfo.processInfo.environment
            let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
            if let existing = env["PATH"] {
                env["PATH"] = "\(extraPath):\(existing)"
            } else {
                env["PATH"] = extraPath
            }
            env["HERMES_ACCEPT_HOOKS"] = "1"
            // Quieter child process noise
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (stdout, stderr, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Output parsing

    private static func looksLikeMissingSession(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("no session found matching")
            || lower.contains("no session found")
    }

    private static func extractSessionID(from text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("session_id:") {
                return trimmed.replacingOccurrences(of: "session_id:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pull the final natural-language reply out of hermes -Q stdout/stderr.
    private static func extractReplyText(stdout: String, stderr: String) -> String {
        // Prefer stdout only — session_id and warnings usually go to stderr.
        let primary = stdout.replacingOccurrences(of: "\r\n", with: "\n")
        let secondary = stderr.replacingOccurrences(of: "\r\n", with: "\n")

        let noisePrefixes = [
            "session_id:",
            "Warning:",
            "⚠️",
            "🤖",
            "HTTP ",
            "Error:",
            "Traceback",
            "Reached maximum",
            "I reached the maximum",
            "No session found",
            "Use 'hermes sessions",
            "Preview",
            "────",
            "↻",
            "Resumed session",
        ]

        func clean(_ text: String) -> String {
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            var kept: [String] = []
            for line in lines {
                if line.isEmpty {
                    if !kept.isEmpty { kept.append("") }
                    continue
                }
                if noisePrefixes.contains(where: { line.hasPrefix($0) || line.contains($0) && $0.hasPrefix("No session") }) {
                    continue
                }
                if line.lowercased().contains("no session found") { continue }
                if line.lowercased().contains("use 'hermes sessions") { continue }
                if line.allSatisfy({ $0 == "." || $0 == " " || $0 == "─" }) { continue }
                kept.append(line)
            }
            while kept.first?.isEmpty == true { kept.removeFirst() }
            while kept.last?.isEmpty == true { kept.removeLast() }
            return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fromOut = clean(primary)
        if !fromOut.isEmpty { return fromOut }

        // Fall back to stderr only if it contains real prose (not just session_id)
        return clean(secondary)
    }
}
