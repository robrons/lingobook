import Foundation

#if os(macOS)
import AVFoundation
import FluidAudio

/// Push-to-talk dictation using Parakeet TDT v3, on this machine.
///
/// Chosen over `SFSpeechRecognizer` for one reason that matters here: Parakeet v3
/// detects the spoken language itself across 25 European languages, so a reader
/// practising French can ask in French one moment and English the next without
/// telling the app which is coming. `SFSpeechRecognizer` must be pinned to a locale
/// before it hears anything, which would have meant a language switch in the UI.
///
/// Inference runs on the Neural Engine rather than the GPU — worth noting on a 16GB
/// machine where the language model already holds several gigabytes of GPU memory.
/// The two don't compete.
@MainActor
@Observable
final class DictationService {

    enum State: Equatable {
        case idle
        /// First use downloads the model, which is a few hundred megabytes.
        case preparing
        case listening
        case transcribing
    }

    private(set) var state: State = .idle
    var errorMessage: String?

    private let engine = AVAudioEngine()
    private let collected = SampleCollector()
    private var asr: AsrManager?

    /// Parakeet wants 16kHz mono; the microphone will not be offering that.
    private static let targetSampleRate = 16_000.0

    // MARK: - Model

    /// Loads the model, downloading it the first time. Safe to call repeatedly.
    func prepare() async {
        guard asr == nil else { return }
        state = .preparing
        do {
            // Explicitly v3. `UnifiedAsrManager` has the friendlier API — plain samples
            // in, string out, no decoder state — but its only weights are
            // `parakeet-unified-en-0.6b`, which is English-only. Multilingual
            // recognition is the entire reason for using Parakeet here, so this takes
            // the wordier road for the model that can actually hear French.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
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

        collected.reset()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard
            inputFormat.sampleRate > 0,
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            errorMessage = "No usable microphone input."
            return
        }

        let collected = self.collected
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            collected.append(Self.resample(buffer, using: converter, to: targetFormat))
        }

        do {
            engine.prepare()
            try engine.start()
            state = .listening
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// Stops recording and returns what was said. Empty if nothing usable was heard.
    func stopListeningAndTranscribe() async -> String {
        guard state == .listening else { return "" }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let samples = collected.drain()
        // Under a quarter-second is a stray keypress, not speech.
        guard samples.count > Int(Self.targetSampleRate / 4) else {
            state = .idle
            return ""
        }

        state = .transcribing
        defer { state = .idle }

        if asr == nil { await prepare() }
        guard let asr else { return "" }

        do {
            // A fresh state per utterance: each push-to-talk press is its own sentence,
            // not a continuation of the last one.
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        collected.reset()
        state = .idle
    }

    // MARK: - Audio plumbing

    /// Converts one captured buffer to 16kHz mono float samples.
    private static func resample(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
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

/// Collects samples from the audio thread for the main actor to read later.
///
/// The tap callback runs on a realtime audio thread, so this cannot be actor-isolated
/// without hopping — a lock is the honest tool for the job.
private final class SampleCollector: @unchecked Sendable {

    private var storage: [Float] = []
    private let lock = NSLock()

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        storage.append(contentsOf: samples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let out = storage
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    func reset() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
#endif
