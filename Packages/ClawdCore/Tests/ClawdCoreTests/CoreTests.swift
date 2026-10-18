import Foundation
import Testing
@testable import ClawdCore

func fixture(_ name: String) throws -> String {
  let u = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
  return try String(contentsOf: u, encoding: .utf8)
}

func date(_ s: String, _ tz: String = "Europe/Berlin") -> Date {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: tz)
  f.dateFormat = "yyyy-MM-dd HH:mm"
  return f.date(from: s)!
}

/// The zone the expected times are written in, passed explicitly so the tests pass in any system time zone.
let berlin = TimeZone(identifier: "Europe/Berlin")!

@Suite struct UsageParserTests {
  @Test func currentFormat() throws {
    let now = date("2026-10-17 11:00")
    let u = try UsageParser.parse(try fixture("usage-2.1.299"), now: now, timeZone: berlin)
    #expect(u.session == 6)
    #expect(u.week == 10)
    #expect(u.fable == 4)
    #expect(u.sessionReset == date("2026-10-17 14:29"))
    #expect(u.weekReset == date("2026-10-21 21:59"))
    #expect(u.day?.requests == 320)
    #expect(u.day?.sessions == 6)
    #expect(u.week7?.requests == 622)
    #expect(u.day?.lines.first == "88% of your usage was at >150k context")
  }

  @Test func quietDaySingular() throws {
    let text = "Current session: 2% used · resets Oct 17 at 2:29pm\n\nLast 24h · 1 request · 1 session\n  Top skills: /usage 1%\n"
    let u = try UsageParser.parse(text, now: date("2026-10-17 11:00"), timeZone: berlin)
    #expect(u.day?.requests == 1)
    #expect(u.day?.sessions == 1)
    #expect(u.day?.lines == ["Top skills: /usage 1%"])
  }

  @Test func legacyCommaFormatWithZone() throws {
    let now = date("2026-10-16 12:00")
    let u = try UsageParser.parse(try fixture("usage-legacy"), now: now, timeZone: berlin)
    #expect(u.session == 10)
    #expect(u.fable == nil)
    // 5:19am Moscow = 4:19am Berlin (CEST)
    #expect(u.sessionReset == date("2026-10-17 04:19"))
    #expect(u.week7 == nil)
    #expect(u.day?.lines.count == 2)
  }

  @Test func noResetsMeansZeroNotMissing() throws {
    let u = try UsageParser.parse("Current session: 0% used\nCurrent week (all models): 3% used · resets Oct 21 at 9pm")
    #expect(u.session == 0)
    #expect(u.sessionReset == nil)
    #expect(u.week == 3)
  }

  @Test func notAvailable() {
    #expect(throws: UsageParseError.notAvailable) { try UsageParser.parse("/usage isn't available in this environment.") }
    #expect(throws: UsageParseError.noLimits) { try UsageParser.parse("hello") }
  }

  @Test func resetStampVariants() {
    let now = date("2026-12-30 10:00")
    #expect(ResetStamp.parse("Jan 2 at 6am", now: now, timeZone: berlin) == date("2027-01-02 06:00"))
    #expect(ResetStamp.parse("Dec 31, 12pm", now: now, timeZone: berlin) == date("2026-12-31 12:00"))
    #expect(ResetStamp.parse("Dec 31, 12:30am", now: now, timeZone: berlin) == date("2026-12-31 00:30"))
    #expect(ResetStamp.parse("3:15pm (Europe/Berlin)", now: now, timeZone: berlin) == date("2026-12-30 15:15"))
    #expect(ResetStamp.parse("garbage", now: now, timeZone: berlin) == nil)
  }

  @Test func statLines() {
    L10n.setting = "en"
    #expect(StatLine.format("88% of your usage was at >150k context") == "88% at >150k context")
    #expect(StatLine.format("Top skills: /a 9%") == "skills: /a 9%")
    #expect(StatLine.format("Something new") == "Something new")
  }
}

@Suite struct RulesTests {
  @Test func span() {
    L10n.setting = "en"
    let now = date("2026-10-17 10:00")
    #expect(Format.span(until: date("2026-10-17 12:05"), now: now) == "2h 05m")
    #expect(Format.span(until: date("2026-10-19 13:00"), now: now) == "2d 3h")
    #expect(Format.span(until: date("2026-10-17 10:42"), now: now) == "42m")
    #expect(Format.span(until: date("2026-10-17 09:00"), now: now) == nil)
  }

  @Test func hearts() {
    #expect(Hearts.halves(nil) == nil)
    #expect(Hearts.halves(0) == 6)
    #expect(Hearts.halves(17) == 5)
    #expect(Hearts.halves(99) == 1)
    #expect(Hearts.halves(100) == 0)
    #expect(Hearts.halves(130) == 0)
  }

  @Test func levels() {
    #expect(Level.of(59) == .ok)
    #expect(Level.of(60) == .warn)
    #expect(Level.of(85) == .crit)
    #expect(Level.of(nil) == .dead)
  }

