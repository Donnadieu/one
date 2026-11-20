import Foundation

// MARK: - Routines that fix themselves: the words (RoutineCare.swift)

extension RoutineCare {

    static func siteName(_ site: String) -> String {
        let s = site.lowercased()
        if s == "x.com" || s == "twitter.com" { return "X" }
        let base = s.split(separator: ".").dropLast().last.map(String.init) ?? s
        return base.capitalizedFirst
    }

    static func short(_ title: String) -> String {
        let w = title.split(separator: " ")
        return w.count <= 3 ? title : w.prefix(3).joined(separator: " ")
    }

    static func blockCause(_ b: Blocker) -> String {
        b.kind == "sign_in" ? "\(siteName(b.site)) signed out" : "\(siteName(b.site)) needs you"
    }

    /// A run's own words, sorted into a short cause for the weekly line.
    static func cause(_ text: String) -> String {
        let t = text.lowercased()
        let x = t.contains("x.com") || text.range(of: "\\bX\\b", options: .regularExpression) != nil ? "X " : ""
        if signedOutWords.contains(where: { t.contains($0) }) { return "\(x)signed out".capitalizedFirst }
        if t.contains("rate limit") || t.contains("rate-limit") { return "\(x)rate limit".capitalizedFirst }
        if t.contains("not answering") || t.contains("isn't answering") { return "Browser not answering" }
        if t.contains("interrupted") || t.contains("cut off") || t.contains("restart") { return "Cut off by a restart" }
        if t.contains("credit") || t.contains("limit") { return "AI account limit" }
        return "Other"
    }

    static func titles(_ b: Blocker, byID: [String: Job]) -> [String] { b.routines.compactMap { byID[$0]?.title } }

    static func waiting(_ b: Blocker, byID: [String: Job]) -> String {
        let t = titles(b, byID: byID)
        if t.count == 1 { return "“\(t[0])” is" }
        return t.isEmpty ? "your routines are" : "\(t.count) routines are"
    }

    /// The needs-you item's first line.
    static func title(_ b: Blocker) -> String {
        b.kind == "sign_in" ? "\(siteName(b.site)) signed out of the hidden browser" : "\(siteName(b.site)) needs you for one step"
    }

    static func missedCount(_ b: Blocker) -> Int { b.missed.values.reduce(0) { $0 + $1.count } }

    /// The needs-you item's second line.
    static func detail(_ b: Blocker, byID: [String: Job]) -> String {
        let n = missedCount(b)
        let what = b.kind == "sign_in" ? "Sign in once in the window" : "Do this one step in the window"
        return "\(waiting(b, byID: byID).capitalizedFirst) paused until then. \(what) and I'll turn them back on"
            + (n == 0 ? "." : " and catch up \(n == 1 ? "the run" : "the \(n) runs") they missed.")
    }

    static func phoneLine(_ b: Blocker, byID: [String: Job]) -> String {
        let what = b.kind == "sign_in" ? "needs you to sign in again" : "needs you for one step"
        return "\(siteName(b.site)) \(what), so \(waiting(b, byID: byID)) paused. Open One and tap Show me the window; "
            + "I'll turn them back on and catch up after."
    }

    static func reminderLine(_ b: Blocker, byID: [String: Job]) -> String {
        "Still waiting on you: " + phoneLine(b, byID: byID)
    }

