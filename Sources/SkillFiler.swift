import Foundation

// MARK: - The recipe filer (storage plan 3e)
// The engine always saves a new recipe (skill) into its own folder, `hermes/skills/<category>/<name>/`. That folder
// is for built-ins only and isn't part of the brain. Right after a save (when nothing is working), at launch and at
// night, One moves each NEW recipe the assistant made into the brain: the room its job belonged to
// (`<room>/skills/<name>/`, flat), a private room's own `skills/<name>/` for a job in that private room, or
// `My Brain/assistant/skills/<name>/` when the job had no clear room. Never a shared room's (left where it is, logged).
// Never: built-ins (the engine's or One's), `my-connections/` (ExperimentalGuard), archived or gone skills, a name
// already in use where it would go. Every move is logged (`hermes/logs/one-skill-filer.log`), recorded in
// `<support>/skill-filer.json` and undoable (`One --file-skills undo <name>`).
// Why not the engine's `skills.create_dir` (new skills saved straight into the brain): the engine's one-step
// rollback refuses any path outside its own home, so One's Undo after "I just learned…" would stop working, and the
// curator only manages skills in its own folder. The filer keeps both, and moves only once the save settled.

struct FiledSkill: Codable {
    var name: String
    var from: String  // the folder it left, in the engine's skills folder
    var to: String  // where it is now
    var room: String  // the room folder's name, or "assistant"
    var ledger: String
    var date: Date
}

struct FilerState: Codable {
    var started = false
    var handled: [String] = []  // log lines decided for good: moved, or left on purpose
    var rooms: [String: String] = [:]  // log line → the room its job was in ("" = none), decided when first seen
    var filed: [FiledSkill] = []
    var undone: [String] = []  // moved back by hand: never moved again by itself
}

