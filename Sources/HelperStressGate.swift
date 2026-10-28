import Foundation

// MARK: - `make helpers-check`, part 4b: getting ready after One was killed (StartupGate.swift)
// While One opens again with helpers to pick back up: it says it's getting ready with the real count, the helpers being
// picked back up can't be opened or messaged, talking waits, and what's sent meanwhile (to the assistant and to a
// sleeping helper) waits next up. Then the helpers wake one by one, One opens only when the last is back, and every
// message held meanwhile reaches the engine: nothing lost, nothing sent to a helper that wasn't back.

extension HelperStress {
    @MainActor
    static func gateHolds(_ m: Model, queued: [Helper]) async {
        print("4b. getting ready: \(queued.count) helpers to pick back up")
        let c0 = m.gateCounts
        check("One shows it's getting ready (\(m.gate == .gettingReady ? "getting ready" : "\(m.gate)"))", m.gate == .gettingReady)
        check("with the real count: picking up \(c0.total), \(c0.back) back", c0.total == queued.count && c0.back == 0)
        check("every helper being picked back up is asleep (starting again)", queued.allSatisfy { m.asleep($0) })
        guard let target = queued.first else { return }
        m.focusHelper(target.id)
        check("a sleeping helper can't be opened", m.openHelper == nil)
        let before = events().count
        await m.send("STRESSHOLD main")
        check(
            "a message to the assistant waits next up, no turn starts",
            m.followUps.contains { $0.helper == nil && $0.c.typed == "STRESSHOLD main" } && !m.thinking)
        m.openHelper = target.id  // as if it was open when the restart began
        await m.send("STRESSHOLD helper")
        m.openHelper = nil
        check("a message to a sleeping helper waits next up", m.followUps.contains { $0.helper == target.id && $0.c.typed == "STRESSHOLD helper" })
        m.talkBegin()
        check("push to talk waits too, and says so", !m.talkingInApp && m.talkNote == GateWords.talk)
        m.talkNote = nil
        try? await Task.sleep(for: .seconds(1))
        let early = events().dropFirst(before)
        check("nothing reached the engine while getting ready", !early.contains { $0.ev == "start" || $0.ev == "main" || $0.ev == "steer" })

        print("4c. the helpers wake one by one; One opens when the last one is back")
        m.resumeInterrupted()
        var backs: [Int] = []
        var openEarly = false
        var tappedAsleep = false
        let opened = await wait(30) {
            let c = m.gateCounts
            if !m.isReady, backs.last != c.back { backs.append(c.back) }
            if m.isReady && !m.waking.isEmpty { openEarly = true }
            if let w = m.waking.first, !tappedAsleep {
                m.focusHelper(w)
                tappedAsleep = true
                if m.openHelper != nil {
                    check("a helper still waking can't be opened", false)
                    m.openHelper = nil
                }
            }
            return m.isReady
        }
        print("   back counts seen while waking: \(backs.prefix(12).map(String.init).joined(separator: " "))\(backs.count > 12 ? " …" : "")")
        check("One opened once every helper was back", opened && m.waking.isEmpty)
        check("never before the last one was back", !openEarly)
        check("they woke one by one (\(backs.count) steps)", backs.count >= 3 && backs == backs.sorted())
        let sid = m.helpers.first { $0.id == target.id }?.sid ?? "?"
        let delivered = await wait(20) {
            let evs = events().dropFirst(before)
            let main = evs.contains { $0.ev == "main" && ($0.text ?? "").contains("STRESSHOLD main") }
            let helper = evs.contains { ($0.ev == "steer" || $0.ev == "main") && $0.sid == sid && ($0.text ?? "").contains("STRESSHOLD helper") }
            return main && helper
        }
        check("both held messages reached the engine once One opened, the helper's only once it was back", delivered)
        _ = await wait(15) { !m.thinking }
        check("and none is still waiting", !m.followUps.contains { $0.c.typed.hasPrefix("STRESSHOLD") && $0.state == .next })
    }

    /// Getting ready never hangs: a failed start and an engine that doesn't come back show the plain line with Try
    /// again, and Try again gets One ready.
    @MainActor
    static func neverStuck(_ m: Model) async {
        print("9. getting ready never hangs")
        let keep = GateTiming.stuckAfter
        GateTiming.stuckAfter = 2
        defer { GateTiming.stuckAfter = keep }
        m.closeGate()
        m.enginePhase(.failed("test"))
        check("a failed start shows the plain line with Try again", m.gate == .stuck(GateWords.failed))
        m.tryGettingReadyAgain()
        check("Try again: ready", await wait(10) { m.isReady })
        Engine.shared.stop()  // gone, and nothing starts it again
        m.closeGate()
        check("an engine that doesn't come back: the line shows, not a forever wait", await wait(6) { m.gate == .stuck(GateWords.slow) })
        m.tryGettingReadyAgain()
        check("Try again starts it and opens One", await wait(15) { m.isReady && Engine.shared.running })
    }
}
