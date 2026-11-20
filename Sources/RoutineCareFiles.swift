import Foundation

// MARK: - Routines that fix themselves: files, the command and carrying it out (RoutineCare.swift)

extension RoutineCare {

    static func hasAll(_ cookies: [String: String], _ n: Need) -> Bool {
        n.cookies.allSatisfy { !(cookies[$0] ?? "").isEmpty }
    }

    static func isAsk(_ id: String) -> Bool { id.hasPrefix(askPrefix) }

    static func load() -> State {
        guard let d = try? Data(contentsOf: stateFile) else { return State() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(State.self, from: d)) ?? State()
    }

    static func save(_ s: State) {
        var s = s
        s.blockers.removeAll { ($0.cleared.map { Date().timeIntervalSince($0) > 8 * 86400 }) ?? false }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: stateFile, options: .atomic)
    }

    static func needs() -> [String: [Need]] {
        guard let d = try? Data(contentsOf: needsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [Need]].self, from: d)) ?? [:]
    }

    static func record(_ e: Event) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(e) else { return }
        append(String(decoding: d, as: UTF8.self) + "\n", to: logFile)
    }

    static func events() -> [Event] {
        guard let t = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return t.split(separator: "\n").compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }
    }

    static func append(_ s: String, to f: URL) {
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? s.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    /// `One --routine-care block|clear …` from a fixer: left for the app's next step.
    static func inbox(_ args: [String]) {
        guard let verb = args.first else { return }
        var item: [String: String] = ["do": verb]
        var k = 1
        if verb == "block", args.count > 1, !args[1].hasPrefix("--") {
            item["job"] = args[1]
            k = 2
        }
        while k < args.count {
            if args[k].hasPrefix("--"), k + 1 < args.count {
                item[String(args[k].dropFirst(2))] = args[k + 1]
                k += 2
            } else {
                if verb == "clear" { item["site"] = args[k] }
                k += 1
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { return }
        append(String(decoding: d, as: UTF8.self) + "\n", to: inboxFile)
    }

    static func takeInbox() -> [[String: String]] {
        guard let t = try? String(contentsOf: inboxFile, encoding: .utf8), !t.isEmpty else { return [] }
        try? FileManager.default.removeItem(at: inboxFile)
        return t.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String] }
    }

    /// `One --routine-care need|block|clear|week|status`. Nil when it's not this command.
    static func cli(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--routine-care") else { return nil }
        let rest = Array(args[(k + 1)...])
        switch rest.first ?? "status" {
        case "need":
            guard rest.count >= 5, let port = Int(rest[3]) else {
                print("usage: One --routine-care need <job id> <site> <port> <cookie,cookie> [login page]")
                return 2
            }
            var all = needs()
            let n = Need(
                site: rest[2].lowercased(), port: port, cookies: rest[4].split(separator: ",").map(String.init), login: rest.count > 5 ? rest[5] : nil
            )
            all[rest[1], default: []].removeAll { $0.key == n.key }
            all[rest[1], default: []].append(n)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let d = try? enc.encode(all), (try? d.write(to: needsFile, options: .atomic)) != nil else { return 1 }
            print("ok: \(rest[1]) needs \(n.site) on \(n.port) (\(n.cookies.joined(separator: ", ")))")
            return 0
        case "block", "clear":
            inbox(rest)
            print("ok: One takes it from here within a minute")
            return 0
        case "week":
            print(weekLine(events(), now: Date()))
            return 0
        default:
            let s = load()
            if s.open.isEmpty { print("nothing waiting on you") }
            for b in s.open { print("\(title(b)): \(b.routines.count) routine(s) waiting since \(b.opened)") }
            return 0
        }
    }

    // MARK: carrying it out (what doesn't need One's window)

    /// The hand-off request for a blocker's window (HumanStep reads it): Show me the window, and the phone's link.
    static func request(_ b: Blocker, target: String, n: Int) -> [String: Any] {
        [
            "id": askID(b, n: n), "created": Date().timeIntervalSince1970, "site": b.site, "kind": b.kind == "yes" ? "approve" : b.kind,
            "port": b.port, "target_id": target, "url": b.login ?? "https://\(b.site)/", "title": "your routines",
            "line": title(b) + ". Tap Show me the window to sign in; I'll catch your routines up after.", "session": "",
        ]
    }

    static func askID(_ b: Blocker, n: Int) -> String {
        askPrefix + b.key.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) } + "-\(n)"
    }

    /// Writes the ask (replacing the blocker's older one) and sends the pings; the rest goes to the doer.
    static func perform(_ effects: [Effect], state: State, doer: Doer, now: Date) {
        for e in effects {
            switch e.kind {
            case "ask":
                guard let b = state.blockers.first(where: { $0.key == e.blocker }) else { continue }
                writeAsk(b, target: doer.target(b) ?? "")
            case "ping": _ = Messenger.send(e.text, to: Messenger.botChat + ":")
            case "pause", "resume": doer.cron(["cron", e.kind, e.job])
            case "run": doer.cron(["cron", "run", e.job])
            case "fixer": doer.fixer(e.blocker, e.text)
            case "say": doer.say(e.text)
            default: continue
            }
        }
        // A cleared blocker's ask goes.
        for b in state.blockers where b.cleared != nil { removeAsks(b) }
    }

    static func writeAsk(_ b: Blocker, target: String) {
        let j = request(b, target: target, n: b.asks)
        removeAsks(b, except: j["id"] as? String)
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? FileManager.default.createDirectory(at: HumanStep.dir, withIntermediateDirectories: true)
        try? d.write(to: HumanStep.dir.appendingPathComponent("\(j["id"] as? String ?? "").request.json"), options: .atomic)
    }

    /// The blocker's earlier asks no one answered: answered as "replaced" so the card and the phone link go.
    static func removeAsks(_ b: Blocker, except keep: String? = nil) {
        let prefix = String(askID(b, n: 0).dropLast(1))
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: HumanStep.dir.path)) ?? [] where n.hasPrefix(prefix) && n.hasSuffix(".request.json") {
            let id = String(n.dropLast(".request.json".count))
            if id == keep { continue }
            if !fm.fileExists(atPath: HumanStep.dir.appendingPathComponent("\(id).answer.json").path) { HumanStep.answer(id, "replaced") }
        }
    }

    /// The cookies of `n.site` in the browser on `n.port` (read only). Nil when it doesn't answer.
    static func signedIn(_ n: Need) async -> Bool? {
        if let s = standIn { return s(n) }
        guard let ws = BrowserKeeper.version(n.port)?["webSocketDebuggerUrl"] as? String, let u = URL(string: ws) else { return nil }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: u)
        task.maximumMessageSize = 32 << 20
        task.resume()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        guard let got = await HumanCheck.cdpCall(task, id: 1, "Storage.getCookies"), let all = got["cookies"] as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSince1970
        var mine: [String: String] = [:]
        for c in all {
            guard let name = c["name"] as? String, let domain = (c["domain"] as? String)?.lowercased() else { continue }
            let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard d == n.site || d.hasSuffix("." + n.site) else { continue }
            if let exp = c["expires"] as? Double, exp > 0, exp < now { continue }
            mine[name] = c["value"] as? String ?? ""
        }
        return hasAll(mine, n)
    }

    nonisolated(unsafe) static var standIn: ((Need) -> Bool?)?

    /// The routines as the step reads them, from `cron/jobs.json`. Call off the main thread.
    static func liveJobs(at cron: URL = Routines.cron) -> [Job] {
        guard let d = try? Data(contentsOf: cron.appendingPathComponent("jobs.json")), let top = try? JSONSerialization.jsonObject(with: d)
        else { return [] }
        let list = (top as? [String: Any])?["jobs"] as? [[String: Any]] ?? top as? [[String: Any]] ?? []
        return list.compactMap { j in Job(j, out: (j["id"] as? String).map { cron.appendingPathComponent("output/\($0)") }) }
    }

    /// A routine's report that stays out of the chat: an open blocker already holds it (no repeat noise).
    static func hushed(job: String, body: String) -> Bool {
        let s = load()
        guard !s.open.isEmpty else { return false }
        let j = Job(["id": job, "last_error": body], out: nil)
        return s.open.contains { b in j.map { covers(b, $0, needs: needs()) } ?? false }
    }

    /// The open blocker's ask should be written again: it's missing or aging out (HumanStep shows a request for an
    /// hour). Never when they answered this one (it comes back at the next reminder).
    static func askStale(_ b: Blocker) -> Bool {
        let id = askID(b, n: b.asks)
        let fm = FileManager.default
        let req = HumanStep.dir.appendingPathComponent("\(id).request.json")
        if fm.fileExists(atPath: HumanStep.dir.appendingPathComponent("\(id).answer.json").path) { return false }
        if let a = try? fm.attributesOfItem(atPath: req.path), let m = a[.modificationDate] as? Date, Date().timeIntervalSince(m) < 1800 {
            return false
        }
        return true
    }

    /// 10 PM to 8 AM: the item stays on screen, but nothing goes to the phone.
    static func quiet(_ now: Date = Date()) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        return h >= 22 || h < 8
    }
}
