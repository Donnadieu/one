import Foundation

// MARK: - The collector's other sources: One's own logs and files (read only)
// Stops, redos and Undo taps (corrections the person made without words), helpers picked back up, routine
// reports, steps only the person could do, engine shutdowns, and health warnings about notes, skills and routines.

/// A helper job as One's learning file knows it: its engine conversation and title.
struct ImproveJob {
    var helper: String
    var session: String
    var title: String
    var started: Double
}

enum ImproveFiles {
    static func lines(_ u: URL) -> [Substring] {
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return t.split(separator: "\n")
    }
    static func utc(_ s: Substring) -> Double? {
        ISO8601DateFormatter().date(from: String(s)).map(\.timeIntervalSince1970)
    }
    static func groups(_ line: Substring, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let s = String(line)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    /// Helper jobs One started (`learning.json`): helper id → conversation and title.
    static func jobs() -> [ImproveJob] {
        let f = Env.support.appendingPathComponent(Env.selfTest ? "selftest-learning.json" : "learning.json")
        guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
            let list = j["jobs"] as? [[String: Any]]
        else { return [] }
        let iso = ISO8601DateFormatter()
        return list.compactMap { r in
            guard let s = r["session"] as? String, let k = r["kind"] as? String else { return nil }
            let t = (r["started"] as? String).flatMap { iso.date(from: $0) }?.timeIntervalSince1970 ?? 0
            return ImproveJob(helper: (r["helper"] as? String) ?? "", session: s, title: k, started: t)
        }
    }
    /// The conversation of the latest job with this title started before `ts`.
    static func session(title: String, before ts: Double, _ jobs: [ImproveJob]) -> String? {
        jobs.filter { $0.title == title && $0.started <= ts + 60 }.max { $0.started < $1.started }?.session
    }

    /// Everything from One's own files between `from` and `to` (Unix seconds).
    static func events(from: Double, to: Double, jobs: [ImproveJob]) -> [ImproveEvent] {
        var out: [ImproveEvent] = []
        let inside = { (t: Double) in t >= from && t < to }
        let logs = Env.hermesHome.appendingPathComponent("logs", isDirectory: true)
        let byHelper = Dictionary(jobs.map { ($0.helper.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Helpers the person stopped (trail ends "Stopped by you").
        let trails = Env.support.appendingPathComponent("helpers", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: trails.path)) ?? [] where name.hasSuffix(".md") {
            let u = trails.appendingPathComponent(name)
            guard let t = try? String(contentsOf: u, encoding: .utf8), t.contains("\n- \(stoppedLine)") else { continue }
            let at = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            guard inside(at) else { continue }
            let title = t.split(separator: "\n").first.map { String($0.drop { $0 == "#" || $0 == " " }) }
            let job = byHelper[String(name.dropLast(3)).uppercased()]
            out.append(ImproveEvent("correction", "stopped", at: at, session: job?.session, title: job?.title ?? title, place: "helper"))
        }
        // The same job sent again within 2 hours (smart routing's redo): the earlier job didn't work.
        for l in lines(logs.appendingPathComponent("one-routing.log")) {
            guard let g = groups(l, #"^(\S+Z) redo: "(.*)" looks like "(.*)" sent again"#), let t = utc(Substring(g[1])), inside(t) else { continue }
            out.append(
                ImproveEvent(
                    "correction", "redo", at: t, session: session(title: g[3], before: t, jobs), title: g[3], place: "helper",
                    quote: "sent again as \"\(g[2])\""))
        }
        // Undo tapped on something it learned (one event per skill per minute; the rollback logs each change).
        var undone = Set<String>()
        for l in lines(logs.appendingPathComponent("one-learning.log")) {
            guard let g = groups(l, #"^(\S+Z) undo (?:room skill )?(\S+)"#), let t = utc(Substring(g[1])), inside(t) else { continue }
            let k = "\(g[2]) \(Int(t / 60))"
            if undone.insert(k).inserted { out.append(ImproveEvent("correction", "undo", at: t, quote: "Undo on the skill \(g[2])")) }
        }
        // Helpers stopped by an error. (Helpers picked back up are read from the engine's history, where One's own
        // "You were interrupted by a restart" note sits in the conversation itself: the guard's log repeats one pick-up
        // for every engine that saw it.)
        for l in lines(logs.appendingPathComponent("one-gateway-guard.log")) {
            guard let g = groups(l, #"^(\S+Z) (?:pid \d+ )?helper "(.*)" didn't finish \((.*)\): stopped$"#), let t = utc(Substring(g[1])), inside(t)
            else { continue }
            out.append(
                ImproveEvent(
                    "broke", "helper_failed", at: t, session: session(title: g[2], before: t, jobs), title: g[2], place: "helper", quote: g[3]))
        }
        // The engine stopping (each stop cuts off whatever was working).
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for l in lines(logs.appendingPathComponent("gateway.log")) where l.contains("Received SIGTERM") {
            guard let t = local.date(from: String(l.prefix(19)))?.timeIntervalSince1970, inside(t) else { continue }
            out.append(ImproveEvent("broke", "engine_stop", at: t))
        }
        out += handoffs(inside)
        out += routineReports(inside)
        return out
    }
    static let stoppedLine = "Stopped by you"

    /// Steps only the person could do (robot check, code, sign-in), from `handoff/*.request.json`.
    static func handoffs(_ inside: (Double) -> Bool) -> [ImproveEvent] {
        let dir = Env.support.appendingPathComponent("handoff", isDirectory: true)
        var out: [ImproveEvent] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".request.json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let t = j["created"] as? Double, inside(t)
            else { continue }
            let id = String(name.dropLast(".request.json".count))
            let answered = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).answer.json").path)
            let what = [(j["kind"] as? String) ?? "step", (j["site"] as? String).map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
            out.append(ImproveEvent("wall", answered ? "handoff_answered" : "handoff", at: t, quote: what))
        }
        return out
    }

    /// Routine reports that say "Not done:", "Partly done:" or carry the engine's failure mark.
    static func routineReports(_ inside: (Double) -> Bool) -> [ImproveEvent] {
        let root = Env.hermesHome.appendingPathComponent("cron/output", isDirectory: true)
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var out: [ImproveEvent] = []
        for job in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !job.hasPrefix(".") {
            let jd = root.appendingPathComponent(job, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: jd.path)) ?? [] where name.hasSuffix(".md") {
                guard let t = f.date(from: String(name.dropLast(3)))?.timeIntervalSince1970, inside(t),
                    let text = try? String(contentsOf: jd.appendingPathComponent(name), encoding: .utf8),
                    let r = text.range(of: "## Response")
                else { continue }
                let reply = text[r.upperBound...]
                let title = text.split(separator: "\n").first { $0.hasPrefix("# Cron Job:") }.map {
                    $0.dropFirst(11).trimmingCharacters(in: .whitespaces)
                }
                let line = { (mark: String) in reply.split(separator: "\n").first { $0.contains(mark) }.map(String.init) ?? mark }
                for (mark, sub) in [("Not done:", "routine_not_done"), ("Partly done:", "routine_partly"), ("[CRON_FAILURE]", "routine_failed")]
                where reply.contains(mark) {
                    out.append(ImproveEvent("broke", sub, at: t, title: title, place: "routine", quote: line(mark)))
                    break
                }
            }
        }
        return out
    }

    // MARK: Health (a snapshot of now, so only for today's file)

    static func capOf(_ key: String, in config: String, _ fallback: Int) -> Int {
        guard let g = groups(Substring(config), #"(?m)^\s*\#(key):\s*(\d+)"#), let n = Int(g[1]) else { return fallback }
        return n
    }

    static func health(now: Double) -> [ImproveEvent] {
        var out: [ImproveEvent] = []
        let home = Env.hermesHome
        let config = (try? String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for (file, key, fallback) in [("MEMORY.md", "memory_char_limit", 2200), ("USER.md", "user_char_limit", 1375)] {
            let cap = capOf(key, in: config, fallback)
            let n = (try? String(contentsOf: home.appendingPathComponent("memories/\(file)"), encoding: .utf8))?.count ?? 0
            if cap > 0, n * 10 >= cap * 9 {
                out.append(ImproveEvent("health", "notes_near_full", at: now, quote: "\(file) holds \(n) of \(cap) characters"))
            }
        }
        var names: [String: [String]] = [:]
        let roots =
            [home.appendingPathComponent("skills", isDirectory: true)] + LearnedDirs.wanted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        for root in roots.map({ $0.resolvingSymlinksInPath() }) { walk(root, root, &names, &out, now) }
        for (n, places) in names.sorted(by: { $0.key < $1.key }) where places.count > 1 {
            out.append(ImproveEvent("health", "skill_twice", at: now, quote: "\(n): " + places.joined(separator: " and ")))
        }
        if let d = try? Data(contentsOf: home.appendingPathComponent("cron/jobs.json")),
            let j = try? JSONSerialization.jsonObject(with: d)
        {
            let jobs = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["jobs"] as? [[String: Any]]) ?? []
            for r in jobs where (r["enabled"] as? Bool) != false {
                let status = (r["last_status"] as? String) ?? "ok"
                let err = r["last_error"] as? String
                guard status != "ok" || (err?.isEmpty == false) else { continue }
                out.append(
                    ImproveEvent(
                        "health", "routine_failing", at: now, title: r["name"] as? String, place: "routine", quote: err ?? "last run: \(status)"))
            }
        }
        return out
    }

    /// Walks a skills folder: oversize SKILL.md files, names seen twice, and folders linking back into themselves.
    static func walk(_ root: URL, _ dir: URL, _ names: inout [String: [String]], _ out: inout [ImproveEvent], _ now: Double, depth: Int = 0) {
        let fm = FileManager.default
        guard depth < 6, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return
        }
        for u in items where !u.lastPathComponent.hasPrefix(".") {
            let v = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if v?.isSymbolicLink == true {
                let to = u.resolvingSymlinksInPath().standardizedFileURL.path
                let here = dir.resolvingSymlinksInPath().standardizedFileURL.path
                if here == to || here.hasPrefix(to + "/") {
                    out.append(ImproveEvent("health", "link_loop", at: now, quote: "\(rel(u, root)) links back to its own folder"))
                }
                continue  // never follow links: a loop would make every skill look like thousands
            }
            if v?.isDirectory == true {
                walk(root, u, &names, &out, now, depth: depth + 1)
            } else if u.lastPathComponent == "SKILL.md" {
                let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
                let name = dir.lastPathComponent
                names[name, default: []].append(rel(dir, root))
                if size > 12 * 1024 {
                    out.append(ImproveEvent("health", "skill_too_big", at: now, title: name, quote: "\(name) is \(size / 1024) KB (limit 12 KB)"))
                }
            }
        }
    }
    static func rel(_ u: URL, _ root: URL) -> String {
        let p = u.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }
}
