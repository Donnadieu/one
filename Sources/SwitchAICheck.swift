import Foundation

/// No network or real model switch: the exact decisions that used to restart a working engine.
enum SwitchAICheck {
    /// `--test-switch-ai`: no engine, no network.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-switch-ai") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(run()) }
        return true
    }
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "✓" : "✗") \(name)")
            if !pass { failures += 1 }
        }
        var working = Helper(title: "Research", task: "finish", sid: "old", state: "working", line: "Working")
        working.resumes = 2
        check("a helper in progress stays on its original AI", !SwitchAI.ready([working], thinking: false))
        check("rollback uses the real old AI, not a stale screen choice", SwitchAI.currentProvider("model:\n  provider: openai-codex\n") == .chatgpt)
        check("the main answer also finishes first", !SwitchAI.ready([], thinking: true))
        working.state = "stopped"
        working.resumeQueued = true
        check("a helper picking back up also finishes first", !SwitchAI.ready([working], thinking: false))
        working.resumeQueued = false
        working.state = "done"
        check("the switch can start once the helper actually finishes", SwitchAI.ready([working], thinking: false))
        check("a failed answer cannot switch the displayed AI", !SwitchAI.answered(stop: "error: unavailable", reply: ""))
        check("a partial or wrong answer cannot switch the displayed AI", !SwitchAI.answered(stop: "end_turn", reply: "sorry"))
        check("a verified answer can switch the displayed AI", SwitchAI.answered(stop: "end_turn", reply: " ready \n"))
        let interrupted = HelperEnd.of(stop: "error: stopped", reply: "half a sentence")
        check("an interrupted helper is never marked done", interrupted == .cutOff)

        // The picker must show every provider (plus Local, which lives outside the enum): the 2-of-4
        // screenshot bug was the list being clipped, not Provider.allCases ever losing a case.
        check(
            "every provider is offered", Set(Provider.allCases.map(\.title)) == ["Claude", "ChatGPT", "Grok", "OpenRouter"])

        // A stuck wait must always carry a plain message to show with Cancel, never a blank screen.
        var busyHelper = Helper(title: "Research", task: "finish", sid: "old", state: "working", line: "Working")
        check(
            "the wait names the waiting helper",
            SwitchAI.waitMessage(for: "Grok", helpers: [busyHelper], thinking: false)?.contains("1 helper") == true)
        busyHelper.state = "done"
        check("no wait message once helpers are free", SwitchAI.waitMessage(for: "Grok", helpers: [busyHelper], thinking: false) == nil)
        check("no wait message while idle", SwitchAI.waitMessage(for: "Grok", helpers: [], thinking: false) == nil)
        check(
            "a wait while the main answer is still going also has a message",
            SwitchAI.waitMessage(for: "Grok", helpers: [], thinking: true)?.contains("current answer") == true)

        // The picker's title must never duplicate: opening Switch AI shows a fixed title in the panel
        // itself and must never append to the persisted chat bubbles (that's what let a stuck attempt's
        // leftover bubble sit next to a fresh one with the same words).
        TestWorld.enter()
        let m = Model.shared
        let before = m.bubbles.count
        m.switchingAI = true
        check("opening Switch AI never adds a chat bubble", m.bubbles.count == before)
        m.switchingAI = false

        return failures == 0 ? 0 : 1
    }
}
