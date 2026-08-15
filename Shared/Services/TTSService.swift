import Foundation
import AVFoundation
import SwiftUI
import NaturalLanguage
#if os(iOS)
import MediaPlayer
#endif

enum TTSLanguage: String, CaseIterable, Identifiable {
    case both = "Both"
    case original = "Original"
    case english = "English"
    var id: String { rawValue }
}

/// Reads bilingual content aloud with the system's speech voices.
///
/// Apple-only on purpose. The OpenAI engine fetched each sentence as an isolated audio
/// clip — a narrator who resets mid-thought — cost API money, and dragged a Keychain
/// password prompt into the middle of reading a book. The system voices, once the
/// enhanced ones are downloaded, do the job with none of that.
@Observable
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    @ObservationIgnored @AppStorage("ttsLanguage") private var ttsLanguageRaw = TTSLanguage.both.rawValue

    var isPlaying = false
    /// Paused mid-utterance (lock screen or headphone button), resumable in place.
    var isPaused = false
    var onFinishReading: (() -> Void)?

    private var wasManuallyStopped = false
    private var nowPlayingTitle = ""

    struct Utterance {
        let text: String
        let language: String
        /// Breathing room after this utterance. A short beat between a sentence and its
        /// translation, a longer one before the next thought — that pause structure is
        /// most of what "someone telling you a story" means, whoever the voice is.
        let pauseAfter: TimeInterval
    }

    private var queue: [Utterance] = []

    override init() {
        super.init()
        synthesizer.delegate = self

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        setupRemoteCommands()
        #endif
    }

    #if os(iOS)
    /// Lock screen, headphones, car steering wheel — anywhere a play/pause button lives.
    /// Without these, reading dies the moment the phone locks in the cupholder.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying, self.isPaused else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { self.resume() }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying, !self.isPaused else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { self.pause() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { self.isPaused ? self.resume() : self.pause() }
            return .success
        }
    }
    #endif

    /// Reflects state onto the lock screen so the pause button there shows the truth.
    private func updateNowPlaying(rate: Float) {
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle.isEmpty ? "LingoBook" : nowPlayingTitle,
            MPMediaItemPropertyArtist: "LingoBook",
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        #endif
    }

    private func clearNowPlaying() {
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    func play(originalParagraphs: [String], englishParagraphs: [String], title: String = "") {
        stop()
        wasManuallyStopped = false
        isPlaying = true
        nowPlayingTitle = title
        updateNowPlaying(rate: 1)
        queue.removeAll()

        let maxCount = max(originalParagraphs.count, englishParagraphs.count)
        let ttsLanguage = TTSLanguage(rawValue: ttsLanguageRaw) ?? .both

        // Detect dominant language of the source text
        let fullText = originalParagraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedLangCode = "en-US"
        if let dominantLang = NLLanguageRecognizer.dominantLanguage(for: fullText) {
            detectedLangCode = dominantLang.rawValue
        }

        for i in 0..<maxCount {
            let wantsOriginal = i < originalParagraphs.count && (ttsLanguage == .both || ttsLanguage == .original)
            let wantsEnglish = i < englishParagraphs.count && (ttsLanguage == .both || ttsLanguage == .english)

            if wantsOriginal {
                let originalText = originalParagraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !originalText.isEmpty {
                    queue.append(Utterance(
                        text: originalText,
                        language: detectedLangCode,
                        pauseAfter: wantsEnglish ? 0.25 : 0.55
                    ))
                }
            }

            if wantsEnglish {
                let enText = englishParagraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !enText.isEmpty {
                    queue.append(Utterance(text: enText, language: "en-US", pauseAfter: 0.55))
                }
            }
        }

        playNext()
    }

    /// Speaks one passage — a tutor reply — in whatever language it happens to be in.
    ///
    /// Shares the reader's synthesiser rather than owning a second one, so a reply can
    /// never talk over the book being read aloud: starting either stops the other.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        wasManuallyStopped = false
        isPlaying = true
        queue.removeAll()

        let language = NLLanguageRecognizer.dominantLanguage(for: trimmed)?.rawValue ?? "en-US"
        queue.append(Utterance(text: trimmed, language: language, pauseAfter: 0))

        updateNowPlaying(rate: 1)
        playNext()
    }

    func stop() {
        wasManuallyStopped = true
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        queue.removeAll()
        isPlaying = false
        isPaused = false
        clearNowPlaying()
    }

    func pause() {
        guard isPlaying, !isPaused, synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
        updateNowPlaying(rate: 0)
    }

    func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        updateNowPlaying(rate: 1)
    }

    private func playNext() {
        guard !queue.isEmpty, isPlaying else {
            isPlaying = false
            if !wasManuallyStopped {
                onFinishReading?()
            }
            return
        }

        let next = queue.removeFirst()
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = Self.bestVoice(forLanguage: next.language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.postUtteranceDelay = next.pauseAfter
        synthesizer.speak(utterance)
    }

    /// The best installed voice for a language.
    ///
    /// `NLLanguageRecognizer` reports "fr"; installed voices identify as "fr-FR" or
    /// "fr-CA". The old exact-string comparison could never match the two, so French
    /// always fell through to the compact robot voice — even with Thomas (Enhanced)
    /// sitting right there, downloaded and ready. Prefix matching plus a quality sort
    /// fixes that: premium beats enhanced beats default.
    static func bestVoice(forLanguage code: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == code || $0.language.hasPrefix(code + "-")
        }

        // Premium and enhanced are the downloadable neural voices — always take those.
        // Among the built-ins, rank explicitly: the compact voices are merely robotic,
        // but Eloquence ("Eddy") and the novelty voices ("Bells", "Boing") are unusable
        // for reading — and the system's own default for French resolves to Eloquence
        // Eddy, so "let the system decide" is not a safe fallback here.
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 4
            case .enhanced: return 3
            default:
                if voice.identifier.contains(".voice.compact") { return 2 }
                if voice.identifier.contains(".eloquence.") { return 1 }
                return 0
            }
        }

        return candidates.max(by: { rank($0) < rank($1) })
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.isPlaying && !self.wasManuallyStopped {
                self.playNext()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}
