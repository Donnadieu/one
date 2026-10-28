import AppKit
import Foundation

/// `One --test-helper-stop` (tools/helper-stop-check.sh, `make helperstop`): real helpers with One's real engine in the
/// throwaway home, driven through `Model` like the UI. A long helper is stopped with its Stop button and another
/// by asking the assistant (its [stop-helper: …] line): each turn ends, the other helpers and the assistant carry on,
/// both stay stopped when the saved helpers are read back the way launch reads them, and "Start again" sends the job
/// out again. Then `--test-update-helpers` (two runs of the same copy, before and after a real update swap): an update
/// with a helper at work goes ahead without waiting for it, and the helper picks back up by itself after the restart,
/// never marked "Stopped by you". Must run from a copy with its own bundle id (the script does that).
enum HelperStopCheck {
    nonisolated(unsafe) static var fails = 0
    static func check(_ name: String, _ ok: Bool) {
        print("  \(ok ? "✓" : "✗") \(name)")
        fflush(stdout)
        if !ok { fails += 1 }
    }
    @MainActor
    static func wait(_ s: Double, until: () -> Bool) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(200)) }
    }
    static func job(_ secs: Int, _ token: String) -> String {
        "Use the terminal tool to run exactly `sleep \(secs)`, then reply with only: \(token). Use no other tool and don't ask anything."
    }

    /// The throwaway engine home, like the other real-engine checks. `fresh` wipes the brain (not the saved helpers).
    @MainActor
    static func setUp(fresh: Bool) async -> Bool {
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/helper-stop-check.sh (a copy with its own settings, throwaway home)")
            return false
        }
        _ = NSApplication.shared  // helpers ask whether One is in front
        let fm = FileManager.default
        let dst = Env.hermesHome.appendingPathComponent("auth.json")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: TestWorld.realSupport.appendingPathComponent("hermes/auth.json"), to: dst)
        let tools = Env.hermesHome.appendingPathComponent("tools")
        if (try? fm.destinationOfSymbolicLink(atPath: tools.path)) == nil {
            try? fm.removeItem(at: tools)
            try? fm.createSymbolicLink(at: tools, withDestinationURL: TestWorld.realSupport.appendingPathComponent("hermes/tools"))
        }
        await SignIn.makeDefault(.claude, model: Provider.claude.tiers[1].1)
        _ = await hermesRun(["config", "set", "auth.adopt_external_logins", "false"])
        if fresh {
            try? fm.removeItem(at: Brain.root)
            _ = Brain.build(owner: "Omar", ai: "Ava", rooms: [])
        }
        Access.override = []
        Persona.write(assistant: "Ava", user: "Omar", connections: [], passwords: "ask each time")
        Engine.shared.onPermission = { _, opts, ans in ans(opts.first { $0.0.hasPrefix("allow") }?.0) }
        if let e = await Engine.shared.start() {
            print("FAIL engine didn't start: \(e)")
            return false
        }
        Model.shared.assistantName = "Ava"
        Model.shared.userName = "Omar"
        return true
    }

    @MainActor
    static func run() async -> Int32 {
        guard await setUp(fresh: true) else { return 2 }
        let m = Model.shared
        m.bubbles = []
        m.helpers = []
        m.shelf = []
        let t0 = Date()
        func at() -> String { String(format: "%.0fs", Date().timeIntervalSince(t0)) }
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        func started(_ title: String) -> Bool { !(h(title)?.trail ?? []).isEmpty }

        print("1. Stop button: a long helper is stopped while another works")
        m.spawnHelper(title: "Long wait", task: job(240, "LONG DONE 1"))
        m.spawnHelper(title: "Short job", task: job(25, "SHORT DONE 4417"))
        await wait(120) { started("Long wait") }
        check("the long helper is at work", h("Long wait")?.state == "working" && started("Long wait"))
        guard let long = h("Long wait") else { return 1 }
        let stopAt = Date()
        m.stopHelper(long.id)
        await wait(30) { (m.helperTurnEnded[long.id] ?? .distantPast) > stopAt }
        let took = (m.helperTurnEnded[long.id] ?? .distantFuture).timeIntervalSince(stopAt)
        print("   [\(at())] its turn ended \(String(format: "%.1f", took)) s after Stop")
        check("its engine turn ended (cancelled) within 30 s", took < 30)
        let stopped = h("Long wait")
        check("it shows stopped by you", stopped?.state == "stopped" && stopped?.stoppedByYou == true && stopped?.line == HelperTrail.stoppedLine)
        check("its trail says Stopped by you", stopped?.trail?.last == "Stopped by you")
        check("it never said it was done", stopped?.reply.contains("LONG DONE") != true)
        await wait(120) { h("Short job")?.state != "working" }
        check("the other helper carried on and finished", h("Short job")?.state == "done" && h("Short job")?.reply.contains("4417") == true)

        print("2. Stop by asking: the assistant's [stop-helper: …] line")
        m.spawnHelper(title: "Price check", task: job(240, "PRICE DONE 2"))
        m.spawnHelper(title: "Keep going", task: job(40, "KEEP DONE 8812"))
        await wait(120) { started("Price check") && started("Keep going") }
        check("both helpers are at work", h("Price check")?.state == "working" && h("Keep going")?.state == "working")
        guard let price = h("Price check") else { return 1 }
        let askAt = Date()
        await m.send("Stop the Price check helper.")
        await wait(60) { !m.thinking }
        let reply = m.bubbles.last { !$0.fromMe }?.text ?? ""
        print("   [\(at())] reply: \(reply.replacingOccurrences(of: "\n", with: " "))")
        check("the reply doesn't show the stop line", !reply.lowercased().contains("[stop-helper"))
        check("it confirms it stopped it", reply.contains("Stopped") && !reply.contains("couldn't find"))
        let p = h("Price check")
        check("Price check is stopped by you", p?.state == "stopped" && p?.stoppedByYou == true)
        await wait(30) { (m.helperTurnEnded[price.id] ?? .distantPast) > askAt }
        check("its engine turn ended", (m.helperTurnEnded[price.id] ?? .distantPast) > askAt)
        check(
            "the helper it wasn't asked about is still at work or done", h("Keep going")?.stoppedByYou != true && h("Keep going")?.state != "stopped")
        await wait(120) { h("Keep going")?.state != "working" }
        check("and finished its job", h("Keep going")?.state == "done" && h("Keep going")?.reply.contains("8812") == true)
        await m.send("Reply with only: PING 3141")
        await wait(60) { !m.thinking }
        check("the assistant still answers", m.bubbles.last { !$0.fromMe }?.text.contains("3141") == true)

        print("3. After a restart: both stay stopped")
        let back = Model.savedHelpers()  // the saved helpers, read back the way launch reads them
        for title in ["Long wait", "Price check"] {
            let b = back.last { $0.title == title }
            check("\(title) is still stopped, not picked back up", b?.state == "stopped" && b?.resumeQueued != true && b?.stoppedByYou == true)
        }
        var again = back
        check("nothing is picked back up at launch", HelperTrail.pick(&again, brief: { $0 }).isEmpty)

        print("4. Start again")
        let before = m.helpers.count
        m.startAgain(price.id)
        let fresh = h("Price check")
        check("the same orb went back to work on its original job", fresh?.id == price.id && fresh?.task == price.task && fresh?.state == "working")
        check("no orb went away and none was added", m.helpers.count == before)
        await wait(90) { started("Price check") }
        check("the new one is at work", started("Price check"))
        if let f = fresh { m.stopHelper(f.id) }
        try? await Task.sleep(for: .seconds(3))
        Engine.shared.stop()
        print(fails == 0 ? "helper-stop ok" : "helper-stop FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    /// First run: a helper at work, a reply in progress, then a real update (download, swap, quit).
    /// Second run (`--after`, the updated copy): the helper picks back up by itself and finishes.
    @MainActor
    static func update(after: Bool) async -> Int32 {
        guard await setUp(fresh: !after) else { return 2 }
        let m = Model.shared
        let token = "RESUMED DONE 5521"
        if !after {
            m.bubbles = []
            m.helpers = []
            print("1. an update with a helper at work (version \(Updater.shared.current))")
            m.spawnHelper(title: "Long wait", task: job(50, token))
            await wait(120) { !(m.helpers.first?.trail ?? []).isEmpty }
            check("the helper is at work", m.helpers.first?.state == "working")
            Task { await m.send("Reply with only: OK 77") }
            await wait(20) { m.thinking }
            guard let zip = ProcessInfo.processInfo.environment["ONE_TEST_UPDATE_ZIP"].flatMap(URL.init(string:)) else {
                print("FAIL no ONE_TEST_UPDATE_ZIP")
                return 1
            }
            Updater.shared.available = ("9.9.9", "test", zip)
            let t = Date()
            Task {
                while true {
                    print(
                        "   [\(String(format: "%.0f", Date().timeIntervalSince(t)))s] \(Updater.shared.state ?? "") · thinking \(m.thinking) · helper \(m.helpers.first?.state ?? "?")"
                    )
                    fflush(stdout)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            await Updater.shared.install()  // quits One when it works
            print("FAIL the update didn't restart: \(Updater.shared.state ?? "")")
            return 1
        }
        print("2. after the update (version \(Updater.shared.current))")
        check("this is the updated copy", Updater.shared.current == "9.9.9")
        let first = m.helpers.first
        print("   saved helper: \(first?.state ?? "none") · \(first?.line ?? "")")
        check("the helper was paused, queued to pick back up", first?.state == "stopped" && first?.resumeQueued == true)
        check("it was at work when the update came (paused, not finished)", first?.trail?.contains("Paused for an update") == true)
        check("it's not marked Stopped by you", first?.stoppedByYou != true && first?.line != HelperTrail.stoppedLine)
        m.resumeInterrupted()
        check("it picked back up by itself", m.helpers.first?.state == "working")
        check("the person is told it was paused for the update", m.bubbles.last?.text == HelperTrail.toldUpdate("Long wait"))
        await wait(200) { m.helpers.first?.state != "working" }
        let done = m.helpers.first
        print("   finished: \(done?.state ?? "?") · \(done?.reply.prefix(80) ?? "")")
        check("it finished its job", done?.state == "done" && done?.reply.contains(token) == true)
        check("never stopped by you", done?.stoppedByYou != true)
        Engine.shared.stop()
        print(fails == 0 ? "update-helpers ok" : "update-helpers FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
