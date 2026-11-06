import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Check: long messages fold, long pastes ask (`One --test-long-paste`, from a test copy with ONE_SUPPORT_DIR set)
// A real on-screen window with the real ask box and the real pop-up; real ⌘V, Esc and Return key events and real
// clicks go through NSApplication's own event dispatch (the same path a person's keys and clicks take).
// Proves: a short paste pastes as before; a long one asks; Esc and a click outside close it without pasting;
// "As a file" makes a "Pasted text, N lines" chip whose file holds the exact text, and the sent message carries the
// path (not the text); "As text" pastes the exact text; Return answers "As a file" and never sends; pictures still
// attach; long messages fold past 12 lines, open state is remembered per message and survives saved bubbles.
// Every other road in (Caps Lock, Edit › Paste, right-click, a drop, dictation, focus elsewhere…): LongPasteRoads.swift.

@MainActor
enum LongPasteCheck {
    static func launch() -> Bool {
        LongRender.cli(CommandLine.arguments)  // --render-long <prefix>: renders and exits
        guard CommandLine.arguments.contains("--test-long-paste") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        run()
        return true
    }

    final class Box: ObservableObject {
        @Published var text = ""
        @Published var focused = true
    }

    struct Host: View {
        @ObservedObject var m: Model
        @ObservedObject var box: Box
        @StateObject var metrics = AskMetrics()
        var body: some View {
            VStack(spacing: 8) {
                // A reply on screen: a click on it takes the typing focus off the box (the ⌘V-elsewhere road).
                ChatTextBox(shown: NSAttributedString(string: "Here's what I found."), markdown: "Here's what I found.", open: { _ in })
                    .frame(height: 40)
                Spacer()
                PictureStrip(m: m)
                AskEditor(text: $box.text, focused: $box.focused, metrics: metrics, onSubmit: { box.text = "SENT" }).frame(height: 120)
                    .background(Color.white.opacity(0.05))
            }
            .padding(28).frame(width: 620, height: 700).background(WorldLook.bg).pasteAsk(m).environment(\.colorScheme, .dark)
        }
    }

