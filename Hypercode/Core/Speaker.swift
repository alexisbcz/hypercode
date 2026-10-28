import AVFoundation
import Markdown
import NaturalLanguage
import Observation

/// The voice engine reading replies aloud.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case pocket, lfm3, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pocket: "Pocket TTS"
        case .lfm3: "LFM3-Audio"
        case .system: "macOS Voices"
        }
    }
}

/// Reads Claude's replies aloud, on-device: Kyutai's Pocket TTS by default, LFM3-Audio, or the macOS voices.
@Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    /// The entries being read right now, so their buttons can show "Stop".
    private(set) var speaking: Set<String> = []
    /// True until the first audio plays: the model is loading, or downloading on first use.
    private(set) var isPreparing = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let audio = AudioQueue()
    @ObservationIgnored private var task: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ entry: Entry) -> Bool { speaking.contains(entry.id) }

    /// Reads replies in order, skipping code and tables, which don't survive being read out.
    func speak(_ entries: [Entry]) {
        stop()
        let text = entries.map { Self.spokenText($0.text) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        speaking = Set(entries.map(\.id))
        let engine = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: Pref.speechEngine) ?? "") ?? .pocket
        switch engine {
        case .pocket: speakWithPocket(text)
        case .lfm3: speakWithLFM3(text)
        case .system: speakWithSystem(text)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        audio.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isPreparing = false
        speaking = []
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.rate = Self.rate
        synthesizer.speak(utterance)
    }

    private func speakWithPocket(_ text: String) {
        let voice = UserDefaults.standard.string(forKey: Pref.pocketVoice) ?? PocketVoice.voices[0]
        speakGenerated(text, load: { try await PocketVoice.shared.load() }) {
            try await PocketVoice.shared.synthesize($0, voice: voice)
        }
    }

    private func speakWithLFM3(_ text: String) {
        let voice = UserDefaults.standard.string(forKey: Pref.lfm3Voice) ?? LFM3Audio.voices[0]
        let language = UserDefaults.standard.string(forKey: Pref.lfm3Language) ?? "en"
        speakGenerated(text, load: {
            try await LFM3Audio.shared.prepare()
            return LFM3Audio.outputSampleRate
        }) {
            try await LFM3Audio.shared.synthesize($0, voice: voice, language: language)
        }
    }

    /// Generates sentence by sentence and plays each as soon as it's ready, while the next one generates.
    private func speakGenerated(_ text: String, load: @escaping () async throws -> Int, synthesize: @escaping (String) async throws -> [Float]) {
        let speed = Float(UserDefaults.standard.object(forKey: Pref.speechRate) as? Double ?? 0.5) * 2
        let chunks = Self.chunks(of: text)
        isPreparing = true
        task = Task {
            do {
                let sampleRate = try await load()
                try Task.checkCancellation()
                try audio.start(sampleRate: sampleRate, speed: speed) { self.finished() }
                for chunk in chunks {
                    let samples = try await synthesize(chunk)
                    try Task.checkCancellation()
                    audio.enqueue(samples)
                    isPreparing = false
                }
                audio.finish()
            } catch is CancellationError {
            } catch {
                // No model yet and no network, say: the macOS voice is better than silence.
                isPreparing = false
                speakWithSystem(text)
            }
        }
    }

    private func finished() {
        task = nil
        isPreparing = false
        speaking = []
    }

    /// Sentences, with short ones joined, so each generated piece is long enough to sound natural
    /// and the first is short enough to start quickly.
    static func chunks(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var chunks: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            current += (current.isEmpty ? "" : " ") + sentence
            // The first piece goes out alone so speech starts fast; later ones gather up to ~240 characters.
            if chunks.isEmpty || current.count > 240 {
                chunks.append(current)
                current = ""
            }
            return true
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A sample in the chosen voice, for Settings.
    func preview() {
        speak([Entry(id: "preview", kind: .assistant, text: "Done. The home screen now shows the next seven days, and all the tests pass.")])
    }

    // MARK: - Voices

    /// The voice picked in Settings, else the best installed voice for the language the text is written in:
    /// Claude often answers in English on a Mac set to another language, and the system voice would mangle it.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Pref.speechVoice), !id.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        return best(for: language) ?? best(for: "en")
    }

    /// An installed Premium or Enhanced voice for the language, else the system's default voice for it
    /// (Samantha for English), never a novelty voice like "Bubbles".
    private static func best(for language: String) -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) && $0.isNatural }
        if let upgraded = candidates.filter({ $0.quality != .default }).max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return upgraded
        }
        let local = region.flatMap { AVSpeechSynthesisVoice(language: "\(language)-\($0)") }
        return local ?? AVSpeechSynthesisVoice(language: language == "en" ? "en-US" : language)
    }

    /// Voices worth offering in Settings: English and the system language, no novelty voices, best quality first.
    static var voices: [AVSpeechSynthesisVoice] {
        let languages = Set(["en", Locale.current.language.languageCode?.identifier ?? "en"])
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in voice.isNatural && languages.contains { voice.language.hasPrefix($0) } }
            .sorted { ($0.quality.rawValue, $1.language, $1.name) > ($1.quality.rawValue, $0.language, $0.name) }
    }

    private static var rate: Float {
        let saved = UserDefaults.standard.object(forKey: Pref.speechRate) as? Double ?? 0.5
        return Float(saved) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) + AVSpeechUtteranceMinimumSpeechRate
    }

    // MARK: - Text

    /// A reply's prose, ready to read: headings and paragraphs as sentences, code blocks, tables and HTML left out.
    nonisolated static func spokenText(_ markdown: String) -> String {
        var parts: [String] = []
        func visit(_ markup: any Markup) {
            switch markup {
            case is CodeBlock, is Markdown.Table, is HTMLBlock, is ThematicBreak:
                return
            case let heading as Heading:
                parts.append(heading.plainText + ".")
            case let paragraph as Paragraph:
                parts.append(paragraph.plainText)
            default:
                markup.children.forEach(visit)
            }
        }
        visit(Document(parsing: markdown))
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Speaker.shared.finished() } }
    }
}

private extension AVSpeechSynthesisVoice {
    /// Not one of the novelty voices ("Bad News", "Bells", "Boing"…).
    var isNatural: Bool { !voiceTraits.contains(.isNoveltyVoice) }
}
