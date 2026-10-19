import AppKit
import SwiftUI

/// Turns URLs and file references in transcript text into links, and opens them.
enum Links {
    /// File references travel under their own scheme, so "Store.swift:42" isn't read as a URL with scheme "store.swift".
    static let fileScheme = "hypercode-file"

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain text with its bare web URLs made clickable.
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector, text.contains("http") || text.contains("www.") else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            // The detector also takes "Package.swift" for a domain; only explicit web addresses count.
            guard let url = match.url, let range = Range(match.range, in: text),
                  ["http://", "https://", "www."].contains(where: text[range].lowercased().hasPrefix),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    /// A Markdown link destination: web and mail links as they are, anything else as a file reference.
    static func destination(_ raw: String) -> URL? {
        if raw.contains("://") || raw.hasPrefix("mailto:") { return URL(string: raw) }
        return fileReference(raw)
    }

    static func fileReference(_ reference: String) -> URL? {
        var components = URLComponents()
        components.scheme = fileScheme
        components.path = reference
        return components.url
    }

    /// Inline code such as `Sources/Store.swift:42`, linked only when it names something in the project.
    static func fileReference(inCode code: String, root: URL?) -> URL? {
        guard root != nil, code.count < 300, !code.contains(" "), code.contains("/") || code.contains("."),
              resolve(code, root: root) != nil
        else { return nil }
        return fileReference(code)
    }

    /// The file a reference points at, absolute or relative to the project, ignoring ":12", ":12:3" or "#L12".
    static func resolve(_ reference: String, root: URL?) -> URL? {
        var path = reference.components(separatedBy: "#").first ?? reference
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":") else { break }
            let tail = path[path.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            path = String(path[..<colon])
        }
        path = (path as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root?.appending(path: path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Files open in their default app and folders in Finder; everything else goes to the system.
    static func open(_ url: URL, root: URL?) -> OpenURLAction.Result {
        guard url.scheme == fileScheme else { return .systemAction }
        let reference = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        guard let file = resolve(reference, root: root) else {
            NSSound.beep()
            return .handled
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
        if isDirectory.boolValue || !NSWorkspace.shared.open(file) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        return .handled
    }
}

extension EnvironmentValues {
    /// The session's project folder, for resolving file references in the transcript.
    @Entry var projectRoot: URL?
}
