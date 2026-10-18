import Foundation
import ClawdCore

struct ChatMessage: Codable, Identifiable, Equatable {
  struct Run: Codable, Equatable {
    var script: String
    var state: String      // pending | running | done | skipped | replaced
    var code: Int32?
  }
  struct Grant: Codable, Equatable {
    var task: String
    var rules: [String]
    var state: String      // pending | granted | skipped | gone | changed
    var kind: String?      // nil: rules a run was refused; "approve": tools a task file asks for
    var fingerprint: String?  // the task content the card was shown for
    var prompt: String?       // that content as the card shows it: the whole text, hidden characters visible
    var info: String?         // when it runs and with which model
  }
  struct Call: Codable, Equatable {
    var tool: String
    var input: String
  }
  struct Act: Codable, Equatable {
    var state: String      // pending | approved | skipped | replaced
    var calls: [Call]
  }

  var id = UUID()
  var role: String         // user | clawd | note | remind
  var text: String
  var at = Date()
  var task: String?
  var run: Run?
  var grant: Grant?
  var act: Act?
  var remote = false
}

/// Talking to Clawd: every message is one headless `claude -p` call in a conversation of its own
/// (--session-id first, then --resume). Claude may look around but not change anything; changes come
/// as a `run` script the user approves with a click.
@MainActor
@Observable
final class ChatController {
  struct State: Codable {
    var sessionId = UUID().uuidString.lowercased()
    var started = false
    var since = Date.distantPast
    var messages: [ChatMessage] = []
  }

  @ObservationIgnored weak var model: AppModel?
  var state = State()
  var busySince: Date?
  var runningScript = false
  var unread = false
  var remote: [ChatMessage] = []
  @ObservationIgnored var proc: Proc?
  @ObservationIgnored var autoChain = 0
  @ObservationIgnored var remotePath = ""
  @ObservationIgnored var remoteOffset: UInt64 = 0
  static let keep = 60
  static let autoChainMax = 3
  static let readVerbs = ["list", "get", "read", "search", "fetch", "find", "query", "view", "show"]

  init(model: AppModel) {
    self.model = model
    if let d = try? Data(contentsOf: AppPaths.chat) {
      let dec = JSONDecoder()
      dec.dateDecodingStrategy = .iso8601
      if var s = try? dec.decode(State.self, from: d) {
        for i in s.messages.indices where s.messages[i].run?.state == "running" { s.messages[i].run?.state = "done" }
        state = s
      }
    }
  }

  var busy: Bool { busySince != nil || runningScript }

  @ObservationIgnored var scriptProc: Proc?
  /// App messages (script output, approvals) that arrived while Claude was still answering.
  @ObservationIgnored var queued: [(String, [String])] = []

  var transcriptExists: Bool {
    guard let home = model?.home else { return false }
    return FileManager.default.fileExists(atPath: ClaudeConfig.transcript(cwd: home.url.path, sessionId: state.sessionId).path)
  }

  /// Local and phone messages in one feed, in time order.
  var feed: [ChatMessage] {
    (state.messages + remote).sorted { $0.at < $1.at }
  }

  /// Demo mode: messages live in memory only.
  @ObservationIgnored var demo = false

  func save() {
    if demo { return }
    if state.messages.count > Self.keep { state.messages.removeFirst(state.messages.count - Self.keep) }
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(state) { try? d.write(to: AppPaths.chat, options: .atomic) }
    writeLog()
  }

  /// The panel's conversation as a file in Clawd's home, so his phone session knows what was said here.
  func writeLog() {
    guard let home = model?.home else { return }
    var lines = ["# Chat in the app panel", "",
                 "The user talks to Clawd here too: in the panel of the CrabBar menu bar app on the Mac.",
                 "Written by the app, latest at the bottom; do not edit.", ""]
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    for m in state.messages where ["user", "clawd", "remind"].contains(m.role) {
      let who = ["user": "User", "clawd": "Clawd", "remind": "Reminder fired"][m.role]!
      var text = m.text
      if let r = m.run { text += "\n[proposed a script: \(r.state)\(r.code.map { ", exit \($0)" } ?? "")]" }
      if let a = m.act { text += "\n[asked to use \(a.calls.map(\.tool).joined(separator: ", ")): \(a.state)]" }
      lines += ["**\(who)** \(f.string(from: m.at))", text, ""]
    }
    try? lines.joined(separator: "\n").write(to: home.url.appendingPathComponent("chat-log.md"), atomically: true, encoding: .utf8)
  }

