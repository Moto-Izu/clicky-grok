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
    /// Absolute or PATH-resolved hermes binary.
    var hermesBinary: String
    /// Session name for --continue (conversation continuity).
    var sessionName: String
    /// Comma-separated Hermes toolsets (must include computer_use for GUI ops).
    var toolsets: String
    /// Max tool-calling iterations for one user utterance.
    var maxTurns: Int
    /// When true, pass --yolo so computer_use can run without TTY approvals.
    var yolo: Bool
    /// Working directory for the agent (optional).
    var workingDirectory: String?

    init(
        hermesBinary: String = ClickyServiceConfig.hermesBinary,
        sessionName: String = ClickyServiceConfig.hermesSessionName,
        toolsets: String = ClickyServiceConfig.hermesToolsets,
        maxTurns: Int = ClickyServiceConfig.hermesMaxTurns,
        yolo: Bool = ClickyServiceConfig.hermesYolo,
        workingDirectory: String? = ClickyServiceConfig.hermesWorkingDirectory
    ) {
        self.hermesBinary = hermesBinary
        self.sessionName = sessionName
        self.toolsets = toolsets
        self.maxTurns = maxTurns
        self.yolo = yolo
        self.workingDirectory = workingDirectory
    }

    /// Sends `userPrompt` with optional screenshot path(s). Returns spoken reply text.
    func runTurn(
        userPrompt: String,
        imagePaths: [String] = [],
        systemContext: String = ""
    ) async throws -> (text: String, duration: TimeInterval, sessionID: String?) {
        let start = Date()
        let resolvedBinary = try resolveHermesBinary()

        // Hermes CLI currently accepts a single --image; use the first (cursor screen).
        let primaryImage = imagePaths.first

        var fullPrompt = ""
        if !systemContext.isEmpty {
            fullPrompt += systemContext.trimmingCharacters(in: .whitespacesAndNewlines)
            fullPrompt += "\n\n---\n\n"
        }
        fullPrompt += userPrompt

        var args: [String] = [
            "chat",
            "-q", fullPrompt,
            "-Q",
            "--max-turns", String(maxTurns),
            "--continue", sessionName,
            "--source", "clicky",
        ]

        if !toolsets.isEmpty {
            args += ["-t", toolsets]
        }
        if let primaryImage, !primaryImage.isEmpty {
            args += ["--image", primaryImage]
        }
        if yolo {
            args.append("--yolo")
        }

        print("🤖 Hermes: \(resolvedBinary) \(args.joined(separator: " ").prefix(200))…")

        let (stdout, stderr, exitCode) = try await runProcess(
            executable: resolvedBinary,
            arguments: args,
            workingDirectory: workingDirectory
        )

        let duration = Date().timeIntervalSince(start)
        let sessionID = Self.extractSessionID(from: stdout + "\n" + stderr)
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

        print("🤖 Hermes reply (\(String(format: "%.1f", duration))s): \(reply.prefix(120))…")
        return (text: reply, duration: duration, sessionID: sessionID)
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
            if path == "hermes" { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to `which hermes` via /usr/bin/env
        if fileManager.isExecutableFile(atPath: "/usr/bin/env") {
            return "/usr/bin/env" // caller must pass "hermes" as first arg — handled below
        }

        // Last resort: search PATH manually
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
            var args = arguments
            var exec = executable

            // If we only know "env", run `env hermes …`
            if executable.hasSuffix("/env") || executable == "/usr/bin/env" {
                exec = "/usr/bin/env"
                args = ["hermes"] + arguments
            }

            process.executableURL = URL(fileURLWithPath: exec)
            process.arguments = args
            if let workingDirectory, !workingDirectory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            var env = ProcessInfo.processInfo.environment
            // Ensure local user bin is on PATH for hermes + cua-driver
            let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
            if let existing = env["PATH"] {
                env["PATH"] = "\(extraPath):\(existing)"
            } else {
                env["PATH"] = extraPath
            }
            // Non-interactive: don't wait on TTY prompts when yolo is off and something slips through
            env["HERMES_ACCEPT_HOOKS"] = "1"
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
        let combined = (stdout + "\n" + stderr)
            .replacingOccurrences(of: "\r\n", with: "\n")

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
        ]

        let lines = combined
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var kept: [String] = []
        for line in lines {
            if line.isEmpty {
                if !kept.isEmpty { kept.append("") }
                continue
            }
            if noisePrefixes.contains(where: { line.hasPrefix($0) }) {
                continue
            }
            // Drop pure spinner / progress junk
            if line.allSatisfy({ $0 == "." || $0 == " " }) { continue }
            kept.append(line)
        }

        // Trim leading/trailing blank lines
        while kept.first?.isEmpty == true { kept.removeFirst() }
        while kept.last?.isEmpty == true { kept.removeLast() }

        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
