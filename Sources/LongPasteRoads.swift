import AppKit
import SwiftUI

// MARK: - Check: every road a long text takes into the box asks the same question, once (part of `--test-long-paste`)
// Since 0.9.96 the question lives in the box (`AskTextView.shouldChangeText`). Before, only a plain ⌘V key press asked,
// so a paste with Caps Lock on, from Edit › Paste or the right-click menu, a drop, dictation, an app that types for
// you (Wispr Flow) or ⌘V with the focus on a chat message went straight in. Each road below runs on the real ask box
// in the real window: the menu items are AppKit's own (the app's Edit menu and the box's right-click menu), keys go
// through NSApplication's event dispatch. A drop is the text view's own drop read (`readSelection`), not a mouse drag.

extension LongPasteCheck {
    /// A clipboard with exactly these types, the way another app leaves it.
    static func put(_ items: [(NSPasteboard.PasteboardType, Data)], on pb: NSPasteboard = .general) {
        pb.clearContents()
        let it = NSPasteboardItem()
        for (t, d) in items { it.setData(d, forType: t) }
        pb.writeObjects([it])
    }
    /// The app's own Edit › <title> item, as a click on it runs it.
    static func menuItem(_ action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (i, it) in menu.items.enumerated() {
            if it.action == action { return (menu, i) }
            if let sub = it.submenu, let f = menuItem(action, in: sub) { return f }
        }
        return nil
    }

    static func roads(_ w: NSWindow, _ box: Box, _ check: (String, Bool) -> Void) {
        let m = Model.shared
        let transcript = LongRender.transcript
        guard let tv = LongPaste.box(in: w) else { return check("the ask box is found in the window", false) }
        func reset(_ s: String = "") {
            m.pasteOffer = nil
            m.files = []
            box.text = s
            pump(0.3)
            w.makeFirstResponder(tv)
            pump(0.2)
        }
        /// One road: the question is up with the right line count, once, and nothing went into the box.
        @discardableResult func asks(_ name: String, lines: Int = 214) -> String? {
            let first = m.pasteOffer?.id
            pump(0.4)
            let asked = m.pasteOffer?.text
            check("\(name): asks", m.pasteOffer?.lines == lines && m.pasteOffer?.id == first)
            check("\(name): nothing went in yet", box.text == "Hi " && tv.string == "Hi ")
            key(w, "\u{1b}", code: 53)
            return asked
        }

        let t0 = Date()
        print("every road in asks once:")
        reset("Hi ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        key(w, "V", code: 9, cmd: true, caps: true)
        asks("⌘V with Caps Lock on")

        reset("Hi ")
        if let (menu, i) = menuItem(#selector(NSText.paste(_:))) {
            menu.performActionForItem(at: i)
            asks("Edit › Paste")
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            asks("Edit › Paste (no app menu here: its action)")
        }

        reset("Hi ")
        let right = NSEvent.mouseEvent(
            with: .rightMouseDown, location: tv.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let right, let cm = tv.menu(for: right), let i = cm.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) }) {
            cm.performActionForItem(at: i)
            asks("right-click › Paste")
        } else {
            check("right-click menu has Paste", false)
        }

        reset("Hi ")
        NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
        asks("Paste and Match Style")

        reset("Hi ")
        let drag = NSPasteboard(name: .drag)
        put([(.string, Data(transcript.utf8))], on: drag)
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        _ = tv.readSelection(from: drag, type: .string)
        asks("a drop on the box")

        reset("Hi ")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertText(transcript, replacementRange: NSRange(location: NSNotFound, length: 0))
        asks("dictation or an input method typing it in")

        reset("Hi ")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.setAccessibilitySelectedText(transcript)
        asks("an app typing it in for you (accessibility, like Wispr Flow)")

