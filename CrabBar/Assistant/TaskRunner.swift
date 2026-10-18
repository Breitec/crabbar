import Foundation
import ClawdCore

/// Recurring tasks from ~/Clawd/tasks, every so often (`every`) or at set times of day (`at`): one at a time
/// as a headless `claude -p`. The reply NOTHING stays silent; anything else lands in the chat with a
/// notification. Tasks wait while usage is high.
/// Tools beyond reading need the user's approval once per task: task files can be written by Claude
/// (chat blocks, the phone session), so a task never gains tools on its own.
@MainActor
@Observable
final class TaskRunner {
  struct Entry: Codable, Equatable {
    var last: Date?
    var report = ""
    var error = ""
    var asked = ""
    var history: [Report] = []
    var approved: [String]?
  }
  struct Report: Codable, Equatable {
    var at: Date
    var text: String
  }

  @ObservationIgnored weak var model: AppModel?
  var state: [String: Entry] = [:]
  var running: String?
  var queue: [String] = []
  @ObservationIgnored var proc: Proc?
  static let historyKeep = 10

  init(model: AppModel) {
    self.model = model
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    if let d = try? Data(contentsOf: AppPaths.tasks), let s = try? dec.decode([String: Entry].self, from: d) { state = s }
  }

  func save() {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(state) { try? d.write(to: AppPaths.tasks, options: .atomic) }
  }

  func forget(_ name: String) {
    state.removeValue(forKey: name)
    save()
  }

  /// Tools of this task the user has not approved yet.
  func unapproved(_ t: ClawdHome.TaskFile) -> [String] {
    let ok = Set(state[t.name]?.approved ?? [])
    return t.tools.filter { !ok.contains($0) }
  }

  /// Approved tools of active tasks: the chat may use them too (reading at once, actions after a click).
  func approvedTools() -> [String] {
    guard let model else { return [] }
    var all = Set<String>()
    for t in model.home.taskFiles() where !t.paused {
      let ok = Set(state[t.name]?.approved ?? [])
      all.formUnion(t.tools.filter { ok.contains($0) })
    }
    return all.sorted()
  }

  /// nil - may run; otherwise the percent it waits on (the higher of session and week).
  func budgetWait(_ t: ClawdHome.TaskFile) -> Int? {
    guard let model else { return nil }
    let max = t.limit ?? model.config.tasksMaxPercent
    if max <= 0 || max >= 100 { return nil }
    guard let u = model.usage else { return nil }
    let pct = Swift.max(u.session ?? 0, u.week ?? 0)
    return pct >= max ? pct : nil
  }

  func request(_ t: ClawdHome.TaskFile) {
    if !unapproved(t).isEmpty { askApproval(t); return }
    if running != nil {
      if running != t.name && !queue.contains(t.name) { queue.append(t.name) }
      return
    }
    start(t)
  }

  /// A card in the chat asking to allow the task's tools; asked once for the same set.
  func askApproval(_ t: ClawdHome.TaskFile) {
    guard let model else { return }
    let want = unapproved(t)
    let key = "approve:" + want.joined(separator: " ")
    var e = state[t.name] ?? Entry()
    if e.asked == key { return }
    e.asked = key
    state[t.name] = e
    save()
    let id = model.chat.add("clawd", "[\(t.name)] " + T("task.approveText"), task: t.name)
    if let i = model.chat.index(id) {
      model.chat.state.messages[i].grant = .init(task: t.name, rules: want, state: "pending", kind: "approve")
      model.chat.save()
    }
    if !model.panelOpen {
      model.chat.unread = true
      Notifier.post(title: "Clawd · \(t.name)", body: T("task.approveText"))
    }
  }

  func update() {
    guard let model, model.config.showTasks, running == nil else { return }
    while !queue.isEmpty {
      let n = queue.removeFirst()
      if let t = model.home.task(named: n) { start(t); if running != nil { return } }
    }
    let now = Date()
    for t in model.home.taskFiles() {
      guard !t.paused, !t.prompt.isEmpty, t.at != nil || t.every != nil, budgetWait(t) == nil else { continue }
      let last = state[t.name]?.last
      if t.at != nil {
        // Once per time of day; a time missed while the Mac slept or was off - once, when it is on again.
        guard t.dueAt(lastRun: last, created: t.created, now: now) else { continue }
      } else {
        guard t.inHours(now), let every = t.every, now.timeIntervalSince(last ?? .distantPast) >= every else { continue }
      }
      if !unapproved(t).isEmpty { askApproval(t); continue }
      start(t)
      if running != nil { return }
    }
  }

