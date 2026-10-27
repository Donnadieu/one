import AppKit

/// `One --test-human-step` (tools/handoff-check.sh): plays the person for a step only a person can do.
/// The engine half (tests/handoff/e2e_engine.py) runs browser_vault enter_code on a local test page with a
/// code box in a throwaway Chrome; after 2 failed tries it asks One for the person. This checks One's half:
/// the line in the chat word for word, the window in front showing that same tab, clicks and typing
/// (with a Backspace) landing on the real page, Done reaching the engine, and the window closing.
/// Never touches the shared hidden browser: the port comes from ONE_HANDOFF_CDP (a test Chrome).
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
        guard Env.selfTest, env["ONE_SUPPORT_DIR"] != nil, let cdp = env["ONE_HANDOFF_CDP"], !cdp.hasSuffix(":9223") else {
            print("refusing: run tools/handoff-check.sh (throwaway folder, a test Chrome, never port 9223)")
            return 2
        }
        let m = Model.shared
        print("1. waiting for the engine to ask for the person")
        let end = Date().addingTimeInterval(120)
        while Date() < end, m.humanSteps.isEmpty {
            m.tendHumanSteps()
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let a = m.humanSteps.first, let w = HumanStep.windows[a.id] else {
            check("the engine asked for the person", false)
            return 1
        }
        check("the chat line, word for word", a.line == HumanStep.line(site: "127.0.0.1", kind: "code"))
        print("   line: \(a.line)")
        check(
            "says what was asked for",
            a.line == "I need you for one step: 127.0.0.1 is asking for a code. A Chrome window is open on it. Enter it there, then tap Done.")
        check("the window is open and in front", w.window?.isVisible == true && w.window?.level == .floating)
        let fe = Date().addingTimeInterval(15)
        while Date() < fe, w.page.frames == 0 { try? await Task.sleep(for: .milliseconds(200)) }
        check("it shows the page live (pictures arriving)", w.page.frames > 0)
        try? await Task.sleep(for: .milliseconds(600))

        func rect(_ id: String) async -> CGRect? {
            let r = await w.page.call(
                "Runtime.evaluate",
                [
                    "expression":
                        "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()",
                    "returnByValue": true,
                ])
            guard let v = (r["result"] as? [String: Any])?["value"] as? [Double], v.count == 4 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        func value() async -> String {
            let r = await w.page.call(
                "Runtime.evaluate",
                ["expression": "document.getElementById('x7') ? document.getElementById('x7').value : location.pathname", "returnByValue": true])
            return (r["result"] as? [String: Any])?["value"] as? String ?? ""
        }
        func click(_ p: CGPoint) {
            let c = w.page.canvas
            let s = w.page.pageSize
            let r = c.shown
            let v = CGPoint(x: p.x * r.width / s.width + r.minX, y: p.y * r.height / s.height + r.minY)
            let at = c.convert(v, to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let e = NSEvent.mouseEvent(
                        with: t, location: at, modifierFlags: [], timestamp: 0, windowNumber: w.window?.windowNumber ?? 0, context: nil,
                        eventNumber: 0,
                        clickCount: 1, pressure: 1)
                else { continue }
                if t == .leftMouseDown { c.mouseDown(with: e) } else { c.mouseUp(with: e) }
            }
        }
        func key(_ chars: String, _ code: UInt16) {
            guard
                let e = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.window?.windowNumber ?? 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { return }
            w.page.canvas.keyDown(with: e)
        }

        print("2. the person clicks the code box and types the code (one typo, fixed with Backspace)")
        guard let box = await rect("x7"), let go = await rect("go") else {
            check("the code box is on the page shown", false)
            return 1
        }
        click(CGPoint(x: box.midX, y: box.midY))
        try? await Task.sleep(for: .milliseconds(300))
        let codes: [Character: UInt16] = ["4": 21, "2": 19, "9": 25]
        for ch in "42429" { key(String(ch), codes[ch] ?? 0) }
        key("\u{7f}", 51)  // Backspace
        for ch in "42" { key(String(ch), codes[ch] ?? 0) }
        try? await Task.sleep(for: .milliseconds(500))
        let typed = await value()
        check("what they typed landed on the real page (\(typed))", typed == "424242")
        click(CGPoint(x: go.midX, y: go.midY))
        try? await Task.sleep(for: .milliseconds(700))
        print("3. the person taps Done")
        m.answerHumanStep(a.id, "done")
        let ans = (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("\(a.id).answer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("Done reached the engine", ans?["answer"] as? String == "done")
        check("the line left the chat and the window closed", m.humanSteps.isEmpty && HumanStep.windows[a.id] == nil && w.window == nil)

        print("4. I'm not at the Mac")
        let fake = "check\(Int(Date().timeIntervalSince1970))"
        let req: [String: Any] = [
            "id": fake, "created": Date().timeIntervalSince1970, "site": "example.com", "kind": "passkey", "port": 1, "target_id": "none",
            "url": "https://example.com/",
        ]
        try? JSONSerialization.data(withJSONObject: req).write(to: HumanStep.dir.appendingPathComponent("\(fake).request.json"))
        m.tendHumanSteps()
        check("a passkey step reads right", m.humanSteps.first?.line.contains("example.com is asking for your passkey") == true)
        m.answerHumanStep(fake, "away")
        let away = (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("\(fake).answer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("I'm not at the Mac reaches the engine", away?["answer"] as? String == "away" && m.humanSteps.isEmpty)
        print(fails == 0 ? "PASS human step (One's half)" : "FAIL human step (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
