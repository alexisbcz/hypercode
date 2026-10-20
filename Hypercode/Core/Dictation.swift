import AVFoundation
import Observation
import Speech

/// Voice input for the composer: microphone audio through Apple's speech recognizer (on-device when the
/// Mac supports it), delivered as a growing transcript while you speak.
@Observable
final class Dictation {
    private(set) var isRecording = false
    /// Why dictation couldn't start or stopped early, for the footer.
    var error: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// Starts listening; `onText` gets the whole transcript so far each time it changes.
    func start(onText: @escaping (String) -> Void) async {
        guard !isRecording else { return }
        error = nil
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

    /// Stops listening; the recognizer delivers its last words before the task ends.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        task = nil
    }

    // MARK: - Off the main actor

    /// Built outside the main actor: the audio thread calls it, and a main-actor closure would trap there.
    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
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