enum SkillFiler {
    static var file: URL { Env.support.appendingPathComponent(Env.selfTest ? "selftest-skill-filer.json" : "skill-filer.json") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-skill-filer.log") }
    static var engineSkills: URL { Env.hermesHome.appendingPathComponent("skills", isDirectory: true) }
    static var assistantSkills: URL { Brain.root.appendingPathComponent("assistant/skills", isDirectory: true) }
    static let key = "skillFiler"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    /// First launch of a One with the filer: on for a new install, off for an existing one (turned on by hand).
    static func settleDefault(fresh: Bool) {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(fresh, forKey: key)
        log("filer \(fresh ? "on (new install)" : "off (existing install; One --file-skills on turns it on)")")
    }

    static func load() -> FilerState {
        guard let d = try? Data(contentsOf: file) else { return FilerState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(FilerState.self, from: d)) ?? FilerState()
    }
    static func save(_ s: FilerState) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: file, options: .atomic)
    }
    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
    static func std(_ u: URL) -> String { u.standardizedFileURL.path }
    static func inside(_ p: String, _ root: URL) -> Bool { p.hasPrefix(std(root) + "/") }

    // MARK: What it may touch

    /// Built-in names: the engine's (`.bundled_manifest`, hub installs) and One's own (`BundledSkills`).
    static func builtins() -> Set<String> {
        var out = Set<String>()
        let man = (try? String(contentsOf: engineSkills.appendingPathComponent(".bundled_manifest"), encoding: .utf8)) ?? ""
        for l in man.split(separator: "\n") {
            let n = l.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !n.isEmpty { out.insert(n) }
        }
        if let d = try? Data(contentsOf: BundledSkills.record), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for rel in j.keys { out.insert(URL(fileURLWithPath: rel).lastPathComponent) }
        }
        if let src = BundledSkills.source { for rel in BundledSkills.list(in: src) { out.insert(URL(fileURLWithPath: rel).lastPathComponent) } }
        if let d = try? Data(contentsOf: engineSkills.appendingPathComponent(".hub/lock.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let inst = j["installed"] as? [String: Any]
        {
            out.formUnion(inst.keys)
        }
        return out
    }

    /// A room is private when its room.yaml says so; without one, the personal and private rooms are.
    static func isPrivate(_ room: URL) -> Bool {
        if let y = try? String(contentsOf: room.appendingPathComponent("room.yaml"), encoding: .utf8) {
            for l in y.split(separator: "\n") where l.hasPrefix("private:") {
                return l.dropFirst(8).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("true")
            }
        }
        return ["personal-room", "private-room"].contains(room.lastPathComponent)
    }

    /// The room a job's words clearly point at (Router's claim; a private room named by its folder), or nil.
    static func room(for text: String?, rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        let local = rooms.filter { !LearnedDirs.isShared($0.path, shared) }
        if let key = Router.room(text) {
            if let r = local.first(where: { $0.lastPathComponent == "\(key)-room" }) { return r }
            if key == "cofounder" {
                return rooms.first { r in
                    let n = (Shared.info(r)?.title ?? r.lastPathComponent).lowercased().replacingOccurrences(of: "-", with: "")
                    return LearnedDirs.isShared(r.path, shared) && n.contains("cofounder")
                }
            }
            return nil
        }
        let t = text.lowercased()
        for r in local where isPrivate(r) {
            let base = r.lastPathComponent.replacingOccurrences(of: "-room", with: "")
            guard base.count >= 3, !["personal", "private"].contains(base) else { continue }
            if Router.has(t, "\\b\(NSRegularExpression.escapedPattern(for: base))\\b") { return r }
        }
        return nil
    }

    enum Dest {
        case move(URL, room: String)
        case leave(String)
    }

    /// Where a recipe made in `room` goes. Only into a folder the engine reads (LearnedDirs.wanted) or a private
    /// room's own `skills` (read in that room's chats only).
    static func destination(room: URL?, name: String, wanted: [String], shared: [String]) -> Dest {
        guard let room else { return .move(assistantSkills.appendingPathComponent(name, isDirectory: true), room: "assistant") }
        if LearnedDirs.isShared(room.path, shared) { return .leave("its job was in a shared room; never filed by itself") }
        if isPrivate(room) {
            return .move(room.appendingPathComponent("skills/\(name)", isDirectory: true), room: room.lastPathComponent)
        }
        let reads = Set(wanted.map { std(URL(fileURLWithPath: $0)) })  // "a//b" and "a/b" are the same folder
        for d in [room.appendingPathComponent("skills"), room.appendingPathComponent("skills/learned")] where reads.contains(std(d)) {
            return .move(d.appendingPathComponent(name, isDirectory: true), room: room.lastPathComponent)
        }
        return .leave("\(room.lastPathComponent)'s recipes folder isn't one the engine reads")
    }

    /// The skill folder a log line made, or why it stays where it is.
    static func source(_ l: LedgerLine, builtins: Set<String>, undone: [String]) -> (URL?, String?) {
        guard l.action == "create" else { return (nil, "not a new skill") }
        guard l.actor == "agent" || l.actor == "curator" else { return (nil, "made by hand (\(l.actor))") }
        guard let md = l.paths.first(where: { $0.hasSuffix("/SKILL.md") }) else { return (nil, "no SKILL.md in the log line") }
        let dir = URL(fileURLWithPath: md).deletingLastPathComponent()
        let p = std(dir)
        guard inside(p, engineSkills) else { return (nil, "not in the engine's skills folder") }
        let rel = String(p.dropFirst(std(engineSkills).count + 1))
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return (nil, "archived") }
        if rel.hasPrefix("my-connections/") { return (nil, "a my-connections skill (Connections manages those)") }
        if builtins.contains(l.skill) || builtins.contains(dir.lastPathComponent) { return (nil, "a built-in") }
        if undone.contains(dir.lastPathComponent) { return (nil, "moved back by hand before") }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) else { return (nil, "gone or archived") }
        return (dir, nil)
    }

    /// Every SKILL.md folder named `name` one level under each of `dirs`, and anywhere under the engine's folder.
    static func others(named name: String, in dirs: [String], except: URL) -> [String] {
        let fm = FileManager.default
        var out = dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("\(name)/SKILL.md").path }.filter { fm.fileExists(atPath: $0) }
        out += BundledSkills.list(in: engineSkills).filter { URL(fileURLWithPath: $0).lastPathComponent == name && !$0.hasPrefix(".") }
            .map { engineSkills.appendingPathComponent($0).path }.filter { std(URL(fileURLWithPath: $0)) != std(except) }
        return out
    }

    // MARK: Filing

    private nonisolated(unsafe) static var lastStamp: [Double] = []
    private nonisolated(unsafe) static var waiting = false
    /// The log's size and time, to read it only when it changed (or a recipe waits for a quiet moment).
    static func stamp() -> [Double] {
        let a = try? FileManager.default.attributesOfItem(atPath: Learning.ledger.path)
        return [((a?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970, Double((a?[.size] as? Int) ?? 0)]
    }
    /// The last move of a recipe with this name, if it was filed.
    static func moved(_ name: String) -> FiledSkill? { load().filed.last { $0.name == name } }

    static func ledgerLines() -> [LedgerLine] {
        guard let t = try? String(contentsOf: Learning.ledger, encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap(LedgerLine.parse)
    }

    /// Files every new recipe it can. `jobText`: the words of the job a log line came from (nil = no known job).
    /// `busy`: something is working; decisions are noted, nothing moves. `settle`: skip a folder changed this recently.
    static func run(
        lines: [LedgerLine]? = nil, jobText: (LedgerLine) -> String?, busy: Bool, wanted: [String]? = nil, settle: TimeInterval = 0
    ) -> [FiledSkill] {
        if lines == nil {
            let now = stamp()
            if now == lastStamp && (!waiting || busy) { return [] }
            lastStamp = now
        }
        var s = load()
        let all = lines ?? ledgerLines()
        let creates = all.filter { $0.action == "create" }
        guard s.started else {
            s.started = true
            s.handled = creates.map(\.id)
            save(s)
            log("first look: \(creates.count) skill(s) already saved before the filer are left where they are")
            return []
        }
        var done = Set(s.handled)
        let fresh = creates.filter { !done.contains($0.id) }
        waiting = busy && !fresh.isEmpty
        guard !fresh.isEmpty else { return [] }
        let shared = Shared.paths
        for l in fresh where s.rooms[l.id] == nil { s.rooms[l.id] = room(for: jobText(l), shared: shared).map(std) ?? "" }
        defer {
            let inLog = Set(all.map(\.id))
            s.handled = done.filter { inLog.contains($0) }.sorted()
            s.rooms = s.rooms.filter { inLog.contains($0.key) && !done.contains($0.key) }
            save(s)
        }
        guard !busy else { return [] }
        let fm = FileManager.default
        let built = builtins()
        let want = wanted ?? LearnedDirs.wanted()
        var moved: [FiledSkill] = []
        for l in fresh {
            let (src, why) = source(l, builtins: built, undone: s.undone)
            guard let src else {
                done.insert(l.id)
                if why != "a built-in" { log("left \(l.skill) in the engine's folder: \(why ?? "")") }
                continue
            }
            if settle > 0, let m = (try? fm.attributesOfItem(atPath: src.appendingPathComponent("SKILL.md").path))?[.modificationDate] as? Date,
                Date().timeIntervalSince(m) < settle
            {
                continue  // still being written or used: next time
            }
            let roomPath = s.rooms[l.id] ?? ""
            let name = src.lastPathComponent
            switch destination(room: roomPath.isEmpty ? nil : URL(fileURLWithPath: roomPath), name: name, wanted: want, shared: shared) {
            case .leave(let reason):
                done.insert(l.id)
                log("left \(name) in the engine's folder: \(reason)")
            case .move(let to, let roomName):
                guard Brain.exists else { continue }
                let clash = (fm.fileExists(atPath: to.path) ? [to.path] : []) + others(named: name, in: want + [std(assistantSkills)], except: src)
                if !clash.isEmpty {
                    done.insert(l.id)
                    log("left \(name) in the engine's folder: the name is already used (\(clash.joined(separator: ", ")))")
                    continue
                }
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: to)
                } catch {
                    log("couldn't move \(name) (\(error.localizedDescription)); trying again later")
                    continue
                }
                done.insert(l.id)
                tidyEmpty(src.deletingLastPathComponent())
                let f = FiledSkill(name: name, from: src.path, to: to.path, room: roomName, ledger: l.id, date: Date())
                s.filed.append(f)
                moved.append(f)
                log("moved \(name): \(src.path) → \(to.path)")
            }
        }
        return moved
    }

    /// A category folder the move left empty goes too (never the engine's skills folder itself).
    static func tidyEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard inside(std(dir), engineSkills), let left = try? fm.contentsOfDirectory(atPath: dir.path),
            left.allSatisfy({ $0 == ".DS_Store" })
        else { return }
        try? fm.removeItem(at: dir)
    }

    /// Moves a filed recipe back to where the engine saved it.
    static func undo(_ name: String) -> (ok: Bool, text: String) {
        var s = load()
        guard let k = s.filed.lastIndex(where: { $0.name == name }) else { return (false, "\(name) wasn't moved by the filer") }
        let f = s.filed[k]
        let fm = FileManager.default
        guard fm.fileExists(atPath: f.to) else { return (false, "\(name) isn't at \(f.to) any more") }
        guard !fm.fileExists(atPath: f.from) else { return (false, "something is already at \(f.from)") }
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: f.from).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(atPath: f.to, toPath: f.from)
        } catch { return (false, "couldn't move \(name) back: \(error.localizedDescription)") }
        s.filed.remove(at: k)
        if !s.undone.contains(name) { s.undone.append(name) }
        save(s)
        log("undo \(name): \(f.to) → \(f.from)")
        return (true, "moved \(name) back to \(f.from)")
    }

    /// `One --file-skills [now|status|on|off|undo <name>]`.
    static func cli(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--file-skills") else { return nil }
        let what = k + 1 < args.count ? args[k + 1] : "status"
        switch what {
        case "on", "off":
            UserDefaults.standard.set(what == "on", forKey: key)
            log("filer turned \(what) (command line)")
            print("the recipe filer is \(what)")
        case "now":
            guard on else {
                print("the recipe filer is off (One --file-skills on)")
                return 1
            }
            // From the command line One can't see which turns are running: a folder changed in the last 10 minutes waits.
            let moved = run(jobText: { _ in nil }, busy: false, settle: 600)
            if moved.contains(where: { $0.room == "assistant" }) {
                let sem = DispatchSemaphore(value: 0)
                Task.detached {
                    await LearnedDirs.sync()
                    sem.signal()
                }
                sem.wait()
            }
            print(moved.isEmpty ? "nothing new to file" : moved.map { "\($0.name) → \($0.to)" }.joined(separator: "\n"))
        case "status":
            let s = load()
            print("the recipe filer is \(on ? "on" : "off")")
            for f in s.filed.suffix(20) { print("- \(f.name) → \(f.to)") }
            if !s.rooms.isEmpty { print("\(s.rooms.count) new skill(s) waiting for a quiet moment") }
        case "undo":
            guard k + 2 < args.count else {
                print("usage: One --file-skills undo <name>")
                return 2
            }
            let r = undo(args[k + 2])
            print(r.text)
            return r.ok ? 0 : 1
        default:
            print("usage: One --file-skills [now|status|on|off|undo <name>]")
            return 2
        }
        return 0
    }
}

