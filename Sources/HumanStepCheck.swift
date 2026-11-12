import AppKit

/// `One --test-human-step` (tools/handoff-check.sh): plays the person for steps only a person can do, on pages that
/// exist ONLY as a form POST answer (tests/handoff/post_server.py), like DocuSign's "enter the code we sent". Opening
/// such a page's address again (a reload, a new tab, a window reopened on the same profile) lands on a log-in page, so
/// the only thing that works is the very tab the helper was on (One 0.9.58 to 0.9.112 closed the hidden browser and
/// reopened the address in a window: Omar saw DocuSign's log-in page twice, Nov 11 2026).
/// 1. A code: the card asks first, nothing pops up; the person types it in the card's box; it lands in
///    the helper's still-open tab (the engine half, tests/handoff/e2e_engine.py, checks the site took it).
/// 2. A step done in the page (approve): the real Chrome window opens on the helper's very page (StepPageCopy), never
///    a fresh load of its address; what the person does there lands on the real site; after Done the hidden browser is
///    back and the helper's tab is past the step.
/// The test Chrome plays One's own hidden browser (as in real use). Never the shared hidden browser: the port comes
/// from ONE_HANDOFF_CDP (a throwaway Chrome on its own port and profile).
enum HumanStepCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let env = ProcessInfo.processInfo.environment
        guard Env.selfTest, env["ONE_SUPPORT_DIR"] != nil, let cdp = env["ONE_HANDOFF_CDP"], !cdp.hasSuffix(":9223"),
            let port = cdp.split(separator: ":").last.flatMap({ Int($0) }), let profile = env["ONE_HANDOFF_PROFILE"]
        else {
            print("refusing: run tools/handoff-check.sh (throwaway folder, a test Chrome, never port 9223)")
            return 2
        }
        let web = env["ONE_TEST_WEB"] ?? "8791"
        // The test Chrome is One's own hidden browser here, exactly as the person's is.
        BrowserKeeper.planOverride = BrowserKeeper.Plan(port: port, profile: profile, headless: true)
        defer { BrowserKeeper.planOverride = nil }
        let chrome = HumanCheck.mainChrome(profile: profile)
        let m = Model.shared

        func tab(_ target: String, _ expr: String) async -> Any? {
            let p = StepPage(port: port, target: target)
            p.connectQuiet()
            defer { p.disconnect() }
            let r = await withTaskGroup(of: [String: Any].self) { g in
                g.addTask { @MainActor in await p.call("Runtime.evaluate", ["expression": expr, "returnByValue": true]) }
                g.addTask { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    p.disconnect()  // a call with no answer gets one now, so the group can end
                    return [:]
                }
                let first = await g.next() ?? [:]
                g.cancelAll()
                return first
            }
            return (r["result"] as? [String: Any])?["value"]
        }
        func alive(_ target: String) -> Bool {
            guard let u = URL(string: "http://127.0.0.1:\(port)/json/list"), let d = try? Data(contentsOf: u),
                let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
            else { return false }
            return l.contains { $0["id"] as? String == target }
        }
        func siteState() -> [String: Any] {
            guard let u = URL(string: "http://127.0.0.1:\(web)/state.json"), let d = try? Data(contentsOf: u) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        /// The helper's tab, untouched: still open, never reloaded (its mark survives), on `path`.
        func untouched(_ target: String, _ path: String) async -> Bool {
            guard alive(target) else { return false }
            return await tab(target, "window.__oneMark === 'same-tab' && location.pathname === '\(path)'") as? Bool == true
        }

        print("1. a code: the engine asks for the person on a page that exists only in its tab")
        let end = Date().addingTimeInterval(150)
        while Date() < end, m.humanSteps.isEmpty {
            m.tendHumanSteps()
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let a = m.humanSteps.first else {
            check("the engine asked for the person", false)
            return 1
        }
        print("   line: \(a.line)")
        check("the card says exactly what to do", a.line == "I need the code 127.0.0.1 sent you. Type it here and I'll take care of it.")
        check("nothing pops up on its own", HumanCheck.active == nil)
        try? await Task.sleep(for: .seconds(2))
        check(
            "the card asks first: no browser window, the hidden browser still up",
            HumanCheck.active == nil && HumanCheck.mainChrome(profile: profile) == chrome)
        check("the helper's tab is still on the code step, never reloaded", await untouched(a.target, "/send-code"))
        print("2. the person types the code in the card's box and taps Send")
        HumanStep.answer(a.id, "code", extra: ["code": "424242"])  // what the card's box sends (and a phone reply)
        let moved = Date().addingTimeInterval(25)
        var path = ""
        while Date() < moved {
            try? await Task.sleep(for: .milliseconds(500))
            path = alive(a.target) ? (await tab(a.target, "location.pathname + location.search") as? String ?? "") : "gone"
            if path.hasPrefix("/welcome") { break }
        }
        check("the code landed in the helper's same tab and it moved on (\(path))", path == "/welcome.html?who=test@example.com")
        m.tendHumanSteps()
        check("the card left the chat", !m.humanSteps.contains { $0.id == a.id })

        print("3. a step done in the page (approve): the real window, on the helper's very page")
        // The real window closes this test Chrome for a while: wait until the engine half is done with it.
        let free = Date().addingTimeInterval(120)
        while Date() < free, !FileManager.default.fileExists(atPath: HumanStep.dir.appendingPathComponent("engine-done").path) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let nu = URL(string: "http://127.0.0.1:\(port)/json/new?http://127.0.0.1:\(web)/approve-start") else { return 1 }
        var nreq = URLRequest(url: nu)
        nreq.httpMethod = "PUT"
        let made = try? await URLSession.shared.data(for: nreq)
        let target = (made.flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] })?["id"] as? String ?? ""
        try? await Task.sleep(for: .seconds(1))
        _ = await tab(target, "document.getElementById('start').click()")
        try? await Task.sleep(for: .seconds(1.5))
        let invite = await tab(target, "document.querySelector('input[name=invite]').value") as? String ?? ""
        check("the tab is on a step that exists only in it (a form answer)", !invite.isEmpty)
        let id2 = "approve\(Int(Date().timeIntervalSince1970))"
        let req: [String: Any] = [
            "id": id2, "created": Date().timeIntervalSince1970, "site": "127.0.0.1", "kind": "approve", "port": port, "target_id": target,
            "url": "http://127.0.0.1:\(web)/approve",
        ]
        try? JSONSerialization.data(withJSONObject: req).write(to: HumanStep.dir.appendingPathComponent("\(id2).request.json"))
        m.tendHumanSteps()
        guard let b = m.humanSteps.first(where: { $0.id == id2 }) else {
            check("One shows the ask", false)
            return 1
        }
        m.showHumanStep(b)  // their yes
        var wpid: pid_t?
        for _ in 0..<40 where wpid == nil {
            try? await Task.sleep(for: .milliseconds(500))
            wpid = HumanCheck.active?.pid
        }
        check("a real Chrome window opened on the same profile", wpid != nil)
        check("One never shows its own picture of the hidden tab", HumanStep.windows[b.id]?.window == nil)
        let wport = port + 20000
        func win(_ expr: String) async -> Any? {
            guard let t = StepPageCopy.firstPage(port: wport) else { return nil }
            let p = StepPage(port: wport, target: t)
            p.connectQuiet()
            defer { p.disconnect() }
            let r = await p.call("Runtime.evaluate", ["expression": expr, "returnByValue": true])
            return (r["result"] as? [String: Any])?["value"]
        }
        var shown = ""
        for _ in 0..<30 where shown != "/approve" {
            try? await Task.sleep(for: .milliseconds(500))
            shown = await win("location.pathname + (document.getElementById('ok') ? '' : ' (no step)')") as? String ?? ""
        }
        check("the window shows the helper's very step, not a log-in page (\(shown))", shown == "/approve")
        check("with the step's own one-time state", await win("document.querySelector('input[name=invite]').value") as? String == invite)
        print("   the person ticks the box and taps Continue in the window")
        _ = await win("document.getElementById('ok').click(); document.getElementById('cont').click()")
        try? await Task.sleep(for: .seconds(2))
        m.answerHumanStep(b.id, "done")  // the card's Done
        var ans: [String: Any] = [:]
        for _ in 0..<60 where ans["relaunched"] == nil {
            try? await Task.sleep(for: .seconds(1))
            ans =
                (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("\(b.id).answer.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let back = ans["target_id"] as? String ?? ""
        let after = alive(back) ? (await tab(back, "location.pathname + location.search") as? String ?? "") : "gone"
        check("the hidden browser is back and the helper's tab is past the step (\(after))", after == "/welcome.html?who=approved")
        check("the site never saw its form-only pages opened again", (siteState()["gets_bounced"] as? Int) == 0)
        check("Done reached the engine", ans["answer"] as? String == "done")

        print("4. I'm not at the Mac")
        let fake = "check\(Int(Date().timeIntervalSince1970))"
        let preq: [String: Any] = [
            "id": fake, "created": Date().timeIntervalSince1970, "site": "example.com", "kind": "passkey", "port": 1, "target_id": "none",
            "url": "https://example.com/",
        ]
        try? JSONSerialization.data(withJSONObject: preq).write(to: HumanStep.dir.appendingPathComponent("\(fake).request.json"))
        m.tendHumanSteps()
        check("a passkey step reads right", m.humanSteps.first { $0.id == fake }?.line.contains("example.com is asking for your passkey") == true)
        m.answerHumanStep(fake, "away")
        let away = (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("\(fake).answer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("I'm not at the Mac reaches the engine", away?["answer"] as? String == "away" && !m.humanSteps.contains { $0.id == fake })
        fails += await codeWaysOut(m)
        print(fails == 0 ? "PASS human step (One's half)" : "FAIL human step (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
