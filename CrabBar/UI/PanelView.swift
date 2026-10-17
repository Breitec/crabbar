import SwiftUI
import ClawdCore

/// Clawd's panel: chat (tips above the merged local and phone feed), reminders with recurring tasks, lists.
struct PanelView: View {
  @Bindable var model: AppModel
  @State var tab = "chat"
  @State var prefill: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Picker("", selection: $tab) {
          Text(T("tab.chat")).tag("chat")
          Text(T("tab.remind")).tag("remind")
          Text(T("tab.lists")).tag("lists")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if tab == "chat" {
          Button {
            model.updateConfig { $0.chatAutoRun.toggle() }
          } label: {
            Text(T("chat.auto")).font(.system(size: 10, weight: .bold))
              .foregroundStyle(model.config.chatAutoRun ? Palette.warn : Palette.textDim)
          }
          .buttonStyle(.plain)
          .help(model.config.chatAutoRun ? T("chat.autoOn") : T("chat.autoOff"))
          Button { model.chat.reset() } label: { Image(systemName: "plus") }
            .buttonStyle(.plain)
            .help(T("chat.new"))
            .disabled(model.chat.busy)
        }
      }
      .padding(10)
      Divider()
      switch tab {
      case "remind": RemindersTab(model: model, prefill: $prefill)
      case "lists": ListsTab(model: model)
      default: ChatTab(model: model)
      }
    }
    .frame(minWidth: 340, idealWidth: 380, minHeight: 420, idealHeight: 560)
    .background(Palette.card)
    .environment(\.colorScheme, .dark)
    .onAppear {
      model.panelOpen = true
      model.chat.unread = false
      if !model.reminders.due.isEmpty { tab = "remind"; model.reminders.due.removeAll() }
    }
    .onDisappear { model.panelOpen = false }
    .onReceive(NotificationCenter.default.publisher(for: .clawdPanelTab)) { n in
      if let t = n.object as? String { tab = t }
      if let p = n.userInfo?["prefill"] as? String { prefill = p }
    }
  }
}

extension Notification.Name {
  static let clawdPanelTab = Notification.Name("clawdPanelTab")
}

// MARK: - chat

struct ChatTab: View {
  @Bindable var model: AppModel
  @State var input = ""
  @State var refining: UUID?
  @State var refineTip: Advisor.Tip?
  @FocusState var focused: Bool