  @discardableResult
  func add(_ role: String, _ text: String, run: ChatMessage.Run? = nil, task: String? = nil) -> UUID {
    var m = ChatMessage(role: role, text: text)
    m.run = run
    m.task = task
    state.messages.append(m)
    save()
    return m.id
  }

  func index(_ id: UUID) -> Int? { state.messages.firstIndex { $0.id == id } }

  // MARK: - context

  /// `forTask` - for a task's run: Auto is for the chat only, a task's run block always waits for the click.
  func context(forTask: Bool = false) -> String {
    guard let model else { return "" }
    let auto = forTask ? "off for tasks - a run block waits for the user's click"
      : model.config.chatAutoRun ? "on - your run scripts start at once, without the user's click" : "off"
    var lines = ["<context>", "now: \(Format.contextNow())", "auto-run: " + auto]
    let tips = model.advisor.tips
    if tips.isEmpty { lines.append("tips: none") } else {
      lines.append("tips:")
      for t in tips {
        lines.append("- \(t.text)")
        if !t.ctx.isEmpty { lines.append("  details: \(t.ctx)") }
      }
    }
    let rem = model.home.activeReminders()
    if rem.isEmpty { lines.append("reminders: none") } else {
      lines.append("reminders (file in the reminders folder - time - text):")
      for r in rem {
        let rep = r.repeats.map { " (repeats \($0.rawValue))" } ?? ""
        lines.append("- \(r.rel) - \(Format.iso(r.at).replacingOccurrences(of: "T", with: " "))\(rep) - \(r.text)")
      }
    }
    let names = model.home.listNames(defaultName: T("lists.default"))
    if !names.isEmpty {
      lines.append("lists (files in the lists folder; \"[x]\" - ticked off):")
      for n in names {
        let items = model.home.readList(n).items.map { ($0.done ? "[x] " : "") + $0.text }
        lines.append("- \(n): " + (items.isEmpty ? "empty" : items.joined(separator: "; ")))
      }
    }
    let tasks = model.home.taskFiles()
    if !tasks.isEmpty {
      lines.append("recurring tasks (files in the tasks folder):")
      for t in tasks {
        let last = model.tasks.state[t.name]?.last.map { Format.local($0, "MMdd HH:mm") } ?? "never"
        var s = "- \(t.name): " + (t.at != nil ? "at \(t.atText)" : "every \(t.everyText)")
        if !t.tools.isEmpty { s += ", tools \(t.tools.joined(separator: " "))" }
        if let h = t.hours { s += ", hours \(h.0)-\(h.1)" }
        if t.paused { s += ", paused" }
        s += ", last run \(last) - " + t.prompt.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        lines.append(s)
      }
    }
    let since = Date().addingTimeInterval(-86400)
    let reports = state.messages.filter { $0.task != nil && $0.at > since }.suffix(5)
    if !reports.isEmpty {
      lines.append("recent reports of your recurring tasks, shown to the user in this chat (the user may be replying to them):")
      for m in reports {
        var t = m.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if t.count > 800 { t = String(t.prefix(800)) + "..." }
        lines.append("- \(Format.local(m.at, "MMdd HH:mm")) \(t)")
      }
    }
    let recent = remote.suffix(12)
    if !recent.isEmpty {
      lines.append("recent conversation in your own session (the user on the phone via Remote Control):")
      for m in recent {
        var t = m.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if t.count > 400 { t = String(t.prefix(400)) + "..." }
        lines.append("- \(Format.local(m.at, "MMdd HH:mm")) \(m.role == "user" ? "user" : "you"): \(t)")
      }
    }
    lines.append("</context>")
    return lines.joined(separator: "\n")
  }