  @Test func mood() {
    let idle = ClaudeSession(pid: 1, name: "a", cwd: "/", busy: false, waiting: false)
    let busy = ClaudeSession(pid: 2, name: "b", cwd: "/", busy: true, waiting: false)
    let wait = ClaudeSession(pid: 3, name: "c", cwd: "/", busy: false, waiting: true)
    #expect(Mood.from(sessionPct: 100, sessions: [wait]) == .dead)
    #expect(Mood.from(sessionPct: 50, sessions: [busy, wait]) == .wait)
    #expect(Mood.from(sessionPct: 50, sessions: [idle, busy]) == .work)
    #expect(Mood.from(sessionPct: nil, sessions: [idle]) == .idle)
    #expect(Mood.from(sessionPct: 10, sessions: []) == .sleep)
  }

  @Test func history() {
    var h = UsageHistory()
    let t = date("2026-10-17 10:00")
    h.add(Usage(session: 5, week: 10), at: t)
    h.add(Usage(session: 5, week: 10), at: t.addingTimeInterval(120))
    #expect(h.samples.count == 1)
    h.add(Usage(session: 5, week: 10), at: t.addingTimeInterval(360))
    h.add(Usage(session: 6, week: 10), at: t.addingTimeInterval(420))
    #expect(h.samples.count == 3)
    h.add(Usage(session: 7, week: 10), at: t.addingTimeInterval(3600))
    #expect(h.runs(from: 0, column: 1).count == 2)
    h.add(Usage(session: 1, week: 1), at: t.addingTimeInterval(9 * 86400))
    #expect(h.samples.count == 1)
  }

  @Test func sprite() {
    let g = ClawdSprite.geometry(ClawdFrame())
    #expect(!g.body.isEmpty)
    #expect(!g.eyes.isEmpty)
    let flipped = ClawdFrame(eyes: "x")
    #expect(!ClawdSprite.geometry(flipped).eyes.isEmpty)
    #expect(ClawdSequences.clickActs.contains("jump"))
    #expect(!ClawdSequences.clickActs.contains("skip"))
    #expect(ClawdSequences.length("soul") == 66)
    let e = MascotEngine(entrance: false)
    for _ in 0..<500 { _ = e.step(areaWidth: 150, areaHeight: 40, hovering: false, mouseX: nil) }
  }

  @Test func weather() {
    #expect(WeatherKind.of(61).rain == 7)
    #expect(WeatherKind.of(65).rain == 16)
    #expect(WeatherKind.of(95).storm)
    let st = SunCalc.times(lat: 50, lon: 10, date: date("2026-06-21 12:00"), timeZone: berlin)
    #expect(st.sr > 4 * 60 && st.sr < 6 * 60)
    #expect(st.ss > 20 * 60 && st.ss < 22 * 60)
  }
}

@Suite struct HomeFilesTests {
  func tmpHome() -> ClawdHome {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)")
    let h = ClawdHome(url: u)
    h.ensure()
    return h
  }

  @Test func remindWhen() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("+20m", now: now, timeZone: berlin) == date("2026-10-17 11:20"))
    #expect(RemindWhen.parse("in 2 stunden", now: now, timeZone: berlin) == date("2026-10-17 13:00"))
    #expect(RemindWhen.parse("18:30", now: now, timeZone: berlin) == date("2026-10-17 18:30"))
    #expect(RemindWhen.parse("09:30", now: now, timeZone: berlin) == date("2026-10-18 09:30"))
    #expect(RemindWhen.parse("morgen 10", now: now, timeZone: berlin) == date("2026-10-18 10:00"))
    #expect(RemindWhen.parse("tomorrow", now: now, timeZone: berlin) == date("2026-10-18 10:00"))
    #expect(RemindWhen.parse("mo 9", now: now, timeZone: berlin) == date("2026-10-19 09:00"))
    #expect(RemindWhen.parse("mon 9:00", now: now, timeZone: berlin) == date("2026-10-19 09:00"))
    #expect(RemindWhen.parse("in einer woche", now: now, timeZone: berlin) == date("2026-10-24 10:00"))
    #expect(RemindWhen.parse("19.10 14:00", now: now, timeZone: berlin) == date("2026-10-19 14:00"))
    #expect(RemindWhen.parse("1.1.27", now: now, timeZone: berlin) == date("2027-01-01 10:00"))
    #expect(RemindWhen.parse("2026-11-16 10:00", now: now, timeZone: berlin) == date("2026-11-16 10:00"))
    #expect(RemindWhen.parse("um 9", now: now, timeZone: berlin) == date("2026-10-18 09:00"))
    #expect(RemindWhen.parse("10", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.parse("Steuern zahlen", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.isRepeat("jeden Montag"))
  }

  @Test func replyBlocks() {
    let reply = """
    Mach ich.

    ```remind
    2026-10-19T10:00 | Kunden anrufen
    ```

    ```list-add
    Einkauf | Milch
    ```

    ```run
    du -sh ~/Library/Caches
    ```

    ```task
    name: Mail
    every: 10m
    tools: mcp__mail
    ---
    Check the inbox.
    ```
    """
    let p = ReplyBlocks.parse(reply)
    #expect(p.text == "Mach ich.")
    #expect(p.run == "du -sh ~/Library/Caches")
    #expect(p.actions.count == 3)
    #expect(p.actions[0] == .remind(date("2026-10-19 10:00", TimeZone.current.identifier), "Kunden anrufen", nil))
    if case .task(let name, let head, let prompt) = p.actions[2] {
      #expect(name == "Mail")
      #expect(head["tools"] == "mcp__mail")
      #expect(prompt == "Check the inbox.")
    } else {
      Issue.record("no task")
    }
  }

  @Test func reminders() {
    let h = tmpHome()
    let at = Date().addingTimeInterval(3600)
    h.newReminder(at: at, text: "Test: eins/zwei")
    let r = h.activeReminders()
    #expect(r.count == 1)
    #expect(r[0].text == "Test: eins/zwei")
    #expect(h.markDone(r[0]) != nil)
    #expect(h.activeReminders().isEmpty)
    #expect(h.doneReminders().count == 1)
  }

  @Test func lists() {
    let h = tmpHome()
    #expect(h.listNames(defaultName: "Einkauf") == ["Einkauf"])
    h.addListItems("Einkauf", "Milch, Brot")
    #expect(h.readList("Einkauf").items.count == 2)
    #expect(h.setListItem("Einkauf", text: "milch", done: true))
    h.clearListDone("Einkauf")
    #expect(h.readList("Einkauf").items.map(\.text) == ["Brot"])
    #expect(h.readList("Einkauf").lines.first == "# Einkauf")
  }

  @Test func tasks() {
    let h = tmpHome()
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail Bash(gh pr list:*)", "hours": "22-7"], prompt: "Do it")
    let t = h.taskFiles()
    #expect(t.count == 1)
    #expect(t[0].every == 600)
    #expect(t[0].tools == ["mcp__mail", "Bash(gh pr list:*)"])
    #expect(t[0].hours?.0 == 22)
    h.setTaskPaused(t[0], true)
    #expect(h.taskFiles()[0].paused)
    #expect(h.grantTools(h.taskFiles()[0], ["WebFetch(domain:x.com)"]))
    #expect(h.taskFiles()[0].tools.last == "WebFetch(domain:x.com)")
    #expect(ClawdHome.parseEvery("1m") == 120)
    #expect(ClawdHome.parseEvery("2 Std") == 7200)
  }
}

