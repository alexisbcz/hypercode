#if DEBUG
import Foundation

/// HYPERCODE_REPLAY=<stream-json file> plays a recorded `claude` stream into a new session at a steady pace,
/// then prints how long the main thread stalled while it rendered, for comparing changes by numbers.
enum Bench {
    static func replayIfRequested(into store: Store) {
        guard let path = ProcessInfo.processInfo.environment["HYPERCODE_REPLAY"],
              let data = FileManager.default.contents(atPath: path)
        else { return }
        let events = data.split(separator: 0x0A).compactMap { JSON.parse(Data($0)) }
        let interval = Double(ProcessInfo.processInfo.environment["HYPERCODE_REPLAY_MS"] ?? "8").map { $0 / 1000 } ?? 0.008

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let project = store.projects.first else { return }
            let session = Session(project: project, title: "Replay")
            store.sessions[project.id, default: []].append(session)
            store.selection = session.id
            // HYPERCODE_REPLAY_SEED=<session .jsonl> starts from a long history, as a real session would.
            if let seed = ProcessInfo.processInfo.environment["HYPERCODE_REPLAY_SEED"] {
                session.entries = Transcript.entries(at: URL(fileURLWithPath: seed)).entries
            }
            session.beginReplay("Write a long markdown guide to SwiftUI performance.")
            let watchdog = Watchdog()
            watchdog.start()
            let start = Date()
            @MainActor func step(_ index: Int) {
                guard index < events.count else {
                    // Let the last frames land before reading the numbers.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let report = watchdog.stop()
                        let elapsed = Date().timeIntervalSince(start)
                        print("BENCH events=\(events.count) wall=\(String(format: "%.2f", elapsed))s \(report)")
                        exit(0)
                    }
                    return
                }
                session.replay(events[index])
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { MainActor.assumeIsolated { step(index + 1) } }
            }
            step(0)
        }
    }
}

/// Pings the main queue from a background thread and records how late each ping runs.
nonisolated private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lateness: [Double] = []
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = Date()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let late = Date().timeIntervalSince(sent) * 1000
                lock.withLock { lateness.append(late) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() -> String {
        lock.withLock { running = false }
        let samples = lock.withLock { lateness }.sorted()
        guard !samples.isEmpty else { return "no samples" }
        let p = { (q: Double) in samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        let stalls = samples.filter { $0 > 33 }
        return String(format: "p50=%.1fms p95=%.1fms max=%.0fms stalls>33ms=%d stalled=%.0fms",
                      p(0.5), p(0.95), samples.last!, stalls.count, stalls.reduce(0, +))
    }
}
#endif