  /// The chat's rules for the tasks' tools: in auto mode the whole server, otherwise only what reads.
  func toolRules(_ tools: [String]) -> [String] {
    var rules: [String] = []
    for t in tools {
      if model?.config.chatAutoRun == true || !t.hasPrefix("mcp__") || t.range(of: #"^mcp__.+__"#, options: .regularExpression) != nil {
        rules.append(t)
        continue
      }
      for v in Self.readVerbs { rules.append("\(t)__\(v)_*") }
    }
    return rules
  }

  // MARK: - sending

  /// `hidden` - a message from the app itself (a script's output), not shown as the user's.
  /// `allow` - tools allowed for this one call only (actions the user just approved).
  func send(_ text: String, hidden: Bool = false, allow: [String] = []) {
    guard let model, let bin = model.claude, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if busySince != nil {
      if hidden { queued.append((text, allow)) }
      return
    }
    if !hidden && runningScript { return }
    if !hidden {
      for i in state.messages.indices {
        if state.messages[i].run?.state == "pending" { state.messages[i].run?.state = "replaced" }
        if state.messages[i].act?.state == "pending" { state.messages[i].act?.state = "replaced" }
      }
      autoChain = 0
      add("user", text)
    }
    let tools = model.tasks.approvedTools()
    var ctx = context()
    if !tools.isEmpty {
      let how = model.config.chatAutoRun ? "all of them at once" : "reading at once; actions after the user approves them"
      ctx = ctx.replacingOccurrences(of: "</context>", with: "tools you may use besides reading: \(tools.joined(separator: " ")) (\(how))\n</context>")
    }
    var args = ["-p", "--output-format", "json", "--model", model.config.chatModel, "--permission-mode", "default"]
    if tools.isEmpty { args.append("--strict-mcp-config") }
    args += ["--disallowedTools", "Write", "Edit", "NotebookEdit", "--append-system-prompt-file", Prompts.chat.path,
             "--allowedTools"] + Prompts.readOnlyRules + toolRules(tools) + allow
    // A first call that failed may still have left its transcript; then the id is taken and must be resumed.
    if !state.started && transcriptExists { state.started = true }
    args += state.started ? ["--resume", state.sessionId] : ["--session-id", state.sessionId]
    busySince = Date()
    let input = (ctx + "\n\n" + text).data(using: .utf8)
    let timeout = model.config.chatTimeoutSeconds
    Task {
      do {
        let p = try Proc.spawn(bin.path, args, cwd: model.home.url.path, stdin: input)
        proc = p
        let o = await p.wait(timeout: timeout)
        proc = nil
        busySince = nil
        if transcriptExists { state.started = true; save() }
        collect(o, timeout: timeout)
      } catch {
        busySince = nil
        add("note", T("chat.error", "\(error)"))
      }
      if !queued.isEmpty {
        let (t, a) = queued.removeFirst()
        send(t, hidden: true, allow: a)
      }
    }
  }

  func cancel() { proc?.kill() }

  func collect(_ o: Proc.Output, timeout: TimeInterval) {
    guard let model else { return }
    if o.timedOut {
      add("note", T("chat.timeout", Int(timeout)))
      return
    }
    let j = try? JSONSerialization.jsonObject(with: o.out) as? [String: Any]
    if let j, (j["is_error"] as? Bool) != true, let result = j["result"] as? String {
      state.started = true
      let r = ReplyBlocks.parse(result)
      let notes = apply(r.actions)
      let calls: [ChatMessage.Call] = ((j["permission_denials"] as? [[String: Any]]) ?? []).compactMap { d in
        guard let tool = d["tool_name"] as? String, tool.hasPrefix("mcp__") else { return nil }
        let input = (try? JSONSerialization.data(withJSONObject: d["tool_input"] ?? [:], options: [.sortedKeys]))
          .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return .init(tool: tool, input: input)
      }
      var msgId: UUID?
      if !r.text.isEmpty || r.run != nil || !calls.isEmpty {
        msgId = add("clawd", r.text, run: r.run.map { .init(script: $0, state: "pending") })
      }
      if !calls.isEmpty, let id = msgId, let i = index(id) {
        state.messages[i].act = .init(state: "pending", calls: calls)
        save()
      }
      for n in notes { add("note", n) }
      if let id = msgId, r.run != nil, model.config.chatAutoRun {
        if autoChain < Self.autoChainMax { autoChain += 1; runScript(id) }
        else { add("note", T("chat.autoStop", Self.autoChainMax)) }
      }
    } else {
      var why = (j?["result"] as? String) ?? ""
      if why.isEmpty { why = o.errText.trimmingCharacters(in: .whitespacesAndNewlines) }
      if why.isEmpty { why = "exit \(o.code)" }
      if why.count > 300 { why = String(why.prefix(300)) + "…" }
      add("note", T("chat.error", why))
    }
    if !model.panelOpen {
      unread = true
      if model.config.showMascot { model.mascot.wave() }
    }
    model.onChange?()
  }

