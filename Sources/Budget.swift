import SwiftUI

// MARK: - A usage budget per job (Claude Design "One Safety Features", Direction A, Omar's pick Nov 9 2026)

/// Every helper gets a share of the AI plan's week: 5% by default, 10% for a standing goal, or what the job says
/// ("Budget 10%: …", "Goal (50 turns, 10%): …"), changed with one tap in its card (5% / 10% / 20% / No limit).
/// At 80% its orb's thin arc turns amber; at 100% One pauses it (its turn ends, nothing can wake it, its goal
/// pauses: the stop mark, JobTree.swift), turns it orange, and offers Give it N% more, Switch to <other account>
/// (when one is signed in, Accounts.swift) and Stop it. The main chat and routines have no budget.
enum Budget {
    static let helperDefault = 0.05
    static let goalDefault = 0.10
    static let warnAt = 0.8
    static let choices: [Double?] = [0.05, 0.10, 0.20, nil]

    /// "Budget 10%: …" at the start of a job, or the "%" inside "Goal (50 turns, 10%): …". Nil = not given.
    static func parse(_ task: String) -> Double? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let pats = [#"^(?i)budget\s*(\d{1,3})\s*%"#, #"^(?i)goal\s*\([^)\n]*?(\d{1,3})\s*%[^)\n]*\)\s*:"#]
        for p in pats {
            guard let rx = try? NSRegularExpression(pattern: p),
                let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t),
                let n = Double(t[r]), n > 0, n <= 100
            else { continue }
            return n / 100
        }
        return nil
    }
    /// What this helper may use (nil = no limit).
    static func of(_ h: Helper) -> Double? {
        if h.budgetOff == true { return nil }
        return h.budget ?? (Goals.helperGoal(h.task) != nil ? goalDefault : helperDefault)
    }
    static func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    /// "8% of its 10%".
    static func words(_ h: Helper) -> String? {
        guard let b = of(h) else { return h.used.map { "\(pct($0)) of the week, no limit" } }
        return "\(pct(h.used ?? 0)) of its \(pct(b))"
    }
    static func pausedLine(_ b: Double) -> String { "Used its \(pct(b)) of the week · paused" }
    /// How full its arc is: used ÷ budget (nil = no arc).
    static func fill(_ h: Helper) -> Double? {
        guard let b = of(h), b > 0, let u = h.used else { return nil }
        return u / b
    }

    /// Checks swap these (no engine, no accounts in a check).
    @MainActor static var resend: (UUID, String) async -> Void = { id, text in await Model.shared.runHelper(id, text, images: []) }
    @MainActor static var otherAccount: (Provider) async -> (label: String, entry: String)? = { p in
        await Accounts.list(p).first { !$0.isActive }.map { ($0.label, $0.entryID) }
    }
    @MainActor static var makeDefault: (Provider, String) async -> Bool = { p, e in await Accounts.makeDefault(p, entryID: e) }
}

/// The plan's week, for the line under the main orb ("This week: 62% used · resets Fri 9 AM").
struct WeekMeter: Equatable {
    var used: Double  // 0…100
    var reset: Date?
    var words: String {
        let f = DateFormatter()
        f.dateFormat = "EEE h a"
        return "This week: \(Int(used.rounded()))% used" + (reset.map { " · resets \(f.string(from: $0))" } ?? "")
    }
}

@MainActor
extension Model {
    /// Every 30 s (from `tendEveryTwo`): what each working helper used; warn at 80%, pause at its budget.
    /// Every 5 minutes while something works: the plan's own meter, for the week line and the calibration.
    func tendBudgets(now: Date = Date()) {
        let working = helpers.filter { $0.state == "working" && $0.sid != nil }
        guard !working.isEmpty, !budgetReading else { return }
        budgetReading = true
        let meterDue = now.timeIntervalSince(lastMeter) >= 300
        if meterDue { lastMeter = now }
        let provider = (provider ?? .claude).hermesID
        let pairs = working.map { ($0.id, $0.sid!) }
        Task { @MainActor in
            defer { budgetReading = false }
            let (shares, reading) = await Task.detached { () -> ([UUID: Double], Usage.Reading?) in
                var store = Usage.load()
                var r: Usage.Reading?
                if meterDue, let m = Usage.meter(provider) {
                    r = Usage.Reading(
                        t: Date().timeIntervalSince1970, provider: provider, week: m.week, reset: m.reset?.timeIntervalSince1970, units: Usage.total()
                    )
                    Usage.add(r!, to: &store)
                    Usage.save(store)
                }
                var out: [UUID: Double] = [:]
                for (id, sid) in pairs { out[id] = Usage.share(units: Usage.tree(sid), store) }
                return (out, r)
            }.value
            if let r = reading { week = WeekMeter(used: r.week, reset: r.reset.map { Date(timeIntervalSince1970: $0) }) }
            for (id, used) in shares { applyUsage(id, used: used) }
        }
    }

    /// One reading for one helper: its share, then the warning and the pause.
    func applyUsage(_ id: UUID, used: Double) {
        guard let h = helpers.first(where: { $0.id == id }) else { return }
        update(id) { $0.used = used }
        guard h.state == "working", let b = Budget.of(h) else { return }
        if used >= b {
            pauseForBudget(id, budget: b)
        } else if used >= b * Budget.warnAt && h.budgetWarned != true {
            update(id) {
                $0.budgetWarned = true
                HelperTrail.add("Has used \(Budget.pct(used)) of its \(Budget.pct(b)) of the week", to: &$0)
            }
            saveTrail(id)
        }
    }