// MARK: - In the app

@MainActor
extension Model {
    /// The words of the job a log line came from: a helper's title and job, or the main chat's job kind.
    func filerJobText(_ l: LedgerLine) -> String? {
        guard let chat = knownChat(l.session) else { return nil }
        if let h = helpers.first(where: { $0.sid == chat }) { return h.title + "\n" + h.task }
        if let j = learning.jobs.last(where: { $0.session == chat && $0.started.addingTimeInterval(-5) <= l.ts }) { return j.kind }
        return learnTurn.active ? bubbles.last { $0.fromMe }?.text : nil
    }

    /// Right after a new skill is logged (every few seconds, when nothing is working) and at launch.
    func tendFiler(launch: Bool = false) {
        guard SkillFiler.on, Brain.exists, onboarded || Env.selfTest else { return }
        let busy = !launch && (thinking || helpers.contains { $0.state == "working" })
        let moved = SkillFiler.run(jobText: filerJobText, busy: busy)
        guard !moved.isEmpty else { return }
        for f in moved {
            // "I just learned…" and its Undo now point at the moved recipe (Undo then puts it in the Trash).
            for k in learning.learned.indices where learning.learned[k].name == f.name && learning.learned[k].room == nil {
                learning.learned[k].room = f.room
                learning.learned[k].path = f.to + "/SKILL.md"
                if let c = learning.learned[k].card, let i = shelf.firstIndex(where: { $0.id == c }) { shelf[i].path = f.to + "/SKILL.md" }
            }
        }
        Learning.save(learning)
        if !launch { Task { await LearnedDirs.sync() } }
    }
}
