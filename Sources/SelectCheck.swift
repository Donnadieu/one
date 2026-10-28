import AppKit
import SwiftUI

// MARK: - Check: chat text can be selected and copied (`One --test-select <case>`)

/// Opens a window with the same chat pieces Home and a helper show (the person's line, a reply,
/// choice buttons, a helper's question and answer, a reader) and drives them with real mouse and key
/// events sent into that window: drag to select, ⌘C, ⌘A, the right-click items, a link, a choice
/// button's spot and the scroll wheel. Leaves the last copy on the clipboard so `pbpaste` can read it.
/// Touches no settings, brain or engine.
@MainActor
enum SelectCheck {
    static let ask = "Tidy my Downloads into folders that make sense, and keep anything from this week where it is"
    static let reply =
        "## Downloads, tidied\n\nI moved **42 files** into 5 folders:\n\n1. **Receipts** (12)\n2. *Screenshots* (18)\n3. Installers (`.dmg`, 6)\n\nSee [the list](https://example.com/list) for details.\n\nNothing was deleted."
    static let rich =
        "## Downloads, tidied\n\nI moved **42 files** into 5 folders:\n\n1. **Receipts** (12)\n2. *Screenshots* (18)\n3. Installers (`.dmg`, 6)\n\n- Kept on top: `resume.pdf`\n  - nested item\n\n| Folder | Files |\n|---|---|\n| Receipts | 12 |\n| Screenshots | 18 |\n\n> Nothing was deleted.\n\nSee [Finder](https://apple.com) for details."
    static let helperAsk = "Find the cheapest flight from PHL to Quebec City on Dec 20"
    static let helperReply =
        "Cheapest: **$212** on Dec 20, PHL to YQB.\n\n- Leaves 6:05 am\n- One stop in Montreal\n\nWant me to keep watching the price?"
    static var opened: [URL] = []
    static var choiceFrame = CGRect.zero
    static var fails = 0

