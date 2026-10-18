import Foundation

#if os(macOS)

/// Claude Code's own folder (sessions, projects, settings.json): CLAUDE_CONFIG_DIR if it is set, ~/.claude
/// otherwise. Every path into it goes through here, as `Get-ClaudeConfigDir` in the original.
public enum ClaudeConfig {
  /// CLAUDE_CONFIG_DIR from the user's login shell: an app started by launchd does not inherit shell
  /// variables, so the app reads it once at start, together with PATH.
  nonisolated(unsafe) public static var shellValue: String?

  /// The value in effect: the app's own environment first (started from a terminal), then the login shell's.
  public static var value: String? {
    for v in [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], shellValue] {
      let t = (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { return t }
    }
    return nil
  }

  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// The folder a CLAUDE_CONFIG_DIR value names: a leading ~ is the home folder, a trailing slash is dropped.
  /// nil when it is unset or not an absolute path: the app and the claude processes it starts would resolve
  /// a relative one against different working folders, so that counts as unset.
  public static func custom(_ value: String?, home: URL) -> URL? {
    var v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if v == "~" || v.hasPrefix("~/") { v = home.path + v.dropFirst() }
    while v.count > 1 && v.hasSuffix("/") { v.removeLast() }
    guard v.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: v, isDirectory: true).standardized
  }

  public static func dir(_ value: String?, home: URL) -> URL {
    custom(value, home: home) ?? home.appendingPathComponent(".claude")
  }

  /// Claude Code's global config (trusted folders): .claude.json inside that folder when CLAUDE_CONFIG_DIR is
  /// set, next to ~/.claude otherwise.
  public static func globalConfig(_ value: String?, home: URL) -> URL {
    custom(value, home: home)?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json")
  }

  /// The moved folder in effect, nil for ~/.claude. Child processes get its normalized path.
  public static var custom: URL? { custom(value, home: home) }
  public static var dir: URL { dir(value, home: home) }
  public static var globalConfig: URL { globalConfig(value, home: home) }
  public static var sessions: URL { dir.appendingPathComponent("sessions") }
  public static var projects: URL { dir.appendingPathComponent("projects") }
  public static var settings: URL { dir.appendingPathComponent("settings.json") }

  /// The folder name Claude Code gives a working directory under projects/.
  public static func projectKey(_ path: String) -> String {
    path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
  }

  /// The transcript of a session that ran in `cwd`.
  public static func transcript(cwd: String, sessionId: String) -> URL {
    projects.appendingPathComponent(projectKey(cwd)).appendingPathComponent("\(sessionId).jsonl")
  }
}
#endif