    /// At its budget: paused (not stopped by you), orange, with the three choices.
    func pauseForBudget(_ id: UUID, budget b: Double) {
        guard let h = helpers.first(where: { $0.id == id }), h.state == "working" else { return }
        if let sid = h.sid {
            StopMark.mark(sid, title: h.title)  // nothing wakes it while paused (the stop plugin)
            Engine.shared.cancel(session: sid)  // its turn ends; a goal pauses (the goal overlay)
        }
        update(id) {
            $0.state = "stopped"
            $0.pausedForBudget = true
            $0.resumeQueued = false
            $0.stoppedByYou = nil
            $0.line = Budget.pausedLine(b)
            $0.seen = false
            HelperTrail.add("Paused: used its \(Budget.pct(b)) of the week", to: &$0)
        }
        saveTrail(id)
        JobTree.log("\(id.uuidString.prefix(8)): paused at its budget (\(Budget.pct(b)))")
        let p = provider ?? .claude
        Task { @MainActor in
            let other = await Budget.otherAccount(p)
            update(id) {
                $0.switchTo = other?.label
                $0.switchEntry = other?.entry
            }
        }
    }

    /// "Give it 10% more": the budget grows by its own size and it carries on where it stopped.
    func giveMoreBudget(_ id: UUID) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForBudget == true else { return }
        let b = Budget.of(h) ?? Budget.helperDefault
        update(id) {
            $0.budget = b * 2
            $0.budgetOff = nil
        }
        await carryOn(id, why: "they gave you \(Budget.pct(b)) more of the week")
    }

    /// "Switch to <account>": that account becomes the default for this AI (for everything One does, the
    /// card says so), then it carries on with a fresh share there.
    func switchBudgetAccount(_ id: UUID) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForBudget == true, let e = h.switchEntry else { return }
        guard await Budget.makeDefault(provider ?? .claude, e) else { return }
        let b = Budget.of(h) ?? Budget.helperDefault
        update(id) { $0.budget = (h.used ?? b) + b }
        await carryOn(id, why: "they switched to their \(h.switchTo ?? "other") account")
    }

    /// "Stop it": it stays stopped, like the Stop button (its tree is already closed by the pause).
    func stopPausedHelper(_ id: UUID) {
        update(id) {
            $0.pausedForBudget = nil
            $0.stoppedByYou = true
            $0.line = HelperTrail.stoppedLine
            $0.seen = true
        }
        saveTrail(id)
    }

    /// Tap the share in its card: 5% / 10% / 20% / No limit.
    func setBudget(_ id: UUID, _ b: Double?) {
        update(id) {
            $0.budget = b
            $0.budgetOff = b == nil ? true : nil
            $0.budgetWarned = nil
        }
        saveTrail(id)
    }

    private func carryOn(_ id: UUID, why: String) async {
        guard let h = helpers.first(where: { $0.id == id }) else { return }
        if let sid = h.sid { StopMark.lift(sid) }
        update(id) {
            $0.pausedForBudget = nil
            $0.budgetWarned = nil
            $0.switchTo = nil
            $0.switchEntry = nil
            HelperTrail.add("Carrying on: \(why)", to: &$0)
        }
        saveTrail(id)
        let text =
            Goals.helperGoal(h.task) != nil
            ? "/goal resume"
            : "(One app note, not from the user: you were paused because you used your share of the week; \(why). Carry on from where you stopped.)"
        await Budget.resend(id, text)
    }
}

// MARK: Views (Direction A: the arc on the orb; the choices in its card; the week under the main orb)

/// The thin arc around a helper's orb: how much of its budget it used (cream, amber past 80%, orange at the limit).
struct BudgetArc: View {
    let fill: Double
    let size: CGFloat
    var body: some View {
        let f = min(1, max(0.02, fill))
        let c = fill >= 1 ? Color(hex: 0xF0A04B) : fill >= Budget.warnAt ? Color(hex: 0xF6B46E, 0.9) : WorldLook.cream.opacity(0.45)
        ZStack {
            Circle().stroke(WorldLook.cream.opacity(0.07), lineWidth: 1.6)
            Circle().trim(from: 0, to: f).stroke(c, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// In a helper's card: "8% of its 10% this week", tap to change; when paused at it, the three choices.
struct BudgetRow: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let w = Budget.words(h) {
                Menu {
                    ForEach(Array(Budget.choices.enumerated()), id: \.offset) { _, c in
                        Button(c.map { Budget.pct($0) + " of the week" } ?? "No limit") { m.setBudget(h.id, c) }
                    }
                } label: {
                    Text(w + " this week").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.6))
                }
                .menuStyle(.borderlessButton).fixedSize().help("Change how much of the week this job may use")
            }
            if h.pausedForBudget == true, let b = Budget.of(h) {
                HStack(spacing: 8) {
                    Button("Give it \(Budget.pct(b)) more") { Task { await m.giveMoreBudget(h.id) } }.buttonStyle(.bordered)
                    if let to = h.switchTo {
                        Button("Switch to \(to)") { Task { await m.switchBudgetAccount(h.id) } }.buttonStyle(.bordered)
                            .help("\(to) becomes the account everything uses from now on")
                    }
                    Button("Stop it") { m.stopPausedHelper(h.id) }.buttonStyle(.bordered)
                }
            }
        }
    }
}

/// Under the main orb: the plan's week, quiet; amber from 80%.
struct WeekLine: View {
    @ObservedObject var m: Model
    var body: some View {
        if let w = m.week {
            Text(w.words).font(.system(size: 11.5))
                .foregroundStyle(w.used >= 80 ? Color(hex: 0xF6B46E, 0.9) : WorldLook.cream.opacity(0.4))
                .accessibilityLabel(w.words)
        }
    }
}