        reset("Hi ")
        let rtf = NSAttributedString(string: transcript, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if let d = try? rtf.data(
            from: NSRange(location: 0, length: rtf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        {
            put([(.rtf, d)])
            key(w, "v", code: 9, cmd: true)
            let asked = asks("rich text only (no plain copy on the clipboard)")
            check("…what it asks about is the plain words", asked == transcript)
        }

        reset("Hi ")
        put([
            (NSPasteboard.PasteboardType("org.chromium.source-url"), Data("https://example.com".utf8)),
            (.html, Data("<p>\(transcript)</p>".utf8)), (.string, Data(transcript.utf8)),
        ])
        key(w, "v", code: 9, cmd: true)
        asks("a copy from Chrome (web page text, with its own types)")

        // The typing focus on a chat message (a click on a reply): ⌘V goes into the box, through the same question.
        reset("Hi ")
        if let reply = chatView(in: w.contentView) {
            w.makeFirstResponder(reply)
            pump(0.2)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            key(w, "v", code: 9, cmd: true)
            check("⌘V with the focus on a chat message: asks", m.pasteOffer?.lines == 214 && m.pasteOffer?.into === tv)
            key(w, "\u{1b}", code: 53)
            w.makeFirstResponder(reply)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Short one.", forType: .string)
            key(w, "v", code: 9, cmd: true)
            check("…a short one goes into the box", m.pasteOffer == nil && box.text == "Hi Short one.")
        } else {
            check("the test window shows a chat message", false)
        }

        // Busy with a reply and talking to a helper in its orb: the same box, the same question.
        reset("Hi ")
        let h = Helper(title: "Flight to Quebec", task: "Find a flight.", state: "working", line: "")
        m.helpers = [h]
        m.openHelper = h.id
        m.thinking = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        key(w, "v", code: 9, cmd: true)
        asks("while a reply is coming, in a helper's thread")
        m.thinking = false
        m.openHelper = nil
        m.helpers = []

        // Size: lines or characters, whichever comes first; a Windows line end counts once.
        let crlf = (1...20).map { "line \($0)" }.joined(separator: "\r\n")
        check("20 lines with Windows line ends are 20 lines, not long", LongPaste.lines(crlf) == 20 && !LongPaste.isLong(crlf))
        check("31 short lines are long", LongPaste.isLong((1...31).map { "l\($0)" }.joined(separator: "\n")))
        check("one line of 2,001 characters is long", LongPaste.isLong(String(repeating: "a", count: 2001)))
        check("one line of 2,000 characters is not", !LongPaste.isLong(String(repeating: "a", count: 2000)))

        // An already filled box: As text goes in where the cursor was, once.
        reset("Hello world")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        key(w, "v", code: 9, cmd: true)
        check("a filled box asks too", m.pasteOffer != nil && box.text == "Hello world")
        LongPaste.asText()
        pump(0.4)
        check("…As text goes in at the cursor, without a second question", box.text == "Hello " + transcript + "world" && m.pasteOffer == nil)
        // Undo and redo of a long paste put it back without asking again. (A stand-in undo list that reports it's
        // undoing or redoing: a real undo can't run inside this check's one long event, where AppKit's own
        // per-event undo group never closes.)
        for (name, keeper) in [("undo", UndoKeeper(UndoKeeper.Undoing())), ("redo", UndoKeeper(UndoKeeper.Redoing()))] {
            w.delegate = keeper
            w.makeFirstResponder(nil)
            reset("Hello world")
            if tv.undoManager !== keeper.u { print("  (the box's undo list isn't the stand-in: \(String(describing: tv.undoManager)))") }
            tv.insertText(transcript, replacementRange: NSRange(location: 6, length: 0))
            pump(0.3)
            check("…\(name) of a long paste never asks", m.pasteOffer == nil && box.text == "Hello " + transcript + "world")
            w.delegate = nil
        }

        // Typing never asks, however long the message gets.
        reset("")
        for _ in 0..<5 { tv.insertText(String(repeating: "word ", count: 100), replacementRange: tv.selectedRange()) }
        check("a message written a bit at a time never asks, however long", m.pasteOffer == nil && box.text.count == 2500)
        reset("")
        print("  (every road took \(Int(Date().timeIntervalSince(t0))) s)")
    }

    final class UndoKeeper: NSObject, NSWindowDelegate {
        final class Undoing: UndoManager { override var isUndoing: Bool { true } }
        final class Redoing: UndoManager { override var isRedoing: Bool { true } }
        let u: UndoManager
        init(_ u: UndoManager) { self.u = u }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { u }
    }

    static func chatView(in v: NSView?) -> ChatTextView? {
        guard let v else { return nil }
        if let c = v as? ChatTextView { return c }
        for s in v.subviews { if let c = chatView(in: s) { return c } }
        return nil
    }
}
