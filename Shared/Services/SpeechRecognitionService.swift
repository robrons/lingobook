import Foundation
import Speech
import AVFoundation

/// Thin wrapper that owns the @Observable UI state on MainActor.
/// All AVAudioEngine / SFSpeechRecognizer work is delegated to a
/// completely non-isolated helper so closures never inherit MainActor.
@Observable
@MainActor
final class SpeechRecognitionService {
    var isListening = false
    var isAuthorized = false
    var onCommandRecognized: ((NavigationCommand) -> Void)?

    enum NavigationCommand: Sendable {
        case next
        case previous
    }

    private let engine = AudioSpeechEngine()

    func toggleListening() {
        if isListening {
            engine.stop()
            isListening = false
        } else {
            isListening = true          // optimistic – corrected below on failure
            engine.start { [weak self] command in
                Task { @MainActor in
                    self?.onCommandRecognized?(command)
                }
            } onAuthorizationResult: { [weak self] authorized in
                Task { @MainActor in
                    self?.isAuthorized = authorized
                    if !authorized { self?.isListening = false }
                }
            } onStopped: { [weak self] in
                Task { @MainActor in
                    self?.isListening = false
                }
            }
        }
    }

    func stopListening() {
        engine.stop()
        isListening = false
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - AudioSpeechEngine (completely non-isolated)
// ─────────────────────────────────────────────────────────────

/// Performs all AVAudioEngine + SFSpeechRecognizer work without
/// any actor isolation, so closures can safely run on any thread.
private final class AudioSpeechEngine: @unchecked Sendable {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private let nextKeywords: Set<String> = ["next", "forward"]
    private let previousKeywords: Set<String> = ["previous", "backward", "back"]
    private var lastCommandTime = Date.distantPast

    private var commandHandler: ((SpeechRecognitionService.NavigationCommand) -> Void)?
    private var stoppedHandler: (() -> Void)?
    private var isActive = false

    // MARK: Public

    func start(
        onCommand: @escaping (SpeechRecognitionService.NavigationCommand) -> Void,
        onAuthorizationResult: @escaping (Bool) -> Void,
        onStopped: @escaping () -> Void
    ) {
        commandHandler = onCommand
        stoppedHandler = onStopped
        isActive = true

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self, self.isActive else { return }
            let authorized = status == .authorized
            onAuthorizationResult(authorized)
            guard authorized else { self.isActive = false; onStopped(); return }
            self.beginRecording()
        }
    }

    func stop() {
        isActive = false
        commandHandler = nil
        stoppedHandler = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: Private

    private func beginRecording() {
        guard isActive, !audioEngine.isRunning else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // This closure runs on a realtime audio thread – no actor isolation.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Audio engine error: \(error)")
            stoppedHandler?()
            return
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result, self.isActive {
                self.processTranscription(result.bestTranscription.formattedString.lowercased())
            }

            if error != nil || (result?.isFinal ?? false) {
                let wasActive = self.isActive
                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.recognitionRequest?.endAudio()
                self.recognitionTask?.cancel()
                self.recognitionRequest = nil
                self.recognitionTask = nil
                // Only auto-restart if we weren't deliberately stopped
                if wasActive {
                    self.beginRecording()
                }
            }
        }
    }

    private func processTranscription(_ text: String) {
        guard Date().timeIntervalSince(lastCommandTime) > 2.0 else { return }

        let words = text.split(separator: " ")
        guard let lastWord = words.last else { return }
        let word = String(lastWord)

        if nextKeywords.contains(word) {
            lastCommandTime = Date()
            commandHandler?(.next)
        } else if previousKeywords.contains(word) {
            lastCommandTime = Date()
            commandHandler?(.previous)
        }
    }
}
