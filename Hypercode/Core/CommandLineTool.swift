import AppKit

/// The `hypercode` command, like VS Code's `code`: a script inside the app, linked into a folder on your PATH.
enum CommandLineTool {
    static let name = "hypercode"

    /// The script in this copy of the app; the link points here, so it follows app updates.
    static var bundled: URL { Bundle.main.bundleURL.appending(path: "Contents/Resources/bin/\(name)") }

    enum Status: Equatable {
        case notInstalled
        case installed(URL)
        /// Linked to another copy of Hypercode (a moved or deleted app, or a dev build).
        case elsewhere(URL)
    }

    static var status: Status {
        for dir in candidates {
            let link = dir.appending(path: name)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                  isHypercode(target) else { continue }
            return target == bundled.path ? .installed(link) : .elsewhere(link)
        }
        return .notInstalled
    }

    /// Links the command into the first writable folder on your PATH, or into /usr/local/bin with your
    /// password when none is. Returns where it went.
    @discardableResult
    static func install() throws -> URL {
        if case .installed(let link) = status { return link }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let path = Set((Shell.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path })
        // Replace a stale link of ours first, so there's only ever one.
        let dirs = staleLinkDirs + candidates.filter { path.contains($0.path) }
        for dir in dirs {
            if dir == home.appending(path: ".local/bin") { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            guard fm.isWritableFile(atPath: dir.path) else { continue }
            let link = dir.appending(path: name)
            try clear(link)
            try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
            return link
        }
        let link = URL(fileURLWithPath: "/usr/local/bin/\(name)")
        try clear(link)
        try runAsAdmin("mkdir -p /usr/local/bin && ln -sf \(shellQuoted(bundled.path)) \(link.path)")
        return link
    }

    static func uninstall() throws {
        for dir in candidates {
            let link = dir.appending(path: name)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), isHypercode(target) else { continue }
            if (try? FileManager.default.removeItem(at: link)) == nil {
                try runAsAdmin("rm -f \(shellQuoted(link.path))")
            }
        }
    }

    /// Where a link may live, in the order `install` prefers: no password, and usually on PATH already.
    private static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: ".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    }

    private static var staleLinkDirs: [URL] {
        if case .elsewhere(let link) = status { [link.deletingLastPathComponent()] } else { [] }
    }

    private static func isHypercode(_ target: String) -> Bool {
        target.hasSuffix(".app/Contents/Resources/bin/\(name)")
    }

    /// Removes our own link; anything else by that name stays, and install stops.
    private static func clear(_ link: URL) throws {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path), isHypercode(target) {
            if (try? fm.removeItem(at: link)) == nil { try runAsAdmin("rm -f \(shellQuoted(link.path))") }
        } else if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            throw Failure("\(link.path) already exists and isn't Hypercode's. Remove it, then try again.")
        }
    }

    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            // -128: the password prompt was cancelled.
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw CancellationError() }
            throw Failure(error[NSAppleScript.errorMessage] as? String ?? "Couldn't change /usr/local/bin.")
        }
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Installs from a menu or button, and says how it went in an alert.
    static func installShowingResult() {
        let alert = NSAlert()
        do {
            let link = try install()
            alert.messageText = "The ‘hypercode’ command is installed"
            alert.informativeText = "Run “hypercode .” in a terminal to open that folder in Hypercode. It's linked at \(link.path)."
        } catch is CancellationError {
            return
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the ‘hypercode’ command"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
