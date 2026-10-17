import Foundation
import ClawdCore

/// `--demo`: fixed, made-up data for screenshots. No probes, no `claude`, no writes to the user's files,
/// the widget snapshot or iCloud; Clawd's folder is a temporary one.
extension AppModel {
  static var demoRequested: Bool { CommandLine.arguments.contains("--demo") }

  func startDemo() {
    demo = true
    let now = Date()
    usage = Demo.usage(now: now)
    usageAt = now
    claudeError = nil
    account = Demo.account
    rawSessions = Demo.sessions
    sessions = Demo.sessions
    status = ServiceStatus(indicator: "none", incidents: [], broken: [])
    statusAt = now
    verLocal = "2.1.302"
    verLatest = "2.1.302"
    weather = Demo.weather
    place = Place(lat: 50, lon: 10, city: "Example")
    history = Demo.history(now: now)
    var p = ProjectScanner.Result()
    for (name, share) in Demo.projectShares {
      p.total[name] = share
      p.paths[name] = "~/Projects/\(name)"
    }
    projects = p
    sky.force = .day

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crabbar-demo-\(UUID().uuidString.prefix(6))")
    home = ClawdHome(url: tmp)
    home.ensure()
    let cal = Calendar.current
    for (days, text) in Demo.reminders {
      if let d = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now)) {
        home.newReminder(at: d.addingTimeInterval(10 * 3600), text: text)
      }
    }
    let list = T("lists.default")
    home.newList(list)
    home.addListItems(list, Demo.listItems.map(\.0).joined(separator: ", "))
    for (item, done) in Demo.listItems where done { home.setListItem(list, text: item, done: true) }
    home.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail", "hours": "8-22"],
                 prompt: "Check the inbox for mail since the last run. Tell me only about letters from people.")

    chat.demo = true
    chat.state = .init()
    chat.remote = []
    for m in Demo.chat { chat.add(m.role, m.text) }
    chat.add("clawd", Demo.reply, run: .init(script: Demo.script, state: "pending"))

    let gb = L10n.lang == .de ? ("6,2", "Caches 3,1, Downloads 2,0, Xcode DerivedData 1,1") : ("6.2", "Caches 3.1, Downloads 2.0, Xcode DerivedData 1.1")
    advisor.tips = [Advisor.Tip(sig: "junk", text: T("adv.junk", gb.0, gb.1), ctx: "",
                                actionLabel: T("adv.act.open", T("adv.place.caches")), actionURL: "", snoozeDays: 3)]
    advisor.checkedAt = now
    mascot.update(sessions: sessions, usage: usage, warn: config.warnPercent, critPct: config.critPercent)
    onChange?()
  }
}
