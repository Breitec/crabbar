import Foundation

#if os(macOS)

/// Fenced blocks in Clawd's replies that the app acts on; the rest is the text shown in the chat.
public enum ReplyAction: Equatable, Sendable {
  case remind(Date, String)
  case remindCancel(String)
  case list(kind: String, list: String, item: String)
  case task(name: String, head: [String: String], prompt: String)
  case taskBad(name: String)
  case taskRemove(String)
}

public struct ParsedReply: Equatable, Sendable {
  public var text: String
  public var run: String?
  public var actions: [ReplyAction]
}

public enum ReplyBlocks {
  static let pattern = #"(?ms)^```(run|remind|remind-cancel|list-add|list-check|list-uncheck|list-remove|task|task-remove)[ \t]*\r?\n(.*?)^```[ \t]*$"#

  public static func parse(_ reply: String) -> ParsedReply {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return ParsedReply(text: reply, run: nil, actions: []) }
    let ns = reply as NSString
    var run: String?
    var actions: [ReplyAction] = []
    for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
      let kind = ns.substring(with: m.range(at: 1))
      let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
      let lines = body.components(separatedBy: .newlines)
      switch kind {
      case "run":
        if !body.isEmpty { run = body }
      case "remind":
        for line in lines {
          let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
          guard parts.count == 2, let at = Format.parseISO(parts[0]), !parts[1].isEmpty else { continue }
          actions.append(.remind(at, parts[1]))
        }
      case "remind-cancel":
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
          actions.append(.remindCancel(line.trimmingCharacters(in: .whitespaces)))
        }
      case "task":
        let split = body.components(separatedBy: "\n").firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }
        guard let i = split else { actions.append(.taskBad(name: "")); continue }
        let headLines = body.components(separatedBy: "\n")[..<i].joined(separator: "\n")
        let prompt = body.components(separatedBy: "\n")[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let head = ClawdHome.keyValues(headLines)
        let name = head["name"] ?? ""
        if name.isEmpty || ClawdHome.parseEvery(head["every"] ?? "") == nil || prompt.isEmpty {
          actions.append(.taskBad(name: name))
        } else {
          actions.append(.task(name: name, head: head, prompt: prompt))
        }
      case "task-remove":
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
          actions.append(.taskRemove(line.trimmingCharacters(in: .whitespaces)))
        }
      default:
        for line in lines {
          let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
          guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
          actions.append(.list(kind: kind, list: ClawdHome.safeName(parts[0]), item: parts[1]))
        }
      }
    }
    let rest = re.stringByReplacingMatches(in: reply, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    return ParsedReply(text: plain(rest), run: run, actions: actions)
  }

  /// The panel shows plain text: drop bold and inline code marks.
  public static func plain(_ s: String) -> String {
    s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
      .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
      .replacingOccurrences(of: #"(\r?\n){3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// What a refused call would need as a permission rule: a command by its first words, a page by its site.
  public static func deniedRule(tool: String, input: [String: Any]) -> String? {
    if tool == "Bash" || tool == "PowerShell", let cmd = input["command"] as? String {
      var words: [String] = []
      for w in cmd.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace) {
        if words.count >= 3 || w.hasPrefix("-") || w.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\"'$|;&<>(){}=")) != nil { break }
        words.append(String(w))
      }
      return words.isEmpty ? nil : "\(tool)(\(words.joined(separator: " ")):*)"
    }
    if tool == "WebFetch", let u = input["url"] as? String {
      if let host = URL(string: u)?.host { return "WebFetch(domain:\(host))" }
      return "WebFetch"
    }
    if ["Write", "Edit", "NotebookEdit"].contains(tool) { return nil }
    return tool
  }
}
#endif
