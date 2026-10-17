import WidgetKit
import SwiftUI
import ClawdCore

// Shared by the Mac and iPhone widget extensions; each one brings its own Provider and RefreshIntent.

struct UsageEntry: TimelineEntry {
  let date: Date
  let snap: WidgetSnapshot?
}

struct WidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: UsageEntry

  var body: some View {
    if let s = entry.snap {
      let _ = { L10n.setting = s.language }()
      switch family {
      case .systemSmall: SmallView(s: s, now: entry.date)
      case .systemMedium: MediumView(s: s, now: entry.date)
      default: LargeView(s: s, now: entry.date)
      }
    } else {
      VStack(spacing: 8) {
        ClawdStill(mood: .sleep, halves: nil).frame(width: 60, height: 36)
        Text(T("widget.noApp")).font(.caption).foregroundStyle(Palette.textHead).multilineTextAlignment(.center)
      }
    }
  }
}

// MARK: - pieces

struct Head: View {
  var s: WidgetSnapshot
  var body: some View {
    HStack(spacing: 4) {
      Text("CLAUDE").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textHead)
      Spacer(minLength: 2)
      if let h = s.halves { HeartsView(halves: h, scale: 0.9) }
      Button(intent: RefreshIntent()) {
        Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textHead)
      }
      .buttonStyle(.plain)
    }
  }
}

struct PercentClawd: View {
  var s: WidgetSnapshot
  var now: Date
  var sky = true

  var body: some View {
    HStack(alignment: .bottom, spacing: 4) {
      HStack(alignment: .lastTextBaseline, spacing: 1) {
        Text(s.usage?.session.map(String.init) ?? "--")
          .font(.system(size: 32, weight: .light))
          .foregroundStyle(s.level.color)
          .minimumScaleFactor(0.6)
        Text("%").font(.system(size: 13)).foregroundStyle(Palette.textHead)
      }
      Spacer(minLength: 0)
      ClawdStill(mood: s.mood, halves: s.halves).frame(width: 44, height: 30)
    }
    .background(alignment: .bottom) {
      if sky { SkyStill(s: s, now: now).frame(height: 40).padding(.horizontal, -4) }
    }
  }
}

struct MiniLimit: View {
  var label: String
  var text: String
  var pct: Int?
  var color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textDim)
        Spacer()
        Text(text).font(.system(size: 9)).foregroundStyle(Palette.textHead).lineLimit(1)
      }
      LimitBar(pct: pct, color: color, height: 4)
    }
  }
}

struct StatusLine: View {
  var s: WidgetSnapshot
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(s.statusLevel.color).frame(width: 6, height: 6)
      Text(s.statusText).font(.system(size: 9)).foregroundStyle(Palette.textHead).lineLimit(1)
    }
  }
}

struct Footer: View {
  var s: WidgetSnapshot
  var now: Date
  var body: some View {
    HStack {
      Text(s.plan).font(.system(size: 8)).foregroundStyle(Palette.textFoot)
      Spacer()
      if let at = s.usageAt {
        let stale = s.isStale(at: now)
        Text((stale ? T("stale") + " · " : "") + Format.hhmm(at)).font(.system(size: 8))
          .foregroundStyle(stale ? Palette.warn : Palette.textFoot)
      }
    }
  }
}

// MARK: - sizes

struct SmallView: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Head(s: s)
      PercentClawd(s: s, now: now)
      LimitBar(pct: s.usage?.session, color: s.level.color, height: 5)
      Text(s.isStale(at: now) ? T("stale") + " · " + s.resetLine(now) : s.resetLine(now)).font(.system(size: 10))
        .foregroundStyle(s.isStale(at: now) ? Palette.warn : Palette.textMain).lineLimit(1).minimumScaleFactor(0.8)
      Spacer(minLength: 0)
      MiniLimit(label: T("ui.week"), text: s.limitText(s.usage?.week, s.usage?.weekReset, now), pct: s.usage?.week, color: Palette.week)
    }
  }
}

struct MediumView: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Head(s: s)
        PercentClawd(s: s, now: now)
        LimitBar(pct: s.usage?.session, color: s.level.color, height: 5)
        Text(s.resetLine(now)).font(.system(size: 10)).foregroundStyle(Palette.textMain).lineLimit(1).minimumScaleFactor(0.8)
      }
      VStack(alignment: .leading, spacing: 7) {
        MiniLimit(label: T("ui.week"), text: s.limitText(s.usage?.week, s.usage?.weekReset, now), pct: s.usage?.week, color: Palette.week)
        if s.usage?.fable != nil {
          MiniLimit(label: T("ui.fable"), text: s.limitText(s.usage?.fable, s.usage?.fableReset, now), pct: s.usage?.fable, color: Palette.fable)
        }
        HStack {
          Text(T("ui.sessions")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textDim)
          Spacer()
          Text(s.sessionsLine).font(.system(size: 9)).foregroundStyle(Palette.textHead).lineLimit(1).minimumScaleFactor(0.8)
        }
        Spacer(minLength: 0)
        if !s.statusText.isEmpty { StatusLine(s: s) }
        Footer(s: s, now: now)
      }
    }
  }
}

struct LargeView: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Head(s: s)
      PercentClawd(s: s, now: now)
      LimitBar(pct: s.usage?.session, color: s.level.color, height: 6)
      Text(s.resetLine(now)).font(.system(size: 11)).foregroundStyle(Palette.textMain)
      MiniLimit(label: T("ui.week"), text: s.limitText(s.usage?.week, s.usage?.weekReset, now), pct: s.usage?.week, color: Palette.week)
      if s.usage?.fable != nil {
        MiniLimit(label: T("ui.fable"), text: s.limitText(s.usage?.fable, s.usage?.fableReset, now), pct: s.usage?.fable, color: Palette.fable)
      }
      HStack {
        Text(T("ui.sessions")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textDim)
        Spacer()
        Text(s.sessionsLine).font(.system(size: 9)).foregroundStyle(Palette.textHead)
      }
      if !s.statusText.isEmpty { StatusLine(s: s) }
      DayChart(s: s, now: now).frame(height: 40)
      if let r = s.nextReminder, let at = s.nextReminderAt {
        HStack(spacing: 4) {
          Image(systemName: "bell").font(.system(size: 8)).foregroundStyle(Palette.warn)
          Text(T("widget.nextReminder", "\(Format.remindTime(at, now: now)) \(r)")).font(.system(size: 9))
            .foregroundStyle(Palette.textMain).lineLimit(1)
        }
      }
      let open = s.lists.filter { $0.open > 0 }
      if !open.isEmpty {
        Text(open.prefix(3).map { T("widget.listOpen", $0.name, $0.open) }.joined(separator: "  ·  "))
          .font(.system(size: 9)).foregroundStyle(Palette.textHead).lineLimit(1)
      }
      Spacer(minLength: 0)
      Footer(s: s, now: now)
    }
  }
}
