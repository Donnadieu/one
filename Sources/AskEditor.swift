import AppKit
import SwiftUI

// MARK: - The ask box's typing area for long messages (Claude Design "Long Message Options", B · Grows + Expand).
// The box wraps and grows line by line up to about half the window, then scrolls inside and always keeps the
// cursor in view, with a soft fade at the top when there's more above. Past four lines an expand button opens
// `WritingPanel`, a big writing space over the screen (X, click outside or Esc closes it; the draft stays).

/// What the editor reports back to the box around it.
@MainActor final class AskMetrics: ObservableObject {
    @Published var contentHeight: CGFloat = AskEditor.oneLine
    @Published var atTop = true
}

struct AskEditor: NSViewRepresentable {
    static let inset: CGFloat = 9
    static let oneLine: CGFloat = 36
    @Binding var text: String
    @Binding var focused: Bool
    @ObservedObject var metrics: AskMetrics
    var size: CGFloat = 14
    /// In the box Return sends and Shift+Return is a new line; in the writing panel Return is a new line and ⌘Return sends.
    var returnSends = true
    var onSubmit: () -> Void
    /// Esc: closes the writing panel. Nil in the box, so Esc keeps doing whatever it did before.
    var onEscape: (() -> Void)? = nil

    func makeNSView(context: Context) -> AskScrollView {
        let sv = AskScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.scrollerKnobStyle = .light
        sv.borderType = .noBorder
        let tv = AskTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = .systemFont(ofSize: size)
        tv.textColor = NSColor(WorldLook.cream)
        tv.insertionPointColor = NSColor(WorldLook.cream)
        tv.selectedTextAttributes = [.backgroundColor: NoteText.cream.withAlphaComponent(0.24)]
        tv.textContainerInset = NSSize(width: 0, height: AskEditor.inset)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.string = text
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        sv.documentView = tv
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: sv.contentView)
        context.coordinator.tv = tv
        context.coordinator.sv = sv
        sv.onResize = { [weak coordinator = context.coordinator] in coordinator?.resized() }
        return sv
    }

    func updateNSView(_ sv: AskScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.tv else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            c.measure()
        }
        if focused, let w = tv.window, w.firstResponder !== tv {
            DispatchQueue.main.async { w.makeFirstResponder(tv) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AskEditor
        weak var tv: AskTextView?
        weak var sv: AskScrollView?
        init(_ p: AskEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            if parent.text != tv.string { parent.text = tv.string }
            measure()
        }
        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                let send = parent.returnSends ? !(flags.contains(.shift) || flags.contains(.option)) : flags.contains(.command)
                if send { parent.onSubmit() } else { textView.insertNewlineIgnoringFieldEditor(nil) }
                return true
            }
            if let esc = parent.onEscape, sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSTextView.complete(_:)) {
                esc()
                return true
            }
            return false
        }
        func focusChanged(_ on: Bool) {
            if parent.focused != on { parent.focused = on }
        }
        /// The text's full height (both insets included), so SwiftUI can size the box up to its cap.
        func measure() {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = max(AskEditor.oneLine, ceil(lm.usedRect(for: tc).height + AskEditor.inset * 2))
            if abs(parent.metrics.contentHeight - h) > 0.5 {
                let m = parent.metrics
                DispatchQueue.main.async { m.contentHeight = h }
            }
        }
        func resized() {
            measure()
            guard let tv, tv.window?.firstResponder === tv else { return }
            tv.scrollRangeToVisible(tv.selectedRange())
        }
        @objc func scrolled() {
            let top = (sv?.contentView.bounds.origin.y ?? 0) <= 1
            if parent.metrics.atTop != top {
                let m = parent.metrics
                DispatchQueue.main.async { m.atTop = top }
            }
        }
    }
}

final class AskScrollView: NSScrollView {
    var onResize: () -> Void = {}
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize()
    }
}

final class AskTextView: NSTextView {
    weak var coordinator: AskEditor.Coordinator?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        return ok
    }
}