  var body: some View {
    let chat = model.chat!
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if model.config.showAdvisor { tipsBlock }
            if chat.feed.isEmpty {
              bubble(ChatMessage(role: "clawd", text: T("chat.hello")))
            }
            ForEach(chat.feed) { m in
              messageView(m).id(m.id)
            }
            if chat.busySince != nil {
              TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let secs = Int(ctx.date.timeIntervalSince(chat.busySince ?? ctx.date))
                HStack(spacing: 6) {
                  ProgressView().controlSize(.small)
                  Text("\(T("chat.thinking")) · \(T("chat.sec", secs))").font(.system(size: 11)).foregroundStyle(Palette.textHead)
                  Spacer()
                  Button { chat.cancel() } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain)
                }
              }
              .id("busy")
            }
            if chat.runningScript {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(T("chat.running")).font(.system(size: 11)).foregroundStyle(Palette.textHead)
                Spacer()
                Button { chat.stopScript() } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain)
              }
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .padding(10)
        }
        .onChange(of: chat.feed.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
        .onChange(of: chat.busySince) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
        .onAppear { proxy.scrollTo("bottom") }
      }
      Divider()
      HStack(spacing: 6) {
        TextField(placeholder, text: $input, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...5)
          .focused($focused)
          .onSubmit(send)
        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
          .buttonStyle(.plain)
          .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy || model.claude == nil)
          .help(T("chat.send"))
      }
      .padding(10)
    }
    .onAppear { focused = true }
  }

  var placeholder: String {
    if refineTip != nil { return T("adv.refineHint") }
    if refining != nil { return T("chat.refineHint") }
    return T("chat.hint")
  }

  func send() {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !model.chat.busy else { return }
    if let tip = refineTip {
      model.chat.send(T("adv.refineMsg", tip.text, t))
    } else {
      model.chat.send(t)
    }
    refineTip = nil
    refining = nil
    input = ""
  }

  @ViewBuilder var tipsBlock: some View {
    let adv = model.advisor!
    if !adv.tips.isEmpty || adv.scanning {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(T("adv.tips")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textDim)
          Spacer()
          Text(adv.scanning ? T("adv.checking") : adv.checkedAt.map { T("adv.checked", Format.hhmm($0)) } ?? "")
            .font(.system(size: 9)).foregroundStyle(Palette.textDim)
          Button { adv.scan() } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).help(T("adv.rescan")).disabled(adv.scanning)
        }
        ForEach(adv.tips) { t in
          VStack(alignment: .leading, spacing: 4) {
            Text(t.text).font(.system(size: 11)).foregroundStyle(Palette.textMain).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              if !t.actionLabel.isEmpty { link(t.actionLabel) { adv.perform(t) } }
              link(T("adv.do")) { model.chat.send(T("adv.doMsg", t.text)) }
              link(T("chat.refine")) { refineTip = t; focused = true }
              Spacer()
              Button { adv.dismiss(t) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(T("adv.close"))
            }
            .font(.system(size: 10))
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#14FFFFFF")))
        }
      }
    }
  }

  func link(_ s: String, _ a: @escaping () -> Void) -> some View {
    Button(action: a) { Text(s).foregroundStyle(Palette.week) }.buttonStyle(.plain)
  }

  func bubble(_ m: ChatMessage) -> some View {
    let mine = m.role == "user"
    return HStack {
      if mine { Spacer(minLength: 40) }
      VStack(alignment: .leading, spacing: 2) {
        if m.remote {
          Text(T("chat.remoteTag")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textDim)
        }
        Text(m.text).font(.system(size: 12)).textSelection(.enabled)
          .foregroundStyle(mine ? .white : Palette.textMain)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Color(hex: "#2563EB") : Color(hex: "#26FFFFFF")))
      if !mine { Spacer(minLength: 40) }
    }
  }

  @ViewBuilder func messageView(_ m: ChatMessage) -> some View {
    switch m.role {
    case "note":
      Text(m.text).font(.system(size: 10)).foregroundStyle(Palette.textDim).frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    case "remind":
      HStack(spacing: 6) {
        Image(systemName: "bell.fill").foregroundStyle(Palette.warn)
        Text(m.text).font(.system(size: 11)).foregroundStyle(Palette.textMain)
        Spacer()
        Text(Format.hhmm(m.at)).font(.system(size: 9)).foregroundStyle(Palette.textDim)
      }
    default:
      VStack(alignment: .leading, spacing: 6) {
        if !m.text.isEmpty { bubble(m) }
        if let r = m.run { runCard(m.id, r) }
        if let a = m.act { actCard(m.id, a) }
        if let g = m.grant { grantCard(m.id, g) }
      }
    }
  }

  func runCard(_ id: UUID, _ r: ChatMessage.Run) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        Text(r.script).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textMain).textSelection(.enabled)
      }
      .frame(maxHeight: 140)
      if r.state == "pending" {
        HStack(spacing: 10) {
          Button(T("chat.run")) { model.chat.runScript(id) }.buttonStyle(.borderedProminent).controlSize(.small)
          link(T("chat.refine")) { refining = id; focused = true }
          link(T("chat.skip")) { model.chat.setRunState(id, "skipped") }
        }
        .font(.system(size: 11))
      } else {
        Text(runStateText(r)).font(.system(size: 10)).foregroundStyle(Palette.textDim)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
  }

  func runStateText(_ r: ChatMessage.Run) -> String {
    switch r.state {
    case "running": return T("chat.state.running")
    case "done": return T("chat.state.done", r.code.map(String.init) ?? "?")
    case "replaced": return T("chat.state.replaced")
    default: return T("chat.state.skipped")
    }
  }

  func actCard(_ id: UUID, _ a: ChatMessage.Act) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(T("chat.actHead")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textHead)
      ForEach(Array(a.calls.enumerated()), id: \.offset) { _, c in
        Text("\(c.tool) \(c.input)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textMain).lineLimit(3)
      }
      if a.state == "pending" {
        HStack(spacing: 10) {
          Button(T("chat.run")) { model.chat.approveAct(id) }.buttonStyle(.borderedProminent).controlSize(.small)
          link(T("chat.skip")) { model.chat.setActState(id, "skipped") }
        }
        .font(.system(size: 11))
      } else {
        Text(T("chat.act.\(a.state)")).font(.system(size: 10)).foregroundStyle(Palette.textDim)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
  }

  func grantCard(_ id: UUID, _ g: ChatMessage.Grant) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(T(g.kind == "approve" ? "task.approveHead" : "task.grantHead", g.task)).font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Palette.textHead)
      ForEach(g.rules, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textMain) }
      if g.state == "pending" {
        HStack(spacing: 10) {
          Button(T("task.grant")) { model.tasks.grant(id) }.buttonStyle(.borderedProminent).controlSize(.small)
          link(T("chat.skip")) { model.chat.setGrantState(id, "skipped") }
        }
        .font(.system(size: 11))
      } else {
        Text(T("task.grant.\(g.state)")).font(.system(size: 10)).foregroundStyle(Palette.textDim)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
  }
}

