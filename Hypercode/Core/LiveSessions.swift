import Darwin
import Foundation

/// Reads the status files each running `claude` process keeps in ~/.claude/sessions/<pid>.json,
/// so sessions driven from a terminal (or by an earlier Hypercode launch) show as working too.
nonisolated enum LiveSessions {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/sessions", directoryHint: .isDirectory)

    /// IDs of sessions whose process is alive and mid-turn.
    static func busy() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var ids: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let status = JSON.parse(data),
                  status["status"]?.string == "busy", let id = status["sessionId"]?.string,
                  case .number(let pid)? = status["pid"], isAlive(pid_t(pid))
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// A crashed process leaves its file behind, still saying busy.
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
