import Foundation
import SwiftUI

// MARK: - Real progress on every helper: the step it's on, how long that step has run, when it last did anything,
// the one line it said about what it's doing, and a calm "No progress for N min" when nothing has happened for a while.
// Fed by the engine's own step events (`Engine.onPulse`: a step starts, a step ends, words, thoughts). Never saved:
// after a restart a helper starts a fresh pulse when it's picked back up. Never stops a helper on its own.

/// What one helper is doing right now (not saved).
struct HelperPulse: Equatable {
    var step = ""  // plain words, no trailing "…" ("Building One")
    var stepAt = Date()  // when that step started
    var open: Set<String> = []  // steps started and not finished yet (their ids)
    var lastAt = Date()  // the last real activity: a step started or ended, words, thoughts
    var plan: String?  // the one plain line it last said about what it's doing
    var said = ""  // its words since its last step (the next plan line comes from here)
    var nudgedAt: Date?
    var stepOpen: Bool { !open.isEmpty }
}

enum HelperProgress {
    /// A step that has run this long shows how long ("Running tests (2 min)…").
    static let longStep: TimeInterval = 30
    /// No step, words or thoughts for this long: the orb says "No progress for 6 min" (amber), with Nudge and Stop
    /// in its thread. Long enough for a normal build or test run, short enough that a hung command shows.
    static let stuckAfter: TimeInterval = 6 * 60
    /// Renders only: the time the screen is drawn at.
    nonisolated(unsafe) static var stillNow: Date?
    static func now(_ live: Date) -> Date { stillNow ?? live }

