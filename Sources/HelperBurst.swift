import Foundation

// MARK: - `tools/jobs-check.sh --helpers`: five helpers asked for at once, against the real engine
// Runs inside `One --test-jobs` (ONE_JOBS_ONLY=helpers), in its throwaway home. Five helpers go out at
// the same moment, each in its own conversation like the app's helpers, plus a question to the assistant
// while they work. All five must start right away (no waiting for a free slot), finish, and the
// assistant must still answer.

/// When each helper (or the assistant) was sent, took its first step, and finished.
final class Stamps: @unchecked Sendable {
    private let l = NSLock()
    private var sent: [String: Date] = [:]
    private var began: [String: Date] = [:]
    private var ended: [String: Date] = [:]
    private var replies: [String: String] = [:]
    let t0 = Date()
    func at(_ d: Date) -> String { String(format: "%.0fs", d.timeIntervalSince(t0)) }
    func send(_ k: String) {
        l.lock()
        sent[k] = Date()
        l.unlock()
        JobsCheck.say("INFO \(k): sent at \(at(Date()))")
    }
    func begin(_ k: String) {
        l.lock()
        let first = began[k] == nil
        if first { began[k] = Date() }
        l.unlock()
        if first { JobsCheck.say("INFO \(k): first step at \(at(Date()))") }
    }
    func end(_ k: String, _ reply: String) {
        l.lock()
        ended[k] = Date()
        replies[k] = reply
        l.unlock()
        JobsCheck.say("INFO \(k): finished at \(at(Date())): \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))")
    }
    func get(_ k: String) -> (sent: Date?, began: Date?, ended: Date?, reply: String) {
        l.lock()
        defer { l.unlock() }
        return (sent[k], began[k], ended[k], replies[k] ?? "")
    }
}

enum HelperBurst {
    static let count = 5
    static let seconds = 20
    static func job(_ n: Int) -> String {
        "Use the terminal tool to run exactly `sleep \(seconds)`, then reply with only: DONE \(n). Use no other tool and don't ask anything."
    }

    /// One turn in its own conversation; it has started once its first step (the sleep) begins.
    static func runOne(_ key: String, _ prompt: String, _ s: Stamps) async {
        s.send(key)
        guard let sid = await Engine.shared.openSession() else {
            s.end(key, "couldn't open a session")
            return
        }
        let reply = Transcript()
        let ask: @Sendable () async -> String = {
            await Engine.shared.promptSession(sid, prompt, onText: { reply.add("", $0) }, onTool: { _ in s.begin(key) })
        }
        let limit = min(240, JobsCheck.deadline.timeIntervalSinceNow)
        let stop = await JobsCheck.within(limit, ask, onTimeout: { Engine.shared.cancel(session: sid) })
        s.end(key, reply.joined + " [\(stop)]")
    }

    static func run() async -> [String] {
        let s = Stamps()
        await withTaskGroup(of: Void.self) { g in
            for n in 1...count { g.addTask { await runOne("Helper \(n)", job(n), s) } }
            g.addTask {
                // The assistant, asked something while all five work.
                try? await Task.sleep(for: .seconds(6))
                await runOne("assistant", "Reply with only: OK", s)
            }
        }
        let rows = (1...count).map { s.get("Helper \($0)") }
        var out: [String] = []
        let started = rows.filter { $0.began != nil }
        let done = rows.enumerated().filter { n, r in r.reply.contains("DONE \(n + 1)") }
        out.append((done.count == count ? "PASS" : "FAIL") + " helpers: \(count) asked at once, \(started.count) started, \(done.count) finished")
        // Together: every first step began before any helper finished its wait.
        let firstEnd = rows.compactMap(\.ended).min() ?? .distantFuture
        let lastStart = started.compactMap(\.began).max() ?? .distantFuture
        let together = started.count == count && lastStart < firstEnd
        out.append(
            (together ? "PASS" : "FAIL")
                + " together: \(started.count) working at the same time (last started \(s.at(lastStart)), first finished \(s.at(firstEnd)))")
        let a = s.get("assistant")
        let took = a.sent.flatMap { x in a.ended.map { $0.timeIntervalSince(x) } } ?? -1
        out.append(
            (a.reply.contains("OK") && took >= 0 && took < Double(seconds) ? "PASS" : "FAIL")
                + String(format: " assistant: answered in %.0fs while the helpers worked", took))
        return out
    }
}
