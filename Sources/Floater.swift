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

/// The assistant itself: the same living rings as the world screen (Claude Design), so it looks
/// like one being everywhere. Breathes when idle, moves like a voice while it works.
struct Orb: View {
    var size: CGFloat = 130
    var active = false
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(WorldLook.start)
            let voice = active ? 0.35 + 0.65 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
            Presence(t: t, lean: .zero, voice: voice, energy: 0)
                .frame(width: 280, height: 280)
                .scaleEffect(size / 100)
                .frame(width: size * 2, height: size * 2)
        }
    }
}

// MARK: - Floating orb (One minimized)
// When One is minimized it becomes a small orb that floats above every window. Hold it to talk
// (let go to send), double-click to open the full window. It glows while One works.

enum FloatState { case idle, listening, working }

struct FloatingOrb: View {
    var state: FloatState
    var size: CGFloat = 72
    /// Fixed time for renders; nil = live animation.
    var fixedT: Double? = nil
    var body: some View {
        if let t = fixedT {
            face(t)
        } else {
            TimelineView(.animation) { tl in face(tl.date.timeIntervalSince(WorldLook.start)) }
        }
    }

    private func face(_ t: Double) -> some View {
        let listening = state == .listening
        let working = state == .working
        let voice: Double =
            listening
            ? 0.45 + 0.4 * abs(sin(t * 4.1) * sin(t * 2.3 + 0.7))
            : working ? 0.3 + 0.35 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
        let energy: Double = working ? 0.45 + 0.25 * sin(t * 2) : listening ? 0.2 : 0
        let k = size / 168  // outer ring (~68pt + wobble) fits inside the disc
        let glow = working ? 0.30 + 0.10 * sin(t * 2.2) : listening ? 0.26 : 0.10
        return ZStack {
            Circle().fill(WorldLook.bg.opacity(0.96))
                .overlay(
                    Circle().fill(
                        RadialGradient(
                            colors: [WorldLook.cream.opacity(listening ? 0.10 : 0.05), .clear],
                            center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.6)))
            Presence(t: t, lean: .zero, voice: voice, energy: energy, line: 1.5 / k)
                .frame(width: 280, height: 280)
                .scaleEffect(k)
                .frame(width: size, height: size)
                .clipShape(Circle())
            Circle().strokeBorder(WorldLook.cream.opacity(listening ? 0.30 : 0.07), lineWidth: 0.75)
            if working {
                // A soft light travelling around the edge: "busy" without a spinner.
                Circle()
                    .trim(from: 0, to: 0.36)
                    .stroke(
                        AngularGradient(
                            colors: [Color(hex: 0xFFE2C2, 0), Color(hex: 0xFFE2C2, 0.55), Color(hex: 0xFFF3E6, 1)],
                            center: .center, startAngle: .degrees(0), endAngle: .degrees(130)),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    .frame(width: size + 9, height: size + 9)
                    .rotationEffect(.degrees(t * 150 + 115))
            }
        }
        .frame(width: size, height: size)
        .background(
            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(hex: 0xFFF1E2, glow), Color(hex: 0xFFF1E2, glow * 0.3), .clear],
                        center: .center, startRadius: size * 0.45, endRadius: size * (working ? 0.82 : 0.7)))
                if listening {
                    // Two gentle ripples while it hears you.
                    ForEach(0..<2, id: \.self) { i in
                        let p = (t * 0.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(WorldLook.cream.opacity(0.55 * (1 - p)), lineWidth: 1.5 - 0.7 * p)
                            .frame(width: size * (1.1 + 0.32 * p), height: size * (1.1 + 0.32 * p))
                    }
                }
            }
            .frame(width: size * 1.8, height: size * 1.8)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .scaleEffect(listening ? 1.08 : 1)
    }
}

/// Small plain-words label next to the orb.
struct FloatHint: View {
    let text: String
    var body: some View {
        Text(text)
            .lineLimit(3).multilineTextAlignment(.leading)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(WorldLook.cream.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: 0x1E1E22, 0.92)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .frame(maxWidth: 250, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What One is hearing while you hold the orb.
struct FloatTranscript: View {
    let text: String
    var level: Double = 0.6
    var t: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.4]
                        let h = 4 + 8 * shape[i] * (0.75 + 0.25 * level * abs(sin(t * 5 + Double(i) * 1.3)))
                        Capsule().fill(Color(hex: 0xFFE2C2, 0.9)).frame(width: 2, height: h)
                    }
                }.frame(height: 12)
                Text("Listening").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.7))
            }
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(WorldLook.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Let go to send").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.62))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1E1E22, 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Render-only: the floating orb parked in the bottom-right corner of a sample dark desktop.
struct FloatScene: View {
    let state: FloatState
    var t: Double = 12.3
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(hex: 0x2A2F3D), Color(hex: 0x15161C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").fontWeight(.semibold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Text("Go")
                    Spacer()
                    Text("Fri 23 Oct  9:41")
                }
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14).frame(height: 24).background(Color.black.opacity(0.35))
                Spacer()
            }
            // A background window, for scale
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x23252C))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) {
                                Circle().fill(Color(hex: UInt32($0), 0.85)).frame(width: 10, height: 10)
                            }
                        }
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)).frame(
                                width: [220, 180, 240, 150, 200, 120][i], height: 9)
                        }
                    }.padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .frame(width: 330, height: 200)
                .position(x: 200, y: 150)
            HStack(alignment: .center, spacing: state == .listening ? 26 : 18) {
                switch state {
                case .idle: FloatHint(text: "Hold to talk · Double-click to open")
                case .listening: FloatTranscript(text: "Move my call with Dana to Thursday at 3, and let her know", level: 0.7, t: t)
                case .working: FloatHint(text: "Moving your call with Dana…")
                }
                FloatingOrb(state: state, size: 72, fixedT: t)
            }
            .padding(.trailing, 44).padding(.bottom, 44)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Push-to-talk key (any key combo or an extra mouse button, chosen by the user)

