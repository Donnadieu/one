import AppKit
import Foundation

/// `One --test-helper-stop --cut` (tools/helper-cut-check.sh, `make helpercut`): the Oct 28 morning, replayed with One's real
/// engine in the throwaway home. Two helpers are at work when the engine restarts under them (what the Folders window's
/// Done did). Neither may show "done" with half a sentence: each shows stopped and picking back up, is picked back up by
/// itself, and only shows done once it really answered with its token. Must run from a copy with its own bundle id.
enum HelperCutCheck {
    @MainActor
    static func run() async -> Int32 {
        HelperStopCheck.fails = 0
        let check = HelperStopCheck.check
        guard await HelperStopCheck.setUp(fresh: true) else { return 2 }
        let m = Model.shared
        m.bubbles = []
        m.helpers = []
        m.shelf = []
        let t0 = Date()
        func at() -> String { String(format: "%.0fs", Date().timeIntervalSince(t0)) }
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        var states: [String: Set<String>] = [:]
        var falseDone: [String] = []
        func watch() {
            for x in m.helpers {
                states[x.title, default: []].insert(x.state)
                if x.state == "done", !x.reply.contains(x.title == "Slow one" ? "SLOW DONE 5521" : "QUICK DONE 9034"),
                    !falseDone.contains(x.title)
                {
                    falseDone.append(x.title)
                    print("   [\(at())] \(x.title) shown done without its answer: \(x.reply.prefix(80))")
                }
            }
        }
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() {
                watch()
                try? await Task.sleep(for: .milliseconds(200))
            }
            watch()
        }

        print("1. Two helpers at work, then the engine restarts under them")
        m.spawnHelper(title: "Slow one", task: HelperStopCheck.job(70, "SLOW DONE 5521"))
        m.spawnHelper(title: "Quick one", task: HelperStopCheck.job(20, "QUICK DONE 9034"))
        await wait(120) { !(h("Slow one")?.trail ?? []).isEmpty && !(h("Quick one")?.trail ?? []).isEmpty }
        check("both are at work", h("Slow one")?.state == "working" && h("Quick one")?.state == "working")
        let restart = await Engine.shared.start()
        print("   [\(at())] engine restarted: \(restart ?? "ok")")
        await wait(10) { m.helpers.allSatisfy { $0.state != "working" } }
        for t in ["Slow one", "Quick one"] {
            let x = h(t)
            print("   [\(at())] \(t): \(x?.state ?? "-") · \(x?.line ?? "-")")
            check("\(t) is not shown done", x?.state != "done" && x?.waiting != true)
        }
        check("each says it's picking back up (or already did)", m.helpers.allSatisfy { $0.state == "working" || $0.resumeQueued == true })

        print("2. Picked back up by itself, done only with the real answer")
        await wait(420) { m.helpers.allSatisfy { $0.state == "done" || ($0.state == "stopped" && $0.resumeQueued != true) } }
        for t in ["Slow one", "Quick one"] {
            let x = h(t)
            print(
                "   [\(at())] \(t): \(x?.state ?? "-") · resumes \(x?.resumes ?? 0) · busy tries \(x?.busyTries ?? 0) · \(x?.reply.prefix(60) ?? "")")
            check("\(t) was picked back up", (x?.resumes ?? 0) >= 1)
            check("\(t) finished with its real answer", x?.state == "done" && x?.reply.contains(t == "Slow one" ? "5521" : "9034") == true)
        }
        check("nothing was ever shown done without its answer", falseDone.isEmpty)
        check("the person was told each was picked back up", m.bubbles.filter { $0.text.contains("I picked it back up") }.count >= 2)
        print(HelperStopCheck.fails == 0 ? "helper-cut ok" : "helper-cut FAILED (\(HelperStopCheck.fails))")
        return HelperStopCheck.fails == 0 ? 0 : 1
    }
}
