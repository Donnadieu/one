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

// Finished routines sit in their own quiet constellation (RoutinesSky.swift); a picked one opens in place (RoutinesSkyActions.swift).
extension RoutinesPanel {
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
        await reload()
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
