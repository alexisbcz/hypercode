import AVFoundation
import Observation

/// Liquid AI's LFM3-Audio-2B, through llama.cpp: speech recognition for dictation and speech for replies,
/// fully on-device. Nothing ships with the app: the first use downloads llama.cpp from its GitHub release and
/// the model from Hugging Face into Application Support. Recognition goes through a `llama-server` Hypercode
/// starts and stops itself; speech runs `llama-tts` once per sentence.
@Observable
final class LFM3Audio {
    static let shared = LFM3Audio()

    static let release = "b11960"
    static let repository = "LiquidAI/LFM3-Audio-2B-GGUF"
    static let licenseURL = URL(string: "https://huggingface.co/LiquidAI/LFM3-Audio-2B/blob/main/LICENSE")!
    /// What the first use downloads, with sizes so progress counts the whole 2.2 GB, not each file.
    static let files: [(name: String, size: Int64)] = [
        ("LFM3-Audio-2B-Q8_0.gguf", 1_846_236_704),
        ("mmproj-LFM3-Audio-2B-Q8_0.gguf", 337_862_080),
    ]

    /// Recognition languages, by the English name the prompt takes.
    static let dictationLanguages = ["English", "Arabic", "Chinese", "Danish", "Dutch", "Finnish", "French", "German", "Greek",
                                     "Hebrew", "Italian", "Japanese", "Korean", "Polish", "Portuguese", "Spanish", "Swedish", "Turkish"]
    /// Speech languages, by the code `llama-tts --tts-lang` takes, with their names.
    static let speechLanguages: [(code: String, name: String)] = [
        ("en", "English (US)"), ("en-gb", "English (UK)"), ("ar", "Arabic"), ("zh", "Chinese"), ("da", "Danish"), ("nl", "Dutch"),
        ("fi", "Finnish"), ("fr", "French"), ("de", "German"), ("el", "Greek"), ("he", "Hebrew"), ("it", "Italian"), ("ja", "Japanese"),
        ("ko", "Korean"), ("pl", "Polish"), ("pt", "Portuguese"), ("es", "Spanish"), ("sv", "Swedish"), ("tr", "Turkish"),
    ]
    static let voices = ["female", "male"]
    /// The model hears 16 kHz audio and speaks at 24 kHz.
    nonisolated static let inputSampleRate = 16_000.0
    static let outputSampleRate = 24_000

    /// What's downloading, while something is.
    struct Download: Equatable {
        var item: String
        var received: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
        var label: String {
            let format = ByteCountFormatter()
            format.countStyle = .file
            return "Downloading \(item)… \(format.string(fromByteCount: received)) of \(format.string(fromByteCount: total))"
        }
    }

    private(set) var download: Download?
    /// True while `llama-server` loads the model, before it answers.
    private(set) var isStarting = false

