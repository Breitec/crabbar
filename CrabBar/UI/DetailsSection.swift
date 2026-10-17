import SwiftUI
import ClawdCore

/// The expandable part: 24h/7d stats from /usage, the 7-day limits chart, top projects and versions.
struct DetailsSection: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.config.showStats {
        Divider().overlay(Palette.divider).padding(.bottom, 8 * k)
        period(T("ui.day"), model.usage?.day)
        period(T("ui.week7"), model.usage?.week7)
      }
      if model.config.showHistory {
        Divider().overlay(Palette.divider).padding(.bottom, 8 * k)
        Caption(text: T("ui.hist")).padding(.bottom, 4 * k)
        HistoryChart(model: model)
        projects
      }
      Divider().overlay(Palette.divider).padding(.bottom, 7 * k)
      versions
    }
  }

  func period(_ label: String, _ p: UsagePeriod?) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Caption(text: label).padding(.bottom, 3 * k)
      Text(p.map { "\(plural($0.requests, "request"))  ·  \(plural($0.sessions, "session"))" } ?? T("noData"))
        .font(.system(size: 10.5 * k)).foregroundStyle(Palette.textMain)
        .padding(.bottom, 2 * k)
      Text(p?.lines.map(StatLine.format).joined(separator: "  ·  ") ?? "")
        .font(.system(size: 10 * k)).foregroundStyle(Palette.textHead)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10 * k)
    }
  }

  @ViewBuilder var projects: some View {
    if let p = model.projects {
      let sum = p.total.values.reduce(0, +)
      if sum > 0 {
        VStack(alignment: .leading, spacing: 2 * k) {
          Caption(text: T("ui.projects")).padding(.bottom, 2 * k).help(T("hist.projTip"))
          ForEach(p.total.sorted { $0.value > $1.value }.prefix(4), id: \.key) { e in
            let share = 100 * e.value / sum
            HStack(spacing: 0) {
              Text(e.key).font(.system(size: 10 * k)).foregroundStyle(Palette.textMain)
                .lineLimit(1).truncationMode(.tail)
                .padding(.trailing, 8 * k)
              Spacer(minLength: 0)
              ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.track)
                RoundedRectangle(cornerRadius: 2).fill(Palette.clawd).frame(width: max(2, 70 * k * share / 100))
              }
              .frame(width: 70 * k, height: 4 * k)
              Text(String(format: "%.0f%%", share)).font(.system(size: 10 * k)).foregroundStyle(Palette.textHead)
                .frame(width: 34 * k, alignment: .trailing)
            }
            .help(p.paths[e.key] ?? "")
          }
        }
        .padding(.bottom, 10 * k)
      }
    } else {
      Text(T("hist.counting")).font(.system(size: 10 * k)).foregroundStyle(Palette.textDim).padding(.bottom, 10 * k)
        .onAppear { if !model.projRunning { model.scanProjects() } }
    }
  }

  var versions: some View {
    HStack(alignment: .top) {
      Button {
        if model.updating { return }
        if model.hasUpdate { model.runClaudeUpdate() }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!) }
      } label: {
        Text(versionText).font(.system(size: 10 * k))
          .foregroundStyle(model.hasUpdate || model.updating ? Palette.warn : Palette.textHead)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
      }
      .buttonStyle(.plain)
      .help(versionTip)
      Spacer(minLength: 8 * k)
      if let r = model.appUpdate {
        Button { model.openReleasePage() } label: {
          Text(T("app.available", r.version)).font(.system(size: 10 * k)).foregroundStyle(Palette.warn)
        }
        .buttonStyle(.plain)
        .help(releaseTip(r))
      } else {
        Text(T("clawd.version", AppModel.appVersion))
          .font(.system(size: 10 * k)).foregroundStyle(Palette.textDim)
          .help(T("clawd.versionTip"))
      }
    }
  }

  func releaseTip(_ r: AppRelease) -> String {
    var lines = [T("app.head", AppModel.appVersion, r.version)]
    if !r.notes.isEmpty { lines += [""] + r.notes.prefix(15).map { "• \($0)" } }
    if r.notes.count > 15 { lines.append(T("chg.more", r.notes.count - 15)) }
    lines += ["", T("app.click")]
    return lines.joined(separator: "\n")
  }

  var versionText: String {
    guard let v = model.verLocal else { return "" }
    if model.updating { return "v\(v)  ·  \(T("ver.updating"))" }
    if model.hasUpdate, let n = model.verLatest { return "v\(v)  ·  \(T("ver.available", n))" }
    if model.verLatest != nil { return "v\(v)  ·  \(T("ver.latest"))" }
    return "v\(v)"
  }

  var versionTip: String {
    guard model.hasUpdate, let l = model.verLocal, let n = model.verLatest else { return T("chg.open") }
    var lines = [T("chg.head", l, n), ""]
    if let c = model.changes, c.forVersion == n {
      lines += c.items.prefix(25).map { "• \($0)" }
      if c.items.count > 25 { lines.append(T("chg.more", c.items.count - 25)) }
      if c.items.isEmpty { lines.append(T("chg.empty")) }
    } else {
      lines.append(T("chg.loading"))
    }
    lines += ["", T("chg.click")]
    return lines.joined(separator: "\n")
  }
}

