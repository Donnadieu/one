import AppKit
import SwiftUI

/// `One --test-helpers-stress queue` (the last part of tools/helpers-check.sh, `make helpers-check`, in preflight).
/// Omar's rule: everything the assistant says goes through one first-in, first-out line (SayQueue.swift). This starts a
/// long streaming reply that is also read aloud (a stand-in voice that makes each sentence slower than it plays, so
/// there is a gap between sentences, the gap that used to let a notice in), then while it streams: three helpers
/// finish (one also finishes "again" three times, one changes from done to needs your yes while its notice waits)
/// and the person sends a message. Proven: the reply finishes whole, on screen and out loud (no sentence dropped);
/// the three notices follow one at a time, in order, each only after the one before was fully spoken; the message
/// goes after them, as the next turn, never into the running one; no notice twice, and the waiting one says the
/// newest state. ONE_QUEUE_SHOT=<png> saves a picture of the chat at the end.
extension HelperStress {
    struct MainEvent: Decodable {
        let ev: String
        let t: Double
        let kind: String?
        let title: String?
    }

    @MainActor
    static func queueCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        m.shelf = []
        m.followUps = []
        // The voice: a stand-in that takes 0.35 s to make each part and 0.2 s to "play" it.
        let sp = Speaker.shared
        Speaker.prefs.set(false, forKey: "voiceMuted")
        UserDefaults.standard.set(false, forKey: "voiceMuted")
        sp.stand = { _ in
            Thread.sleep(forTimeInterval: 0.35)
            return nil
        }
        sp.standSecs = 0.2
        let base = sp.reached
        let t0 = Date()
        func at() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        // What was being said, 20 times a second: (time, a reply's voice or words still pending).
        var said: [(Double, Bool)] = []
        var sampling = true
        Task { @MainActor in
            while sampling {
                said.append((Date().timeIntervalSince1970, m.voicePlaying))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        func mains() -> [MainEvent] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(MainEvent.self, from: Data($0.utf8)) }
                .filter { $0.ev.hasPrefix("main-") || $0.ev == "steer" }
        }

