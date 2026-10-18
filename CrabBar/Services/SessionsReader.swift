import Foundation
import Darwin
import ClawdCore

/// Claude Code keeps a registry of running sessions in sessions/<pid>.json of its folder (~/.claude or
/// CLAUDE_CONFIG_DIR). Files outlive their processes, so a file only counts if its PID is alive and started
/// when the file says (±5 s).
enum SessionsReader {
  static var dir: URL { ClaudeConfig.sessions }

  static func startTime(_ pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
  }

  static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

  /// "Fri Oct 16 11:36:17 2026": Claude Code writes it as UTC without a zone; accept local too in case that changes.
  static func parseProcStart(_ s: String) -> [Date] {
    let norm = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return [TimeZone(identifier: "UTC")!, TimeZone.current].compactMap { tz in
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = tz
      f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
      return f.date(from: norm)
    }
  }

  static func read() -> [ClaudeSession] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var out: [ClaudeSession] = []
    for u in files where u.pathExtension == "json" {
      guard let d = try? Data(contentsOf: u),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let pidN = j["pid"] as? NSNumber else { continue }
      let pid = pid_t(pidN.int32Value)
      if pid <= 0 || Proc.isOwn(pid) || !alive(pid) { continue }
      if let ps = j["procStart"] as? String, let real = startTime(pid) {
        let wants = parseProcStart(ps)
        if !wants.isEmpty && !wants.contains(where: { abs(real.timeIntervalSince($0)) <= 5 }) { continue }
      }
      let cwd = (j["cwd"] as? String) ?? ""
      var name = (j["name"] as? String) ?? ""
      if name.isEmpty { name = (cwd as NSString).lastPathComponent }
      let status = (j["status"] as? String) ?? ""
      out.append(ClaudeSession(pid: pid, name: name, cwd: cwd, busy: status == "busy", waiting: status == "waiting",
                               waitingFor: (j["waitingFor"] as? String) ?? "", kind: (j["kind"] as? String) ?? "",
                               sessionId: (j["sessionId"] as? String) ?? ""))
    }
    return out.sorted { $0.pid < $1.pid }
  }
}
