import Foundation
import AppKit
import UserNotifications
import ClawdCore

enum Notifier {
  static func requestAuth() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  static func post(title: String, body: String, sound: Bool = true) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    if sound { c.sound = .default }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
  }
}

/// Fires due reminders from ~/Clawd/reminders: a card with snooze chips, a chat entry, Clawd hops. A repeating
/// one leaves a file for its next time. Also asks a small model when the panel's "when" field is not understood.
@MainActor
@Observable
final class ReminderCenter {
  @ObservationIgnored weak var model: AppModel?
  var due: [ClawdHome.Reminder] = []
  var asking = false
  @ObservationIgnored var fired = Set<String>()
  @ObservationIgnored var show: ((ClawdHome.Reminder, URL?, String) -> Void)?

  init(model: AppModel) { self.model = model }

  func update() {
    guard let model else { return }
    let now = Date()
    for r in model.home.activeReminders() {
      if r.at > now { break }
      if fired.contains(r.path.path) { continue }
      fired.insert(r.path.path)
      let to = model.home.fire(r, now: now).done
      var text = r.text
      if now.timeIntervalSince(r.at) > 300 { text = T("chat.remindLate", text, Format.remindTime(r.at)) }
      model.chat.add("remind", text)
      due.append(r)
      if let show { show(r, to, text) } else { Notifier.post(title: T("chat.remindTitle"), body: text) }
      if model.config.showMascot { model.mascot.jumpIfFree() }
      model.onChange?()
    }
  }

  func snooze(_ r: ClawdHome.Reminder, doneFile: URL?, chip: String) {
    guard let model, let at = RemindWhen.parse(chip) else { return }
    if let f = doneFile { try? FileManager.default.removeItem(at: f) }
    model.home.newReminder(at: at, text: r.text)
    model.chat.add("note", T("pop.later", Format.remindTime(at), r.text))
    due.removeAll { $0.id == r.id }
  }

  func dismiss(_ r: ClawdHome.Reminder) { due.removeAll { $0.id == r.id } }

  /// What the local parser does not know goes to a small model with no tools: a date or NONE.
  func ask(_ when: String) async -> Date? {
    guard let model, let bin = model.claude, !asking else { return nil }
    asking = true
    defer { asking = false }
    let prompt = [
      "Now: \(Format.contextNow()).",
      "A user wrote when a reminder should go off: \"\(when)\"",
      "Turn it into a local date and time. A day without a time is 10:00; a time already gone today is tomorrow.",
      "If the text names no day, date, time or period at all (it is a task, a word, gibberish), the answer is NONE - never guess.",
      "Reply with exactly one line: the time as yyyy-MM-ddTHH:mm, or NONE."
    ].joined(separator: "\n")
    let o = await Proc.run(bin.path, ["-p", "--output-format", "text", "--model", model.config.quickModel,
                                      "--tools", "", "--strict-mcp-config", "--no-session-persistence"] + Prompts.ownSettings,
                           cwd: NSTemporaryDirectory(), stdin: prompt.data(using: .utf8), timeout: 60)
    guard let r = o.text.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#, options: .regularExpression),
          let at = Format.parseISO(String(o.text[r])), at > Date().addingTimeInterval(-60) else { return nil }
    return at
  }
}