/// The typing area as the ask box shows it: the live editor, or (in renders) the same text drawn still.
struct AskField: View {
    @Binding var text: String
    @Binding var focused: Bool
    @ObservedObject var metrics: AskMetrics
    let hint: String
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    var body: some View {
        let h = min(max(metrics.contentHeight, AskEditor.oneLine), maxHeight)
        Group {
            if HomeView.still {
                // ImageRenderer can't draw an NSTextView: show the end of the text, as the live box would.
                Text(text.isEmpty ? hint : text + "▏").font(.system(size: 14)).lineSpacing(1)
                    .foregroundStyle(WorldLook.cream.opacity(text.isEmpty ? 0.4 : 1))
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, AskEditor.inset)
                    .frame(height: h, alignment: .bottom)
                    .clipped()
            } else {
                AskEditor(text: $text, focused: $focused, metrics: metrics, onSubmit: onSubmit).frame(height: h)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(hint).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.4))
                                .padding(.top, AskEditor.inset).allowsHitTesting(false)
                        }
                    }
            }
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fades ? 22 : 0)
                Color.black
            }
        )
        .animation(.easeOut(duration: 0.15), value: h)
    }
    var fades: Bool { metrics.contentHeight > maxHeight + 1 && (HomeView.still || !metrics.atTop) }
    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    /// Height of `text` at a given width, for renders (no live editor to measure it).
    static func stillHeight(_ text: String, width: CGFloat) -> CGFloat {
        let a = NSAttributedString(string: text + "▏", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let r = a.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(AskEditor.oneLine, ceil(r.height + AskEditor.inset * 2))
    }
}

/// The big writing space the expand button opens. Closes with X, a click on the dim backdrop, or Esc; the
/// draft stays in the ask box either way.
struct WritingPanel: View {
    @ObservedObject var m: Model
    @Binding var draft: String
    let close: () -> Void
    let send: () -> Void
    @StateObject var metrics = AskMetrics()
    @State var focused = true
    var body: some View {
        PopupStage(close: close) { g in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    MiniOrb(size: 16)
                    Text("Writing to \(m.name)").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 150)  // the X and "Esc to close"
                }
                .frame(height: 30).padding(.horizontal, 24).padding(.vertical, 14)
                Divider().overlay(WorldLook.cream.opacity(0.08))
                page.padding(.horizontal, 28).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
                Divider().overlay(WorldLook.cream.opacity(0.08))
                HStack(spacing: 14) {
                    Text("\(AskField.words(draft)) words").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Return for a new line · ⌘ Return to send").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Shrink back", action: close).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button(action: send) {
                        Text("Send").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .padding(.horizontal, 18).padding(.vertical, 8).background(Capsule().fill(WorldLook.cream))
                    }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
            .frame(width: min(760, g.width - 60), height: max(320, g.height * 0.8))
        }
        .foregroundStyle(WorldLook.cream)
    }
    @ViewBuilder var page: some View {
        if HomeView.still {
            Text(draft + "▏").font(.system(size: 16)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, AskEditor.inset)
        } else {
            AskEditor(text: $draft, focused: $focused, metrics: metrics, size: 16, returnSends: false, onSubmit: send, onEscape: close)
        }
    }
}

/// Render-only (`--render-world <prefix>` → long-start, long-middle, long-end, long-panel): the home screen with a
/// long message being typed, to check the box against the Claude Design mockup.
enum LongMessageRender {
    static let message = """
        Elias, I need your help thinking through next week, because it's getting messy and I keep dropping things.

        First, the ConstructEase client update is due Friday. Last week we shipped the new scheduling screen, but the export to PDF still breaks when a project has more than fifty line items, and I promised them a fix. Can you pull together what changed from Basecamp and the two GitHub repos, and draft the update in my usual voice? Keep it short, lead with what works, and be honest about the export bug and when it will be fixed.

        Second, Ek and I want to pick the problem we go after for the co-founder project before the end of the month. We have three candidates in the room: the personal injury firms drowning in intake calls, the small contractors who can't keep track of change orders, and the clinics that lose patients between referral and first visit. I'd like a one-page comparison: who pays, how painful it is, how easy it is to reach those people, and what we'd build first. Don't pick for us, but tell me which one you'd lean toward and why.

        Third, personal stuff. My daughter's school has a parent meeting on Thursday at six, and I also told my brother I'd call him this week about our mom's birthday dinner. Please put both on my calendar and remind me the morning of.

        Last thing: I keep losing track of my long messages in this box. If you notice me writing something huge like this again, maybe suggest I split it into separate jobs so helpers can run them at the same time.

        Thanks. No rush on the comparison, but the client update matters most.
        """
    /// The `long-*` names in the render list; true when this name was one of them.
    @MainActor static func draw(_ name: String, _ out: String) -> Bool {
        guard name.hasPrefix("long-") else { return false }
        png(String(name.dropFirst(5)), "\(out)-\(name).png")
        print("wrote \(out)-\(name).png")
        return true
    }
    @MainActor static func png(_ state: String, _ path: String) {
        let paras = message.components(separatedBy: "\n\n")
        HomeView.stillDraft =
            state == "start" ? String(paras[0].prefix(60)) : state == "middle" ? paras.prefix(3).joined(separator: "\n\n") : message
        HomeView.stillWriting = state == "panel"
        defer {
            HomeView.stillDraft = ""
            HomeView.stillWriting = false
        }
        HomeRender.png(HomeRender.scene(4), path, height: 760)
    }
}