/// Session (green, filled) and week (blue) over the last 7 days; hover shows the moment.
struct HistoryChart: View {
  @Environment(\.k) var k
  var model: AppModel
  @State private var cursor: CGFloat?

  var body: some View {
    let h = 44 * k
    let t1 = UsageHistory.minute(model.now)
    let t0 = t1 - 7 * 1440
    VStack(alignment: .leading, spacing: 0) {
      GeometryReader { g in
        let w = g.size.width
        Canvas { ctx, size in
          func xp(_ t: Int) -> CGFloat { w * CGFloat(t - t0) / CGFloat(t1 - t0) }
          func yp(_ v: Int) -> CGFloat { 1 + (h - 2) * (1 - CGFloat(min(100, v)) / 100) }
          // Midnight lines.
          for x in midnights(t0: t0, t1: t1).map({ xp($0) }) {
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(Palette.divider), lineWidth: 1)
          }
          for (col, color) in [(2, Palette.week), (1, Palette.ok)] {
            for run in model.history.runs(from: t0, column: col) {
              var pts = run.map { CGPoint(x: xp($0.0), y: yp($0.1)) }
              if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + 1, y: pts[0].y)) }
              let line = Path { p in p.addLines(pts) }
              if col == 1 {
                var area = Path()
                area.move(to: CGPoint(x: pts[0].x, y: h))
                area.addLines(pts)
                area.addLine(to: CGPoint(x: pts.last!.x, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .color(Palette.histArea))
              }
              ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
          }
          if let c = cursor {
            ctx.stroke(Path { $0.move(to: CGPoint(x: c, y: 0)); $0.addLine(to: CGPoint(x: c, y: h)) },
                       with: .color(Color(hex: "#66FFFFFF")), lineWidth: 1)
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          if case .active(let p) = phase { cursor = max(0, min(w, p.x)) } else { cursor = nil }
        }
      }
      .frame(height: h)
      dayLabels(t0: t0, t1: t1).frame(height: 11 * k)
      caption(t0: t0, t1: t1)
        .font(.system(size: 10 * k))
        .foregroundStyle(Palette.textHead)
        .lineLimit(1)
        .padding(.top, 1)
        .padding(.bottom, 10 * k)
    }
  }

  func midnights(t0: Int, t1: Int) -> [Int] {
    let cal = Calendar.current
    var d = cal.startOfDay(for: Date(timeIntervalSince1970: Double(t0) * 60))
    var out: [Int] = []
    while true {
      d = cal.date(byAdding: .day, value: 1, to: d)!
      let m = UsageHistory.minute(d)
      if m >= t1 { break }
      out.append(m)
    }
    return out
  }

  func dayLabels(t0: Int, t1: Int) -> some View {
    GeometryReader { g in
      let w = g.size.width
      let marks = [t0] + midnights(t0: t0, t1: t1) + [t1]
      ZStack(alignment: .topLeading) {
        ForEach(Array(marks.dropLast().enumerated()), id: \.offset) { i, m in
          let x0 = w * CGFloat(m - t0) / CGFloat(t1 - t0)
          let x1 = w * CGFloat(marks[i + 1] - t0) / CGFloat(t1 - t0)
          if x1 - x0 >= 14 * k {
            Text(Format.local(Date(timeIntervalSince1970: Double(m + 1) * 60), "EEE"))
              .font(.system(size: 8 * k)).foregroundStyle(Palette.textFoot)
              .frame(width: x1 - x0)
              .offset(x: x0)
          }
        }
      }
    }
  }

  @ViewBuilder func caption(t0: Int, t1: Int) -> some View {
    if let c = cursor {
      Text(pointText(c, t0: t0, t1: t1))
    } else if model.history.samples.isEmpty {
      Text(T("hist.empty"))
    } else {
      HStack(spacing: 0) {
        Text("━ ").foregroundStyle(Palette.ok)
        Text(T("hist.session") + "    ")
        Text("━ ").foregroundStyle(Palette.week)
        Text(T("hist.week"))
      }
    }
  }

  func pointText(_ x: CGFloat, t0: Int, t1: Int) -> String {
    let w = 238 * k
    let t = t0 + Int(Double(t1 - t0) * Double(min(x, w) / w))
    var parts = [Format.local(Date(timeIntervalSince1970: Double(t) * 60), "EEE HH:mm")]
    if let s = model.history.sample(at: t) {
      if s[1] >= 0 { parts.append("\(T("hist.session")) \(s[1])%") }
      if s[2] >= 0 { parts.append("\(T("hist.week")) \(s[2])%") }
    } else {
      parts.append(T("noData"))
    }
    if let byName = model.projects?.hours[t / 60], let top = byName.max(by: { $0.value < $1.value }) { parts.append(top.key) }
    return parts.joined(separator: "  ·  ")
  }
}