    /// The still for `--render-world chat-select`: the AppKit drawing of each piece, with a selection showing.
    static func scene() -> some View {
        let w: CGFloat = 520
        return VStack(spacing: 14) {
            Image(nsImage: ChatText.snapshot(ask, size: ChatText.callout, width: w, plain: true, center: true))
            Image(nsImage: ChatText.snapshot(rich, width: w - 36, select: NSRange(location: 30, length: 52))).padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.07)))
            ChoiceRow(choices: ["Yes, go ahead", "Not now"]) { _ in }
        }.padding(24).frame(width: 600).background(WorldLook.bg).environment(\.colorScheme, .dark)
    }

    /// The live window's content.
    static func live(reader: Bool) -> some View {
        Group {
            if reader {
                ReaderText(text: reply + "\n\n" + Array(repeating: "More of the plan, line after line.", count: 40).joined(separator: "\n\n"))
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        ChatText(text: ask, size: ChatText.callout, plain: true, center: true, accent: true).frame(maxWidth: .infinity)
                        ChatText(text: reply, size: 16).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                        ChoiceRow(choices: ["Yes, go ahead", "Not now"]) { _ in }
                            .background(GeometryReader { g in Color.clear.onAppear { choiceFrame = g.frame(in: .global) } })
                        VStack(alignment: .leading, spacing: 12) {
                            ChatText(text: helperAsk, size: ChatText.callout, plain: true, accent: true)
                            ChatText(text: helperReply, size: 15).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(18).background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                        ForEach(0..<30, id: \.self) { i in Text("Filler line \(i) so the page scrolls").foregroundStyle(.secondary) }
                    }.padding(28)
                }
            }
        }
        .frame(width: 620, height: 560).background(WorldLook.bg).environment(\.colorScheme, .dark)
        .environment(
            \.openURL,
            OpenURLAction { u in
                opened.append(u)
                return .handled
            })
    }

    /// Runs the check and exits when `--test-select` is among the arguments; returns otherwise.
    nonisolated static func main(_ args: [String]) {
        guard let k = args.firstIndex(of: "--test-select") else { return }
        TestWorld.enter()  // a test copy only: one window, events sent into it, the clipboard
        MainActor.assumeIsolated { run(k + 1 < args.count ? args[k + 1] : "reply") }
        exit(0)
    }

    static func run(_ which: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Same Edit items the real app's menu has, so ⌘C / ⌘A go the normal way.
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        app.mainMenu = main
        let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: live(reader: which == "reader"))
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if which == "all" {
                for c in ["user", "reply", "helper", "selectall", "menu", "link", "choice", "scroll"] {
                    print("== \(c)")
                    await front(win)
                    await drive(c, win)
                }
            } else {
                await front(win)
                await drive(which, win)
            }
            print(fails == 0 ? "PASS \(which)" : "FAIL \(which): \(fails) problem(s)")
            exit(fails == 0 ? 0 : 1)
        }
        app.run()
    }

    /// ⌘C and ⌘A need the window in front; wait a little if someone is using another app.
    static func front(_ win: NSWindow) async {
        for _ in 0..<20 where !win.isKeyWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    static func views(_ v: NSView) -> [ChatTextView] {
        (v as? ChatTextView).map { [$0] } ?? v.subviews.flatMap(views)
    }

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { fails += 1 }
    }

    /// Window point of character `i` in `tv` (`end` = its right edge), mid-height of its line.
    static func point(_ tv: ChatTextView, _ i: Int, end: Bool = false) -> NSPoint {
        let lm = tv.layoutManager!
        let g = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: g, in: tv.textContainer!)
        let p = NSPoint(x: end ? r.maxX - 0.5 : r.minX + 0.5, y: r.midY)
        return tv.convert(p, to: nil)
    }

    static func mouse(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow, count: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            eventNumber: 0, clickCount: count, pressure: t == .leftMouseUp ? 0 : 1)!
    }

    static func drag(_ from: NSPoint, _ to: NSPoint, _ w: NSWindow) async {
        let app = NSApplication.shared
        app.postEvent(mouse(.leftMouseDown, from, w), atStart: false)
        for k in 1...6 {
            let f = CGFloat(k) / 6
            app.postEvent(mouse(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), w), atStart: false)
        }
        app.postEvent(mouse(.leftMouseUp, to, w), atStart: false)
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func click(_ p: NSPoint, _ w: NSWindow) async { await drag(p, p, w) }

    static func key(_ c: String, code: UInt16, _ w: NSWindow) async {
        let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
            context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
        NSApplication.shared.postEvent(e, atStart: false)
        try? await Task.sleep(for: .milliseconds(600))
    }

    static var board: String { NSPasteboard.general.string(forType: .string) ?? "" }

    /// Select from the start of `a` to the end of `b` in `tv`, ⌘C, and check the clipboard.
    static func selectCopy(_ tv: ChatTextView, _ a: String, _ b: String, _ w: NSWindow) async {
        let s = (tv.textStorage?.string ?? "") as NSString
        let ra = s.range(of: a)
        let rb = s.range(of: b)
        guard ra.location != NSNotFound, rb.location != NSNotFound else { return check(false, "text not found: \(a) / \(b)") }
        ChatTextView.put("(nothing yet)")
        await drag(point(tv, ra.location), point(tv, NSMaxRange(rb) - 1, end: true), w)
        let want = s.substring(with: NSRange(location: ra.location, length: NSMaxRange(rb) - ra.location))
        check(tv.selectedRange().length == want.utf16.count, "drag selected \(tv.selectedRange().length) chars (want \(want.utf16.count))")
        await key("c", code: 8, w)
        check(board == want, "⌘C copied: \(board.debugDescription)")
    }

    static func drive(_ which: String, _ w: NSWindow) async {
        let tvs = views(w.contentView!).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
        print("window key: \(w.isKeyWindow), text views: \(tvs.count)")
        switch which {
        case "user":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            await selectCopy(tvs[0], "Downloads", "keep anything", w)
        case "reply":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            await selectCopy(tvs[1], "42 files", "Screenshots", w)
        case "helper":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            await selectCopy(tvs[3], "$212", "One stop", w)
        case "reader":
            guard let tv = tvs.first else { return check(false, "no reader text") }
            await selectCopy(tv, "42 files", "Receipts", w)
        case "selectall":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            await click(point(tvs[1], 3), w)
            await key("a", code: 0, w)
            check(tvs[1].selectedRange().length == (tvs[1].textStorage?.string ?? "").utf16.count, "⌘A selected the whole reply only")
            check(tvs[3].selectedRange().length == 0, "the helper's text stayed unselected")
            await key("c", code: 8, w)
            check(
                board == (tvs[1].textStorage?.string ?? ""),
                "⌘C after ⌘A copied the whole reply (key \(w.isKeyWindow), got \(board.prefix(40).debugDescription))")
        case "menu":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            let tv = tvs[1]
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            let m = tv.menu(for: mouse(.rightMouseDown, point(tv, 5), w))!
            check(m.items.map(\.title).prefix(2) == ["Copy", "Copy as Markdown"], "right-click items: \(m.items.map(\.title))")
            for it in m.items where it.title.hasPrefix("Copy") {
                NSApplication.shared.sendAction(it.action!, to: it.target, from: it)
                let want = it.title == "Copy" ? tv.plainText : reply
                check(board == want && (it.title != "Copy" || !board.contains("**")), "\(it.title) gave \(board.prefix(60).debugDescription)…")
            }
            ChatTextView.put("")
            NSApplication.shared.sendAction(#selector(ChatTextView.copyPlain(_:)), to: tvs[0], from: nil)
            check(board == ask, "Copy on the person's own line")
        case "link":
            guard tvs.count >= 4 else { return check(false, "expected 4 chat texts") }
            let r = ((tvs[1].textStorage?.string ?? "") as NSString).range(of: "the list")
            await click(point(tvs[1], r.location + 2), w)
            check(opened.map(\.absoluteString) == ["https://example.com/list"], "link click opened: \(opened)")
        case "choice":
            // Sent clicks don't reach SwiftUI buttons (they read the real mouse), so check the part this
            // change could break: no chat text sits over the choice buttons, and the click lands beside them.
            let f = choiceFrame
            let p = NSPoint(x: f.minX + 30, y: w.contentView!.bounds.height - f.midY)
            let hit = w.contentView?.hitTest(p)
            check(
                f.height > 0 && !(hit is ChatTextView),
                "a click on the first choice reaches the buttons, not a chat text (\(String(describing: hit.map { type(of: $0) })))")
            let over = tvs.filter {
                NSIntersectsRect(
                    $0.convert($0.bounds, to: nil), NSRect(x: f.minX, y: w.contentView!.bounds.height - f.maxY, width: f.width, height: f.height))
            }
            check(over.isEmpty, "no chat text overlaps the choice row")
        case "scroll":
            guard tvs.count >= 4, let sv = tvs[1].enclosingScrollView else { return check(false, "no scroll view around the reply") }
            let before = sv.contentView.bounds.origin.y
            let e = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)!)!
            let hit = w.contentView?.hitTest(point(tvs[1], 10))
            check(hit is ChatTextView, "the wheel lands on the reply's text (\(String(describing: hit.map { type(of: $0) })))")
            hit?.scrollWheel(with: e)
            try? await Task.sleep(for: .milliseconds(500))
            check(
                sv.contentView.bounds.origin.y != before,
                "scroll wheel over the reply scrolled the page (\(before) → \(sv.contentView.bounds.origin.y))")
        default:
            check(false, "unknown case \(which)")
        }
    }
}
