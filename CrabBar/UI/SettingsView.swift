import SwiftUI
import ServiceManagement
import ClawdCore

/// Every config.json key with a control. The file stays the source of truth and can be edited by hand.
struct SettingsView: View {
  @Bindable var model: AppModel
  @State var loginItem = SMAppService.mainApp.status == .enabled
  @State var page = 0

  func bind<T>(_ kp: WritableKeyPath<Config, T>) -> Binding<T> {
    Binding(get: { model.config[keyPath: kp] }, set: { v in model.updateConfig { $0[keyPath: kp] = v } })
  }

  /// Text settings are saved on Return or when the field loses focus, not on every keystroke.
  func optDouble(_ label: String, _ kp: WritableKeyPath<Config, Double?>) -> some View {
    CommitField(label: label, value: model.config[keyPath: kp].map { String($0) } ?? "") { s in
      let v = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
      model.updateConfig { $0[keyPath: kp] = v }
    }
  }

  func optString(_ label: String, _ kp: WritableKeyPath<Config, String?>) -> some View {
    CommitField(label: label, value: model.config[keyPath: kp] ?? "") { s in
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      model.updateConfig { $0[keyPath: kp] = t.isEmpty ? nil : t }
    }
  }

  func text(_ label: String, _ kp: WritableKeyPath<Config, String>, fallback: String) -> some View {
    CommitField(label: label, value: model.config[keyPath: kp]) { s in
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      model.updateConfig { $0[keyPath: kp] = t.isEmpty ? fallback : t }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("", selection: $page) {
        Text(L10n.lang == .de ? "Allgemein" : "General").tag(0)
        Text(L10n.lang == .de ? "Daten" : "Data").tag(1)
        Text("Clawd").tag(2)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding([.horizontal, .top], 16)
      .padding(.bottom, 4)
      switch page {
      case 0:
      Form {
        Section {
          Picker(T("menu.language"), selection: bind(\.language)) {
            Text(T("menu.langSystem")).tag("system")
            Text("Deutsch").tag("de")
            Text("English").tag("en")
          }
          Toggle(L10n.lang == .de ? "Bei Anmeldung starten" : "Launch at login", isOn: $loginItem)
            .onChange(of: loginItem) { _, on in
              do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                loginItem = SMAppService.mainApp.status == .enabled
              }
            }
          HStack {
            Text(L10n.lang == .de ? "Größe" : "Scale")
            Slider(value: bind(\.scale), in: 0.6...2.5, step: 0.05)
            Text(String(format: "%.2f", model.config.scale)).monospacedDigit().frame(width: 40)
          }
          Toggle(L10n.lang == .de ? "Prozent im Menüleisten-Icon" : "Percent in the menu bar icon", isOn: bind(\.menuBarPercent))
          Toggle(L10n.lang == .de ? "Tooltip mit Reset-Uhrzeiten" : "Tooltip with reset clock times", isOn: bind(\.trayResetClock))
        }
        Section(L10n.lang == .de ? "Schwebendes Fenster" : "Floating window") {
          Toggle(L10n.lang == .de ? "Anzeigen" : "Show", isOn: Binding(get: { model.config.floating },
                                                                        set: { v in model.updateConfig { $0.floating = v }; appDelegate?.syncFloating() }))
          Toggle(L10n.lang == .de ? "Immer im Vordergrund" : "Always on top", isOn: bind(\.topmost))
          HStack {
            Text(L10n.lang == .de ? "Deckkraft" : "Opacity")
            Slider(value: bind(\.opacity), in: 0.3...1)
          }
        }
        Section(L10n.lang == .de ? "Anzeige" : "Display") {
          Toggle("Clawd", isOn: bind(\.showMascot))
          Toggle(L10n.lang == .de ? "Himmel und Wetter" : "Sky and weather", isOn: bind(\.showSky))
          Toggle("Sessions", isOn: bind(\.showSessions))
          Toggle("Status (status.claude.com)", isOn: bind(\.showStatus))
          Toggle(L10n.lang == .de ? "Konto" : "Account", isOn: bind(\.showAccount))
          Toggle(L10n.lang == .de ? "24h/7d-Statistik" : "24h/7d stats", isOn: bind(\.showStats))
          Toggle(L10n.lang == .de ? "Verlauf und Projekte" : "History and projects", isOn: bind(\.showHistory))
          Stepper("\(L10n.lang == .de ? "Gelb ab" : "Yellow from") \(model.config.warnPercent)%", value: bind(\.warnPercent), in: 1...99)
          Stepper("\(L10n.lang == .de ? "Rot ab" : "Red from") \(model.config.critPercent)%", value: bind(\.critPercent), in: 1...100)
        }
      }
      .formStyle(.grouped)
      case 1:

      Form {
        Section(L10n.lang == .de ? "Ort für den Himmel" : "Location for the sky") {
          optDouble(L10n.lang == .de ? "Breitengrad (leer = automatisch)" : "Latitude (empty = automatic)", \.weatherLat)
          optDouble(L10n.lang == .de ? "Längengrad" : "Longitude", \.weatherLon)
          Toggle(L10n.lang == .de ? "macOS-Ortungsdienste verwenden" : "Use macOS Location Services", isOn: bind(\.weatherUseLocation))
          Toggle(L10n.lang == .de ? "Ort über IP ermitteln (ipwho.is, Drittanbieter)" : "Locate by IP (ipwho.is, third party)",
                 isOn: bind(\.weatherIPLookup))
          Text(L10n.lang == .de
               ? "Wetter kommt von Open-Meteo, ersatzweise von met.no. Nur die gerundeten Koordinaten werden gesendet."
               : "Weather from Open-Meteo, met.no as a fallback. Only rounded coordinates are sent.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.lang == .de ? "Intervalle (Sekunden)" : "Intervals (seconds)") {
          numberRow("/usage", bind(\.usageIntervalSeconds))
          numberRow("Status", bind(\.statusIntervalSeconds))
          numberRow(L10n.lang == .de ? "Konto" : "Account", bind(\.accountIntervalSeconds))
          numberRow(L10n.lang == .de ? "Wetter" : "Weather", bind(\.weatherIntervalSeconds))
          numberRow(L10n.lang == .de ? "Versionen" : "Versions", bind(\.versionIntervalSeconds))
          numberRow("Tick", bind(\.refreshSeconds))
        }
        Section("iPhone") {
          Toggle(T("set.icloud"), isOn: bind(\.iCloudSync)).disabled(!CloudUpload.available)
          Text(CloudUpload.available ? T("set.icloudNote") : T("set.icloudMissing"))
            .font(.caption).foregroundStyle(.secondary)
          if let e = model.cloud.lastError {
            Text(T("ios.error", e)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          } else if model.cloud.lastAt != .distantPast {
            let _ = model.now
            Text(T("set.icloudLast", Format.hhmmss(model.cloud.lastAt))).font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("CrabBar") {
          Toggle(T("set.updateCheck"), isOn: bind(\.updateCheck))
          Text(T("set.updateNote")).font(.caption).foregroundStyle(.secondary)
          if model.config.updateCheck, let r = model.appRelease {
            Text(model.appUpdate == nil ? T("set.updateNone", AppModel.appVersion) : T("app.available", r.version))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Claude Code") {
          optString(L10n.lang == .de ? "Pfad zu claude (leer = neueste finden)" : "Path to claude (empty = find newest)", \.claudePath)
          Text("\(model.claude?.path ?? "–")  v\(model.claude?.version ?? "?")").font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button(L10n.lang == .de ? "Neu suchen" : "Search again") { Task { await model.locateClaude() } }
        }
      }
      .formStyle(.grouped)
      default:

      Form {
        Section("Clawd") {
          optString(L10n.lang == .de ? "Clawds Ordner (leer = ~/Clawd)" : "Clawd's folder (empty = ~/Clawd)", \.clawdHome)
          Toggle(L10n.lang == .de ? "Chat" : "Chat", isOn: bind(\.showChat))
          text(L10n.lang == .de ? "Chat-Modell" : "Chat model", \.chatModel, fallback: "sonnet")
          text(L10n.lang == .de ? "Schnelles Modell (Aufgaben, Zeiten)" : "Quick model (tasks, times)", \.quickModel, fallback: "haiku")
          numberRow(L10n.lang == .de ? "Timeout (s)" : "Timeout (s)", bind(\.chatTimeoutSeconds))
          Toggle(L10n.lang == .de ? "Auto: Skripte ohne Klick ausführen" : "Auto: run scripts without a click", isOn: bind(\.chatAutoRun))
          Toggle(L10n.lang == .de ? "Wiederkehrende Aufgaben" : "Recurring tasks", isOn: bind(\.showTasks))
          Stepper("\(L10n.lang == .de ? "Aufgaben pausieren ab" : "Tasks wait from") \(model.config.tasksMaxPercent)%",
                  value: bind(\.tasksMaxPercent), in: 0...100, step: 5)
        }
        Section("Remote Control") {
          Toggle(T("menu.clawdSession"), isOn: bind(\.clawdSession))
          text(L10n.lang == .de ? "Sessionname" : "Session name", \.clawdSessionName, fallback: "crabbar")
        }
        Section(L10n.lang == .de ? "Mac-Tipps" : "Mac tips") {
          Toggle(L10n.lang == .de ? "Aktiv" : "Enabled", isOn: bind(\.showAdvisor))
          numberRow(L10n.lang == .de ? "Intervall (Min)" : "Interval (min)", bind(\.advisorIntervalMinutes))
          numberRow(L10n.lang == .de ? "Freier Speicher unter (GB)" : "Free space below (GB)", bind(\.advisorDiskGB))
          numberRow(L10n.lang == .de ? "Datenmüll ab (GB)" : "Junk from (GB)", bind(\.advisorJunkGB))
          numberRow(L10n.lang == .de ? "RAM-Fresser ab (%)" : "Memory hog from (%)", bind(\.advisorMemPercent))
          Stepper("\(L10n.lang == .de ? "Ungenutzt seit" : "Unused for") \(model.config.advisorUnusedDays) d",
                  value: bind(\.advisorUnusedDays), in: 7...720, step: 15)
          Stepper("\(L10n.lang == .de ? "Uptime ab" : "Uptime from") \(model.config.advisorUptimeDays) d",
                  value: bind(\.advisorUptimeDays), in: 1...90)
        }
        Button(T("menu.config")) { NSWorkspace.shared.open(AppPaths.config) }
      }
      .formStyle(.grouped)
      }
    }
    .frame(width: 520, height: 600)
  }

  func numberRow(_ label: String, _ b: Binding<Double>) -> some View {
    HStack {
      Text(label)
      Spacer()
      TextField("", value: b, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
    }
  }
}

struct CommitField: View {
  var label: String
  var value: String
  var onCommit: (String) -> Void
  @State private var draft = ""
  @State private var loaded = false
  @FocusState private var focused: Bool

  var body: some View {
    TextField(label, text: $draft)
      .focused($focused)
      .onSubmit(commit)
      .onChange(of: focused) { _, f in if !f { commit() } }
      .onAppear { if !loaded { draft = value; loaded = true } }
      .onDisappear(perform: commit)
      .onChange(of: value) { _, v in if !focused { draft = v } }
  }

  func commit() {
    if draft != value { onCommit(draft) }
  }
}