  /// Applies remind/list/task blocks and returns the notes to show.
  func apply(_ actions: [ReplyAction]) -> [String] {
    guard let home = model?.home else { return [] }
    var notes: [String] = []
    for a in actions {
      switch a {
      case .remind(let at, let text, let rep):
        home.newReminder(at: at, text: text, repeats: rep)
        notes.append(T("chat.remindSet", Format.remindTime(at) + (rep.map { ", " + $0.label } ?? ""), text))
      case .remindCancel(let name):
        if let r = home.removeReminder(name) { notes.append(T("chat.remindCancel", r.text)) }
      case .list(let kind, let list, let item):
        var ok = true
        switch kind {
        case "list-add": home.addListItems(list, item)
        case "list-check": ok = home.setListItem(list, text: item, done: true)
        case "list-uncheck": ok = home.setListItem(list, text: item, done: false)
        default: ok = home.removeListItem(list, text: item)
        }
        if ok { notes.append(T("chat.\(kind)", list, item)) }
      case .task(let name, var head, let prompt):
        // Only well-formed permission rules survive; the task runs them only after the user approved them.
        let asked = ClawdHome.splitTools(head["tools"] ?? "")
        let ok = asked.filter(ClawdHome.isValidToolRule)
        let dropped = asked.filter { !ClawdHome.isValidToolRule($0) }
        head["tools"] = ok.joined(separator: " ")
        // A block that leaves out paused or limit keeps them. One that unpauses a paused task takes its
        // approval back: `paused` is not part of what an approval holds for. Found ignoring case, as the file is.
        let old = home.task(named: ClawdHome.safeName(name))
        let merged = ClawdHome.mergedHead(head, over: old)
        head = merged.head
        if home.newTask(name: name, head: head, prompt: prompt) != nil {
          if merged.resumes, let old { model?.tasks.revoke(old.name) }
          let when = ClawdHome.whenText(every: ClawdHome.parseEvery(head["every"] ?? ""), at: ClawdHome.parseAt(head["at"] ?? ""))
          notes.append(T("chat.taskSet", name, when))
        }
        if !dropped.isEmpty { notes.append(T("chat.taskDropped", dropped.joined(separator: " "))) }
      case .taskBad(let name):
        notes.append(T("chat.taskBad", name))
      case .taskRemove(let name):
        if let t = home.removeTask(name) {
          model?.tasks.forget(t.name)
          notes.append(T("chat.taskRemove", t.name))
        }
      }
    }
    return notes
  }

  // MARK: - approved scripts and tool calls

  func runScript(_ id: UUID) {
    guard let i = index(id), let run = state.messages[i].run, run.state == "pending", !runningScript, busySince == nil else { return }
    state.messages[i].run?.state = "running"
    runningScript = true
    save()
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-run-\(UUID().uuidString.prefix(8)).sh")
    try? ("export LANG=en_US.UTF-8\n" + run.script + "\n").write(to: u, atomically: true, encoding: .utf8)
    Task {
      // Approved scripts run without a deadline, as in the original; the panel has a stop button.
      var o: Proc.Output
      do {
        let p = try Proc.spawn("/bin/zsh", ["-f", u.path], cwd: model?.home.url.path)
        scriptProc = p
        o = await p.wait(timeout: 24 * 3600)
      } catch {
        o = Proc.Output(code: -1, out: Data(), err: "\(error)".data(using: .utf8)!, timedOut: false)
      }
      scriptProc = nil
      try? FileManager.default.removeItem(at: u)
      runningScript = false
      if let i = index(id) {
        state.messages[i].run?.state = "done"
        state.messages[i].run?.code = o.code
      }
      save()
      var text = (o.text + o.errText).trimmingCharacters(in: .whitespacesAndNewlines)
      if text.count > 3000 { text = "…" + String(text.suffix(3000)) }
      let stopped = o.timedOut || stopRequested
      stopRequested = false
      if stopped { add("note", T("chat.runStopped")) }
      send("[run result] exit code \(o.code)\(stopped ? " (stopped by the user before it finished)" : "")\n\(text)", hidden: true)
      model?.advisor.scan()
    }
  }

