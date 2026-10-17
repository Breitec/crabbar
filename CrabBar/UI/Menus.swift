import SwiftUI
import ClawdCore

@MainActor
var appDelegate: AppDelegate? { AppDelegate.shared }

/// The original tray menu, available on right-click of the menu bar icon and of the card header.
struct MainMenuItems: View {
  var model: AppModel

  var body: some View {
    Text("CrabBar · Claude Code v\(model.verLocal ?? "?")")
    if let r = model.appUpdate {
      Button(T("app.menu", r.version)) { model.openReleasePage() }
    }
    Divider()
    Button(T("menu.toggle")) { appDelegate?.toggleFloating() }
    Button(T("menu.panel")) { model.openPanel?(nil) }
    Button(T("menu.refresh")) { model.refreshNow() }
    Button(T("menu.bigger")) { model.updateConfig { $0.scale = min(4, (($0.scale + 0.1) * 100).rounded() / 100) } }
    Button(T("menu.smaller")) { model.updateConfig { $0.scale = max(0.6, (($0.scale - 0.1) * 100).rounded() / 100) } }
    Divider()
    Button(T("menu.advisor")) { model.advisor.scan(); model.openPanel?("chat") }
    Toggle(T("menu.clawdSession"), isOn: Binding(get: { model.config.clawdSession },
                                                set: { v in model.updateConfig { $0.clawdSession = v } }))
    Button(T("menu.clawdRestart")) { model.clawdSession.restart() }.disabled(!model.config.clawdSession)
    Divider()
    Menu(T("menu.language")) {
      ForEach([("system", T("menu.langSystem")), ("de", "Deutsch"), ("en", "English")], id: \.0) { code, name in
        Button((model.config.language == code ? "✓ " : "   ") + name) { model.updateConfig { $0.language = code } }
      }
    }
    Button(T("menu.settings")) { appDelegate?.openSettings() }
    Button(T("menu.config")) { NSWorkspace.shared.open(AppPaths.config) }
    Divider()
    Button(T("menu.exit")) { NSApp.terminate(nil) }
  }
}

/// Developer mode on right-click of Clawd or the sky: moods, animations, hearts, sky and a demo.
struct DevMenuItems: View {
  var model: AppModel

  var body: some View {
    let m = model.mascot
    Text(T("mm.head"))
    Button(T("mm.auto")) { m.stopDemo(); m.forceHearts = nil; model.sky.force = nil; model.sky.forceWx = nil }
    Button(T("mm.demo")) { m.startDemo() }
    Menu(T("mm.state")) {
      ForEach(Mood.allCases, id: \.self) { mood in
        Button(T("mood.\(mood.rawValue)")) { m.stopDemo(); m.force = mood }
      }
    }
    Menu(T("mm.anim")) {
      ForEach(ClawdSequences.actNames, id: \.self) { a in
        Button(T("act.\(a)")) { m.start(a) }
      }
    }
    Toggle(T("mm.sweat"), isOn: Binding(get: { m.forceCrit }, set: { m.forceCrit = $0 }))
    Menu(T("mm.hearts")) {
      Button(T("mm.byLimit")) { m.stopDrain(); m.forceHearts = nil }
      ForEach((0...6).reversed(), id: \.self) { h in
        Button("\(h) · \(T("health.\(h)"))") { m.stopDrain(); m.forceHearts = h }
      }
      Button(T("mm.drain")) { m.startDrain() }
    }
    Menu(T("mm.sky")) {
      Button(T("mm.byClock")) { model.sky.force = nil }
      ForEach(SkyPhase.allCases, id: \.self) { p in
        Button(T("phase.\(p.rawValue)")) { model.sky.force = p }
      }
      Divider()
      Button(T("mm.wxLive")) { model.sky.forceWx = nil }
      ForEach([0, 2, 3, 45, 53, 63, 82, 95, 73], id: \.self) { c in
        Button(WeatherKind.of(c).name) { model.sky.forceWx = c }
      }
    }
  }
}
