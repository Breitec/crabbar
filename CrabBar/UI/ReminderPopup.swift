import SwiftUI
import AppKit
import ClawdCore

/// A borderless card at the bottom right when a reminder fires, stacked, with snooze chips and Done.
@MainActor
final class ReminderPopups {
  private var panels: [NSPanel] = []
  weak var model: AppModel?

  init(model: AppModel) { self.model = model }

  func show(_ r: ClawdHome.Reminder, doneFile: URL?, text: String) {
    guard let model else { return }
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var closed = false
    let close: () -> Void = { [weak self, weak panel] in
      guard !closed, let panel else { return }
      closed = true
      panel.orderOut(nil)
      self?.panels.removeAll { $0 === panel }
      self?.layout()
      model.reminders.dismiss(r)
      // Drop the SwiftUI view (and its closures) once the click has been handled.
      DispatchQueue.main.async { panel.contentView = nil }
    }
    let view = ReminderCard(text: text, at: r.at,
                            onSnooze: { chip in model.reminders.snooze(r, doneFile: doneFile, chip: chip); close() },
                            onMore: {
                              if let f = doneFile { try? FileManager.default.removeItem(at: f) }
                              model.openPanel?("remind")
                              NotificationCenter.default.post(name: .clawdPanelTab, object: "remind", userInfo: ["prefill": r.text])
                              close()
                            },
                            onDone: close)
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    panel.setContentSize(host.fittingSize)
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = host
    panels.append(panel)
    layout()
    panel.orderFrontRegardless()
    NSSound(named: "Glass")?.play()
  }

  private func layout() {
    guard let screen = NSScreen.main?.visibleFrame else { return }
    var y = screen.minY + 16
    for p in panels {
      p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 16, y: y))
      y += p.frame.height + 10
    }
  }
}

struct ReminderCard: View {
  var text: String
  var at: Date
  var onSnooze: (String) -> Void
  var onMore: () -> Void
  var onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Canvas { ctx, _ in Draw.clawd(&ctx, frame: ClawdFrame(eyes: "wide", arms: "up"), origin: .zero, scale: 0.8) }
          .frame(width: 29, height: 21)
        VStack(alignment: .leading, spacing: 1) {
          Text(T("chat.remindTitle")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textDim)
          Text(Format.remindTime(at)).font(.system(size: 9)).foregroundStyle(Palette.textDim)
        }
      }
      Text(text).font(.system(size: 13)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
      Text(T("pop.laterHead")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textDim)
      HStack(spacing: 6) {
        ForEach(L10n.list("pop.snooze"), id: \.self) { c in
          Button(c) { onSnooze(c) }.buttonStyle(.bordered).controlSize(.small)
        }
        Button("…", action: onMore).buttonStyle(.bordered).controlSize(.small)
        Spacer()
        Button(T("pop.done"), action: onDone).buttonStyle(.borderedProminent).controlSize(.small)
      }
    }
    .padding(12)
    .frame(width: 340)
    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card)
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border)))
    .environment(\.colorScheme, .dark)
  }
}
