import SwiftUI
import ClawdCore

private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
  var k: CGFloat {
    get { self[ScaleKey.self] }
    set { self[ScaleKey.self] = newValue }
  }
}

struct Caption: View {
  @Environment(\.k) var k
  var text: String
  var body: some View {
    Text(text).font(.system(size: 9 * k, weight: .semibold)).foregroundStyle(Palette.textDim)
  }
}

/// The widget itself, 1:1 with the original layout: limits, Clawd on his sky, sessions, status, details.
struct UsageCard: View {
  var model: AppModel
  var floating = false
  var onHide: () -> Void = {}
  var onExit: () -> Void = {}
  var onMenu: (() -> NSMenu)?

  var k: CGFloat { model.config.scale }

  var body: some View {
    let u = model.usage
    let c = model.config
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.bottom, 6 * k)

      MascotSkyRow(model: model)
        .padding(.bottom, 4 * k)

      LimitBar(pct: u?.session, color: model.sessionLevel.color, height: 6 * k)
        .padding(.bottom, 7 * k)

      Text(resetLine)
        .font(.system(size: 11 * k))
        .foregroundStyle(Palette.textMain)
        .padding(.bottom, 9 * k)

      limitRow(T("ui.week"), pct: u?.week, reset: u?.weekReset, color: Palette.week)
      if u?.fable != nil {
        limitRow(T("ui.fable"), pct: u?.fable, reset: u?.fableReset, color: Palette.fable, last: true)
      }

      if c.showSessions {
        HStack(alignment: .firstTextBaseline, spacing: 8 * k) {
          Caption(text: T("ui.sessions"))
          Spacer(minLength: 0)
          Text(model.sessionsLine)
            .font(.system(size: 10 * k))
            .foregroundStyle(Palette.textHead)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .help(model.sessionsTip)
        .padding(.top, 10 * k)
      }

      if c.showStatus {
        Button {
          NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
        } label: {
          HStack(alignment: .top, spacing: 6 * k) {
            Circle().fill(model.statusLevel.color).frame(width: 7 * k, height: 7 * k).padding(.top, 4 * k)
            VStack(alignment: .leading, spacing: 1) {
              Text(model.statusText)
                .font(.system(size: 10.5 * k))
                .foregroundStyle(model.status?.allGood == false && !model.statusStale ? Palette.textMain : Palette.textHead)
                .fixedSize(horizontal: false, vertical: true)
              if !model.statusExtra.isEmpty {
                Text(model.statusExtra).font(.system(size: 10 * k)).foregroundStyle(Palette.textHead)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(T("ui.openStatus"))
        .padding(.top, 10 * k)
      }

      if c.expanded {
        DetailsSection(model: model)
          .padding(.top, 11 * k)
      }

      footer.padding(.top, 7 * k)
    }
    .environment(\.k, k)
    .padding(EdgeInsets(top: 10 * k, leading: 12 * k, bottom: 11 * k, trailing: 12 * k))
    .frame(width: 262 * k, alignment: .leading)
    .coordinateSpace(.named("card"))
    .onContinuousHover(coordinateSpace: .named("card")) { phase in
      // As in the original, the cursor anywhere over the widget wakes Clawd and draws his gaze.
      switch phase {
      case .active(let p):
        model.hovering = true
        model.mouseX = p.x / k - model.areaOriginX
      case .ended:
        model.hovering = false
        model.mouseX = nil
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 10 * (floating ? k : 1))
        .fill(Palette.card)
        .overlay(RoundedRectangle(cornerRadius: 10 * (floating ? k : 1)).stroke(Palette.border, lineWidth: 1))
    )
    .environment(\.colorScheme, .dark)
  }

  var resetLine: String {
    guard let u = model.usage, u.session != nil else {
      if let e = model.claudeError { return e }
      return model.usageAt == nil ? T("loading") : T("noData")
    }
    if let r = u.sessionReset {
      if let s = Format.span(until: r, now: model.now) { return T("reset.in", s) }
      return T("reset.closed")
    }
    return ""
  }

  var header: some View {
    HStack(spacing: 0) {
      Text(T("ui.title"))
        .font(.system(size: 9.5 * k, weight: .semibold))
        .foregroundStyle(Palette.textHead)
      Spacer(minLength: 4)
      TipBadge(model: model)
      if model.config.showMascot { HeaderHearts(model: model) }
      headerButton(model.config.expanded ? "▴" : "▾", size: 11, help: T("ui.details")) {
        model.updateConfig { $0.expanded.toggle() }
      }
      .padding(.trailing, 9 * k)
      headerButton("–", size: 13, help: T("ui.hide"), action: onHide)
        .padding(.trailing, 9 * k)
      headerButton("✕", size: 11, help: T("ui.exit"), action: onExit)
    }
    .contextMenu { MainMenuItems(model: model) }
  }

  func headerButton(_ s: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(s).font(.system(size: size * k)).foregroundStyle(Palette.textHead).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  func limitRow(_ label: String, pct: Int?, reset: Date?, color: Color, last: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Caption(text: label)
        Spacer()
        Text(limitText(pct, reset))
          .font(.system(size: 10 * k))
          .foregroundStyle(Palette.textHead)
      }
      .padding(.bottom, 4 * k)
      LimitBar(pct: pct, color: color, height: 4 * k)
        .padding(.bottom, last ? 0 : 7 * k)
    }
  }

  func limitText(_ pct: Int?, _ reset: Date?) -> String {
    guard let pct else { return model.usage == nil ? "" : T("noData") }
    var s = "\(pct)%"
    if let r = reset, let sp = Format.span(until: r, now: model.now) { s += "  ·  \(sp)" }
    return s
  }

  var footer: some View {
    HStack {
      Text(accountLine)
        .font(.system(size: 9 * k))
        .foregroundStyle(model.account?.loggedIn == false ? Palette.crit : Palette.textFoot)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(accountLine)
      Spacer(minLength: 8 * k)
      Text(stamp).font(.system(size: 9 * k)).foregroundStyle(Palette.textFoot)
    }
  }

  var accountLine: String {
    guard model.config.showAccount, let a = model.account else { return "" }
    if !a.loggedIn { return T("acc.out") }
    return [a.plan, a.email].filter { !$0.isEmpty }.joined(separator: "  ·  ")
  }

  var stamp: String {
    guard let at = model.usageAt else { return "" }
    let s = Format.hhmmss(at)
    return model.isStale ? "\(T("stale")) · \(s)" : s
  }
}

/// Clawd's panel badge: bell (reminder due) > blue chat (unread) > lamp with tip count > grey chat.
struct TipBadge: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    let due = !model.reminders.due.isEmpty
    let unread = model.chat.unread
    let tips = model.config.showAdvisor ? model.advisor.tips.count : 0
    if model.config.showChat || tips > 0 || due {
      let (icon, color, count, tip): (String, Color, String, String) =
        due ? ("bell.fill", Palette.warn, "", T("chat.badgeRemind"))
        : unread ? ("bubble.left.fill", Palette.week, "", T("chat.badgeUnread"))
        : tips > 0 ? ("lightbulb.fill", Palette.warn, "\(tips)", T("adv.badge", tips))
        : ("bubble.left", Palette.textHead, "", T("chat.badge"))
      Button {
        model.openPanel?(nil)
      } label: {
        HStack(spacing: 2 * k) {
          Image(systemName: icon).font(.system(size: 9 * k))
          if !count.isEmpty { Text(count).font(.system(size: 9.5 * k, weight: .semibold)) }
        }
        .foregroundStyle(color)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(tip)
      .padding(.trailing, 12 * k)
    }
  }
}

/// The big percentage with Clawd beside it, both in front of the sky.
struct MascotSkyRow: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    let u = model.usage
    HStack(alignment: .bottom, spacing: 0) {
      HStack(alignment: .lastTextBaseline, spacing: 2 * k) {
        Text(u?.session.map(String.init) ?? "--")
          .font(.system(size: 30 * k, weight: .light))
          .foregroundStyle(model.sessionLevel.color)
          .monospacedDigit()
        Text("%")
          .font(.system(size: 14 * k))
          .foregroundStyle(Palette.textHead)
      }
      if model.config.showMascot {
        MascotArea(model: model)
          .padding(.leading, 10 * k)
          .padding(.bottom, -3 * k)
      } else {
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .bottom) {
      if model.config.showMascot && model.config.showSky {
        SkyLayer(model: model)
          .padding(.bottom, -3 * k)
      }
    }
  }
}

