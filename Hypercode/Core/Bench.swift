#if DEBUG
import AVFoundation
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

extension Bench {
    /// HYPERCODE_TTS_FILE=<out.wav> synthesizes a sample reply with Pocket TTS, writes it as a WAV,
    /// prints load and generation times against the audio's length, and quits. Nothing is played.
    static func synthesizeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["HYPERCODE_TTS_FILE"] else { return }
        let text = Speaker.spokenText("""
        Done. The home screen now shows the next seven days under the current conditions.

        I reused the data the service already fetches, so there's no extra network call. All twenty-four tests pass.
        """)
        Task {
            do {
                let start = Date()
                let sampleRate = try await PocketVoice.shared.load()
                let loaded = Date()
                var samples: [Float] = []
                var firstChunk: TimeInterval?
                for chunk in Speaker.chunks(of: text) {
                    samples += try await PocketVoice.shared.synthesize(chunk, voice: "alba")
                    if firstChunk == nil { firstChunk = Date().timeIntervalSince(loaded) }
                }
                let generation = Date().timeIntervalSince(loaded)
                let seconds = Double(samples.count) / Double(sampleRate)
                let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
                try file.write(from: buffer)
                print(String(format: "TTS load=%.1fs first-sentence=%.2fs generated=%.2fs audio=%.1fs speed=%.1fx realtime rms=%.3f rate=%d",
                             loaded.timeIntervalSince(start), firstChunk ?? 0, generation, seconds, seconds / generation, rms, sampleRate))
            } catch {
                print("TTS failed: \(error)")
            }
            exit(0)
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
