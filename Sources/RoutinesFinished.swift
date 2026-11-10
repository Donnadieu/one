import AppKit
import SwiftUI

// MARK: - Finished routines (Omar, Nov 9 2026). A routine that ran every time it was set to (its repeat count reached,
// or a one-shot that ran) is done on purpose, not broken: "Argo P009 check" ran its 15 runs with no errors and the
// dial still drew it orange with an X. Now it leaves the day dial for a quiet, folded "Finished" list in calm grey with
// a check ("Finished Nov 8 · ran 15 times"). Its card opens its past reports and offers Run again, which renews it
// only after a yes. The orange X stays for runs that really failed (`Routines.failedRecord`, `Dial.alarm`).

extension Routines {
    /// "Finished Nov 8 · ran 15 times", "Finished Nov 8 · ran once".
    static func finishedLine(_ r: Routine) -> String {
        var s = "Finished"
        if let l = r.lastRun {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            s += " " + f.string(from: l)
        }
        if r.runs == 1 { s += " · ran once" } else if r.runs > 1 { s += " · ran \(r.runs) times" }
        return s
    }

    /// The card's line under the title: why it stopped, in plain words.
    static func finishedWhy(_ r: Routine) -> String {
        if r.lastFailed { return "It ran every time it was set to. Its last run didn't work." }
        if r.once || r.runs <= 1 { return "It ran once, as planned. Nothing is wrong." }
        return "It ran all \(r.runs) times it was set to. Nothing is wrong."
    }

    /// What "Run again" asks before it does anything.
    static func renewQuestion(_ r: Routine) -> String {
        if r.once { return "Run it again? It runs once more, now." }
        let often = r.often.prefix(1).lowercased() + r.often.dropFirst()
        return "Run it again? It goes back on your dial, \(often), for " + (r.runs <= 1 ? "one more run." : "another \(r.runs) runs.")
    }

    /// Its past reports, newest first.
    static func reports(_ id: String, dir: URL = cron) -> [(at: Date, file: URL)] {
        let out = dir.appendingPathComponent("output/\(id)")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        return names.reversed().compactMap { n in f.date(from: String(n.dropLast(3))).map { ($0, out.appendingPathComponent(n)) } }
    }

    /// What Run again does, as engine commands. A one-shot is re-armed to run once more, now (the engine's own way).
    /// A routine that used up its runs can't be switched back on (the engine keeps a finished record closed), so it
    /// comes back as a new routine with the same instructions, schedule and settings, for as many runs as it had.
    /// Its reports reach the chat either way: One reads every report itself.
    static func renewSteps(_ j: [String: Any], now: Date = Date()) -> [String] {
        guard let id = j["id"] as? String else { return [] }
        let sched = j["schedule"] as? [String: Any] ?? [:]
        let kind = sched["kind"] as? String ?? ""
        let rep = j["repeat"] as? [String: Any]
        if kind == "once" { return ["cron", "resume", id, "--run-now"] }
        var when = (sched["expr"] as? String) ?? (sched["display"] as? String) ?? ""
        if kind == "interval", let m = (sched["minutes"] as? Int) ?? (sched["minutes"] as? Double).map({ Int($0) }) { when = "every \(m)m" }
        var times = (rep?["times"] as? Int) ?? (rep?["completed"] as? Int) ?? 1
        // Set for one day of the year ("30 7 28 10 *"): run it once more, in two minutes, not next year.
        if runsOnce(sched) {
            let f = ISO8601DateFormatter()
            f.timeZone = .current
            when = f.string(from: now.addingTimeInterval(120))
            times = 1
        }
        var a = ["cron", "create", when, j["prompt"] as? String ?? ""]
        a += ["--name", (j["name"] as? String) ?? "A routine"]
        a += ["--repeat", String(max(1, times))]
        let deliver = (j["deliver"] as? String) ?? "local"
        a += ["--deliver", deliver == "origin" ? "local" : deliver]
        for s in (j["skills"] as? [String]) ?? [] { a += ["--skill", s] }
        let text: [(String, String)] = [
            ("script", "--script"), ("workdir", "--workdir"), ("model", "--model"), ("provider", "--provider"),
            ("reasoning_effort", "--reasoning-effort"), ("failure_deliver", "--failure-deliver"), ("monitor_script", "--monitor-script"),
            ("monitor_url", "--monitor-url"),
        ]
        for (k, flag) in text { if let v = j[k] as? String, !v.isEmpty { a += [flag, v] } }
        if j["no_agent"] as? Bool == true { a.append("--no-agent") }
        if ((j["context_from"] as? [String]) ?? []).contains("self") { a.append("--continuity") }
        return a
    }

