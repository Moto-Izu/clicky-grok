//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs (via Worker) and plays it
//  back. Falls back to macOS AVSpeechSynthesizer when the Worker is not
//  configured or the request fails.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let proxyURL: URL
    private let usesWorker: Bool
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var systemSpeechActive = false

    init(proxyURL: String, usesWorker: Bool = ClickyServiceConfig.isWorkerConfigured) {
        self.proxyURL = URL(string: proxyURL)!
        self.usesWorker = usesWorker

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` via ElevenLabs when available, otherwise system TTS.
    func speakText(_ text: String) async throws {
        stopPlayback()

        if usesWorker {
            do {
                try await speakWithElevenLabs(text)
                return
            } catch {
                print("⚠️ ElevenLabs TTS failed, falling back to system voice: \(error)")
            }
        } else {
            print("🔊 TTS: Worker not configured — using system voice")
        }

        try await speakWithSystemVoice(text)
    }

    private func speakWithElevenLabs(_ text: String) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ElevenLabsTTS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ElevenLabsTTS",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    private func speakWithSystemVoice(_ text: String) async throws {
        try Task.checkCancellation()
        systemSpeechActive = true

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        // Prefer Japanese voice for this fork; fall back to system default.
        if let voice = AVSpeechSynthesisVoice(language: "ja-JP")
            ?? AVSpeechSynthesisVoice(language: "ja") {
            utterance.voice = voice
        }

        speechSynthesizer.speak(utterance)
        print("🔊 System TTS: speaking \(text.prefix(80))...")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        if audioPlayer?.isPlaying == true { return true }
        return systemSpeechActive || speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        systemSpeechActive = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.systemSpeechActive = false
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.systemSpeechActive = false
        }
    }
}
