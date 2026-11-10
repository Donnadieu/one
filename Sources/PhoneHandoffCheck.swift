import CryptoKit
import Foundation

/// `One --test-phone-handoff` (preflight, CI only, a test copy): the phone hand-off end to end on loopback, with a
/// stand-in page (in place of the hidden browser's tab) and a stand-in phone. No chat message is really sent and no
/// tunnel is opened: both are swapped for stand-ins here.
enum PhoneHandoffCheck {
    static func main(_ args: [String]) {
        guard args.contains("--test-phone-handoff") else { return }
        TestWorld.enter()
        MainActor.assumeIsolated {
            Task { @MainActor in exit(await run()) }
        }
        RunLoop.main.run()
    }

    final class Box<T>: @unchecked Sendable {
        var v: T
        init(_ v: T) { self.v = v }
    }

    static func get(_ url: String) async -> Int {
        guard let u = URL(string: url), let (_, r) = try? await URLSession.shared.data(from: u) else { return -1 }
        return (r as? HTTPURLResponse)?.statusCode ?? -1
    }
    static func phone(_ port: UInt16, _ room: String) -> URLSessionWebSocketTask {
        let t = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws/\(room)")!)
        t.resume()
        return t
    }
    static func sealed(_ j: [String: Any], _ k: SymmetricKey) -> URLSessionWebSocketTask.Message {
        .data(PhoneHandoff.seal(try! JSONSerialization.data(withJSONObject: j), k)!)
    }

    @MainActor static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        // 1. What a phone may send: taps, scrolls, short text, Enter/Backspace/Tab, Done, Not now. Nothing else.
        let ok = { (j: [String: Any]) in PhoneHandoff.allowed(try! JSONSerialization.data(withJSONObject: j)) }
        check(
            "a tap, a scroll, text, Enter, Done and Not now pass",
            ok(["t": "tap", "x": 0.5, "y": 0.2]) == .tap(0.5, 0.2) && ok(["t": "scroll", "dy": 200.0]) == .scroll(200)
                && ok(["t": "text", "s": "123456"]) == .text("123456") && ok(["t": "key", "k": "Enter"]) == .key("Enter")
                && ok(["t": "done"]) == .done && ok(["t": "notnow"]) == .notNow)
        check(
            "anything else is dropped: other DevTools calls, new tabs, going to a page, keys like ⌘L, a tap off the page",
            ok(["t": "Target.createTarget", "url": "https://x"]) == nil && ok(["t": "navigate", "url": "https://x"]) == nil
                && ok(["t": "key", "k": "Meta+L"]) == nil && ok(["t": "tap", "x": 1.5, "y": 0.1]) == nil
                && ok(["t": "text", "s": "a\nb"]) == nil && ok(["t": "text", "s": String(repeating: "a", count: 201)]) == nil
                && ok(["t": "tap", "x": 0.1, "y": 0.1, "method": "Runtime.evaluate"]) == nil)
        check(
            "a tap becomes a mouse press at that point of the page, text becomes typing",
            PhoneHandoff.cdp(.tap(0.5, 0.25), w: 400, h: 800).map(\.0) == Array(repeating: "Input.dispatchMouseEvent", count: 3)
                && (PhoneHandoff.cdp(.tap(0.5, 0.25), w: 400, h: 800)[1].1["y"] as? Double) == 200
                && PhoneHandoff.cdp(.text("12"), w: 1, h: 1).first?.0 == "Input.insertText")
        check("the audit never keeps what was typed", PhoneHandoff.auditWords(.text("123456")) == "typed 6 characters")
        // 2. One page: its own site and its sign-in hosts only.
        check(
            "one page: its own site stays (www.amazon.com, amazon.com/ap/mfa)",
            PhoneHandoff.stays(URL(string: "https://www.amazon.com/ap/mfa")!, stepSite: "amazon.com"))
        check(
            "a Google step may go through accounts.google.com",
            PhoneHandoff.stays(URL(string: "https://accounts.google.com/x")!, stepSite: "google.com"))
        check(
            "another site ends it",
            !PhoneHandoff.stays(URL(string: "https://evil.example/x")!, stepSite: "amazon.com")
                && !PhoneHandoff.stays(URL(string: "https://amazon.com.evil.example/")!, stepSite: "amazon.com"))
        check("site names: www.amazon.co.uk is amazon.co.uk", PhoneHandoff.site("www.amazon.co.uk") == "amazon.co.uk")
        // 3. When to send: a minute unanswered, or they're away, or no screen.
        check(
            "sent after a minute, or at once when they're away or there's no screen",
            !PhoneHandoff.due(waited: 10, idle: 5, screen: true) && PhoneHandoff.due(waited: 61, idle: 5, screen: true)
                && PhoneHandoff.due(waited: 0, idle: 400, screen: true) && PhoneHandoff.due(waited: 0, idle: 0, screen: false))
        // 4. The seal: the key lives only in the link's # part.
        let l = PhoneHandoff.newLink()
        let url = l.url(base: "https://abc.trycloudflare.com")
        check(
            "the link: 128-bit room in the path, 256-bit key only after #",
            l.room.count == 32 && url.contains("/h/\(l.room)#k=")
                && !url.split(separator: "#")[0].contains(l.keyText))
        let msg = Data("{\"t\":\"tap\"}".utf8)
        check(
            "sealed both ways; another key can't open it",
            PhoneHandoff.open(PhoneHandoff.seal(msg, l.key)!, l.key) == msg
                && PhoneHandoff.open(PhoneHandoff.seal(msg, l.key)!, SymmetricKey(size: .bits256)) == nil)
        check(
            "the page has no key in it and escapes the job's title",
            !PhonePage.html(title: "x", ends: Date()).contains(l.keyText) && PhonePage.html(title: "<b>", ends: Date()).contains("&lt;b&gt;")
                && !PhonePage.html(title: "<b>", ends: Date()).contains("<b>"))
        let f = [UInt8](PhoneSocket.encode(Data(repeating: 7, count: 70_000)))
        var round = Data(f)
        check("socket frames of any size read back", PhoneSocket.frame(&round)?.1.count == 70_000)

