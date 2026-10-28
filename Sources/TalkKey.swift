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
            HStack {
                Text("Push to talk").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 150)  // the X and "Esc to close"
            }.frame(height: 28)
            Text("Hold this key or button anywhere on your Mac, talk, then let go to send.").foregroundStyle(WorldLook.cream.opacity(0.75))
            HStack(spacing: 12) {
                Text(recording ? "Press a key or a mouse button…" : (key?.label ?? "Off"))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(minWidth: 220, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(recording ? 0.12 : PopupLook.card))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                            WorldLook.cream.opacity(recording ? 0.4 : PopupLook.cardEdge)))
                Button(recording ? "Cancel" : "Change") { recording ? stop() : record() }.buttonStyle(.bordered)
            }
            if let warn { Text(warn).foregroundStyle(.orange).font(.callout) }
            Text("Good choices: a key like F5, a combo like ⌥ Space, or a side button on your mouse.")
                .font(.callout).foregroundStyle(WorldLook.cream.opacity(0.6))
            HStack {
                Button("Turn off") {
                    stop()
                    key = nil
                    TalkKey.current = nil
                    TalkKeys.shared.apply()
                }.buttonStyle(.bordered)
                Button("Use ⌥ Space") {
                    stop()
                    key = .standard
                    TalkKey.current = .standard
                    TalkKeys.shared.apply()
                }.buttonStyle(.bordered)
                Spacer()
                Button {
                    stop()
                    done()
                } label: {
                    Text("Done").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 20).frame(height: 34).background(Capsule().fill(WorldLook.cream))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(WorldLook.cream)
        .padding(22).frame(width: 470)
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
