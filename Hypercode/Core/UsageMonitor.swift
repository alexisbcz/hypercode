import Foundation
import Observation

/// Claude plan limits (from Anthropic's usage API, with Claude Code's own login)
/// and this week's token use per day (from the local session logs).
@Observable
final class UsageMonitor {
    struct Window: Equatable {
        var percent: Double
        var resetsAt: Date?
    }

    struct Day: Identifiable, Equatable {
        var date: Date
        var tokens: Int
        var messages: Int
        var id: Date { date }
    }

    private(set) var session: Window?
    private(set) var weekly: Window?
    private(set) var weeklyByModel: [(name: String, window: Window)] = []
    private(set) var days: [Day] = []
    private(set) var updatedAt: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false

    @ObservationIgnored private let ledger = UsageLedger()
    @ObservationIgnored private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
    }

    var todayTokens: Int { days.last?.tokens ?? 0 }
    var weekTokens: Int { days.reduce(0) { $0 + $1.tokens } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let limits = Self.fetchLimits()
        let ledger = ledger
        async let week = Task.detached { ledger.lastSevenDays() }.value

        days = await week
        switch await limits {
        case .success(let usage):
            session = usage.session
            weekly = usage.weekly
            weeklyByModel = usage.byModel
            error = nil
            updatedAt = .now
        case .failure(let failure):
            error = failure.message
        }
        #if DEBUG
        // HYPERCODE_USAGE_SNAPSHOT=<dir> renders the status item and popover to PNGs, for checking by eye.
        if let dir = ProcessInfo.processInfo.environment["HYPERCODE_USAGE_SNAPSHOT"] {
            writeSnapshots(to: URL(fileURLWithPath: dir))
        }
        #endif
    }

    // MARK: - Plan limits

    private struct Limits {
        var session: Window?
        var weekly: Window?
        var byModel: [(name: String, window: Window)]
    }

    private struct Failure: Error { let message: String }

    nonisolated private static func fetchLimits() async -> Result<Limits, Failure> {
        guard let token = accessToken() else {
            return .failure(Failure(message: "Sign in to Claude Code to see plan limits."))
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(Failure(message: "Couldn't reach Anthropic.")) }
        guard http.statusCode == 200, let json = JSON.parse(data) else {
            return .failure(Failure(message: http.statusCode == 401
                ? "Login expired. Run Claude Code once to refresh it."
                : "Usage API returned \(http.statusCode)."))
        }

        func window(_ key: String) -> Window? {
            guard let w = json[key], case .number(let percent)? = w["utilization"] else { return nil }
            return Window(percent: percent, resetsAt: w["resets_at"]?.string.flatMap(parseDate))
        }
        let models = [("Opus", "seven_day_opus"), ("Sonnet", "seven_day_sonnet")]
            .compactMap { name, key in window(key).map { (name: name, window: $0) } }
        return .success(Limits(session: window("five_hour"), weekly: window("seven_day"), byModel: models))
    }

    /// Reads Claude Code's OAuth token through `security`, the same way Claude Code does,
    /// so macOS doesn't ask the user to grant this app access to the keychain item.
    nonisolated private static func accessToken() -> String? {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let json = JSON.parse(data) else { return nil }
        return json["claudeAiOauth"]?["accessToken"]?.string
    }

    nonisolated private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Tallies assistant-message tokens per local day from ~/.claude/projects.
/// Logs are append-only, so each file is read once and then only from where it left off.
nonisolated final class UsageLedger: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64
        var seen: Set<String>
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var buckets: [Date: (tokens: Int, messages: Int)] = [:]

    func lastSevenDays() -> [UsageMonitor.Day] {
        lock.lock()
        defer { lock.unlock() }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        scan(since: start)

        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let bucket = buckets[day] ?? (0, 0)
            return UsageMonitor.Day(date: day, tokens: bucket.tokens, messages: bucket.messages)
        }
    }

    private func scan(since start: Date) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= start,
                  let size = values.fileSize
            else { continue }
            var state = files[url.path] ?? FileState(offset: 0, seen: [])
            guard UInt64(size) > state.offset else { continue }
            read(url, from: &state, since: start)
            files[url.path] = state
        }
    }

    private static let needle = Array(#""usage":{"#.utf8)
    private let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func read(_ url: URL, from state: inout FileState, since start: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)

        var pending = Data()
        var done = false
        while !done {
            // Drain Foundation temporaries per chunk; a first scan reads gigabytes.
            done = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return true }
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    consume(pending[lineStart..<newline], state: &state, since: start)
                    lineStart = pending.index(after: newline)
                }
                state.offset += UInt64(lineStart - pending.startIndex)
                pending.removeSubrange(pending.startIndex..<lineStart)
                return false
            }
        }
        // A trailing partial line is left for next time, when it's complete.
    }

    private func consume(_ line: Data, state: inout FileState, since start: Date) {
        // Most bytes are request blobs and tool output; only lines carrying usage are worth decoding.
        let hasUsage = line.withUnsafeBytes { raw in
            Self.needle.withUnsafeBytes { memmem(raw.baseAddress, raw.count, $0.baseAddress, $0.count) != nil }
        }
        guard hasUsage, let json = JSON.parse(line), json["type"]?.string == "assistant",
              let message = json["message"], let usage = message["usage"],
              let stamp = json["timestamp"]?.string, let date = dayFormatter.date(from: stamp), date >= start
        else { return }

        // Streaming writes one line per content block, all repeating the message's usage.
        let key = (message["id"]?.string ?? "") + (json["requestId"]?.string ?? "")
        guard state.seen.insert(key).inserted else { return }

        func count(_ k: String) -> Int {
            if case .number(let n)? = usage[k] { return Int(n) }
            return 0
        }
        let tokens = count("input_tokens") + count("output_tokens")
            + count("cache_creation_input_tokens") + count("cache_read_input_tokens")
        let day = Calendar.current.startOfDay(for: date)
        buckets[day, default: (0, 0)].tokens += tokens
        buckets[day, default: (0, 0)].messages += 1
    }
}