        // 5. End to end: a stand-in page (the hidden browser's tab), the hand-off request, a stand-in phone.
        let page = PhoneServer(room: "unused", page: "")
        page.socketPath = "/devtools/page/TAB1"
        let calls = Box<[String]>([])
        let pageSock = Box<PhoneSocket?>(nil)
        page.onPhone = { s, _ in
            pageSock.v = s
            s.onMessage = { d in
                if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let m = j["method"] as? String { calls.v.append(m) }
            }
        }
        guard let pagePort = page.start() else {
            check("stand-in page starts", false)
            return 1
        }
        let ask = HumanStepAsk(
            id: "h1", site: "amazon.com", kind: "code", line: "", port: Int(pagePort), target: "TAB1", url: "https://www.amazon.com/ap/mfa")
        try? FileManager.default.createDirectory(at: HumanStep.dir, withIntermediateDirectories: true)
        let sent = Box<[(String, String)]>([])
        let edited = Box<[String]>([])
        PhoneSession.send = { t, u in
            sent.v.append((t, u))
            return 42
        }
        PhoneSession.edit = { _, t in edited.v.append(t) }
        PhoneSession.publicBase = { port, _ in "http://127.0.0.1:\(port)" }
        let s = PhoneSession(ask: ask, title: "Order paper towels")
        check("starts and sends one message with the link", s.start() && sent.v.count == 1)
        check(
            "in plain words: \"Amazon.com needs a code for Order paper towels … Works once, for 10 minutes.\"",
            sent.v.first?.0.contains("needs a code for Order paper towels") == true && sent.v.first?.0.contains("10 minutes") == true)
        guard let link = sent.v.first?.1, let base = link.split(separator: "/h/").first, let port = UInt16(base.split(separator: ":").last ?? ""),
            let room = link.split(separator: "/h/").last?.split(separator: "#").first
        else {
            check("the link reads back", false)
            return 1
        }
        check("the page opens at its link", await get("\(base)/h/\(room)") == 200)
        let (other, root, plainWS) = (await get("\(base)/h/other"), await get("\(base)/"), await get("\(base)/ws/\(room)"))
        check("nothing else is served (another room, the root, the socket without upgrading)", other == 404 && root == 404 && plainWS == 404)
        let ph = phone(port, String(room))
        try? await Task.sleep(for: .milliseconds(800))
        check("the phone's opening attaches to that one tab and starts its picture", calls.v.contains("Page.startScreencast"))
        let second = phone(port, String(room))
        var refused = false
        do { _ = try await second.receive() } catch { refused = true }
        check("a second phone is refused", refused)
        // The tab sends a frame: the phone gets it sealed, and can open it.
        let frame: [String: Any] = [
            "method": "Page.screencastFrame", "params": ["data": "QUJD", "sessionId": 1, "metadata": ["deviceWidth": 400.0, "deviceHeight": 800.0]],
        ]
        pageSock.v?.send(try! JSONSerialization.data(withJSONObject: frame), op: 1)
        var got: [String: Any]?
        if case .data(let d)? = try? await ph.receive(),
            let k = Data(
                base64Encoded: String(link.split(separator: "#k=").last!).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
                    of: "_", with: "/") + "=")
        {
            let key = SymmetricKey(data: k)
            got = PhoneHandoff.open(d, key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(
                "the phone gets the page's picture, sealed",
                got?["t"] as? String == "frame" && got?["d"] as? String == "QUJD"
                    && String(decoding: d, as: UTF8.self).range(of: "QUJD") == nil)
            try? await ph.send(sealed(["t": "text", "s": "123456"], key))
            try? await ph.send(sealed(["t": "tap", "x": 0.5, "y": 0.5], key))
            try? await ph.send(.data(Data("{\"t\":\"Target.createTarget\"}".utf8)))  // not sealed: dropped
            try? await ph.send(sealed(["t": "Runtime.evaluate", "expression": "1"], key))  // not allowed: dropped
            try? await Task.sleep(for: .milliseconds(800))
            check("its typing and taps reach that tab", calls.v.contains("Input.insertText") && calls.v.contains("Input.dispatchMouseEvent"))
            check("nothing else does", !calls.v.contains("Target.createTarget") && !calls.v.contains("Runtime.evaluate"))
            try? await ph.send(sealed(["t": "done"], key))
            try? await Task.sleep(for: .milliseconds(800))
        } else {
            check("the phone gets the page's picture, sealed", false)
        }
        let answer = (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("h1.answer.json"))).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("Done on the phone answers the step, so the helper carries on", (answer?.values.contains { "\($0)" == "done" }) == true)
        let after = await get("\(base)/h/\(room)")
        check(
            "and the link ends: the message says so, the server stops",
            s.ended == "done on the phone" && edited.v.last?.hasPrefix("Done.") == true && after == -1)
        let audit = (try? String(contentsOf: HumanStep.dir.appendingPathComponent("h1.audit.jsonl"), encoding: .utf8)) ?? ""
        check(
            "the audit: created, sent, opened, refused a second phone, typed 6 characters, dropped, ended",
            ["created", "link sent", "opened on their phone", "refused a second phone", "typed 6 characters", "dropped", "ended"].allSatisfy {
                audit.contains($0)
            })
        check("and never the code itself", !audit.contains("123456"))

        // 6. The tab going to another site ends it.
        page.stop()
        let page2 = PhoneServer(room: "unused", page: "")
        page2.socketPath = "/devtools/page/TAB2"
        let tab2 = Box<PhoneSocket?>(nil)
        page2.onPhone = { s, _ in tab2.v = s }
        let port2 = page2.start() ?? 0
        let s2 = PhoneSession(
            ask: HumanStepAsk(id: "h2", site: "amazon.com", kind: "code", line: "", port: Int(port2), target: "TAB2", url: "https://www.amazon.com/"),
            title: "x")
        _ = s2.start()
        if let l2 = sent.v.last?.1, let b2 = l2.split(separator: "/h/").first, let p2 = UInt16(b2.split(separator: ":").last ?? ""),
            let r2 = l2.split(separator: "/h/").last?.split(separator: "#").first
        {
            let ph2 = phone(p2, String(r2))
            try? await Task.sleep(for: .milliseconds(800))
            let nav: [String: Any] = ["method": "Page.frameNavigated", "params": ["frame": ["id": "f", "url": "https://evil.example/login"]]]
            tab2.v?.send(try! JSONSerialization.data(withJSONObject: nav), op: 1)
            try? await Task.sleep(for: .milliseconds(800))
            ph2.cancel()
        }
        check("the tab going to another site ends the link", s2.ended?.hasPrefix("the page went to another site") == true)
        s2.stop("check over")
        page2.stop()
        print(fails == 0 ? "phone handoff ok" : "phone handoff: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