    static func key(_ w: NSWindow, _ chars: String, code: UInt16, cmd: Bool = false, caps: Bool = false) {
        front(w)
        var flags: NSEvent.ModifierFlags = cmd ? .command : []
        if caps { flags.insert(.capsLock) }
        for t: NSEvent.EventType in [.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(
                with: t, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            {
                NSApp.postEvent(e, atStart: false)
            }
        }
        pump(0.6)
    }
    /// Keys go to the key window: keep the test window in front even if something else took focus meanwhile.
    static func front(_ w: NSWindow) {
        for _ in 0..<10 where !w.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            pump(0.3)
        }
    }
    static func paste(_ w: NSWindow, _ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        key(w, "v", code: 9, cmd: true)
    }
    /// Lets the app's own event loop deliver posted events (monitors run there) and SwiftUI update.
    static func pump(_ s: Double) {
        let until = Date().addingTimeInterval(s)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
        }
    }
    static func button(_ name: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        for _ in 0..<10 {
            var wins: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
            for w in (wins as? [AXUIElement]) ?? [] {
                for b in MessageHistoryClickCheck.buttons(in: w) {
                    var t: CFTypeRef?
                    var d: CFTypeRef?
                    AXUIElementCopyAttributeValue(b, kAXTitleAttribute as CFString, &t)
                    AXUIElementCopyAttributeValue(b, kAXDescriptionAttribute as CFString, &d)
                    if (t as? String) == name || (d as? String) == name { return b }
                }
            }
            pump(0.3)
        }
        return nil
    }
    static func click(_ w: NSWindow, _ name: String) -> Bool {
        front(w)
        guard AXIsProcessTrusted() else {
            // A CI runner may not let a program read its own buttons' places: press the same action instead.
            name == "As a file" ? LongPaste.asFile() : LongPaste.asText()
            pump(0.6)
            return true
        }
        guard let b = button(name), let p = MessageHistoryClickCheck.screenCenter(b) else { return false }
        MessageHistoryClickCheck.click(window: w, screenPointTopLeft: p)
        pump(0.6)
        return true
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)  // every line out at once, even if a time limit stops the run
        var fails = 0
        let box = Box()
        func check(_ name: String, _ ok: Bool) {
            print(
                "  \(ok ? "✓" : "✗") \(name)\(ok ? "" : "  [box: \(box.text.prefix(40).debugDescription), asking: \(Model.shared.pasteOffer != nil), chips: \(Model.shared.files.count), key: \(NSApp.keyWindow != nil)]")"
            )
            if !ok { fails += 1 }
        }
        let m = Model.shared
        let transcript = LongRender.transcript

        print("folding long messages:")
        check("a 214-line transcript folds", LongFold.folds(transcript))
        check("its label says 214 lines", LongFold.label(transcript) == 214)
        let twelve = (1...12).map { "line \($0)" }.joined(separator: "\n")
        check("12 short lines don't fold", !LongFold.folds(twelve))
        check("13 lines fold", LongFold.folds(twelve + "\nline 13"))
        check("a short message doesn't fold", !LongFold.folds("What's my flight time on the 20th?"))
        check("one long paragraph (2,000 characters) folds", LongFold.folds(String(repeating: "word ", count: 400)))
        let b = Bubble(fromMe: true, text: transcript)
        var raw = LongFold.set(LongFold.key(b), open: true, in: "")
        check("opening a message is remembered", LongFold.isOpen(LongFold.key(b), in: raw))
        raw = LongFold.set(LongFold.key(b), open: false, in: raw)
        check("hiding it again is remembered", !LongFold.isOpen(LongFold.key(b), in: raw))
        var many = ""
        for i in 0..<400 { many = LongFold.set("k\(i)", open: true, in: many) }
        check("the remembered list stays small", many.split(separator: "\n").count == LongFold.maxRemembered && LongFold.isOpen("k399", in: many))
        // Old saved bubbles (the format every earlier One wrote) still load, and a message keeps its name across a restart.
        UserDefaults.standard.set(
            [["me": true, "t": transcript, "f": [String](), "d": b.date.timeIntervalSince1970] as [String: Any], ["me": false, "t": "Got it."]],
            forKey: "bubbles")
        let back = Model.savedBubbles()
        check("old saved bubbles still load", back.count == 2 && back[0].text == transcript && back[1].text == "Got it.")
        check("a saved message keeps its fold name after a restart", back.first.map(LongFold.key) == LongFold.key(b))
        UserDefaults.standard.removeObject(forKey: "bubbles")

        print("pasting, in a real window:")
        check("no paste is long below 31 lines and 2,001 characters", !LongPaste.isLong(twelve) && LongPaste.isLong(transcript))
        m.onboarded = true
        LongPaste.install()  // as the app does it: pictures and files first, then long text
        let w = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 620, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Host(m: m, box: box))
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        pump(1.0)
        front(w)
        for _ in 0..<15 where !(w.isKeyWindow && w.firstResponder is AskTextView) { pump(0.2) }
        check("the ask box has the typing focus", w.firstResponder is AskTextView)

        paste(w, "Short and sweet.")
        check("a short paste pastes as before, no question", m.pasteOffer == nil && box.text == "Short and sweet.")
        box.text = "Here's the call."
        pump(0.3)

        paste(w, transcript)
        check("a long paste asks first", m.pasteOffer?.lines == 214)
        check("…and nothing went into the box yet", box.text == "Here's the call.")
        if AXIsProcessTrusted() {
            check("the question's buttons are on screen", button("As a file") != nil && button("As text") != nil)
        } else {
            print("  (this runner can't read buttons; clicks press their action)")
        }
        paste(w, transcript)
        check("⌘V again while it asks pastes nothing behind it", m.pasteOffer != nil && box.text == "Here's the call.")
        key(w, "\u{1b}", code: 53)
        check("Esc closes it without pasting", m.pasteOffer == nil && box.text == "Here's the call.")

        paste(w, transcript)
        // A real click outside the panel, high on the dim (the panel sits just above the ask box).
        front(w)
        for t: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(
                with: t, location: NSPoint(x: 310, y: 640), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                NSApp.sendEvent(e)
            }
            pump(0.15)
        }
        pump(0.6)
        check("a click outside closes it without pasting", m.pasteOffer == nil && box.text == "Here's the call.")

        paste(w, transcript)
        check("a real click on As a file works", click(w, "As a file"))
        check("…the question is gone", m.pasteOffer == nil)
        check("…the box text is untouched", box.text == "Here's the call.")
        let f = m.files.first
        check("…a chip named \"Pasted text, 214 lines\"", m.files.count == 1 && f?.name == "Pasted text, 214 lines")
        check("…its file holds the exact pasted text", f.flatMap { try? String(contentsOf: $0.copy, encoding: .utf8) } == transcript)
        check("…kept in One's own folder", f?.copy.path.hasPrefix(Env.support.appendingPathComponent("Shared with me").path) == true)
        check("…the chip shows the start of the first line", f?.preview.map { transcript.hasPrefix($0) && $0.count >= 40 } == true)
        if let c = m.compose(box.text) {
            check("the sent message shows the chip and his words, not 214 lines", c.display == "📄 Pasted text, 214 lines\nHere's the call.")
            check("the assistant is told where the file is", f.map { c.engine.contains($0.copy.path) } == true)
            check("the assistant isn't sent the 214 lines inline", !c.engine.contains("[00:04:19]"))
        } else {
            check("the message composes", false)
        }
        check("sending empties the chips", m.files.isEmpty)

        box.text = ""
        pump(0.3)
        paste(w, transcript)
        check("a real click on As text works", click(w, "As text"))
        check("…the exact text is in the box", m.pasteOffer == nil && box.text == transcript)
        check("…no chip was made", m.files.isEmpty)

        box.text = "Keep this."
        pump(0.3)
        paste(w, transcript)
        key(w, "\r", code: 36)
        check("Return answers As a file", m.pasteOffer == nil && m.files.count == 1)
        check("…and never sends the message", box.text == "Keep this.")
        m.files = []

        // A picture on the clipboard still attaches as a picture (the old path), never asks.
        let img = NSImage(size: NSSize(width: 40, height: 40))
        img.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        img.unlockFocus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        key(w, "v", code: 9, cmd: true)
        check("a copied picture still attaches as a picture", m.pictures.count == 1 && m.pasteOffer == nil)
        m.pictures = []

        roads(w, box, check)  // every other road in (LongPasteRoads.swift)

        w.close()
        print(fails == 0 ? "long paste: all checks passed" : "long paste: \(fails) check(s) failed")
        exit(fails == 0 ? 0 : 1)
    }
}