// MARK: - reminders and tasks

struct RemindersTab: View {
  @Bindable var model: AppModel
  @Binding var prefill: String?
  @State var text = ""
  @State var when = ""
  @State var editing: ClawdHome.Reminder?
  @State var error = ""
  @State var openTask: String?
  @State var refresh = 0

  var body: some View {
    let home = model.home
    let _ = (refresh, model.now)
    let rems = home.activeReminders()
    let tasks = home.taskFiles()
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        form
        Caption2(T("rem.upcoming"))
        if rems.isEmpty {
          Text(T("rem.none")).font(.system(size: 11)).foregroundStyle(Palette.textDim)
        }
        ForEach(rems) { r in
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text(r.text).font(.system(size: 12)).foregroundStyle(Palette.textMain)
              Text("\(Format.remindTime(r.at)) · \(T("rem.in", Format.span(until: r.at) ?? "0m"))")
                .font(.system(size: 10)).foregroundStyle(Palette.textDim)
            }
            Spacer()
            Menu {
              Button(T("rem.edit")) { editing = r; text = r.text; when = Format.iso(r.at).replacingOccurrences(of: "T", with: " ") }
              Button(T("rem.later")) { _ = home.moveReminder(r, to: r.at.addingTimeInterval(3600)); refresh += 1 }
              Button(T("rem.delete"), role: .destructive) { try? FileManager.default.removeItem(at: r.path); refresh += 1 }
            } label: { Image(systemName: "ellipsis.circle") }
              .menuStyle(.borderlessButton).fixedSize()
          }
        }
        if model.config.showTasks && !tasks.isEmpty {
          Caption2(T("task.head")).padding(.top, 6)
          ForEach(tasks) { t in taskRow(t) }
        }
        let done = home.doneReminders()
        if !done.isEmpty {
          Caption2(T("rem.done")).padding(.top, 6)
          ForEach(Array(done.enumerated()), id: \.offset) { _, d in
            HStack {
              Text(d.text).font(.system(size: 11)).foregroundStyle(Palette.textHead).lineLimit(1)
              Spacer()
              Text(Format.remindTime(d.at)).font(.system(size: 9)).foregroundStyle(Palette.textDim)
              Button(T("rem.again")) { text = d.text; when = "" }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.week)
            }
          }
        }
      }
      .padding(10)
    }
    .onAppear {
      if let p = prefill { text = p; prefill = nil }
    }
    .onChange(of: prefill) { _, p in if let p { text = p; prefill = nil } }
  }

  var form: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(T("rem.textHint"), text: $text).textFieldStyle(.roundedBorder)
      TextField(T("rem.whenHint"), text: $when).textFieldStyle(.roundedBorder).onSubmit(save)
      HStack(spacing: 6) {
        ForEach(L10n.list("rem.chips"), id: \.self) { c in
          Button(c) { when = c }.buttonStyle(.bordered).controlSize(.mini)
        }
      }
      HStack {
        Text(hint).font(.system(size: 10)).foregroundStyle(error.isEmpty ? Palette.textDim : Palette.crit)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        if editing != nil { Button(T("rem.cancel")) { editing = nil; text = ""; when = "" }.buttonStyle(.plain).font(.system(size: 10)) }
        Button(editing == nil ? T("rem.add") : T("rem.save"), action: save)
          .buttonStyle(.borderedProminent).controlSize(.small)
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || when.isEmpty || model.reminders.asking)
      }
    }
  }

  var hint: String {
    if !error.isEmpty { return error }
    if model.reminders.asking { return T("rem.whenAsking") }
    if when.isEmpty { return "" }
    if RemindWhen.isRepeat(when) { return T("rem.repeat") }
    if let d = RemindWhen.parse(when) { return Format.remindTime(d) }
    return T("rem.whenAsk")
  }

  func save() {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !when.isEmpty else { return }
    error = ""
    if RemindWhen.isRepeat(when) {
      model.chat.send(T("rem.repeatMsg", t, when))
      NotificationCenter.default.post(name: .clawdPanelTab, object: "chat")
      text = ""; when = ""
      return
    }
    let finish: (Date) -> Void = { at in
      if let e = editing { try? FileManager.default.removeItem(at: e.path) }
      model.home.newReminder(at: at, text: t)
      editing = nil; text = ""; when = ""
      refresh += 1
    }
    if let at = RemindWhen.parse(when) { finish(at); return }
    Task {
      if let at = await model.reminders.ask(when) { finish(at) } else { error = T("rem.badWhen") }
    }
  }

  func taskRow(_ t: ClawdHome.TaskFile) -> some View {
    let st = model.tasks.state[t.name]
    let status: String = {
      if model.tasks.running == t.name { return T("task.running") }
      if model.tasks.queue.contains(t.name) { return T("task.queued") }
      if t.paused { return T("task.paused") }
      if t.every == nil { return T("task.badEvery") }
      if let w = model.tasks.budgetWait(t) { return T("task.budget", w) }
      if let e = st?.error, !e.isEmpty { return T("task.lastError", e) }
      if let l = st?.last { return T("task.last", Format.remindTime(l)) }
      return T("task.never")
    }()
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(t.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textMain)
          Text("\(t.every.map(ClawdHome.formatEvery) ?? t.everyText) · \(status)")
            .font(.system(size: 10)).foregroundStyle(Palette.textDim).lineLimit(2)
        }
        Spacer()
        Menu {
          Button(T("task.now")) { model.tasks.request(t) }
          Button(t.paused ? T("task.resume") : T("task.pause")) { model.home.setTaskPaused(t, !t.paused); refresh += 1 }
          Button(T("task.open")) { NSWorkspace.shared.open(t.path) }
          Button(T("task.delete"), role: .destructive) {
            _ = model.home.removeTask(t.name)
            model.tasks.forget(t.name)
            refresh += 1
          }
        } label: { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).fixedSize()
      }
      if openTask == t.name {
        let hist = st?.history ?? []
        if hist.isEmpty {
          Text(T("task.noReports")).font(.system(size: 10)).foregroundStyle(Palette.textDim)
        }
        ForEach(Array(hist.reversed().enumerated()), id: \.offset) { _, h in
          VStack(alignment: .leading, spacing: 1) {
            Text(Format.remindTime(h.at)).font(.system(size: 9)).foregroundStyle(Palette.textDim)
            Text(h.text).font(.system(size: 11)).foregroundStyle(Palette.textMain).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { openTask = openTask == t.name ? nil : t.name }
  }
}

struct Caption2: View {
  var text: String
  init(_ t: String) { text = t }
  var body: some View {
    Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textDim)
  }
}

