import AVFoundation
import Markdown
import NaturalLanguage
import Observation

/// Reads Claude's replies aloud with the system's speech voices, on-device.
@Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    /// The entries being read right now, so their buttons can show "Stop".
    private(set) var speaking: Set<String> = []

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.rate = Self.rate
        speaking = Set(entries.map(\.id))
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = []
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
        DispatchQueue.main.async { MainActor.assumeIsolated { Speaker.shared.speaking = [] } }
    }
}

private extension AVSpeechSynthesisVoice {
    /// Not one of the novelty voices ("Bad News", "Bells", "Boing"…).
    var isNatural: Bool { !voiceTraits.contains(.isNoveltyVoice) }
}