    /// What the fixer helper is asked to do.
    static func fixerBrief(_ j: Job, blocker: Blocker?) -> String {
        let home = Env.hermesHome.path
        var t =
            "Fix the routine “\(j.title)” (job \(j.id)): its last run failed"
            + (j.lastRun.map { " at " + Routines.stamp($0, now: Date()) } ?? "") + ". Its own words: \(j.why.isEmpty ? "none" : j.why)\n"
            + "Nobody is at the Mac to ask, so do it yourself and never ask in the chat.\n"
            + "1. Diagnose from the records, not the run's own excuse (load the one-scheduled-jobs skill): \(home)/cron/jobs.json, "
            + "\(home)/cron/output/\(j.id)/, \(home)/cron/steps/\(j.id).jsonl and its session in state.db.\n"
            + "2. Try every fix that needs nobody: re-check the sign-ins it uses (`One --browser-check`, and browser_vault find_session "
            + "for the site across One's hidden browsers; never port 9333). When the cause looks passing (a rate limit, the network, "
            + "a browser not answering, a run cut off by a restart or sleep), retry once with a backoff: wait 2 minutes, or an hour "
            + "for a rate limit, and only while it's still the same day; never run `One --connect-chrome`, never sign in with a "
            + "password form, never restart One or a browser.\n"
            + "3. If it's fixed, make up the missed run once: `hermes cron run \(j.id)` in the background (terminal background=true, "
            + "notify=true, output to a log file; it runs the whole job), within its daily limits, never repeating what already "
            + "went out, and not when its next run is less than an hour away.\n"
            + "4. If only Omar can fix it (a sign-in, a code, a robot check, a yes), don't ask him yourself: run "
            + "`One --routine-care block \(j.id) --site <site> --kind <sign_in|code|check|approve|yes> --why \"<one plain line>\"`. "
            + "One shows him one needs-you item with Show me the window, tells his phone, reminds him, and catches the routine up "
            + "once it's done. Then stop.\n"
            + "5. Answer in two short lines: the cause, and what you did (fixed and caught up, waiting on Omar, or couldn't fix and why)."
        if let b = blocker {
            t += "\nOne already put up a needs-you item for this: \(b.why). If you get it working without him, the item clears by itself."
        }
        return t
    }

    // MARK: the weekly health line

    static func duration(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h" + (m % 60 == 0 ? "" : " \(m % 60) min")
    }

    static func weekLine(_ all: [Event], now: Date) -> String {
        let e = all.filter { now.timeIntervalSince($0.at) <= 7 * 86400 && $0.at <= now.addingTimeInterval(60) }
        let fails = e.filter { $0.kind == "failed" || $0.kind == "skipped" }
        guard !fails.isEmpty else { return "Routines this week: no failures." }
        var causes: [String: Int] = [:]
        for f in fails { causes[f.cause, default: 0] += 1 }
        let list = causes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        var line = "Routines this week: \(fails.count) failed run\(fails.count == 1 ? "" : "s") (\(list.joined(separator: ", ")))."
        let fixes = e.filter { $0.kind == "cleared" || $0.kind == "fixed" }.compactMap(\.minutes)
        if !fixes.isEmpty {
            let avg = fixes.reduce(0, +) / fixes.count
            line += " Time to fix: \(duration(avg)) on average" + (fixes.count > 1 ? ", longest \(duration(fixes.max() ?? avg))." : ".")
        }
        let caught = e.filter { $0.kind == "caught_up" }.count
        if caught > 0 { line += " \(caught) missed run\(caught == 1 ? "" : "s") caught up." }
        return line
    }

    /// For a good morning or status report: the week's line, to put in the report as it is.
    static func weekNote(_ typed: String, now: Date = Date()) -> String {
        guard Helpers.isRoutine(typed) else { return "" }
        return "\n\n(One app note, not from the user: ROUTINE HEALTH. Put this line in the report as it is: "
            + weekLine(events(), now: now) + ")"
    }

    /// Every prompt: a routine that needs a site's sign-in says so, so One can check it before it runs.
    static var note: String {
        "\n\n(One app note, not from the user: ROUTINE SIGN-INS. When you set up a routine that needs a site's sign-in in a hidden "
            + "browser, declare it once: `One --routine-care need <job id> <site> <port> <cookie,cookie> [login page]` (for X on 9224: "
            + "`x.com 9224 auth_token,ct0,twid https://x.com/i/flow/login`). One then checks it an hour before each run and asks "
            + "them itself if it's missing; a routine never asks.)"
    }

}
