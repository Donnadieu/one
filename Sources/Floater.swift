import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

// MARK: - Floating orb window (shown when One is minimized or hidden)

@MainActor final class FloatUI: ObservableObject {
    static let shared = FloatUI()
    static let orbBox: CGFloat = 150
    static let cardSize = CGSize(width: 290, height: 220)
    @Published var onRight = false
    @Published var showHint = false
    @Published var reply: String?
    @Published var note: String?
}

struct FloatOrbView: View {
    @ObservedObject var m = Model.shared
    @ObservedObject var l = Listener.shared
    var body: some View {
        FloatingOrb(state: l.listening ? .listening : (m.thinking || m.helpers.contains { $0.state == "working" } ? .working : .idle), size: 72)
            .frame(width: FloatUI.orbBox, height: FloatUI.orbBox)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: l.listening)
    }
}

/// A short message card beside the orb (a reply, a problem, a note).
struct FloatNote: View {
    let text: String
    var footer: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 13.5)).foregroundStyle(WorldLook.cream).lineSpacing(2).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.62)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1E1E22, 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

struct FloatCard: View {
    @ObservedObject var m = Model.shared
    @ObservedObject var l = Listener.shared
    @ObservedObject var ui = FloatUI.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !l.listening)) { tl in
            ZStack(alignment: ui.onRight ? .leading : .trailing) {
                Color.clear
                content(tl.date.timeIntervalSince(WorldLook.start)).padding(.horizontal, 12)
            }
        }
        .frame(width: FloatUI.cardSize.width, height: FloatUI.cardSize.height)
        .environment(\.colorScheme, .dark)
    }
    @ViewBuilder func content(_ t: Double) -> some View {
        if l.listening {
            FloatTranscript(text: l.text.isEmpty ? "I'm listening…" : l.text, level: max(0.3, l.level), t: t)
        } else if let p = l.problem ?? ui.note {
            FloatNote(text: p)
        } else if m.thinking {
            FloatHint(text: m.working ?? "Working on it…")
        } else if let r = ui.reply {
            FloatNote(text: r, footer: "Double-click the orb to see it all")
        } else if ui.showHint {
            FloatHint(text: "Hold to talk · Double-click to open")
        }
    }
}

/// Mouse handling for the orb: drag to move, hold to talk, double-click to open One.
final class OrbHost: NSView {
    private var grab = NSPoint.zero, downAt = NSPoint.zero
    private var dragging = false, holding = false
    private var holdTimer: Timer?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let q = convert(point, from: superview)
        return hypot(q.x - bounds.midX, q.y - bounds.midY) < 46 ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { registerForDraggedTypes([.fileURL, .png, .tiff]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let pb = s.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return MainActor.assumeIsolated {
                let n = PictureIn.addURLs(urls)
                if n > 0 { Floater.shared.gotPictures(n) }
                return n > 0
            }
        }
        let pics = Picture.fromPasteboard(pb)
        guard !pics.isEmpty else { return false }
        MainActor.assumeIsolated {
            PictureIn.add(pics)
            Floater.shared.gotPictures(pics.count)
        }
        return true
    }
    override func mouseDown(with e: NSEvent) {
        holdTimer?.invalidate()
        if e.clickCount >= 2 {
            Floater.shared.openMain()
            return
        }
        downAt = NSEvent.mouseLocation
        dragging = false
        if let w = window { grab = NSPoint(x: downAt.x - w.frame.minX, y: downAt.y - w.frame.minY) }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, !self.dragging else { return }
            self.holding = true
            Floater.shared.beginTalk()
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging && !holding && hypot(p.x - downAt.x, p.y - downAt.y) > 4 {
            dragging = true
            holdTimer?.invalidate()
        }
        guard dragging, let w = window else { return }
        w.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
        Floater.shared.placeCard()
    }
    override func mouseUp(with e: NSEvent) {
        holdTimer?.invalidate()
        if holding {
            holding = false
            Floater.shared.endTalk()
        } else if dragging {
            dragging = false
            Floater.shared.settle()
        } else if e.clickCount == 1 {
            Floater.shared.flashHint()
        }
    }
}