  @ObservationIgnored var stopRequested = false

  func stopScript() {
    guard let p = scriptProc else { return }
    stopRequested = true
    p.kill()
  }

  func setRunState(_ id: UUID, _ s: String) {
    guard let i = index(id), state.messages[i].run?.state == "pending" else { return }
    state.messages[i].run?.state = s
    save()
  }

  func approveAct(_ id: UUID) {
    guard busySince == nil, !runningScript, let i = index(id), let a = state.messages[i].act, a.state == "pending" else { return }
    state.messages[i].act?.state = "approved"
    save()
    let list = a.calls.map { "- \($0.tool) \($0.input)" }.joined(separator: "\n")
    send("[approved] The user clicked Run: make exactly these calls now, then say briefly what came of them.\n\(list)",
         hidden: true, allow: Array(Set(a.calls.map(\.tool))).sorted())
  }

  func setActState(_ id: UUID, _ s: String) {
    guard let i = index(id), state.messages[i].act?.state == "pending" else { return }
    state.messages[i].act?.state = s
    save()
  }

  func setGrantState(_ id: UUID, _ s: String) {
    guard let i = index(id), state.messages[i].grant?.state == "pending" else { return }
    state.messages[i].grant?.state = s
    save()
  }

  /// "+": a new conversation here; the phone conversation so far is no longer shown.
  func reset() {
    guard busySince == nil else { return }
    state = State()
    state.since = Date()
    remote = []
    save()
  }

  // MARK: - the phone conversation

  /// Clawd's own session keeps its conversation in projects/<home>/<id>.jsonl in Claude Code's folder; only
  /// what was added since the last look is read.
  func updateRemoteFeed() {
    guard let model, let id = model.clawdSession.sessionId else { return }
    let path = ClaudeConfig.transcript(cwd: model.home.url.path, sessionId: id).path
    if path != remotePath { remotePath = path; remoteOffset = 0; remote = [] }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
    if size < remoteOffset { remoteOffset = 0; remote = [] }
    if size == remoteOffset { return }
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    try? h.seek(toOffset: remoteOffset)
    let data = h.readDataToEndOfFile()
    try? h.close()
    guard let nl = data.lastIndex(of: 10) else { return }
    let chunk = data[data.startIndex...nl]
    remoteOffset += UInt64(chunk.count)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
      let l = String(line)
      if l.range(of: #""type":"(user|assistant)""#, options: .regularExpression) == nil ||
        l.contains("\"tool_result\"") || l.contains("\"isMeta\":true") { continue }
      guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
            let type = j["type"] as? String, ["user", "assistant"].contains(type), (j["isSidechain"] as? Bool) != true,
            let msg = j["message"] as? [String: Any] else { continue }
      var say = ""
      if let s = msg["content"] as? String { say = s }
      else if let parts = msg["content"] as? [[String: Any]] {
        say = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
      }
      say = ReplyBlocks.plain(say)
      if say.isEmpty || say.hasPrefix("<") { continue }
      let at = (j["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
      let role = type == "user" ? "user" : "clawd"
      if role == "clawd", let last = remote.last, last.role == "clawd" {
        remote[remote.count - 1].text += "\n\n" + say
        continue
      }
      if at < state.since { continue }
      var m = ChatMessage(role: role, text: say, at: at)
      m.remote = true
      remote.append(m)
    }
    if remote.count > 40 { remote.removeFirst(remote.count - 40) }
  }
}