@Suite struct ReviewRegressionTests {
  @Test func weekdaysAreWholeWords() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("sauna 18", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.parse("monatsende", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.parse("dose holen 9:30", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.parse("freitag 9", now: now, timeZone: berlin) == date("2026-10-23 09:00"))
    #expect(RemindWhen.parse("am montag 10:30", now: now, timeZone: berlin) == date("2026-10-19 10:30"))
    #expect(RemindWhen.parse("sat", now: now, timeZone: berlin) == date("2026-10-24 10:00"))
  }

  @Test func invalidDatesFail() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("31.2.", now: now, timeZone: berlin) == nil)
    #expect(RemindWhen.parse("2026-02-30", now: now, timeZone: berlin) == nil)
  }

  @Test func isoParsing() {
    #expect(Format.parseISO("2026-11-16T10:00") == date("2026-11-16 10:00", TimeZone.current.identifier))
    #expect(Format.parseISO("2026-11-16T10:00:00.000") != nil)
    #expect(Format.parseISO("2026-11-16T09:00:00Z") != nil)
    #expect(Format.parseISO("2026-11-16T10:00:00+01:00") != nil)
    // A local time in the spring DST gap moves forward instead of disappearing.
    #expect(Format.parseISO("2027-03-28T02:30") != nil)
    #expect(Format.parseISO("2026-13-01") == nil)
  }

  @Test func toolRules() {
    #expect(ClawdHome.isValidToolRule("mcp__mail"))
    #expect(ClawdHome.isValidToolRule("mcp__mail__list_messages"))
    #expect(ClawdHome.isValidToolRule("Bash(gh pr list:*)"))
    #expect(ClawdHome.isValidToolRule("WebFetch(domain:github.com)"))
    #expect(!ClawdHome.isValidToolRule("Bash"))
    #expect(!ClawdHome.isValidToolRule("Write"))
    #expect(!ClawdHome.isValidToolRule("--dangerously-skip-permissions"))
    #expect(!ClawdHome.isValidToolRule("Bash(-rf:*)"))
  }

  @Test func stillSkyShowsClouds() {
    let r = SkyEngine().still(width: 140, height: 40, now: date("2026-10-17 12:00"), sun: (420, 1140),
                              weather: Weather(code: 3, temp: 10, wind: 8), place: nil)
    #expect(!r.clouds.isEmpty)
    #expect(r.clouds.allSatisfy { $0.opacity > 0.6 })
    #expect(r.flash == 0)
  }

  @Test func widgetStalenessAndReloadKey() {
    var s = WidgetSnapshot()
    s.usageAt = date("2026-10-17 10:00")
    s.staleAfter = 210
    #expect(!s.isStale(at: date("2026-10-17 10:03")))
    #expect(s.isStale(at: date("2026-10-17 10:04")))
    s.usage = Usage(session: 5, week: 9, day: UsagePeriod(requests: 1, sessions: 1, lines: []))
    let k1 = s.displayKey
    s.usage?.day = UsagePeriod(requests: 99, sessions: 2, lines: ["x"])
    #expect(s.displayKey == k1)
    s.usage?.session = 6
    #expect(s.displayKey != k1)
  }

  @Test func devMenuSemantics() {
    let e = MascotEngine(entrance: false)
    e.startDrain()
    #expect(e.force == nil)
    e.force = .work
    e.forceCrit = true
    e.stopDemo()
    #expect(e.force == nil && !e.forceCrit)
  }
}