    /// A one-shot, or a schedule set for one day of the year (the way some one-off checks were made).
    static func runsOnce(_ sched: [String: Any]) -> Bool {
        if (sched["kind"] as? String) == "once" { return true }
        let f = ((sched["expr"] as? String) ?? "").split(separator: " ")
        return (sched["kind"] as? String) == "cron" && f.count == 5 && Int(f[2]) != nil && Int(f[3]) != nil
    }

    /// Run again, after the person's yes. True when the engine took it.
    static func renew(_ id: String) async -> Bool {
        guard let d = try? Data(contentsOf: cron.appendingPathComponent("jobs.json")),
            let top = try? JSONSerialization.jsonObject(with: d),
            let j = ((top as? [String: Any])?["jobs"] as? [[String: Any]] ?? top as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == id }
            )
        else { return false }
        let steps = renewSteps(j)
        guard !steps.isEmpty else { return false }
        let (code, out) = await hermesRun(steps, timeout: 60)
        guard code == 0 else { return false }
        // A routine's own instructions can name its id (its step log path): point them at the new one.
        let prompt = j["prompt"] as? String ?? ""
        if steps[1] == "create", prompt.contains(id),
            let new = out.components(separatedBy: "Created job: ").dropFirst().first?.split(whereSeparator: \.isWhitespace).first
        {
            _ = await hermesRun(["cron", "edit", String(new), "--prompt", prompt.replacingOccurrences(of: id, with: String(new))], timeout: 60)
        }
        return true
    }
}

