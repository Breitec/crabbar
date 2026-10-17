import Foundation
import Darwin
import ClawdCore

/// Optional: keeps Clawd's own interactive Claude Code session running in his home with Remote Control,
/// so the user can talk to him from the phone. Hidden on a pseudo terminal once the folder is trusted;
/// the first time it opens in Terminal so the trust question can be answered.
@MainActor
final class ClawdSessionKeeper {
  struct Saved: Codable { var sessionId: String? }

  weak var model: AppModel?
  private(set) var sessionId: String?
  private var pty: PtyProc?
  private var startedAt: Date?
  private var misses = 0

  init(model: AppModel) {
    self.model = model
    if let d = try? Data(contentsOf: AppPaths.clawd), let s = try? JSONDecoder().decode(Saved.self, from: d) {
      sessionId = s.sessionId
    }
  }

  private func persist() {
    if let d = try? JSONEncoder().encode(Saved(sessionId: sessionId)) { try? d.write(to: AppPaths.clawd, options: .atomic) }
  }

  var name: String {
    let n = model?.config.clawdSessionName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return n.isEmpty ? "crabbar" : n
  }

  var projectKey: String {
    (model?.home.url.path ?? "").replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
  }

  var trusted: Bool {
    guard let home = model?.home.url.path else { return false }
    let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    guard let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let projects = j["projects"] as? [String: Any], let p = projects[home] as? [String: Any] else { return false }
    return (p["hasTrustDialogAccepted"] as? Bool) == true
  }

  /// Clawd's sessions in the registry: in his home, by name (or any interactive one there, as in the original).
  func mine(_ all: [ClaudeSession]) -> [ClaudeSession] {
    guard let home = model?.home.url.path else { return [] }
    return all.filter { $0.cwd == home && ($0.name == name || $0.kind == "interactive") }
  }

  func update(allSessions: [ClaudeSession]) {
    guard let model else { return }
    if pty?.reap() == true { pty = nil }
    guard model.config.clawdSession else {
      stop()
      misses = 0
      return
    }
    let found = mine(allSessions)
    if let s = found.first(where: { $0.name == name }) ?? found.first {
      if !s.sessionId.isEmpty && s.sessionId != sessionId { sessionId = s.sessionId; persist() }
      misses = 0
      return
    }
    if let p = pty, !p.reap() { return }
    if let st = startedAt, Date().timeIntervalSince(st) < 180 { return }
    if misses >= 3 { return }
    misses += 1
    start()
  }

  /// Ends every registered Clawd session (also one started in Terminal); the next tick starts a fresh one.
  func restart() {
    stop()
    for s in mine(model?.rawSessions ?? []) {
      let pid = s.pid
      Darwin.kill(pid, SIGTERM)
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
      }
    }
    misses = 0
    startedAt = Date().addingTimeInterval(-170)
  }

  private func start() {
    guard let model, let bin = model.claude else { return }
    stop()
    var args = ["-n", name, "--remote-control", name, "--append-system-prompt-file", Prompts.session.path]
    if let id = sessionId {
      let t = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(projectKey)/\(id).jsonl")
      if FileManager.default.fileExists(atPath: t.path) { args += ["--resume", id] }
    }
    startedAt = Date()
    if trusted {
      pty = try? PtyProc.spawn(bin.path, args, cwd: model.home.url.path)
    } else {
      let quoted = ([bin.path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
      Terminal.run(command: quoted, title: "Clawd", cwd: model.home.url.path)
    }
  }

  func stop() {
    pty?.terminate()
    pty = nil
  }
}