// MARK: - lists

struct ListsTab: View {
  @Bindable var model: AppModel
  @State var current = ""
  @State var add = ""
  @State var newName: String?
  @State var refresh = 0

  var body: some View {
    let home = model.home
    let _ = (refresh, model.now)
    let names = home.listNames(defaultName: T("lists.default"))
    let name = names.contains(current) ? current : (names.first ?? "")
    let list = home.readList(name)
    VStack(alignment: .leading, spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(names, id: \.self) { n in
            let open = home.readList(n).items.filter { !$0.done }.count
            Button("\(n)\(open > 0 ? " \(open)" : "")") { current = n }
              .buttonStyle(.bordered).controlSize(.small)
              .tint(n == name ? Palette.week : nil)
          }
          if let _ = newName {
            TextField(T("list.newHint"), text: Binding(get: { newName ?? "" }, set: { newName = $0 }))
              .textFieldStyle(.roundedBorder).frame(width: 160)
              .onSubmit {
                if let n = newName, let made = home.newList(n) { current = made }
                newName = nil
                refresh += 1
              }
              .onExitCommand { newName = nil }
          } else {
            Button { newName = "" } label: { Image(systemName: "plus") }.buttonStyle(.bordered).controlSize(.small)
          }
        }
        .padding(10)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          if list.items.isEmpty {
            Text(T("list.empty")).font(.system(size: 11)).foregroundStyle(Palette.textDim)
          }
          ForEach(list.items) { it in
            HStack {
              Button {
                home.setListItem(name, idx: it.idx, done: !it.done)
                refresh += 1
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: it.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(it.done ? Palette.ok : Palette.textHead)
                  Text(it.text).font(.system(size: 12))
                    .strikethrough(it.done)
                    .foregroundStyle(it.done ? Palette.textDim : Palette.textMain)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Spacer()
              Button { home.removeListItem(name, idx: it.idx); refresh += 1 } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Palette.textDim)
            }
          }
          HStack {
            if list.items.contains(where: \.done) {
              Button(T("list.clear")) { home.clearListDone(name); refresh += 1 }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(Palette.week)
            }
            Spacer()
            if list.items.isEmpty && !name.isEmpty {
              Button(T("list.delete")) { home.removeList(name); current = ""; refresh += 1 }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(Palette.crit)
            }
          }
          .padding(.top, 4)
        }
        .padding(10)
      }
      Divider()
      TextField(T("list.addHint"), text: $add)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          home.addListItems(name, add)
          add = ""
          refresh += 1
        }
        .padding(10)
    }
  }
}
