import Foundation

/// A long-lived `claude -p` process speaking stream-json on stdin and stdout.
final class ClaudeProcess {
    let config: RunConfig
    var onEvent: (JSON) -> Void = { _ in }
    var onExit: (_ status: Int32, _ stderr: String) -> Void = { _, _ in }

    private let process = Process()
    private let stdin = Pipe()

    init(sessionID: String, resume: Bool, cwd: URL, config: RunConfig) {
        self.config = config
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", config.mode.rawValue,
        ]
        if let effort = config.effort { args += ["--effort", effort.rawValue] }
        if config.model != "default" { args += ["--model", config.model] }
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]

        process.executableURL = Shell.claude
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = Shell.environment
        process.standardInput = stdin
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in lines.append(handle.availableData) {
                guard let event = JSON.parse(line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent(event) } }
            }
        }
        let errors = LineBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = errors.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let message = errors.remainder
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit(status, message) } }
        }
        try process.run()
    }

    /// `content` is a string or an array of Messages API content blocks.
    func send(_ content: Any) {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// The CLI's `initialize` reply from a throwaway process in `cwd`: the models `/model` offers and
    /// every slash command and skill available there. Nil when claude can't be run or doesn't answer within 20 seconds.
    nonisolated static func initialize(claude: URL, environment: [String: String], cwd: URL) -> JSON? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = claude
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }

        let request = #"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"# + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        let lines = LineBuffer()
        while case let data = output.fileHandleForReading.availableData, !data.isEmpty {
            for line in lines.append(data) {
                guard let event = JSON.parse(line), event["type"]?.string == "control_response" else { continue }
                return event["response"]?["response"]
            }
        }
        return nil
    }
}

/// Splits a byte stream into newline-delimited lines. Used from a single pipe queue.
nonisolated final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private var all = Data()

    func append(_ data: Data) -> [Data] {
        all.append(data)
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    var remainder: String { String(decoding: all.suffix(4000), as: UTF8.self) }
}

/// GUI apps don't inherit the login shell's PATH, so borrow it once at launch.
enum Shell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if !path.isEmpty { env["PATH"] = path }
        }
        return env
    }()

    static let claude: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        let found = dirs.map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: found ?? "\(home)/.local/bin/claude")
    }()
}