struct TalkKey: Codable, Equatable {
    var keyCode: UInt32? = nil  // keyboard
    var mods: UInt32 = 0  // Carbon modifier mask
    var mouse: Int? = nil  // extra mouse button number (2 = middle, 3/4 = side)
    var label: String
    static let standard = TalkKey(keyCode: UInt32(kVK_Space), mods: UInt32(optionKey), label: "⌥ Space")
    static var current: TalkKey? {
        get {
            let d = UserDefaults.standard
            if d.bool(forKey: "talkKeyOff") { return nil }
            guard let raw = d.data(forKey: "talkKey"), let k = try? JSONDecoder().decode(TalkKey.self, from: raw) else { return .standard }
            return k
        }
        set {
            let d = UserDefaults.standard
            if let k = newValue {
                d.set(false, forKey: "talkKeyOff")
                d.set(try? JSONEncoder().encode(k), forKey: "talkKey")
            } else {
                d.set(true, forKey: "talkKeyOff")
            }
        }
    }
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
    static func name(_ e: NSEvent) -> String {
        let f = e.modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        let k = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return s.isEmpty ? k : s + " " + k
    }
    static func isFunctionKey(_ code: UInt16) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80].contains(code)
    }
}

/// Listens for the chosen key or mouse button anywhere on the Mac. Holding it = holding the orb.
@MainActor final class TalkKeys {
    static let shared = TalkKeys()
    private var hotRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var mouseMonitors: [Any] = []
    private var down = false
    var paused = false  // while choosing a new key

    func apply() {
        if let r = hotRef {
            UnregisterEventHotKey(r)
            hotRef = nil
        }
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        guard let k = TalkKey.current else { return }
        if let code = k.keyCode {
            if !handlerInstalled {
                handlerInstalled = true
                var types = [
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
                ]
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    { _, ev, _ in
                        let pressed = GetEventKind(ev) == UInt32(kEventHotKeyPressed)
                        DispatchQueue.main.async { pressed ? TalkKeys.shared.press() : TalkKeys.shared.release() }
                        return noErr
                    }, 2, &types, nil, nil)
            }
            RegisterEventHotKey(code, k.mods, EventHotKeyID(signature: OSType(0x4F4E4554), id: 1), GetApplicationEventTarget(), 0, &hotRef)
        } else if let b = k.mouse {
            let handle: (NSEvent) -> Void = { e in
                guard e.buttonNumber == b else { return }
                e.type == .otherMouseDown ? TalkKeys.shared.press() : TalkKeys.shared.release()
            }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp], handler: handle) { mouseMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(
                matching: [.otherMouseDown, .otherMouseUp],
                handler: { e in
                    handle(e)
                    return e
                })
            {
                mouseMonitors.append(l)
            }
        }
    }
    /// Push to talk: listening only while the key is held down; letting go sends.
    func press() {
        guard !paused, !down else { return }
        down = true
        Floater.shared.keyTalkBegin()
    }
    func release() {
        guard down else { return }
        down = false
        Floater.shared.keyTalkEnd()
    }
}

struct TalkKeySheet: View {
    var done: () -> Void
    @State var key: TalkKey? = TalkKey.current
    @State var recording = false
    @State var warn: String?
    @State var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push to talk").font(.title2.weight(.semibold))
            Text("Hold this key or button anywhere on your Mac, talk, then let go to send.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(recording ? "Press a key or a mouse button…" : (key?.label ?? "Off"))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(minWidth: 220, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(recording ? 0.14 : 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(recording ? 0.4 : 0.12)))
                Button(recording ? "Cancel" : "Change") { recording ? stop() : record() }
            }
            if let warn { Text(warn).foregroundStyle(.orange).font(.callout) }
            Text("Good choices: a key like F5, a combo like ⌥ Space, or a side button on your mouse.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Turn off") {
                    stop()
                    key = nil
                    TalkKey.current = nil
                    TalkKeys.shared.apply()
                }
                Button("Use ⌥ Space") {
                    stop()
                    key = .standard
                    TalkKey.current = .standard
                    TalkKeys.shared.apply()
                }
                Spacer()
                Button("Done") {
                    stop()
                    done()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 470)
        .onDisappear { stop() }
    }
    func record() {
        warn = nil
        recording = true
        TalkKeys.shared.paused = true
        if let r = TalkKey.current, r.keyCode != nil {
            TalkKey.current = nil
            TalkKeys.shared.apply()
            TalkKey.current = r
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { e in
            if e.type == .otherMouseDown {
                let n = e.buttonNumber
                save(TalkKey(mouse: n, label: n == 2 ? "Middle mouse button" : "Mouse button \(n + 1)"))
                return nil
            }
            if e.keyCode == 53 {
                stop()
                return nil
            }  // Esc cancels
            let mods = TalkKey.carbonMods(e.modifierFlags)
            if mods == 0 && !TalkKey.isFunctionKey(e.keyCode) {
                warn = "That key is used for typing. Add ⌥, ⌃ or ⌘, or use an F key."
                return nil
            }
            save(TalkKey(keyCode: UInt32(e.keyCode), mods: mods, label: TalkKey.name(e)))
            return nil
        }
    }
    func save(_ k: TalkKey) {
        key = k
        TalkKey.current = k
        stop()
    }
    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        recording = false
        TalkKeys.shared.paused = false
        TalkKeys.shared.apply()
    }
}

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
