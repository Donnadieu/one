import Foundation

/// `One --test-listener` (preflight, CI only; no microphone needed): push to talk's own rules (TalkState.swift).
/// Omar, Nov 17 2026: "Sometimes it says 'Didn't catch that', or it's red and it's not even sending stuff."
/// The press that went wrong, replayed: he lets go, presses again within 1.6 s, and the first press's late final
/// (or its cancel) arrives during the second. Before 0.9.128 that marked the second press finished before he spoke
/// and its words were lost. Also: what letting go does when nothing came back.
enum ListenerCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-listener") else { return false }
        TestWorld.enter()  // scratch One folder, own settings; CI only
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }

        // 1. A second press while the first one is still finishing.
        var s = TalkState()
        let first = s.start()
        s.heard(first, "Another thing that I", final: false)
        let second = s.start()  // pressed again, 1 s after letting go
        check("a new press starts empty", s.text.isEmpty && !s.gotFinal)
        check("the first press's late final is dropped", !s.heard(first, "Another thing that I think", final: true))
        check("so the second press isn't marked finished before he speaks", !s.gotFinal && s.text.isEmpty)
        check("the first press's cancel (reported as final, no words) is dropped too", !s.heard(first, nil, final: true) && !s.gotFinal)
        s.heard(second, "needs to improve in One", final: false)
        s.level(first, 0.9)
        check("the second press keeps its own words", s.text == "needs to improve in One")
        check("and its own loudness (an old press's level never counts)", s.peak == 0)
        s.level(second, 0.5)
        s.heard(second, "needs to improve in One is our speech-to-text", final: true)
        check("its own final ends it with its own words", s.gotFinal && s.text.hasSuffix("speech-to-text"))

        // 2. What letting go does.
        check("words came back: send them", TalkOutcome.after(text: " hello ", peak: 0.6, onDevice: true) == .send("hello"))
        check("nothing came back but the mic heard speech: try Apple's server", TalkOutcome.after(text: "", peak: 0.6, onDevice: true) == .tryServer)
        check(
            "already on the server: say it heard him but couldn't make out words", TalkOutcome.after(text: "", peak: 0.6, onDevice: false) == .unclear
        )
        check("a quiet press: nothing heard", TalkOutcome.after(text: "  ", peak: 0.05, onDevice: true) == .nothing)
        check("what he said never goes in the log", !TalkOutcome.send("my secret words").logLine.contains("secret"))

        print(fails == 0 ? "listener ok" : "listener failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
