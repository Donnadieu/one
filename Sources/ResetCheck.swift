import Foundation

// MARK: - Check: `--reset` clears onboarding ONLY, never helpers/bubbles/shelf — `One --test-reset`

/// Regression test for the 0.9.74 incident: `helpers` (one finished helper, "Message history") went empty
/// right after an update + restart, with nothing in that release's Sources diff touching helpers persistence.
/// Root cause: `--reset` ("reset onboarding") called `UserDefaults.standard.removePersistentDomain`, which
/// drops EVERYTHING under the bundle id, not just onboarding. A `--reset` run against the real bundle id
/// (by hand, by a script, or by a helper doing fresh-install-style testing) during a release would silently
/// empty `helpers` along with it. Proves `Model.resetOnboarding()` clears only the onboarding keys and
/// leaves helpers, bubbles and the shelf exactly as they were.
@MainActor
enum ResetCheck {
    /// `--test-reset`: a copy with its own settings (never the real One; TestWorld.enter() refuses otherwise).
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-reset") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        check("runs as a command-line tool (never touches a real engine)", Env.commandLine)

        let d = UserDefaults.standard
        let m = Model.shared

        // Seed a finished helper ("Message history"-style: done, never cleared), plus bubbles and a shelf
        // card, exactly like a real conversation mid-update.
        m.onboarded = true
        m.assistantName = "Juno"
        m.userName = "Omar"
        m.interviewOffered = true
        let finished = Helper(title: "Message history", task: "Scroll back through the one conversation.", sid: "s-1", state: "done", line: "")
        m.helpers = [finished]
        m.bubbles = [Bubble(fromMe: true, text: "Hi"), Bubble(fromMe: false, text: "Hi, Omar.")]
        m.saveBubbles()
        d.set(["{\"id\":\"a\"}"], forKey: "shelf")

        Model.resetOnboarding()

        check("onboarding is cleared (welcome flow runs again)", !d.bool(forKey: "onboarded"))
        check("assistant name is cleared", d.string(forKey: "assistantName") == nil || d.string(forKey: "assistantName") == "")
        check("the interview flag is cleared", !d.bool(forKey: "interviewOffered"))

        let savedHelpers = Model.savedHelpers()
        check("the finished helper survives --reset", savedHelpers.contains { $0.title == "Message history" && $0.state == "done" })
        let savedBubbles = Model.savedBubbles()
        check("chat bubbles survive --reset", savedBubbles.count == 2)
        check("the shelf survives --reset", (d.stringArray(forKey: "shelf") ?? []).count == 1)

        d.removeObject(forKey: "helpers")
        d.removeObject(forKey: "bubbles")
        d.removeObject(forKey: "shelf")
        m.helpers = []
        m.bubbles = []
        print(fails == 0 ? "reset: all checks passed" : "reset: \(fails) check(s) failed")
        return fails == 0 ? 0 : 1
    }
}