@Suite struct CloudSnapshotTests {
  @Test func uploadThrottle() {
    #expect(!CloudSnapshot.shouldUpload(key: "b", lastKey: "a", since: 59))
    #expect(CloudSnapshot.shouldUpload(key: "b", lastKey: "a", since: 60))
    #expect(CloudSnapshot.shouldUpload(key: "a", lastKey: nil, since: .infinity))
    #expect(!CloudSnapshot.shouldUpload(key: "a", lastKey: "a", since: 599))
    #expect(CloudSnapshot.shouldUpload(key: "a", lastKey: "a", since: 600))
  }

  @Test func phoneCopyAgesLater() {
    var s = WidgetSnapshot()
    s.usageAt = date("2026-10-17 10:00")
    s.staleAfter = 210
    let p = CloudSnapshot.phoneCopy(s)
    #expect(s.isStale(at: date("2026-10-17 10:04")))
    #expect(!p.isStale(at: date("2026-10-17 10:28")))
    #expect(p.isStale(at: date("2026-10-17 10:29")))
    #expect(p.displayKey == s.displayKey)
  }

  @Test func codingRoundTrip() throws {
    var s = WidgetSnapshot.sample(now: date("2026-10-17 10:00"))
    s.writtenAt = date("2026-10-17 10:01")
    s.history = [[29_400_000, 42, 18]]
    s.lists = [.init(name: "Einkauf", open: 3)]
    #expect(try WidgetSnapshot.decoded(s.encoded()) == s)
  }
}

@Suite struct AppReleaseTests {
  @Test func comparesVersions() {
    #expect(AppRelease.newer("v1.1", than: "1.0.0"))
    #expect(AppRelease.newer("1.0.1", than: "1.0"))
    #expect(AppRelease.newer("1.10.0", than: "1.9.3"))
    #expect(!AppRelease.newer("v1.0.0", than: "1.0"))
    #expect(!AppRelease.newer("0.9", than: "1.0.0"))
    #expect(!AppRelease.newer("nightly", than: "1.0.0"))
  }

  @Test func parsesLatestRelease() throws {
    let json = """
    {"tag_name": "v1.2", "draft": false, "prerelease": false, "html_url": "https://evil.example/",
     "body": "## What's new\\r\\n- **Update hint** in the details\\r\\n* Faster `/usage`\\r\\n\\r\\nThanks!"}
    """
    let r = try #require(AppRelease.parse(Data(json.utf8)))
    #expect(r.version == "1.2.0")
    #expect(r.notes == ["Update hint in the details", "Faster /usage"])
    #expect(AppRelease.page == "https://github.com/Breitec/crabbar/releases/latest")
  }

  @Test func skipsDraftsAndJunk() {
    #expect(AppRelease.parse(Data(#"{"tag_name": "v2.0", "prerelease": true}"#.utf8)) == nil)
    #expect(AppRelease.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    #expect(AppRelease.parse(Data("<html>".utf8)) == nil)
  }
}

/// For what is in the system's zone by design: reminder files and the times in Claude's blocks.
func local(_ s: String) -> Date { date(s, TimeZone.current.identifier) }

@Suite struct ClaudeConfigTests {
  let home = URL(fileURLWithPath: "/Users/test")

  @Test func defaultFolder() {
    #expect(ClaudeConfig.dir(nil, home: home).path == "/Users/test/.claude")
    #expect(ClaudeConfig.dir("  ", home: home).path == "/Users/test/.claude")
    #expect(ClaudeConfig.globalConfig(nil, home: home).path == "/Users/test/.claude.json")
  }

  @Test func movedFolder() {
    #expect(ClaudeConfig.dir("/Volumes/data/claude/", home: home).path == "/Volumes/data/claude")
    #expect(ClaudeConfig.dir("~/cc", home: home).path == "/Users/test/cc")
    #expect(ClaudeConfig.dir("/Volumes/data/./claude/../cc", home: home).path == "/Volumes/data/cc")
    // .claude.json moves into the folder along with it, as Claude Code does.
    #expect(ClaudeConfig.globalConfig("~/cc", home: home).path == "/Users/test/cc/.claude.json")
  }

  @Test func relativeCountsAsUnset() {
    // App and claude would resolve it against different working folders.
    #expect(ClaudeConfig.custom("claude-config", home: home) == nil)
    #expect(ClaudeConfig.dir("claude-config", home: home).path == "/Users/test/.claude")
    #expect(ClaudeConfig.globalConfig("./cc", home: home).path == "/Users/test/.claude.json")
    #expect(ClaudeConfig.custom("~other/cc", home: home) == nil)
    #expect(ClaudeConfig.custom("~", home: home)?.path == "/Users/test")
  }