extension RoutinesPanel {
    /// Bottom left, above the legend: "✓ Finished · 2", folded until tapped.
    @ViewBuilder func finishedSection(_ rs: [Routine], now: Date) -> some View {
        if !rs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if finishedOpen {
                    ForEach(rs.prefix(6)) { r in finishedRow(r) }
                    if rs.count > 6 {
                        Text("and \(rs.count - 6) more").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.35)).padding(
                            .leading, 30)
                    }
                    Rectangle().fill(WorldLook.cream.opacity(0.07)).frame(height: 1).padding(.vertical, 4)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { finishedOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        finishedCheck(16)
                        Text("Finished · \(rs.count)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.5))
                        Image(systemName: finishedOpen ? "chevron.down" : "chevron.up").font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(WorldLook.cream.opacity(0.35))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(finishedOpen ? "Fold the finished routines" : "Routines that ran every time they were set to")
            }
            .padding(finishedOpen ? 10 : 0)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x1E1E22, finishedOpen ? 0.96 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(finishedOpen ? 0.1 : 0)))
            .frame(width: 212, alignment: .leading)
            .starCalm(floor: 0.12)
            .frame(width: 260, height: 630, alignment: .bottomLeading)
            .offset(x: finishedOpen ? 14 : 24, y: 0)
        }
    }

    func finishedRow(_ r: Routine) -> some View {
        Button {
            pick(r.id)
        } label: {
            HStack(spacing: 9) {
                finishedCheck(16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.7)).lineLimit(1)
                    Text(Routines.finishedLine(r)).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.42)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(WorldLook.cream.opacity(sel == r.id ? 0.08 : 0)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Calm grey with a check: done on purpose.
    func finishedCheck(_ size: CGFloat) -> some View {
        Circle().fill(WorldLook.cream.opacity(0.16)).frame(width: size, height: size)
            .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(WorldLook.cream.opacity(0.62)))
    }

    func finishedCard(_ r: Routine, now: Date) -> some View {
        let reports = Routines.reports(r.id)
        return cardShell(orange: false) {
            eyebrow("Finished", dot: WorldLook.cream.opacity(0.4))
            Text(r.title).font(.system(size: 15, weight: .semibold)).padding(.top, 9).fixedSize(horizontal: false, vertical: true)
            Text(Routines.finishedWhy(r)).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.6)).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1).padding(.vertical, 11)
            VStack(alignment: .leading, spacing: 8) {
                fact("Finished", r.lastRun.map { Routines.stamp($0, now: now) } ?? "Yes")
                fact("Ran", r.runs == 1 ? "Once" : "\(r.runs) times", color: WorldLook.cream.opacity(0.85))
                if r.lastFailed { fact("Last run", "Didn't work", color: Color(hex: 0xF6B46E)) }
                fact("How often", r.often)
                reportsFact(reports, now: now)
            }
            if renewAsk == r.id {
                Text(Routines.renewQuestion(r)).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.8)).padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    pill("Yes, run it again", filled: true) { Task { await renewNow(r) } }
                    pill("Not now") { renewAsk = nil }
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 6) {
                    pill("Run again", filled: true) {
                        note = nil
                        renewAsk = r.id
                    }
                    pill("Ask \(m.name)") {
                        ask("Tell me about my finished routine “\(r.title)”: what it found over its runs, and whether it's worth running again.")
                    }
                }
                .padding(.top, 14)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.6)).padding(.top, 8).fixedSize(
                    horizontal: false, vertical: true)
            }
            if renewHelp == r.id {
                pill("Ask \(m.name) to do it") {
                    renewHelp = nil
                    ask(
                        "Please set up my finished routine “\(r.title)” (id \(r.id)) to run again: same instructions, schedule and settings, "
                            + (r.once ? "once more, now." : "for another \(r.runs) runs.")
                            + " The Routines screen couldn't do it by itself. I've already said yes.")
                }
                .padding(.top, 8)
            }
        }
    }

    /// Its past reports: the newest few, each opens in One's reader.
    @ViewBuilder func reportsFact(_ reports: [(at: Date, file: URL)], now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Reports").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.45)).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if reports.isEmpty { Text("None kept").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.6)) }
                ForEach(Array(reports.prefix(4).enumerated()), id: \.offset) { _, rp in
                    Button {
                        m.routinesOpen = false
                        m.viewing = rp.file
                    } label: {
                        Text(Routines.stamp(rp.at, now: now)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(
                            WorldLook.cream.opacity(0.85)
                        )
                        .underline(color: WorldLook.cream.opacity(0.3))
                    }.buttonStyle(.plain).help("Read this report")
                }
                if reports.count > 4 {
                    Text("and \(reports.count - 4) earlier").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.4))
                }
            }
        }
    }

    func renewNow(_ r: Routine) async {
        busy = true
        note = "Setting it up again…"
        let ok = await Routines.renew(r.id)
        renewAsk = nil
        busy = false
        snap = await Task.detached { Routines.load() }.value
        guard ok else {
            // The engine can refuse to set a routine up again by itself (its safety check can't read a file the
            // instructions name). The yes is already given: hand it to the assistant, who can sort that out.
            note = "I couldn't set it up again by myself."
            renewHelp = r.id
            return
        }
        note = r.once ? "It runs now. Its result shows up here." : "It's back on your dial."
        // Open its card on the dial (a one-shot keeps its id; a renewed routine comes back under a new one).
        sel = snap.routines.first { $0.title == r.title && $0.state != .finished }?.id ?? sel
    }
}
