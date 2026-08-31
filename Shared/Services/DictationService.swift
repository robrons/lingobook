import Foundation

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

    /// The single in-flight load, so simultaneous askers wait on one instead of
    /// each starting another. Releasing the space bar while the panel's own warm-up
    /// was still running used to begin a *second* full model bring-up and block the
    /// transcript behind it.
    private var loading: Task<AsrManager?, Never>?

    /// Where a shared copy of the weights lives, if the reader has pointed us at one.
    ///
    /// The sandbox rewrites this app's Application Support to its own container, so a
    /// copy another app already downloaded is invisible and FluidAudio fetches its own
    /// ~460MB. A security-scoped bookmark, granted once through an open panel, is the
    /// sanctioned way back to the shared folder.
    private static let bookmarkKey = "dictation.modelFolderBookmark"

    // MARK: - Model

    /// True when the ~460MB really does have to come down the wire.
    ///
    /// Asked so the wait can be named honestly: a first-ever fetch and a half-second
    /// read from disk both put us in `.preparing`, and telling the reader to expect
    /// 460MB when the file is already there reads as a hang that never comes.
    var willDownload: Bool {
        guard asr == nil, sharedModelFolder == nil else { return false }
        let cached = try? FileManager.default.contentsOfDirectory(
            atPath: AsrModels.defaultCacheDirectory(for: .v3).path
        )
        return cached?.isEmpty ?? true
    }

    /// Loads the model. Safe to call repeatedly, and from several places at once.
    ///
    /// Explicitly v3. `UnifiedAsrManager` has the friendlier API — plain samples in,
    /// string out, no decoder state — but its only weights are
    /// `parakeet-unified-en-0.6b`, which is English-only. Multilingual recognition is
    /// the entire reason for using Parakeet here.
    func prepare() async {
        _ = await loadedManager()
    }

    /// The model, loading it if this is the first ask and joining the load already
    /// running if it isn't.
    private func loadedManager() async -> AsrManager? {
        if let asr { return asr }
        if let loading { return await loading.value }

        // Left alone mid-utterance: the status line is already saying "Transcribing…",
        // and replacing that with "preparing" would be a step backwards on screen.
        if state == .idle { state = .preparing }

        let task = Task { await self.load() }
        loading = task
        let manager = await task.value
        loading = nil
        if state == .preparing { state = .idle }
        return manager
    }

    private func load() async -> AsrManager? {
        do {
            let models = try await weights()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            await Self.warmUp(manager)
            asr = manager
            return manager
        } catch {
            errorMessage = "Couldn't load the speech model: \(error.localizedDescription)"
            return nil
        }
    }

    /// Reads the weights, and this choice of call is the whole fix for the wait after
    /// the space bar comes up.
    ///
    /// `downloadAndLoad` is the obvious one and the wrong one. Before it will hand back
    /// files it can already see, it re-verifies all four model bundles against
    /// HuggingFace — measured here at 167 seconds, against 0.4s for `loadFromCache`
    /// reading the very same files. It bought nothing, because the weights are pinned
    /// to v3 and never change under us, and it charged the reader the entire gap
    /// between releasing space and seeing their words.
    ///
    /// `loadFromCache` still fetches anything genuinely missing, so it covers the first
    /// run too; it just declines to ask the network about files already on the disk.
    private func weights() async throws -> AsrModels {
        if let folder = sharedModelFolder {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            return try await AsrModels.load(from: folder, version: .v3)
        }

        if let cached = try? await AsrModels.loadFromCache(version: .v3) {
            return cached
        }

        // Only reached when that failed outright — a fetch interrupted half way, say.
        // This is the call that repairs a broken folder, so it is worth the wait here.
        return try await AsrModels.downloadAndLoad(version: .v3)
    }

    /// One throwaway pass over silence, so Core ML instantiates the Neural Engine
    /// program now rather than inside the reader's first question. Loading the model
    /// does not compile it; the first `transcribe` does.
    private static func warmUp(_ manager: AsrManager) async {
        do {
            var decoderState = try TdtDecoderState()
            let silence = [Float](repeating: 0, count: Int(AudioCapture.sampleRate / 2))
            _ = try await manager.transcribe(silence, decoderState: &decoderState)
        } catch {
            // Nothing is lost by a warm-up that fails: the next real utterance simply
            // pays the instantiation it would have paid anyway.
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

        guard let asr = await loadedManager() else { return "" }

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
            // A load already running is reading from the wrong place now.
            loading?.cancel()
            loading = nil
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
