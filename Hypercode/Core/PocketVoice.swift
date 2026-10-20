import AVFoundation
import MLX
import MLXAudioTTS

/// Kyutai's Pocket TTS, through MLX on Apple silicon: natural speech, fully on-device.
/// The model (about 240 MB) downloads from Hugging Face the first time it's used, then loads from the cache.
actor PocketVoice {
    static let shared = PocketVoice()
    static let repository = "mlx-community/pocket-tts"
    static let voices = ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"]

    private var model: PocketTTSModel?

    var isLoaded: Bool { model != nil }

    /// Loads (downloading on first use) and returns the sample rate of what `synthesize` returns.
    func load() async throws -> Int {
        try await loadedModel().sampleRate
    }

    /// One stretch of text as mono Float32 samples.
    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        let model = try await loadedModel()
        let audio = try await model.generate(text: text, voice: voice, generationParameters: model.defaultGenerationParameters)
        return audio.asArray(Float.self)
    }

    private func loadedModel() async throws -> PocketTTSModel {
        if let model { return model }
        let loaded = try await PocketTTSModel.fromPretrained(Self.repository)
        model = loaded
        return loaded
    }
}

/// Plays generated samples as they arrive, so speech starts after the first sentence, not the whole reply.
/// A time-pitch unit sets the speed without making voices sound higher or lower.
final class AudioQueue {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var pending = 0
    private var isFinishing = false
    /// Bumped by every start and stop: stopping the player fires the callbacks of buffers it drops,
    /// and those mustn't count against the next reply.
    private var run = 0
    private var onDrained: (() -> Void)?

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    func start(sampleRate: Int, speed: Float, onDrained: @escaping () -> Void) throws {
        stop()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        if self.format != format {
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        timePitch.rate = speed
        run += 1
        self.onDrained = onDrained
        pending = 0
        isFinishing = false
        if !engine.isRunning { try engine.start() }
        player.play()
    }

    func enqueue(_ samples: [Float]) {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        pending += 1
        let run = run
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.onMain { [weak self] in
            self?.played(run)
        })
    }

    /// Built outside the main actor: the audio thread calls it, and a main-actor closure would trap there.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
    }

    /// Nothing more is coming; `onDrained` runs once what's queued has played.
    func finish() {
        isFinishing = true
        if pending == 0 { drained() }
    }

    func stop() {
        run += 1
        onDrained = nil
        pending = 0
        isFinishing = false
        player.stop()
    }

    private func played(_ run: Int) {
        guard run == self.run else { return }
        pending = max(0, pending - 1)
        if isFinishing, pending == 0 { drained() }
    }

    private func drained() {
        let done = onDrained
        onDrained = nil
        done?()
    }
}
