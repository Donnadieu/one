import AppKit
import SwiftUI

// MARK: - Getting ready (Claude Design "Startup Options", option A, picked by Omar on Oct 28)
//
// While One is getting ready (opening after an update, a quit, a crash or a wake from sleep, or any engine restart
// mid-session such as a folder change or a new model), nothing that isn't ready can be used. The orb breathes with a
// plain line, "Getting ready… picking up 4 helpers · 1 of 4 back" (real counts, never a time). Each helper being picked
// back up sleeps, dimmed, with "starting again", and can't be tapped or messaged until it's re-attached; they wake one
// by one. The ask box, push to talk, the floating orb and the choice buttons wait. Everything opens together once the
// engine is started, the conversation loaded and every resumed helper re-attached. Anything sent meanwhile (a hidden
// note, a routine's report, a message to a helper) waits "next up" and goes the moment it opens: never lost.
// Never stuck: a start that fails, or takes too long, shows a plain line with Try again.

enum Gate: Equatable {
    case ready
    case gettingReady
    case stuck(String)  // what went wrong, in plain words; shown with Try again

    /// At launch: closed until the engine is up, for the real app once set up. Test and render modes start open
    /// (their engine starts still close and open it, like the real one).
    static var atLaunch: Gate { UserDefaults.standard.bool(forKey: "onboarded") && !Env.commandLine ? .gettingReady : .ready }
}

enum GateWords {
    static let box = "Getting ready… you can type once I open"
    static let talk = "Getting ready… you can talk once I open."
    static let helper = "starting again"
    static let failed = "I couldn't get ready."
    static let slow = "This is taking longer than usual"
    static func line(total: Int) -> String { total == 0 ? "Getting ready…" : "Getting ready… picking up \(total) helper\(total == 1 ? "" : "s")" }
    static func back(_ back: Int, of total: Int) -> String { "· \(back) of \(total) back" }
}

enum GateTiming {
    /// Engine up but a helper still re-attaching after this long: the chat opens; that helper keeps sleeping until it's back.
    nonisolated(unsafe) static var helpersMax: Double = 60
    /// Engine still not up after this long: the plain line with Try again.
    nonisolated(unsafe) static var stuckAfter: Double = 90
}

@MainActor
extension Model {
    /// One is open for input: typing, talking, choices, tapping helpers.
    var isReady: Bool { gate == .ready }

    /// This helper is being picked back up and isn't back yet: dimmed, "starting again", can't be tapped or messaged.
    func asleep(_ h: Helper) -> Bool {
        waking.contains(h.id) || (h.resumeQueued == true && h.stoppedByYou != true && !paused)
    }

    /// "picking up N helpers · k of N back": every helper of this get-ready, and how many are back.
    var gateCounts: (total: Int, back: Int) {
        let queued = helpers.filter { $0.resumeQueued == true && $0.stoppedByYou != true && !waking.contains($0.id) }.count
        return (wakingTotal + queued, max(0, wakingTotal - waking.count))
    }

    /// Engine news (Engine.onPhase): every start, every crash, at launch or mid-session.
    func enginePhase(_ p: Engine.Phase) {
        switch p {
        case .starting:
            closeGate()
        case .gone:
            closeGate()
            resumeWhenReady(after: 1)  // gone by itself: start it again (helpers or not), so getting ready never waits on nobody
        case .started:
            gateCheck()
        case .failed:
            if gate != .ready { gate = .stuck(GateWords.failed) }
        }
    }

    func closeGate() {
        if gate == .ready {
            wakingTotal = waking.count
            gateRoster = []
        }
        noteGateRoster(helpers.filter { asleep($0) }.map(\.id))
        if gate != .gettingReady { gateSince = Date() }
        gate = .gettingReady
        if talkingInApp { talkNote = nil }  // what they're saying now still goes, after it opens
        watchGate()
    }

    /// Opens when the engine is up with its conversation, and no helper is still being picked back up.
    func gateCheck() {
        guard gate != .ready, Engine.shared.running, waking.isEmpty else { return }
        if !paused, helpers.contains(where: { $0.resumeQueued == true && $0.stoppedByYou != true }) { return }
        openGate()
    }

    func openGate() {
        gate = .ready
        gateSince = nil
        wakingTotal = waking.count
        sendWaiting()  // what was sent while getting ready goes now, in order
    }