  @Test func projectKey() {
    #expect(ClaudeConfig.projectKey("/Users/test/Clawd") == "-Users-test-Clawd")
    #expect(ClaudeConfig.projectKey("/Users/test/My Stuff.x") == "-Users-test-My-Stuff-x")
  }
}

@Suite struct RepeatingReminderTests {
  func tmpHome() -> ClawdHome {
    let h = ClawdHome(url: FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)"))
    h.ensure()
    return h
  }

  @Test func words() {
    #expect(RemindRepeat.word("Monthly") == .monthly)
    #expect(RemindRepeat.word(" weekly  # mondays") == .weekly)
    #expect(RemindRepeat.word("every") == nil)
    #expect(RemindRepeat.word("") == nil)
  }

  @Test func nextTime() {
    let at = date("2026-10-17 09:00")
    #expect(RemindRepeat.daily.next(after: at, from: at, timeZone: berlin) == date("2026-10-18 09:00"))
    // The Mac was off for a few days: the series goes on from the next time after now.
    #expect(RemindRepeat.daily.next(after: date("2026-10-20 12:00"), from: at, timeZone: berlin) == date("2026-10-21 09:00"))
    #expect(RemindRepeat.weekly.next(after: date("2026-10-20 12:00"), from: at, timeZone: berlin) == date("2026-10-24 09:00"))
    #expect(RemindRepeat.yearly.next(after: at, from: at, timeZone: berlin) == date("2027-10-17 09:00"))
    // The time of day stays across the end of summer time.
    #expect(RemindRepeat.daily.next(after: date("2026-10-24 10:00"), from: date("2026-10-24 10:00"), timeZone: berlin) == date("2026-10-25 10:00"))
  }

  @Test func monthEnds() {
    let jan31 = date("2026-01-31 10:00")
    #expect(RemindRepeat.monthly.next(after: jan31, from: jan31, timeZone: berlin) == date("2026-02-28 10:00"))
    #expect(RemindRepeat.monthly.next(after: date("2026-03-01 00:00"), from: jan31, timeZone: berlin) == date("2026-03-31 10:00"))
    let leap = date("2028-02-29 10:00")
    #expect(RemindRepeat.yearly.next(after: leap, from: leap, timeZone: berlin) == date("2029-02-28 10:00"))
  }

  @Test func fileRoundTrip() throws {
    let h = tmpHome()
    let at = local("2026-10-17 09:00")
    let u = h.newReminder(at: at, text: "Visa-Saldo prüfen", repeats: .monthly)
    #expect(try String(contentsOf: u, encoding: .utf8) == "---\nat: 2026-10-17T09:00\nrepeat: monthly\n---\nVisa-Saldo prüfen\n")
    let r = try #require(h.activeReminders().first)
    #expect(r.repeats == .monthly)

    // Fired 40 days late: one file in done, the next one after now.
    let fired = h.fire(r, now: local("2026-11-26 12:00"))
    #expect(fired.done != nil)
    let next = try #require(h.activeReminders().first)
    #expect(h.activeReminders().count == 1)
    #expect(next.at == local("2026-12-17 09:00"))
    #expect(next.repeats == .monthly)
    #expect(next.text == "Visa-Saldo prüfen")
    #expect(h.doneReminders().count == 1)

    // Moving keeps it repeating; a plain one fires without a successor.
    let moved = h.moveReminder(next, to: local("2026-12-18 10:00"))
    #expect(h.activeReminders().map(\.repeats) == [.monthly])
    #expect(moved.lastPathComponent.hasPrefix("2026-12-18 10-00"))
    let plain = h.newReminder(at: local("2026-12-01 10:00"), text: "einmal")
    let p = try #require(h.activeReminders().first { $0.path.lastPathComponent == plain.lastPathComponent })
    #expect(p.repeats == nil)
    #expect(h.fire(p, now: local("2026-12-01 10:01")).next == nil)
  }

  @Test func handWrittenFile() throws {
    let h = tmpHome()
    let dir = h.reminders.appendingPathComponent("2026-11")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "---\nat: 2026-11-16T10:00\nrepeat: Weekly\n---\nPay the taxes\n"
      .write(to: dir.appendingPathComponent("2026-11-16 10-00 Pay the taxes.md"), atomically: true, encoding: .utf8)
    try "---\nat: 2026-11-17T10:00\nrepeat: sometimes\n---\nOdd\n"
      .write(to: dir.appendingPathComponent("2026-11-17 10-00 Odd.md"), atomically: true, encoding: .utf8)
    let r = h.activeReminders()
    #expect(r.map(\.repeats) == [.weekly, nil])
  }

  @Test func remindBlock() {
    let p = ReplyBlocks.parse("""
    ```remind
    2026-11-17T10:00 monthly | Check the Visa card balance
    2026-10-19 10:00 | Call the client
    2026-10-19 09:00 weekly | Team call
    2026-10-20T10:00 monatlich | Konto prüfen
    2026-10-21T10:00 Uhr | Zahnarzt
    soon | Never
    ```
    """)
    #expect(p.actions == [.remind(local("2026-11-17 10:00"), "Check the Visa card balance", .monthly),
                          .remind(local("2026-10-19 10:00"), "Call the client", nil),
                          .remind(local("2026-10-19 09:00"), "Team call", .weekly),
                          .remind(local("2026-10-20 10:00"), "Konto prüfen", nil),
                          .remind(local("2026-10-21 10:00"), "Zahnarzt", nil)])
  }
}

