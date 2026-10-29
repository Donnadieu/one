import Foundation

/// No network or real model switch: the exact decisions that used to restart a working engine.
enum SwitchAICheck {
    /// `--test-switch-ai`: no engine, no network.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-switch-ai") else { return false }
        TestWorld.enter()
        exit(run())
    }
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

        return failures == 0 ? 0 : 1
    }
}