    /// Never stuck: helpers that take too long stop holding the chat (they keep sleeping until back); an engine that
    /// doesn't come up shows the plain line with Try again.
    func watchGate() {
        gateWatch += 1
        let token = gateWatch
        Task { @MainActor in
            while self.gateWatch == token, self.gate == .gettingReady {
                try? await Task.sleep(for: .seconds(1))
                guard self.gateWatch == token, self.gate == .gettingReady, let since = self.gateSince else { return }
                let waited = Date().timeIntervalSince(since)
                if Engine.shared.running, waited > GateTiming.helpersMax {
                    self.openGate()
                } else if !Engine.shared.running, waited > GateTiming.stuckAfter {
                    self.gate = .stuck(GateWords.slow)
                }
            }
        }
    }

    /// Try again on the stuck line.
    func tryGettingReadyAgain() {
        gate = .gettingReady
        gateSince = Date()
        watchGate()
        Task { @MainActor in
            if Engine.shared.running {
                self.resumeInterrupted()
                self.gateCheck()
            } else if Engine.shared.isStarting {
                _ = await Engine.shared.startOver()  // a start that hangs is replaced, not waited on
            } else {
                await self.startEngineAgain()
            }
        }
    }

    /// Picks up helpers a restart cut off, all at once. Runs once the engine is ready and
    /// whenever a helper finishes. Tells the person once per helper, in the chat, on the orb and out loud.
    /// Each one sleeps (`waking`) until its conversation is re-attached, then wakes; the last one opens One.
    func resumeInterrupted() {
        guard Engine.shared.running, !paused, helpers.contains(where: { $0.resumeQueued == true }) else { return }
        let picked = HelperTrail.pick(&helpers) { Helpers.brief(assistant: self.assistantName, user: self.userName, task: $0) }
        waking.formUnion(picked.map(\.id))
        noteGateRoster(picked.map(\.id))
        wakingTotal += picked.count
        // One line for the whole batch: 46 helpers cut off by one restart used to post 46 lines and say each out loud.
        // Said once per cut-off, not on every retry while a helper's last step finishes.
        let told = picked.compactMap { p in
            helpers.first { $0.id == p.id && ($0.busyTries == nil || $0.busyTries == 1) }.map { $0.restartNews ?? HelperTrail.told($0.title) }
        }
        if let line = told.count == 1 ? told.first : (told.isEmpty ? nil : HelperTrail.toldMany(told.count)) {
            Floater.shared.note(line)
            enqueue(.line(bubble: line, spoken: line))  // after whatever is being said, never into it (silent when muted)
        }
        for p in picked {
            guard let h = helpers.first(where: { $0.id == p.id }) else { continue }
            HelperTrail.flush(h)
            Task { @MainActor in
                let sid = await HelperTrail.session(
                    old: h.sid, reopen: { await Engine.shared.reopenSession($0) }, open: { await Engine.shared.openSession() })
                self.waking.remove(p.id)  // back (or given up on): it wakes
                guard let sid else {
                    self.update(p.id) {
                        $0.state = "stopped"
                        $0.line = "Couldn't pick it back up · tap to see what it did"
                    }
                    self.gateCheck()
                    return
                }
                self.update(p.id) { $0.sid = sid }
                self.gateCheck()
                await self.runHelper(p.id, p.prompt, images: [])
            }
        }
        gateCheck()
    }
}

// MARK: - How it looks (the layer over the window: ReadyLayer.swift)

/// A helper being picked back up: a dim orb with a dashed edge, breathing slowly, until it's back.
struct SleepingOrb: View {
    let size: CGFloat
    let t: Double
    var body: some View {
        let breath = 0.5 + 0.5 * sin(t * .pi * 2 / 4.2)
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [Color(hex: 0x3A3936), Color(hex: 0x19191B)], center: UnitPoint(x: 0.42, y: 0.38), startRadius: 0,
                    endRadius: size * 0.6))
            Circle().strokeBorder(WorldLook.cream.opacity(0.10 + 0.08 * breath), lineWidth: 1)
            Circle().stroke(WorldLook.cream.opacity(0.30 + 0.12 * breath), style: StrokeStyle(lineWidth: 1, dash: [2.5, 3]))
                .frame(width: size + 10, height: size + 10)
        }
        .frame(width: size, height: size)
    }
}