@Suite struct TaskAtTests {
  func task(_ at: String) -> ClawdHome.TaskFile {
    var t = ClawdHome.TaskFile(name: "Morning", path: URL(fileURLWithPath: "/tmp/Morning.md"))
    t.atText = at
    t.at = ClawdHome.parseAt(at)
    return t
  }

  @Test func parse() {
    #expect(ClawdHome.parseAt("09:00, 18:00") == [540, 1080])
    #expect(ClawdHome.parseAt("18:00 9.15; 9.15") == [555, 1080])
    #expect(ClawdHome.parseAt("9") == [540])
    #expect(ClawdHome.parseAt("9h30") == [570])
    #expect(ClawdHome.parseAt("7h") == [420])
    #expect(ClawdHome.parseAt("25:00") == nil)
    #expect(ClawdHome.parseAt("9:75") == nil)
    #expect(ClawdHome.parseAt("09:00, morgens") == nil)
    #expect(ClawdHome.parseAt("") == nil)
  }

  @Test func atLeastTwoMinutesApart() {
    #expect(ClawdHome.parseAt("09:00, 09:01, 09:02, 09:03, 09:04, 09:05") == [540, 542, 544])
    // 00:01 is one minute after midnight, 23:59 one minute before it.
    #expect(ClawdHome.parseAt("23:57, 23:58, 23:59, 00:00, 00:01") == [0, 1437])
    #expect(ClawdHome.parseAt("23:59, 00:00") == [0])
    #expect(ClawdHome.parseAt("00:00, 23:58") == [0, 1438])
    #expect(ClawdHome.parseAt("12:00, 12:00") == [720])
  }

  @Test func slots() {
    let t = task("09:00, 18:00")
    #expect(t.slot(date("2026-10-17 08:00"), timeZone: berlin) == date("2026-10-16 18:00"))
    #expect(t.slot(date("2026-10-17 09:00"), timeZone: berlin) == date("2026-10-17 09:00"))
    #expect(t.slot(date("2026-10-17 17:59"), timeZone: berlin) == date("2026-10-17 09:00"))
    #expect(t.slot(date("2026-10-17 23:00"), timeZone: berlin) == date("2026-10-17 18:00"))
    // The day summer time ends: nine is still nine.
    #expect(t.slot(date("2026-10-25 09:30"), timeZone: berlin) == date("2026-10-25 09:00"))
  }

  @Test func due() {
    let t = task("09:00, 18:00")
    let made = date("2026-10-01 12:00")
    // Ran at nine: not again before six.
    #expect(!t.dueAt(lastRun: date("2026-10-17 09:00"), created: made, now: date("2026-10-17 10:00"), timeZone: berlin))
    #expect(t.dueAt(lastRun: date("2026-10-17 09:00"), created: made, now: date("2026-10-17 18:00"), timeZone: berlin))
    #expect(!t.dueAt(lastRun: date("2026-10-16 18:00"), created: made, now: date("2026-10-17 08:00"), timeZone: berlin))
    // Off since the day before yesterday: one catch-up run, then quiet until the next time.
    #expect(t.dueAt(lastRun: date("2026-10-15 18:00"), created: made, now: date("2026-10-17 10:00"), timeZone: berlin))
    #expect(!t.dueAt(lastRun: date("2026-10-17 10:00"), created: made, now: date("2026-10-17 10:01"), timeZone: berlin))
    // A new task waits for its next time instead of going off for one already past.
    #expect(!t.dueAt(lastRun: nil, created: date("2026-10-17 10:00"), now: date("2026-10-17 10:05"), timeZone: berlin))
    #expect(t.dueAt(lastRun: nil, created: date("2026-10-17 10:00"), now: date("2026-10-17 18:01"), timeZone: berlin))
  }

  @Test func fileAndBlock() throws {
    let h = ClawdHome(url: FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)"))
    h.ensure()
    let u = try #require(h.newTask(name: "Morning", head: ["at": "09:00, 18:00", "tools": "mcp__mail"], prompt: "Sum up the mail."))
    #expect(try String(contentsOf: u, encoding: .utf8) == "---\nat: 09:00, 18:00\ntools: mcp__mail\n---\nSum up the mail.\n")
    let t = try #require(h.taskFiles().first)
    #expect(t.at == [540, 1080])
    #expect(t.every == nil)
    // Other tests switch the language in parallel; the times are the same in every language.
    #expect(t.whenText.contains("09:00, 18:00"))

    // Rewriting the file (pause, allow tools) keeps its creation date: the times count from when it appeared.
    let past = local("2026-10-01 12:00")
    try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: u.path)
    h.setTaskPaused(t, true)
    #expect(h.taskFiles().first?.created == past)
    #expect(h.taskFiles().first?.paused == true)