        // ONE_QUEUE_SHOT: the home screen, live, pictured the moment the third notice is on screen (the message still Next up).
        let shot = ProcessInfo.processInfo.environment["ONE_QUEUE_SHOT"].flatMap { $0.isEmpty ? nil : $0 }
        if shot != nil {
            m.assistantName = "Elias"
            sp.standSecs = 1.2  // each part plays longer than it takes to make: a notice's words show while it's still said
        }
        let live = shot == nil ? nil : liveWindow(m)
        if live != nil {
            Task { @MainActor in  // the chat itself, not the While you were gone card (the test copy is never in front)
                while sampling {
                    if m.helpers.contains(where: \.finishedAway) { m.clearAway() }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        var shotTaken = false
        if let host = live, let shot {
            Task { @MainActor in
                while sampling && !shotTaken {
                    if m.bubbles.contains(where: { $0.text.hasPrefix("By the way, Q3") }) {
                        try? await Task.sleep(for: .milliseconds(400))  // its words faded in; it's still being said
                        shoot(host, to: shot)
                        print(
                            "   on screen then: \(m.bubbles.map { ($0.fromMe ? "Omar: " : "") + $0.text.prefix(30) }), next up: \(m.followUps.map(\.display))"
                        )
                        shotTaken = true
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }
        print("7. a long reply read aloud; three helpers finish and a message is sent while it streams")
        Task { await m.send("STRESSLONG n=10 secs=5") }
        _ = await wait(15) { m.turnStarted }
        print("   [\(at())] the reply is streaming")
        for (t, s) in [("Q1", "0.4"), ("Q2", "0.6"), ("Q3", "0.8")] { m.spawnHelper(title: t, task: "STRESSJOB \(t) secs=\(s)") }
        func h(_ t: String) -> Helper? { m.helpers.first { $0.title == t } }
        _ = await wait(10) { ["Q1", "Q2", "Q3"].allSatisfy { h($0)?.state == "done" } }
        print("   [\(at())] Q1, Q2, Q3 finished")
        check("all three finished while the reply was still streaming", m.thinking && ["Q1", "Q2", "Q3"].allSatisfy { h($0)?.state == "done" })
        // Q1 ends the same way three more times (picked back up, carried on after a check): still one notice.
        if let q1 = h("Q1")?.id { for _ in 0..<3 { m.queueDoneNote(q1) } }
        // Q2 changes to "needs your yes" while its notice waits: the notice says the newest state, once.
        if let q2 = h("Q2")?.id {
            m.update(q2) {
                $0.state = "needsYes"
                $0.line = "Needs your yes"
            }
            m.queueDoneNote(q2)
        }
        let before = mains().filter { $0.ev == "main-start" }.count
        await m.send("QUEUEMSG PLUM")
        check("the message waits Next up, shown at once", m.followUps.map(\.state) == [.next] && m.followUps.first?.display == "QUEUEMSG PLUM")
        check(
            "the line holds 3 notices, then the message",
            m.outbox == m.helpers.filter { $0.title.hasPrefix("Q") }.map { .helperNews($0.id) } + [.message(m.followUps.first?.id ?? UUID())])
        try? await Task.sleep(for: .milliseconds(300))
        check("nothing new went to the engine during the reply", mains().filter { $0.ev == "main-start" }.count == before && m.thinking)

        let done = await wait(60) { mains().filter { $0.ev == "main-end" }.count >= 5 && m.outbox.isEmpty && !m.outboxRunning && m.sayFree }
        try? await Task.sleep(for: .milliseconds(400))
        print("   [\(at())] everything said")
        check("it all went through within a minute", done)

        // Q1 finishing the same way again later: no second notice.
        if let q1 = h("Q1")?.id { m.queueDoneNote(q1) }
        try? await Task.sleep(for: .seconds(2))
        sampling = false

        let ev = mains()
        let starts = ev.filter { $0.ev == "main-start" }
        let ends = ev.filter { $0.ev == "main-end" }
        let order = starts.map { [$0.kind ?? "", $0.title ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }
        print("   the engine got, in order: \(order)")
        check(
            "in order: the reply, Q1 done, Q2 needs your yes, Q3 done, then the message",
            order == ["long", "note Q1 done", "note Q2 needsYes", "note Q3 done", "msg PLUM"])
        check("no message went into the running turn (no mid-turn steer)", !ev.contains { $0.ev == "steer" })
        var overlap = false
        var spokenOver = false
        for k in 1..<max(1, starts.count) where k < starts.count {
            if k - 1 < ends.count, starts[k].t < ends[k - 1].t { overlap = true }
            // Right after this turn began (before it could have any words of its own to say): was the one before still
            // being said? (Sampling slips under load, so a sample just before the start proves nothing either way.)
            if said.contains(where: { $0.0 > starts[k].t && $0.0 <= starts[k].t + 0.25 && $0.1 }) { spokenOver = true }
        }
        check("never two turns at once (each began after the one before ended)", !overlap && starts.count == ends.count)
        check("each began only after the one before was fully spoken", !spokenOver)

        let others = m.bubbles.filter { !$0.fromMe }.map(\.text)
        let long = others.first ?? ""
        check(
            "the reply is whole in the chat (all 10 sentences and its last words)",
            (1...10).allSatisfy { long.contains(String(format: "Sentence %02d", $0)) } && long.contains("END-OF-LONG-REPLY"))
        let parts = others.map { Speaker.spoken($0).count }.reduce(0, +)
        check("every part of every reply was spoken, none cut (\(sp.reached - base) of \(parts))", sp.reached - base == parts && parts > 10)
        let shown = m.bubbles.map { ($0.fromMe ? "Omar: " : "") + $0.text.prefix(48) }
        print("   the chat: \(shown)")
        check(
            "the chat reads: ask, whole reply, Q1, Q2, Q3, the message, its answer",
            m.bubbles.count == 7 && m.bubbles[0].fromMe && others.count == 5
                && others[1] == "By the way, Q1 is done. Tap it to take a look."
                && others[2] == "By the way, Q2 needs your yes. Tap it to take a look."
                && others[3] == "By the way, Q3 is done. Tap it to take a look."
                && m.bubbles[5].fromMe && m.bubbles[5].text == "QUEUEMSG PLUM" && others[4] == "Got PLUM.")
        let notices = others.filter { $0.hasPrefix("By the way") }
        check("no notice twice (3 notices for 3 helpers)", notices.count == 3 && Set(notices).count == 3)
        check("nothing left waiting", m.followUps.isEmpty && m.outbox.isEmpty)

        if let host = live, let shot { shoot(host, to: shot.replacingOccurrences(of: ".png", with: " (end).png")) }
        sp.stand = nil
        sp.standSecs = 0
        print(fails == 0 ? "queue ok" : "queue FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    /// The real home screen with this chat, live in an off-screen window (a live window draws the scrolling chat,
    /// which a still render leaves blank). `shoot` saves what it shows right now.
    @MainActor
    static func liveWindow(_ m: Model) -> NSHostingView<AnyView> {
        HomeView.still = true
        let size = CGSize(width: 1180, height: 1340)
        let view = VStack(spacing: 0) {
            HStack(spacing: 16) {
                NamePill(name: m.name) {}
                Spacer()
                TopBarButtons(name: m.name, voiceOff: false, paused: false)
            }
            .padding(.leading, 18).padding(.trailing, 16).frame(height: 52)
            HomeView(m: m).frame(height: size.height - 52, alignment: .top).clipped()
        }
        .frame(width: size.width, height: size.height)
        .background(HomeBackdrop(outer: true))
        .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark)
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view))
        w.contentView = host
        w.orderFront(nil)
        return host
    }
    @MainActor
    static func shoot(_ host: NSHostingView<AnyView>, to path: String) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("   picture: \(path)")
    }
}