    @ObservationIgnored private var preparing: Task<Void, any Error>?
    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var serverURL: URL?
    @ObservationIgnored private var starting: Task<URL, any Error>?

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Hypercode/LFM3", directoryHint: .isDirectory)
    }
    static var tools: URL { directory.appending(path: "llama-\(release)", directoryHint: .isDirectory) }
    static var models: URL { directory.appending(path: "models", directoryHint: .isDirectory) }
    static var model: URL { models.appending(path: files[0].name) }
    static var projector: URL { models.appending(path: files[1].name) }

    /// Whether everything is on disk already, so Settings can say what the first use costs.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: tools.appending(path: "llama-server").path)
            && files.allSatisfy { FileManager.default.fileExists(atPath: models.appending(path: $0.name).path) }
    }

    private init() {
        // Quitting (or `exit`) takes the server down with the app, rather than leaving 2 GB of model loaded.
        atexit { if serverPID > 0 { kill(serverPID, SIGTERM) } }
    }

    // MARK: - Downloads

    /// Downloads llama.cpp and the model if they're missing. Concurrent callers share one download.
    func prepare() async throws {
        if let preparing { return try await preparing.value }
        let task = Task { try await install() }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func install() async throws {
        defer { download = nil }
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: Self.tools.appending(path: "llama-server").path) {
            // The release's macOS build, which unpacks to llama-<release>/ with its dylibs beside the binaries.
            let url = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(Self.release)/llama-\(Self.release)-bin-macos-arm64.tar.gz")!
            download = Download(item: "llama.cpp", received: 0, total: 0)
            let archive = try await Self.fetch(url) { [weak self] received, total in self?.download = Download(item: "llama.cpp", received: received, total: total) }
            defer { try? fm.removeItem(at: archive) }
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", Self.directory.path])
            // Downloaded binaries carry quarantine, and Gatekeeper would stop them from launching.
            try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Self.tools.path])
        }

        try fm.createDirectory(at: Self.models, withIntermediateDirectories: true)
        let missing = Self.files.filter { !fm.fileExists(atPath: Self.models.appending(path: $0.name).path) }
        let total = missing.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for file in missing {
            let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/main/\(file.name)")!
            download = Download(item: "LFM3-Audio", received: done, total: total)
            let base = done
            let temporary = try await Self.fetch(url) { [weak self] received, _ in
                self?.download = Download(item: "LFM3-Audio", received: base + received, total: total)
            }
            // Moved in only once complete, so a file that exists is a whole one.
            let destination = Self.models.appending(path: file.name)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporary, to: destination)
            done += file.size
        }
    }

    /// Downloads to a temporary file, reporting bytes on the main actor as they arrive.
    nonisolated private static func fetch(_ url: URL, progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    // MARK: - Recognition

    /// The words in 16 kHz mono `samples`. `language` is an English name ("French"), or nil to let the model tell.
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let base = try await serverAddress()
        let prompt = language.map { "Perform ASR in \($0)." } ?? "Perform ASR."
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": Self.wav(samples, sampleRate: Int(Self.inputSampleRate)).base64EncodedString(), "format": "wav"]]]],
            ],
            "temperature": 0,
        ]
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let choice = (json?["choices"] as? [[String: Any]])?.first,
              let text = (choice["message"] as? [String: Any])?["content"] as? String
        else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw LFM3Error.server(message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The running server, starting it (and downloading first, the first time) if needed.
    /// HYPERCODE_LLAMA_URL points at a server that's already running instead.
    private func serverAddress() async throws -> URL {
        if let external = ProcessInfo.processInfo.environment["HYPERCODE_LLAMA_URL"].flatMap(URL.init(string:)) { return external }
        if let serverURL, server?.isRunning == true { return serverURL }
        if let starting { return try await starting.value }
        let task = Task { try await startServer() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func startServer() async throws -> URL {
        try await prepare()
        isStarting = true
        defer { isStarting = false }
        let port = ProcessInfo.processInfo.environment["HYPERCODE_LLAMA_PORT"].flatMap(Int.init) ?? Self.freePort()
        let process = Process()
        process.executableURL = Self.tools.appending(path: "llama-server")
        // One slot with an 8K context holds several minutes of speech; the model's own 128K would reserve gigabytes.
        process.arguments = ["-m", Self.model.path, "--mmproj", Self.projector.path, "--host", "127.0.0.1", "--port", String(port),
                             "-c", "8192", "-np", "1", "--no-webui"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { LFM3Audio.shared.serverExited() } }
        }
        try process.run()
        server = process
        serverPID = process.processIdentifier
        let url = URL(string: "http://127.0.0.1:\(port)")!
        // /health answers 503 while the model loads.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard process.isRunning else { throw LFM3Error.server("llama-server quit while loading the model.") }
            if let (_, response) = try? await URLSession.shared.data(from: url.appending(path: "health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                serverURL = url
                return url
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        throw LFM3Error.server("llama-server didn't start within two minutes.")
    }

    private func serverExited() {
        if server?.isRunning == false {
            server = nil
            serverURL = nil
            serverPID = 0
        }
    }

    /// A port nothing is listening on, from the kernel.
    nonisolated private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 18083
    }

    // MARK: - Speech

    /// One stretch of text as 24 kHz mono samples. `voice` is "female" or "male"; `language` a code from `speechLanguages`.
    func synthesize(_ text: String, voice: String, language: String) async throws -> [Float] {
        try await prepare()
        let output = FileManager.default.temporaryDirectory.appending(path: "hypercode-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try await Self.run(Self.tools.appending(path: "llama-tts").path, [
            "-m", Self.model.path, "-mm", Self.projector.path, "-p", text,
            "--tts-voice", voice, "--tts-lang", language, "-o", output.path,
        ])
        let file = try AVAudioFile(forReading: output)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: - Helpers

    /// Runs a tool to completion; cancelling the task stops it.
    nonisolated private static func run(_ path: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let reader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let log = String(decoding: await reader.value, as: UTF8.self)
            let last = log.split(separator: "\n").last.map(String.init) ?? ""
            throw LFM3Error.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)): \(last)")
        }
    }

    /// Mono samples at any rate, resampled to the 16 kHz the model hears.
    nonisolated static func resampled(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard sampleRate != inputSampleRate, !samples.isEmpty,
              let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * inputSampleRate / sampleRate) + 1024)
        else { return samples }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var given = false
        nonisolated(unsafe) let pending = input
        _ = converter.convert(to: output, error: nil) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return pending
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// 16-bit PCM WAV, what the server's `input_audio` takes.
    nonisolated static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}

/// The running `llama-server`, for the exit handler, which can't reach the main actor.
nonisolated(unsafe) private var serverPID: pid_t = 0

enum LFM3Error: LocalizedError {
    case server(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .server(let message), .tool(let message): message
        }
    }
}

/// Hands a download's progress and its file back from URLSession's queue.
nonisolated private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @MainActor (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, any Error>?
    private var lastReport = Date.distantPast

    init(progress: @escaping @MainActor (Int64, Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // A few updates a second is plenty for a progress label.
        guard Date().timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = Date()
        let progress = progress
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(totalBytesWritten, totalBytesExpectedToWrite) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so it moves somewhere that lasts first.
        let kept = FileManager.default.temporaryDirectory.appending(path: "hypercode-\(UUID().uuidString)")
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            finish(.failure(LFM3Error.server("Download failed with HTTP \(status).")))
        } else if (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
            finish(.success(kept))
        } else {
            finish(.failure(CocoaError(.fileWriteUnknown)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