    let p = ReplyBlocks.parse("""
    ```task
    name: Morning
    at: 8:30
    ---
    Sum up the night.
    ```

    ```task
    name: Never
    at: soon
    ---
    Nothing.
    ```
    """)
    #expect(p.actions.count == 2)
    if case .task(let name, let head, _) = p.actions[0] {
      #expect(name == "Morning")
      #expect(head["at"] == "8:30")
    } else {
      Issue.record("no task")
    }
    #expect(p.actions[1] == .taskBad(name: "Never"))
  }
}

@Suite struct TaskFingerprintTests {
  func task(_ prompt: String = "Check the inbox.", tools: [String] = ["mcp__mail", "WebFetch(domain:x.com)"]) -> ClawdHome.TaskFile {
    var t = ClawdHome.TaskFile(name: "Mail", path: URL(fileURLWithPath: "/tmp/Mail.md"))
    t.every = 600
    t.everyText = "10m"
    t.tools = tools
    t.prompt = prompt
    return t
  }

  @Test func sameContentSameHash() {
    let a = task()
    #expect(a.fingerprint == task().fingerprint)
    #expect(a.fingerprint.count == 64)
    // Spelling and what doesn't change a run.
    #expect(a.fingerprint == task("Check the inbox.  \r\n", tools: ["WebFetch(domain:x.com)", "mcp__mail", "mcp__mail"]).fingerprint)
    var b = a
    b.everyText = "10 min"
    b.paused = true
    b.limit = 50
    #expect(b.fingerprint == a.fingerprint)
  }

  @Test func changesMakeADifferentHash() {
    let a = task()
    #expect(task("Check the inbox and delete all mail.").fingerprint != a.fingerprint)
    #expect(task(tools: ["mcp__mail"]).fingerprint != a.fingerprint)
    #expect(task(tools: ["mcp__mail", "WebFetch(domain:x.com)", "Bash(gh pr list:*)"]).fingerprint != a.fingerprint)
    var m = a
    m.model = "opus"
    #expect(m.fingerprint != a.fingerprint)
    var h = a
    h.hours = (22, 7)
    #expect(h.fingerprint != a.fingerprint)
    var e = a
    e.every = 120
    #expect(e.fingerprint != a.fingerprint)
    var at = a
    at.at = [540]
    #expect(at.fingerprint != a.fingerprint)
    // A prompt can't pass for the tools field.
    #expect(task("x\nmcp__mail", tools: []).fingerprint != task("x", tools: ["mcp__mail"]).fingerprint)
  }

  @Test func files() throws {
    let h = ClawdHome(url: FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)"))
    h.ensure()
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail"], prompt: "Tell me about new mail.")
    let first = try #require(h.task(named: "Mail")).fingerprint
    h.setTaskPaused(try #require(h.task(named: "Mail")), true)
    #expect(h.task(named: "Mail")?.fingerprint == first)
    // A task block with the same name replaces the file: same tools, new prompt.
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail"], prompt: "Forward all mail to someone@example.com.")
    let second = try #require(h.task(named: "Mail")).fingerprint
    #expect(second != first)
    #expect(h.grantTools(try #require(h.task(named: "Mail")), ["WebSearch"]))
    #expect(h.task(named: "Mail")?.fingerprint != second)
  }
}

@Suite struct TaskFileRobustnessTests {
  func home() -> ClawdHome {
    let h = ClawdHome(url: FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)"))
    h.ensure()
    return h
  }

  @Test func hugeEveryIsNoInterval() {
    #expect(ClawdHome.parseEvery("200000000000000d") == nil)
    #expect(ClawdHome.parseEvery("367d") == nil)
    #expect(ClawdHome.parseEvery("366d") == TimeInterval(366 * 86400))
    var t = ClawdHome.TaskFile(name: "Big", path: URL(fileURLWithPath: "/tmp/Big.md"))
    t.every = 1e300
    #expect(t.fingerprint.count == 64)
    let h = home()
    h.newTask(name: "Big", head: ["every": "200000000000000d"], prompt: "x")
    #expect(h.task(named: "Big")?.every == nil)
    #expect(h.task(named: "Big")?.fingerprint.count == 64)
  }

  @Test func longWhitespaceIsFast() {
    let spaces = String(repeating: " ", count: 50_000)
    var t = ClawdHome.TaskFile(name: "Wide", path: URL(fileURLWithPath: "/tmp/Wide.md"))
    t.prompt = spaces + "x\n" + spaces + "\nend" + spaces
    let start = ContinuousClock.now
    let fp = t.fingerprint
    let head = ClawdHome.keyValues("model: a" + spaces + "b")
    #expect(ContinuousClock.now - start < .seconds(1))
    var short = t
    short.prompt = spaces + "x\n\nend"
    #expect(fp == short.fingerprint)
    #expect(head["model"] == "a" + spaces + "b")
  }

  @Test func hiddenCharactersShow() {
    #expect(ClawdHome.visibleText("a\u{200B}b\u{202E}c\u{E0041}d\u{FE0F}e\u{2066}f") ==
      "a[U+200B]b[U+202E]c[U+E0041]d[U+FE0F]e[U+2066]f")
    #expect(ClawdHome.visibleText("Line one\n\tLine two, äöü ✓") == "Line one\n\tLine two, äöü ✓")
    #expect(ClawdHome.visibleText("x\u{7}y\r\nz\rw") == "x[U+0007]y\nz\nw")
  }

