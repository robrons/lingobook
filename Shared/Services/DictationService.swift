import Foundation

#if os(macOS)
import AVFoundation
import FluidAudio

/// Captures microphone audio as 16kHz mono samples.
///
/// Deliberately *not* `@MainActor`, and that is the whole point of it existing as a
/// separate type. `AVAudioEngine` delivers buffers by calling a closure on a realtime
/// audio thread. A closure written inside a `@MainActor` type inherits main-actor
/// isolation, so Swift checks the executor when Core Audio calls it, finds the wrong
/// thread, and kills the process — `dispatch_assert_queue_fail`, on the first buffer.
/// Marking the helper it calls `nonisolated` does not help: the trap fires at the
/// closure, before the helper is reached. Nothing in this class is isolated, so the
/// audio thread runs code that never claimed to belong anywhere else.
private final class AudioCapture: @unchecked Sendable {

    enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "No usable microphone input." }
    }

    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var storage: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false

    func start() throws {
        guard !isRunning else { return }

        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard
            inputFormat.sampleRate > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw Failure.noInput }

        self.targetFormat = target
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.append(self.resample(buffer))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stops capture and hands back everything recorded.
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        lock.lock()
        let samples = storage
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
        return samples
    }

    func cancel() {
        _ = stop()
    }

    // MARK: - Audio thread

    private func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        storage.append(contentsOf: samples)
        lock.unlock()
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, let targetFormat else { return [] }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Push-to-talk dictation using Parakeet TDT v3, on this machine.
///
/// Chosen over `SFSpeechRecognizer` because Parakeet v3 identifies the spoken language
/// itself across 25 European languages — a reader practising French can ask in French
/// one moment and English the next without telling the app which is coming, where
/// `SFSpeechRecognizer` must be pinned to a locale before it hears anything.
///
/// Inference runs on the Neural Engine, not the GPU, so it does not contend with the
/// several gigabytes the language model already holds.
@MainActor
@Observable
final class DictationService {

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
    }

    private(set) var state: State = .idle
    var errorMessage: String?

    private let capture = AudioCapture()
    private var asr: AsrManager?

    /// Where a shared copy of the weights lives, if the reader has pointed us at one.
    ///
    /// The sandbox rewrites this app's Application Support to its own container, so a
    /// copy another app already downloaded is invisible and FluidAudio fetches its own
    /// ~460MB. A security-scoped bookmark, granted once through an open panel, is the
    /// sanctioned way back to the shared folder.
    private static let bookmarkKey = "dictation.modelFolderBookmark"

    // MARK: - Model

    /// True when weights must be fetched because no shared folder has been granted.
    var willDownload: Bool { asr == nil && sharedModelFolder == nil }

    /// Loads the model. Safe to call repeatedly.
    ///
    /// Explicitly v3. `UnifiedAsrManager` has the friendlier API — plain samples in,
    /// string out, no decoder state — but its only weights are
    /// `parakeet-unified-en-0.6b`, which is English-only. Multilingual recognition is
    /// the entire reason for using Parakeet here.
    func prepare() async {
        guard asr == nil else { return }
        state = .preparing
        do {
            let models: AsrModels
            if let folder = sharedModelFolder {
                let accessed = folder.startAccessingSecurityScopedResource()
                defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
                models = try await AsrModels.load(from: folder, version: .v3)
            } else {
                models = try await AsrModels.downloadAndLoad(version: .v3)
            }

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
            state = .idle
        } catch {
            errorMessage = "Couldn't load the speech model: \(error.localizedDescription)"
            state = .idle
        }
    }

    // MARK: - Recording

    func startListening() {
        guard state == .idle || state == .preparing else { return }
        do {
            try capture.start()
            state = .listening
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops recording and returns what was said. Empty if nothing usable was heard.
    func stopListeningAndTranscribe() async -> String {
        guard state == .listening else { return "" }

        let samples = capture.stop()

        // Under a quarter-second is a stray keypress, not speech.
        guard samples.count > Int(AudioCapture.sampleRate / 4) else {
            state = .idle
            return ""
        }

        state = .transcribing
        defer { state = .idle }

        if asr == nil { await prepare() }
        guard let asr else { return "" }

        do {
            // A fresh state per utterance: each press is its own sentence, not a
            // continuation of the last one.
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorMessage = "Couldn't transcribe that: \(error.localizedDescription)"
            return ""
        }
    }

    func cancel() {
        guard state == .listening else { return }
        capture.cancel()
        state = .idle
    }

    // MARK: - Sharing another app's weights

    /// Remembers a folder the reader granted, and loads from it instead of downloading.
    func useModelFolder(_ url: URL) async {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            asr = nil
            await prepare()
        } catch {
            errorMessage = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    /// The granted folder, if one still resolves.
    private var sharedModelFolder: URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }

        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ),
            !stale
        else {
            // Moved or deleted: forget it and fall back to downloading, rather than
            // failing every time from here on.
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return nil
        }

        return url
    }
}
#endif