@MainActor final class Floater: NSObject {
    static let shared = Floater()
    private var orb: NSPanel?
    private var card: NSPanel?
    private var replyToken = 0, hintToken = 0

    private var mainWindow: NSWindow? { NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain } }

    func setup() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { n in
            if !(n.object is NSPanel) { self.show() }
        }
        // The red button (and ⌘W) tucks One away into the orb instead of closing it. Only Quit (Dock › Quit, ⌘Q) ends it.
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            Task { @MainActor in
                guard let w = n.object as? NSWindow, !(w is NSPanel), let b = w.standardWindowButton(.closeButton) else { return }
                if b.target !== self {
                    b.target = self
                    b.action = #selector(Floater.tuckAway(_:))
                }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "w",
                let w = NSApp.keyWindow, !(w is NSPanel), w.attachedSheet == nil
            {
                Floater.shared.tuckAway(nil)
                return nil
            }
            return e
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            if !(n.object is NSPanel) { Task { @MainActor in if Model.shared.onboarded { self.show() } } }
        }
        nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { n in
            if !(n.object is NSPanel) { self.hide() }
        }
        // Stage Manager turns the yellow button into "move to the side strip", which still counts as visible.
        // So: whenever you're in another app, the orb is there; come back to One and it goes away.
        // The orb is only there when the window isn't: window on screen = orb gone, window closed/minimized/covered = orb.
        for name in [
            NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                if let w = n.object as? NSWindow, w is NSPanel { return }
                Task { @MainActor in self.syncOrb() }
            }
        }
        // Hiding One (⌘H) would hide the orb too, so turn "hide" into "tuck the window away and show the orb".
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard Model.shared.onboarded else { return }
                self.mainWindow?.orderOut(nil)
                NSApp.unhideWithoutActivation()
                self.show()
            }
        }
    }

    private func panel(_ size: CGSize) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        // .auxiliary + .canJoinAllApplications: Stage Manager leaves the orb on screen instead of tucking it into One's stage.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .auxiliary, .canJoinAllApplications]
        p.isReleasedWhenClosed = false
        return p
    }

    private func build() {
        guard orb == nil else { return }
        let o = panel(CGSize(width: FloatUI.orbBox, height: FloatUI.orbBox))
        let host = OrbHost(frame: NSRect(x: 0, y: 0, width: FloatUI.orbBox, height: FloatUI.orbBox))
        let hv = NSHostingView(rootView: FloatOrbView())
        hv.frame = host.bounds
        hv.autoresizingMask = [.width, .height]
        host.addSubview(hv)
        o.contentView = host
        let c = panel(FloatUI.cardSize)
        c.ignoresMouseEvents = true
        c.contentView = NSHostingView(rootView: FloatCard())
        orb = o
        card = c
        let d = UserDefaults.standard
        if d.object(forKey: "orbX") != nil {
            o.setFrameOrigin(NSPoint(x: d.double(forKey: "orbX"), y: d.double(forKey: "orbY")))
        } else if let v = NSScreen.main?.visibleFrame {
            o.setFrameOrigin(NSPoint(x: v.maxX - FloatUI.orbBox + 10, y: v.maxY - FloatUI.orbBox + 10))
        }
        clamp()
    }

    func show() {
        guard Model.shared.onboarded else { return }
        build()
        placeCard()
        orb?.orderFrontRegardless()
        card?.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "orbHintSeen") { UserDefaults.standard.set(true, forKey: "orbHintSeen") }
        flashHint()
    }

    func hide() {
        if Listener.shared.listening { Listener.shared.finish { _ in } }
        orb?.orderOut(nil)
        card?.orderOut(nil)
    }

    /// Is One's window actually on screen (not closed, minimized or fully covered)?
    var windowOnScreen: Bool {
        guard let w = mainWindow else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }
    func syncOrb() {
        guard Model.shared.onboarded else { return }
        if windowOnScreen { if !Listener.shared.listening && !keyTalk { hide() } } else { show() }
    }

    @objc func tuckAway(_ sender: Any?) {
        guard Model.shared.onboarded else {
            mainWindow?.miniaturize(nil)
            return
        }
        mainWindow?.orderOut(nil)
        show()
    }

    func openMain() {
        hide()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the orb fully on a screen.
    private func clamp() {
        guard let o = orb else { return }
        let f = o.frame
        let pad: CGFloat = 30  // the glow can hang off the edge, the orb itself can't
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? NSScreen.main
        guard let v = scr?.visibleFrame else { return }
        let x = min(max(f.minX, v.minX - pad), v.maxX - f.width + pad)
        let y = min(max(f.minY, v.minY - pad), v.maxY - f.height + pad)
        o.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func settle() {
        clamp()
        placeCard()
        if let f = orb?.frame {
            UserDefaults.standard.set(f.minX, forKey: "orbX")
            UserDefaults.standard.set(f.minY, forKey: "orbY")
        }
    }

    func placeCard() {
        guard let o = orb?.frame, let c = card else { return }
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: o.midX, y: o.midY)) } ?? NSScreen.main
        let onRight = o.midX < (scr?.frame.midX ?? 0)
        if FloatUI.shared.onRight != onRight { FloatUI.shared.onRight = onRight }
        let sz = FloatUI.cardSize
        let inset: CGFloat = 32  // tuck the card into the orb's glow
        let x = onRight ? o.maxX - inset : o.minX - sz.width + inset
        c.setFrame(NSRect(x: x, y: o.midY - sz.height / 2, width: sz.width, height: sz.height), display: true)
    }

    func flashHint() {
        hintToken += 1
        let tk = hintToken
        FloatUI.shared.showHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if self.hintToken == tk { FloatUI.shared.showHint = false } }
    }

    func beginTalk() {
        let ui = FloatUI.shared
        ui.reply = nil
        ui.note = nil
        ui.showHint = false
        Listener.shared.begin()
    }

    private var keyTalk = false
    /// Push-to-talk key held: show the orb (even over One) and listen.
    private var keyInApp = false
    func keyTalkBegin() {
        if windowOnScreen {
            keyInApp = true
            Model.shared.talkBegin()
            return
        }
        keyInApp = false
        build()
        placeCard()
        orb?.orderFrontRegardless()
        card?.orderFrontRegardless()
        keyTalk = true
        beginTalk()
    }
    func keyTalkEnd() {
        if keyInApp {
            keyInApp = false
            Model.shared.talkEnd()
            return
        }
        Listener.shared.finish { heard in
            guard !heard.isEmpty else {
                if Listener.shared.problem == nil { self.note("I didn't catch that. Hold the key and talk, then let go.") }
                self.tuckIfOneInFront(after: 4)
                return
            }
            Task { @MainActor in
                if Model.shared.thinking { self.note("Got it. I'll do that right after this.") }
                while Model.shared.thinking { try? await Task.sleep(nanoseconds: 400_000_000) }
                await Model.shared.send(heard, toNova: true)
                if NSApp.isActive { self.tuckIfOneInFront(after: 0) } else { self.showReply() }
            }
        }
    }
    private func tuckIfOneInFront(after s: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            if NSApp.isActive && !Listener.shared.listening && !Model.shared.thinking {
                self.keyTalk = false
                self.hide()
            }
        }
    }
    func gotPictures(_ n: Int) {
        note(n == 1 ? "Got it. Hold me and say what to do with it." : "Got all \(n). Hold me and say what to do with them.")
    }

    func endTalk() {
        Listener.shared.finish { heard in
            guard !heard.isEmpty else {
                if Listener.shared.problem == nil { self.note("I didn't catch that. Hold the orb and talk, then let go.") }
                return
            }
            Task { @MainActor in
                await Model.shared.send(heard, toNova: true)
                self.showReply()
            }
        }
    }

    func note(_ s: String) {
        FloatUI.shared.note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if FloatUI.shared.note == s { FloatUI.shared.note = nil } }
    }

    private func showReply() {
        guard let b = Model.shared.bubbles.last, !b.fromMe else { return }
        var t = Choices.split(b.text).body
        for mark in ["**", "__", "`", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 220 { t = String(t.prefix(217)) + "…" }
        replyToken += 1
        let tk = replyToken
        FloatUI.shared.reply = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if self.replyToken == tk { FloatUI.shared.reply = nil } }
    }
}
