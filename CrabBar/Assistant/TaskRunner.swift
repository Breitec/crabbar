import Foundation
import ClawdCore

/// Recurring tasks from ~/Clawd/tasks, every so often (`every`) or at set times of day (`at`): one at a time
/// as a headless `claude -p`. The reply NOTHING stays silent; anything else lands in the chat with a
/// notification. Tasks wait while usage is high.
/// Tools beyond reading need the user's approval once per task content: task files can be written by Claude
/// (chat blocks, the phone session), so a task never gains tools on its own, and a rewritten one asks again.
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
    /// `TaskFile.fingerprint` of the content `approved` was given for; nil from before there was one.
    var approvedFor: String?
    /// The task was seen paused; only the panel's Resume or a new approval clears it.
    var pauseSeen: Bool?
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

  /// Tools of this task the user has not approved yet. An approval holds for the content it was given for:
  /// once the prompt, the tools, the model or the times change, or a paused task runs again without the
  /// panel's Resume, all of its tools need approval again.
  func unapproved(_ t: ClawdHome.TaskFile) -> [String] {
    let e = state[t.name]
    return t.unapproved(approved: e?.approved, approvedFor: e?.approvedFor, pauseSeen: e?.pauseSeen == true)
  }

  /// Pause and Resume in the panel: the user's own, so resuming there keeps the approval.
  func setPaused(_ t: ClawdHome.TaskFile, _ paused: Bool) {
    guard let model else { return }
    state[t.name, default: Entry()].pauseSeen = paused ? true : nil
    save()
    model.home.setTaskPaused(t, paused)
  }

  /// A pause from anywhere (the chat, Claude's phone session, the file) stays on record, so that resuming
  /// it anywhere but in the panel asks again.
  func notePauses(_ files: [ClawdHome.TaskFile]) {
    var changed = false
    for t in files where t.paused && state[t.name]?.pauseSeen != true {
      state[t.name, default: Entry()].pauseSeen = true
      changed = true
    }
    if changed { save() }
  }

  /// Approved tools of active tasks: the chat may use them too (reading at once, actions after a click).
  func approvedTools() -> [String] {
    guard let model else { return [] }
    var all = Set<String>()
    for t in model.home.taskFiles() where !t.paused {
      let open = Set(unapproved(t))
      all.formUnion(t.tools.filter { !open.contains($0) })
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

  /// "Run now": a task still waiting for approval shows its card again, also one skipped or scrolled away,
  /// with the file as it is now.
  func request(_ task: ClawdHome.TaskFile) {
    guard let t = model?.home.task(named: task.name) else { return }
    if !unapproved(t).isEmpty {
      state[t.name]?.asked = ""
      askApproval(t)
      return
    }
    if running != nil {
      if running != t.name && !queue.contains(t.name) { queue.append(t.name) }
      return
    }
    start(t)
  }

  /// A task resumed outside the panel: its next run asks again, and the card says why.
  func revoke(_ name: String) {
    state[name, default: Entry()].pauseSeen = true
    save()
  }

  /// What a card shows of the task, all that its fingerprint covers: the whole text and how it runs.
  func describe(_ t: ClawdHome.TaskFile) -> (prompt: String, info: String) {
    var info = [t.whenText]
    if let h = t.hours { info.append(T("task.hours", h.0, h.1)) }
    info.append(T("task.model", t.model.isEmpty ? (model?.config.quickModel ?? "") : t.model))
    return (ClawdHome.visibleText(t.prompt), info.joined(separator: " · "))
  }

  /// A card in the chat asking to allow the task's tools, with what the task does; asked once for the same
  /// content. An older card of the task that is still open no longer counts.
  func askApproval(_ t: ClawdHome.TaskFile) {
    guard let model else { return }
    let want = unapproved(t)
    let fp = t.fingerprint
    let key = "approve:\(fp):" + want.joined(separator: " ")
    var e = state[t.name] ?? Entry()
    if e.asked == key { return }
    e.asked = key
    state[t.name] = e
    save()
    for m in model.chat.state.messages where m.grant?.task == t.name && m.grant?.kind == "approve" {
      model.chat.setGrantState(m.id, m.grant?.fingerprint == nil || m.grant?.fingerprint == fp ? "replaced" : "changed")
    }
    let why = (e.approved ?? []).isEmpty ? "task.approveText"
      : e.approvedFor == nil ? "task.approveAgain"
      : e.approvedFor == fp && e.pauseSeen == true ? "task.approveResumed" : "task.approveChanged"
    let d = describe(t)
    let id = model.chat.add("clawd", "[\(t.name)] " + T(why), task: t.name)
    if let i = model.chat.index(id) {
      model.chat.state.messages[i].grant = .init(task: t.name, rules: want, state: "pending", kind: "approve", fingerprint: fp,
                                                 prompt: d.prompt, info: d.info)
      model.chat.save()
    }
    if !model.panelOpen {
      model.chat.unread = true
      Notifier.post(title: "Clawd · \(t.name)", body: T(why))
    }
  }

  func update() {
    guard let model else { return }
    let files = model.home.taskFiles()
    // Also with tasks switched off, so a pause made and undone meanwhile still asks on resume.
    notePauses(files)
    guard model.config.showTasks, running == nil else { return }
    while !queue.isEmpty {
      let n = queue.removeFirst()
      if let t = model.home.task(named: n) { start(t); if running != nil { return } }
    }
    let now = Date()
    for t in files {
      guard !t.paused, !t.prompt.isEmpty, t.at != nil || t.every != nil else { continue }
      // The card comes at once, not only when the task is due (asked once for the same content).
      if !unapproved(t).isEmpty { askApproval(t); continue }
      guard budgetWait(t) == nil else { continue }
      let last = state[t.name]?.last
      if t.at != nil {
        // Once per time of day; a time missed while the Mac slept or was off - once, when it is on again.
        guard t.dueAt(lastRun: last, created: t.created, now: now) else { continue }
      } else {
        guard t.inHours(now), let every = t.every, now.timeIntervalSince(last ?? .distantPast) >= every else { continue }
      }
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
    if !t.tools.isEmpty { head.append("tools you may use besides reading: \(t.tools.joined(separator: " "))") }
    if let r = prev?.report, !r.isEmpty { head.append("your last report to the user:\n\(r)") }
    head.append("</task>")
    // Only the time and the task's own head and last report: the chat's context holds what replies, the phone and
    // other tasks wrote without a click, and that must not steer a run with tools.
    let ctx = "<context>\nnow: \(Format.contextNow())\n</context>"
    let text = ctx + "\n\n" + head.joined(separator: "\n") + "\n\n" + t.prompt
    let m = override ?? (t.model.isEmpty ? model.config.quickModel : t.model)
    let args = ["-p", "--output-format", "json", "--model", m, "--permission-mode", "default", "--no-session-persistence"]
      + Prompts.ownSettings + Prompts.mcpFlags(t.tools)
      + ["--disallowedTools", "Write", "Edit", "NotebookEdit", "--append-system-prompt-file", Prompts.tasks.path,
         "--allowedTools"] + Prompts.readOnlyRules + t.tools
    running = t.name
    let timeout = model.config.chatTimeoutSeconds
    Task {
      do {
        let p = try Proc.spawn(bin.path, args, cwd: model.home.url.path, stdin: text.data(using: .utf8), env: Prompts.ownEnv)
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
        // The click approves the task as it ran, so the card shows that, not just what the run replied.
        let d = describe(t)
        model.chat.state.messages[i].grant = .init(task: t.name, rules: want, state: "pending", fingerprint: t.fingerprint,
                                                   prompt: d.prompt, info: d.info)
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
    // A task may remind and keep lists, not make, change or remove tasks: its reply can come from text it read in a
    // mail or on a web page. A `run` block stays a card that waits for the user's click.
    var dropped: [String] = []
    let allowed = r.actions.filter {
      switch $0 {
      case .remind, .remindCancel, .list: return true
      case .task(let name, _, _), .taskBad(let name), .taskRemove(let name): dropped.append(name); return false
      }
    }
    for n in model.chat.apply(allowed) { model.chat.add("note", n) }
    if !dropped.isEmpty {
      let names = Set(dropped.filter { !$0.isEmpty }).sorted()
      model.chat.add("note", T("task.blocksDropped", t.name, names.isEmpty ? T("task.unnamed") : names.joined(separator: ", ")))
    }
    if !model.panelOpen {
      model.chat.unread = true
      Notifier.post(title: "Clawd · \(t.name)", body: r.text.count > 200 ? String(r.text.prefix(200)) + "…" : r.text)
      if model.config.showMascot { model.mascot.wave() }
    }
    model.onChange?()
  }

  /// "Allow" on a card: approve the task's own tools, or add the refused rules to its `tools`; it runs again now.
  /// A card holds for the content it was shown for: if the task file changed since, a new card asks instead.
  func grant(_ msgId: UUID) {
    guard let model, let i = model.chat.index(msgId), let g = model.chat.state.messages[i].grant, g.state == "pending" else { return }
    guard let t = model.home.task(named: g.task) else { model.chat.setGrantState(msgId, "gone"); return }
    var e = state[t.name] ?? Entry()
    guard let fp = g.fingerprint, fp == t.fingerprint else {
      e.asked = ""
      state[t.name] = e
      save()
      if unapproved(t).isEmpty { model.chat.setGrantState(msgId, "outdated"); return }
      model.chat.setGrantState(msgId, g.fingerprint == nil ? "replaced" : "changed")
      askApproval(t)
      return
    }
    // The content approved is the one shown plus the rules added here, not whatever the file says afterwards.
    var granted = t
    if g.kind != "approve" {
      if !model.home.grantTools(t, g.rules) { return }
      granted.tools = t.tools + g.rules.filter { !t.tools.contains($0) }
    }
    let kept = e.approvedFor == fp ? (e.approved ?? []) : []
    e.approved = Array(Set(kept + g.rules)).sorted()
    e.approvedFor = granted.fingerprint
    e.pauseSeen = t.paused ? true : nil
    e.last = nil
    e.asked = ""
    state[t.name] = e
    save()
    model.chat.setGrantState(msgId, "granted")
  }
}