struct SkyLayer: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    GeometryReader { g in
      let sky = model.skyRender
      Canvas { ctx, size in
        var c = ctx
        c.scaleBy(x: k, y: k)
        Draw.sky(&c, sky, size: CGSize(width: size.width / k, height: size.height / k))
      }
      .mask(EdgeFade())
      .onAppear { model.skySize = CGSize(width: g.size.width / k, height: g.size.height / k) }
      .onChange(of: g.size) { _, s in model.skySize = CGSize(width: s.width / k, height: s.height / k) }
      .help(model.skyRender.tooltip)
      .contextMenu { DevMenuItems(model: model) }
    }
  }
}

struct MascotArea: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    GeometryReader { g in
      let render = model.mascotRender
      Canvas { ctx, size in
        var c = ctx
        c.scaleBy(x: k, y: k)
        Draw.mascot(&c, render, size: CGSize(width: size.width / k, height: size.height / k))
      }
      .contentShape(Rectangle())
      .onAppear {
        model.areaSize = CGSize(width: g.size.width / k, height: g.size.height / k)
        model.areaOriginX = g.frame(in: .named("card")).minX / k
      }
      .onChange(of: g.size) { _, s in
        model.areaSize = CGSize(width: s.width / k, height: s.height / k)
        model.areaOriginX = g.frame(in: .named("card")).minX / k
      }
      .onTapGesture { location in
        // Only on Clawd himself (the 36 × 26.4 sprite, which moves with the lift).
        let r = model.mascotRender
        let x = location.x / k, y = location.y / k
        let top = g.size.height / k - (r.bottom + ClawdSprite.height)
        if x >= r.x - 4 && x <= r.x + ClawdSprite.width + 4 && y >= top - 4 && y <= top + ClawdSprite.height + 4 {
          model.mascot.click()
        }
      }
      .contextMenu { DevMenuItems(model: model) }
    }
    .frame(height: 44 * k)
  }
}

/// The hearts redraw every animation tick; kept in their own view so the card itself does not.
struct HeaderHearts: View {
  @Environment(\.k) var k
  var model: AppModel

  var body: some View {
    let r = model.mascotRender
    if let h = r.halves {
      HeartsView(halves: h, beat: r.heartBeat, scale: k)
        .help(r.heartsTip)
        .padding(.trailing, 12 * k)
    }
  }
}
