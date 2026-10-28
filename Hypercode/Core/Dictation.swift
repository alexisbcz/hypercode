import AVFoundation
import Observation
import Speech

/// Who turns dictation into text.
enum DictationEngine: String, CaseIterable, Identifiable {
    case apple, lfm3
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple" : "LFM3-Audio" }
}

/// Voice input for the composer: microphone audio through Apple's speech recognizer (on-device when the
/// Mac supports it), delivered as a growing transcript while you speak, or through LFM3-Audio, which
/// transcribes the whole recording once you stop.
@Observable
final class Dictation {
    private(set) var isRecording = false
    /// LFM3-Audio is turning the recording into text (or downloading, the first time).
    private(set) var isTranscribing = false
    /// Why dictation couldn't start or stopped early, for the footer.
    var error: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var onText: ((String) -> Void)?
    @ObservationIgnored private var transcription: Task<Void, Never>?

    /// Starts listening; `onText` gets the whole transcript so far each time it changes.
    func start(onText: @escaping (String) -> Void) async {
        guard !isRecording, !isTranscribing else { return }
        error = nil
        if DictationEngine(rawValue: UserDefaults.standard.string(forKey: Pref.dictationEngine) ?? "") == .lfm3 {
            await startRecording(onText: onText)
            return
        }
        guard await Self.authorize() else {
            error = "Allow Microphone and Speech Recognition for Hypercode in System Settings › Privacy & Security."
            return
        }
        // The language picked in Settings, else the system's.
        let chosen = UserDefaults.standard.string(forKey: Pref.dictationLocale).flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
        guard let recognizer = chosen ?? SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else {
            error = "Speech recognition isn't available right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(feeding: request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        self.engine = engine
        self.request = request
        isRecording = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, isFinal, failure in
            guard let self else { return }
            if let text { onText(text) }
            if let failure, isRecording {
                // "No speech detected" after a silent stop isn't worth reporting.
                if (failure as NSError).code != 1110 { error = failure.localizedDescription }
                stop()
            } else if isFinal {
                stop()
            }
        })
    }

    /// Stops listening; the recognizer delivers its last words before the task ends, and LFM3-Audio
    /// transcribes what was recorded. `discarding` drops the recording instead, as sending the message does.
    func stop(discarding: Bool = false) {
        if discarding {
            transcription?.cancel()
            transcription = nil
            isTranscribing = false
        }
        guard isRecording else { return }
        isRecording = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        task = nil
        if let recording, let onText {
            self.recording = nil
            self.onText = nil
            if !discarding { transcribe(recording, onText: onText) }
        }
    }

    // MARK: - LFM3-Audio

    private func startRecording(onText: @escaping (String) -> Void) async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Allow Microphone for Hypercode in System Settings › Privacy & Security."
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let recording = Recording(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(recording: recording))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        self.recording = recording
        self.onText = onText
        isRecording = true
        // Download and load the model while you speak, so it's ready when you stop.
        Task { try? await LFM3Audio.shared.prepare() }
    }

    private func transcribe(_ recording: Recording, onText: @escaping (String) -> Void) {
        let sampleRate = recording.sampleRate
        let samples = recording.samples
        // Under a quarter of a second is a click on the button, not speech.
        guard Double(samples.count) > sampleRate / 4 else { return }
        let language = UserDefaults.standard.string(forKey: Pref.dictationLFM3Language).flatMap { $0.isEmpty ? nil : $0 }
        isTranscribing = true
        transcription = Task {
            do {
                let audio = await Task.detached { LFM3Audio.resampled(samples, from: sampleRate) }.value
                let text = try await LFM3Audio.shared.transcribe(audio, language: language)
                try Task.checkCancellation()
                if !text.isEmpty { onText(text) }
            } catch is CancellationError {
            } catch {
                self.error = "LFM3-Audio couldn't transcribe: \(error.localizedDescription)"
            }
            isTranscribing = false
            transcription = nil
        }
    }

    // MARK: - Off the main actor

    /// Built outside the main actor: the audio thread calls it, and a main-actor closure would trap there.
    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func tap(recording: Recording) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            recording.append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }

    /// Recognition results arrive on a background queue; this hops them to the main actor.
    nonisolated private static func results(
        _ handler: @escaping @MainActor (String?, Bool, (any Error)?) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(text, isFinal, error) } }
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// The microphone's samples (first channel, at its own rate), appended from the audio thread.
nonisolated private final class Recording: @unchecked Sendable {
    let sampleRate: Double
    private let lock = NSLock()
    private var buffer: [Float] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock { buffer.append(contentsOf: samples) }
    }

    var samples: [Float] { lock.withLock { buffer } }
}