    static func dur(_ s: TimeInterval) -> String {
        let s = max(0, Int(s))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
    static func bare(_ step: String) -> String {
        var s = step.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("…") || s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }
    /// Steps whose words don't say what's slow: a long one reads "Waiting on a slow command".
    static let vague: Set<String> = ["Working on your Mac", "Running a small program", "Working it out on your Mac", "Working on it"]
    static func stuck(_ p: HelperPulse, now: Date) -> Bool { now.timeIntervalSince(p.lastAt) >= stuckAfter }
    static func stuckLine(_ p: HelperPulse, now: Date) -> String { "No progress for \(dur(now.timeIntervalSince(p.lastAt)))" }

    /// The line under a working helper's orb.
    /// `short`: under the orb, where about 22 characters fit (pointing at it shows the rest).
    static func line(_ p: HelperPulse?, fallback: String, now: Date, building: Bool = false, short: Bool = false) -> String {
        guard let p, !p.step.isEmpty else { return fallback }
        if !short && stuck(p, now: now) { return stuckLine(p, now: now) }  // inside its thread only; under the orb, the step
        let step = bare(p.step)
        if building && step.hasPrefix("Building") && p.stepOpen { return "Waiting for another build…" }
        let ran = now.timeIntervalSince(p.stepAt)
        if p.stepOpen {
            if ran < longStep { return step + "…" }
            if vague.contains(step) { return short ? "Slow step (\(dur(ran)))" : "Waiting on a slow command (\(dur(ran)))" }
            return "\(step) (\(dur(ran)))…"
        }
        let quiet = now.timeIntervalSince(p.lastAt)
        if quiet < longStep { return step + "…" }
        return short ? "Thinking (\(dur(quiet)))…" : "Thinking it over · last step \(dur(quiet)) ago"
    }
    /// The smaller line in its thread: how long this step has run and when it last did anything.
    static func detail(_ p: HelperPulse, now: Date) -> String {
        let ran = now.timeIntervalSince(p.stepAt)
        let quiet = now.timeIntervalSince(p.lastAt)
        let since = quiet < 5 ? "just now" : "\(dur(quiet)) ago"
        if p.stepOpen { return ran < 5 ? "Started just now" : "On this step for \(dur(ran)) · last activity \(since)" }
        return "Last step \(since)"
    }

    /// One plain line from what it last said ("I'll run the tests, then push."), or nil when nothing fits:
    /// no code, paths, links, tags or error dumps; a sentence a regular person can read.
    static func plan(_ said: String) -> String? {
        var lines = said.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lines.removeAll { $0.hasPrefix("[") || $0.hasPrefix("```") || $0.hasPrefix("|") || $0.hasPrefix(">") }
        guard var t = lines.last else { return nil }
        for mark in ["**", "__", "`", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        while let f = t.first, "-*• ".contains(f) { t.removeFirst() }
        // The last whole sentence.
        let parts = t.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
        guard var s = parts.last else { return nil }
        if !s.hasSuffix(".") && !s.hasSuffix(":") && !s.hasSuffix("!") && !s.hasSuffix("?") { s += "." }
        if s.hasSuffix(":") { s = String(s.dropLast()) + "." }
        let low = s.lowercased()
        let scary = ["error", "traceback", "exception", "failed", "fatal", "denied", "http", "://", "{", "}", "$", "=", "\\", "~/", "./"]
        guard s.count >= 12, s.count <= 120, !scary.contains(where: { low.contains($0) }),
            !s.split(separator: " ").contains(where: { $0.contains("/") || $0.contains("_") })
        else { return nil }
        return s
    }

    /// The nudge, handed to its running turn (it reads it after its current step).
    static func nudge(_ quiet: TimeInterval) -> String {
        "(One app note: \(UserDefaults.standard.string(forKey: "userName") ?? "They") nudged you from your orb: it has shown no progress for "
            + "\(dur(quiet)). If a command is hanging, stop waiting on it and try a quicker way. Then say in one plain line where you are and "
            + "what's next, and carry on with the job.)"
    }

    // Builds of One wait for each other (build.sh holds this lock while it compiles).
    static var buildLock: String { ProcessInfo.processInfo.environment["ONE_BUILD_LOCK"] ?? "/tmp/one-build-\(getuid()).lock" }  // same as build.sh
    nonisolated(unsafe) private static var lockSeen: (at: Date, taken: Date?) = (.distantPast, nil)
    /// When the current build lock was taken (nil: no build running). Read at most every 2 seconds.
    static func lockTaken(now: Date = Date()) -> Date? {
        if now.timeIntervalSince(lockSeen.at) < 2 { return lockSeen.taken }
        let a = try? FileManager.default.attributesOfItem(atPath: buildLock + "/pid")
        lockSeen = (now, a?[.modificationDate] as? Date)
        return lockSeen.taken
    }
    /// This helper's build started while another build already held the lock, so it's waiting its turn.
    static func waitingForBuild(_ p: HelperPulse, now: Date = Date()) -> Bool {
        guard p.stepOpen, bare(p.step).hasPrefix("Building"), let t = lockTaken(now: now) else { return false }
        return t < p.stepAt.addingTimeInterval(-1)
    }
}

/// Plain words for the steps of building software ("Building One…", "Running tests…", "Pushing to GitHub…").
extension Plain {
    static func dev(_ w: [String], at i: Int, cmd: String) -> String? {
        let head = (w[i].split(separator: "/").last.map(String.init) ?? w[i]).lowercased()
        let next = i + 1 < w.count ? w[i + 1].lowercased() : ""
        let low = cmd.lowercased()
        let one = w.contains { x in
            let c = (x.split(separator: "/").last.map(String.init) ?? x).lowercased()
            return c.hasPrefix("one-") || c == "one.app" || c == "one"
        }
        let what = one ? "One" : "the app"
        if low.contains("--render") { return "Drawing screenshots…" }
        if head == "build.sh" || (head == "make" && (next == "build" || next.isEmpty)) || head == "xcodebuild"
            || (head == "swift" && next == "build") || head == "swiftc" || (["npm", "pnpm", "yarn"].contains(head) && low.contains("build"))
        {
            return low.contains("--package") ? "Packaging \(what)…" : "Building \(what)…"
        }
        if head == "make", ["check", "test", "full", "preflight", "jobs", "lint"].contains(next) || next.hasSuffix("-check") {
            return next == "lint" ? "Checking the code…" : "Running tests…"
        }
        if head.hasSuffix("-check.sh") || head == "preflight.sh" || head == "pytest" || (head == "swift" && next == "test")
            || (["npm", "pnpm", "yarn"].contains(head) && next == "test") || low.contains(" --test-")
        {
            return "Running tests…"
        }
        if head == "git" && next == "push" { return "Pushing to GitHub…" }
        if head == "git" && next == "commit" { return "Saving the changes…" }
        if head == "gh" && next == "release" { return "Publishing a release…" }
        if head == "gh" && next == "pr" { return low.contains("merge") ? "Merging on GitHub…" : "Opening a pull request…" }
        if head == "gh" && next == "run" { return "Checking the build on GitHub…" }
        if head == "notarytool" || low.contains("notarytool") { return "Getting Apple's OK…" }
        return nil
    }
}

@MainActor
extension Model {
    /// Listens to every conversation's step events once; only working helpers get a pulse.
    func wirePulse() {
        guard !pulseWired else { return }
        pulseWired = true
        Engine.shared.onPulse = { sid, kind, call, status in
            Task { @MainActor in self.pulse(sid: sid, kind: kind, call: call, status: status) }
        }
    }
    func pulse(sid: String, kind: String, call: String?, status: String?) {
        guard let h = helpers.first(where: { $0.sid == sid && $0.state == "working" }) else { return }
        var p = pulses[h.id] ?? HelperPulse(step: "", stepAt: Date(), lastAt: Date())
        let now = Date()
        switch kind {
        case "tool_call": if let c = call { p.open.insert(c) }
        case "tool_call_update":
            guard status == "completed" || status == "failed", let c = call else { return }
            p.open.remove(c)
        case "agent_message_chunk", "agent_thought_chunk":
            if now.timeIntervalSince(p.lastAt) < 1 { return }  // words stream in pieces: once a second is enough
        default: return
        }
        p.lastAt = now
        pulses[h.id] = p
    }
    /// A helper's turn starts: a fresh pulse.
    func pulseStart(_ id: UUID) {
        wirePulse()
        pulses[id] = HelperPulse(step: "", stepAt: Date(), lastAt: Date())
    }
    /// A step started: its plain words, and the line it said just before (what it's doing).
    func pulseStep(_ id: UUID, _ step: String) {
        var p = pulses[id] ?? HelperPulse()
        if let plan = HelperProgress.plan(p.said) { p.plan = plan }
        p.said = ""
        if HelperProgress.bare(step) != HelperProgress.bare(p.step) || !p.stepOpen { p.stepAt = Date() }
        p.step = step
        p.lastAt = Date()
        pulses[id] = p
    }
    func pulseText(_ id: UUID, _ s: String) {
        guard var p = pulses[id] else { return }
        p.said += s
        if p.said.count > 4000 { p.said = String(p.said.suffix(2000)) }
        pulses[id] = p
    }
    func pulseEnd(_ id: UUID) { pulses[id] = nil }
    /// "Nudge it" in a quiet helper's thread: one plain note into its running turn. Never stops it.
    func nudgeHelper(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.state == "working", let sid = h.sid else { return }
        let quiet = Date().timeIntervalSince(pulses[id]?.lastAt ?? Date())
        pulses[id]?.nudgedAt = Date()
        update(id) { HelperTrail.add("Nudged by you", to: &$0) }
        saveTrail(id)
        Task { _ = await Engine.shared.steer(Helpers.forHelper(HelperProgress.nudge(quiet)), session: sid) }
    }
    /// The line under a helper's orb, live.
    func progressLine(_ h: Helper, now: Date, short: Bool = false) -> String {
        guard h.state == "working", let p = pulses[h.id] else { return HelperRings.status(h) }
        return HelperProgress.line(p, fallback: h.line, now: now, building: HelperProgress.waitingForBuild(p), short: short)
    }
    func seemsStuck(_ h: Helper, now: Date) -> Bool {
        guard h.state == "working", let p = pulses[h.id] else { return false }
        return HelperProgress.stuck(p, now: now)
    }
}

/// Inside a working helper's thread: the step with its time, its plan line, and when it's gone quiet, Nudge and Stop.
struct HelperProgressView: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let now = HelperProgress.now(tl.date)
            if let p = m.pulses[h.id] {
                content(p, now: now)
            } else {
                Text(h.line).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder func content(_ p: HelperPulse, now: Date) -> some View {
        let stuck = HelperProgress.stuck(p, now: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(WorldLook.cream.opacity(0.7)).frame(width: 6, height: 6)
                Text(m.progressLine(h, now: now)).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(WorldLook.cream.opacity(0.9))
            }
            if !p.step.isEmpty {
                Text(HelperProgress.detail(p, now: now)).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.45)).padding(
                    .leading, 14)
            }
            if let plan = p.plan {
                Text("“\(plan)”").font(.system(size: 12.5)).italic().foregroundStyle(WorldLook.cream.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 14)
            }
            if stuck { stuckBox(p, now: now).padding(.top, 6) }
        }
    }
    func stuckBox(_ p: HelperPulse, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Nothing has happened for \(HelperProgress.dur(now.timeIntervalSince(p.lastAt))). It may be stuck on a slow step. It keeps going unless you stop it."
            )
            .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let n = p.nudgedAt {
                    Text(
                        "Nudged \(now.timeIntervalSince(n) < 60 ? "just now" : HelperProgress.dur(now.timeIntervalSince(n)) + " ago") · it reads it after this step"
                    )
                    .font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
                } else {
                    Button {
                        m.nudgeHelper(h.id)
                    } label: {
                        Label("Nudge it", systemImage: "hand.tap")
                    }.buttonStyle(.bordered).help("Asks it where it is and to try a quicker way if a command is hanging.")
                }
                Spacer()
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12)))
    }
}

extension HelperProgress {
    /// Calm amber: quieter than the orange of "needs your yes".
    static let amber = Color(hex: 0xE9C27D)
}