  func start(_ t: ClawdHome.TaskFile, model override: String? = nil, retry: Bool = false) {
    guard let model, let bin = model.claude, running == nil, !t.prompt.isEmpty, unapproved(t).isEmpty else { return }
    let prev = state[t.name]
    let when = t.at != nil ? "at=\"\(t.atText)\"" : "every=\"\(t.everyText)\""
    var head = ["<task name=\"\(t.name)\" \(when)>"]
    if let last = prev?.last {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyy-MM-dd HH:mm"
      let u = ISO8601DateFormatter()
      head.append("last run: \(f.string(from: last)) local time (\(Format.utcOffset())) = \(u.string(from: last))")
    } else {
      head.append("last run: never - this is the first one")
    }
    if let r = prev?.report, !r.isEmpty { head.append("your last report to the user:\n\(r)") }
    head.append("</task>")
    let text = model.chat.context() + "\n\n" + head.joined(separator: "\n") + "\n\n" + t.prompt
    let m = override ?? (t.model.isEmpty ? model.config.quickModel : t.model)
    let args = ["-p", "--output-format", "json", "--model", m, "--permission-mode", "default", "--no-session-persistence",
                "--disallowedTools", "Write", "Edit", "NotebookEdit", "--append-system-prompt-file", Prompts.tasks.path,
                "--allowedTools"] + Prompts.readOnlyRules + t.tools
    running = t.name
    let timeout = model.config.chatTimeoutSeconds
    Task {
      do {
        let p = try Proc.spawn(bin.path, args, cwd: model.home.url.path, stdin: text.data(using: .utf8))
        proc = p
        let o = await p.wait(timeout: timeout)
        proc = nil
        running = nil
        collect(t, o, retry: retry, timeout: timeout)
      } catch {
        running = nil
        result(t, report: nil, why: "\(error)")
      }
    }
  }

  func collect(_ t: ClawdHome.TaskFile, _ o: Proc.Output, retry: Bool, timeout: TimeInterval) {
    if o.timedOut { result(t, report: nil, why: T("task.timeout", Int(timeout))); return }
    let j = try? JSONSerialization.jsonObject(with: o.out) as? [String: Any]
    if let j, (j["is_error"] as? Bool) != true, let res = j["result"] as? String {
      let need = ((j["permission_denials"] as? [[String: Any]]) ?? []).compactMap { d -> String? in
        guard let tool = d["tool_name"] as? String else { return nil }
        return ReplyBlocks.deniedRule(tool: tool, input: (d["tool_input"] as? [String: Any]) ?? [:])
      }.filter(ClawdHome.isValidToolRule)
      // No words at all is not "nothing to say": one more go with the chat's model, then a failure.
      if res.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && need.isEmpty {
        if !retry, let m = model?.config.chatModel { start(t, model: m, retry: true) }
        if running == nil { result(t, report: nil, why: T("task.empty")) }
        return
      }
      result(t, report: res, why: "", need: need)
    } else {
      var why = (j?["result"] as? String) ?? ""
      if why.isEmpty { why = o.errText.trimmingCharacters(in: .whitespacesAndNewlines) }
      if why.isEmpty { why = "exit \(o.code)" }
      if why.count > 300 { why = String(why.prefix(300)) + "…" }
      result(t, report: nil, why: why)
    }
  }

  func result(_ t: ClawdHome.TaskFile, report: String?, why: String, need: [String] = []) {
    guard let model else { return }
    var e = state[t.name] ?? Entry()
    e.last = Date()
    guard let report else {
      if why != e.error { model.chat.add("note", T("task.error", t.name, why)) }
      e.error = why
      state[t.name] = e
      save()
      return
    }
    e.error = ""
    let said = report.trimmingCharacters(in: .whitespacesAndNewlines)
    let nothing = said.range(of: #"^\W*NOTHING\W*$"#, options: .regularExpression) != nil
    let want = Array(Set(need.filter { !t.tools.contains($0) })).sorted()
    let askKey = want.joined(separator: " ")
    if !want.isEmpty && askKey != e.asked {
      e.asked = askKey
      state[t.name] = e
      save()
      let id = model.chat.add("clawd", "[\(t.name)] " + (!said.isEmpty && !nothing ? said : T("task.needs")), task: t.name)
      if let i = model.chat.index(id) {
        model.chat.state.messages[i].grant = .init(task: t.name, rules: want, state: "pending")
        model.chat.save()
      }
      if !model.panelOpen {
        model.chat.unread = true
        Notifier.post(title: "Clawd · \(t.name)", body: T("task.needs"))
      }
      return
    }
    if said.isEmpty || nothing { state[t.name] = e; save(); return }
    let r = ReplyBlocks.parse(said)
    e.report = r.text.count > 1500 ? String(r.text.prefix(1500)) + "…" : r.text
    e.history = Array((e.history + [Report(at: Date(), text: e.report)]).suffix(Self.historyKeep))
    state[t.name] = e
    save()
    model.chat.add("clawd", "[\(t.name)] \(r.text)", run: r.run.map { .init(script: $0, state: "pending") }, task: t.name)
    for n in model.chat.apply(r.actions) { model.chat.add("note", n) }
    if !model.panelOpen {
      model.chat.unread = true
      Notifier.post(title: "Clawd · \(t.name)", body: r.text.count > 200 ? String(r.text.prefix(200)) + "…" : r.text)
      if model.config.showMascot { model.mascot.wave() }
    }
    model.onChange?()
  }

  /// "Allow" on a card: approve the task's own tools, or add the refused rules to its `tools`; it runs again now.
  func grant(_ msgId: UUID) {
    guard let model, let i = model.chat.index(msgId), let g = model.chat.state.messages[i].grant, g.state == "pending" else { return }
    guard let t = model.home.task(named: g.task) else { model.chat.setGrantState(msgId, "gone"); return }
    if g.kind != "approve" {
      if !model.home.grantTools(t, g.rules) { return }
    }
    var e = state[t.name] ?? Entry()
    e.approved = Array(Set((e.approved ?? []) + g.rules)).sorted()
    e.last = nil
    e.asked = ""
    state[t.name] = e
    save()
    model.chat.setGrantState(msgId, "granted")
  }
}
