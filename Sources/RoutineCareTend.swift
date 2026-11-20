import SwiftUI

// MARK: - Routines that fix themselves: One's minute (RoutineCare.swift has the rules) and the needs-you item

enum RoutineCareRun {
    @MainActor static var busy = false
    @MainActor static var last = Date.distantPast
    /// The needs-you item's words, by ask id (filled each minute from the state).
    @MainActor static var cards: [String: (title: String, detail: String)] = [:]

    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        RoutineCare.append(line, to: Env.hermesHome.appendingPathComponent("logs/one-routine-care.log"))
    }

    /// A tab on the site's sign-in page in that hidden browser (an open one is used again), so the window and the
    /// phone's link both open on it.
    static func target(_ b: RoutineCare.Blocker) async -> String? {
        let pages = await BlockedAsk.pages(port: b.port)
        if let p = pages.first(where: { $0.url.lowercased().contains(b.site) && ($0.url.contains("login") || $0.url.contains("flow")) }) {
            return p.target
        }
        return await HumanCheck.openTab(port: b.port, url: b.login ?? "https://\(b.site)/")
    }
}

@MainActor
extension Model {
    /// Once a minute (from `tendRoutines`): read the routines, check the sign-ins that are due, take the step, carry it out.
    func tendRoutineCare() {
        guard !Env.commandLine, onboarded, !RoutineCareRun.busy, Date().timeIntervalSince(RoutineCareRun.last) >= 55 else { return }
        RoutineCareRun.busy = true
        RoutineCareRun.last = Date()
        Task {
            defer { RoutineCareRun.busy = false }
            let now = Date()
            let (jobs, needs, start) = await Task.detached { (RoutineCare.liveJobs(), RoutineCare.needs(), RoutineCare.load()) }.value
            var signed: [String: Bool] = [:]
            for n in RoutineCare.wanted(start, jobs: jobs, needs: needs, now: now) {
                if let v = await RoutineCare.signedIn(n) { signed[n.key] = v }
            }
            var s = start
            let effects = RoutineCare.step(&s, jobs: jobs, needs: needs, signedIn: signed, now: now, quiet: RoutineCare.quiet(now))
            var targets: [String: String] = [:]
            for b in s.open { targets[b.key] = await RoutineCareRun.target(b) ?? "" }
            // Done in the window but still signed out: the item comes back at once (no new phone message).
            for k in s.blockers.indices where s.blockers[k].cleared == nil && signed[s.blockers[k].key] == false {
                if HumanStep.answerOf(RoutineCare.askID(s.blockers[k], n: s.blockers[k].asks)) == "done" { s.blockers[k].asks += 1 }
            }
            RoutineCare.save(s)
            let doer = RoutineCare.Doer(
                cron: { args in
                    Task {
                        let (code, out) = await hermesRun(args, timeout: args.count > 1 && args[1] == "run" ? 2400 : 60)
                        RoutineCareRun.log("\(args.joined(separator: " ")): exit \(code) \(out.suffix(160))")
                    }
                },
                fixer: { [weak self] title, task in
                    guard let self, !self.helpers.contains(where: { $0.title == title && HelperClose.busy($0) }) else { return }
                    RoutineCareRun.log("fixer: \(title)")
                    self.spawnHelper(title: title, task: task)
                },
                say: { [weak self] line in
                    Floater.shared.note(line)
                    self?.enqueue(.line(bubble: line, spoken: line))
                },
                target: { targets[$0.key] })
            RoutineCare.perform(effects, state: s, doer: doer, now: now)
            for b in s.open { RoutineCare.keepAsk(b, target: targets[b.key] ?? "") }
            let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            RoutineCareRun.cards = Dictionary(
                s.open.map { b in
                    (String(RoutineCare.askID(b, n: 0).dropLast(1)), (RoutineCare.title(b), RoutineCare.detail(b, byID: byID)))
                }, uniquingKeysWith: { a, _ in a })
            for e in effects where e.kind != "swallow" { RoutineCareRun.log("\(e.kind) \(e.job) \(e.blocker)") }
        }
    }

    /// The needs-you items for routines, shown at the top of home.
    var routineAsks: [HumanStepAsk] { humanSteps.filter { RoutineCare.isAsk($0.id) } }
}

extension HumanStep {
    /// What they answered a request with, or nil.
    static func answerOf(_ id: String) -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(id).answer.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return j["answer"] as? String
    }
}

/// ONE item at the top of home while routines wait on the person: what's blocked, what's waiting, Show me the window.
struct RoutineAskCard: View {
    let a: HumanStepAsk
    var body: some View {
        let words = RoutineCareRun.cards.first { a.id.hasPrefix($0.key) }?.value
        let open = HumanCheck.active?.id == a.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("NEEDS YOU").font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(words?.title ?? a.line).font(.headline).foregroundStyle(WorldLook.cream).fixedSize(horizontal: false, vertical: true)
            if let d = words?.detail { Text(d).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if open {
                    Text("The window is open. Sign in there, then tap Done.").foregroundStyle(.secondary)
                    Button("Done") { Model.shared.answerHumanStep(a.id, "done") }.buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                } else {
                    Button("Show me the window") { Model.shared.showHumanStep(a) }.buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                    Button("Later") { Model.shared.answerHumanStep(a.id, "away") }.buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.orange.opacity(0.35)))
    }
}