  @Test func headerOnlyRewrites() throws {
    let h = home()
    let u = h.tasks.appendingPathComponent("Mail.md")
    let raw = "---\r\nevery: 10m\r\ntools: mcp__mail\r\n---\r\nCheck the mail.\r\ntools: Bash(rm:*)\r\npaused: no\r\n"
    try FileManager.default.createDirectory(at: h.tasks, withIntermediateDirectories: true)
    try raw.write(to: u, atomically: true, encoding: .utf8)
    let t = try #require(h.task(named: "Mail"))
    #expect(t.tools == ["mcp__mail"])
    #expect(t.prompt.contains("tools: Bash(rm:*)"))
    let fp = t.fingerprint

    h.setTaskPaused(t, true)
    let p = try #require(h.task(named: "Mail"))
    #expect(p.paused)
    #expect(p.fingerprint == fp)
    #expect(p.prompt.contains("paused: no"))
    h.setTaskPaused(p, false)
    let r = try #require(h.task(named: "Mail"))
    #expect(!r.paused)
    #expect(r.fingerprint == fp)
    #expect(r.every == 600)

    #expect(h.grantTools(r, ["WebSearch"]))
    let g = try #require(h.task(named: "Mail"))
    #expect(g.tools == ["mcp__mail", "WebSearch"])
    #expect(g.prompt == r.prompt)
    var expected = r
    expected.tools = ["mcp__mail", "WebSearch"]
    #expect(g.fingerprint == expected.fingerprint)

    // Only "paused: yes" in the header: unpausing leaves a header that still parses.
    let v = h.tasks.appendingPathComponent("Solo.md")
    try "---\npaused: yes\n---\nJust read.\n".write(to: v, atomically: true, encoding: .utf8)
    h.setTaskPaused(try #require(h.task(named: "Solo")), false)
    #expect(h.task(named: "Solo")?.prompt == "Just read.")
    #expect(h.task(named: "Solo")?.paused == false)
  }
}

@Suite struct TaskResumeTests {
  func home() -> ClawdHome {
    let h = ClawdHome(url: FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)"))
    h.ensure()
    return h
  }

  @Test func lowerCaseBlockKeepsThePause() throws {
    let h = home()
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail", "limit": "50", "paused": "yes"], prompt: "Read the mail.")
    let old = try #require(h.task(named: "mail"))
    #expect(old.name == "Mail")
    // Same text and tools, other case, no paused or limit: the task stays paused with its limit.
    let kept = ClawdHome.mergedHead(["every": "10m", "tools": "mcp__mail"], over: old)
    #expect(!kept.resumes)
    h.newTask(name: "mail", head: kept.head, prompt: "Read the mail.")
    let t = try #require(h.task(named: "Mail"))
    #expect(t.paused)
    #expect(t.limit == 50)
    #expect(t.fingerprint == old.fingerprint)
    // Resuming by a block takes the approval back.
    #expect(ClawdHome.mergedHead(["every": "10m", "paused": "no"], over: t).resumes)
    #expect(!ClawdHome.mergedHead(["every": "10m", "paused": "yes"], over: t).resumes)
    #expect(h.removeTask("MAIL")?.name == "Mail")
  }

  @Test func resumedOutsideThePanelAsks() throws {
    let h = home()
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail", "paused": "yes"], prompt: "Read the mail.")
    let paused = try #require(h.task(named: "Mail"))
    let fp = paused.fingerprint
    #expect(paused.unapproved(approved: ["mcp__mail"], approvedFor: fp, pauseSeen: true).isEmpty)
    // Someone else takes "paused: yes" out of the file.
    let raw = try String(contentsOf: paused.path, encoding: .utf8).replacingOccurrences(of: "paused: yes\n", with: "")
    try raw.write(to: paused.path, atomically: true, encoding: .utf8)
    let resumed = try #require(h.task(named: "Mail"))
    #expect(!resumed.paused)
    #expect(resumed.fingerprint == fp)
    #expect(resumed.unapproved(approved: ["mcp__mail"], approvedFor: fp, pauseSeen: true) == ["mcp__mail"])
    // Resumed with the panel's Resume (no pause on record): the approval holds.
    #expect(resumed.unapproved(approved: ["mcp__mail"], approvedFor: fp, pauseSeen: false).isEmpty)
    #expect(resumed.unapproved(approved: ["mcp__mail"], approvedFor: "other", pauseSeen: false) == ["mcp__mail"])
  }

  @Test func frontMatterIsLinear() {
    let raw = "---" + String(repeating: "\n", count: 50_000) + "x"
    let start = ContinuousClock.now
    #expect(ClawdHome.frontMatter(raw) == nil)
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(ClawdHome.frontMatter("---\n\n---\nbody")?.1 == "body")
    #expect(ClawdHome.frontMatter("---\r\nevery: 10m\r\n---\r\nbody")?.0 == "every: 10m")
    #expect(ClawdHome.frontMatter("---  \n\nevery: 10m\n---\nbody")?.0 == "\nevery: 10m")
  }
}
