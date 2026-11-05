import Foundation

// MARK: - Each helper gets its own copy of a repo

/// When a new helper's job names a git repo (a path in the job text) that another helper is working in right now,
/// One gives the new helper its own copy: a git worktree next to the repo (`<repo>-<job>`, on its own branch
/// `helper/<job>-<id>`, from the repo's last saved state). The helper is told to work only there. When its orb is
/// taken off the screen (or at the next launch, if One closed first), the copy goes: a clean copy is removed, and
/// its branch too if nothing was saved on it; a copy with unsaved changes is kept and logged, never deleted.
/// Copies are listed in `Support/One/helper-copies.json`. Repos inside the brain or One's own data are never copied.
enum HelperRepos {
    struct Copy: Codable, Equatable {
        var helper: String  // the helper's id
        var repo: String  // the original repo's root
        var path: String  // the copy
        var branch: String
        var base: String  // the commit it started from
    }
    static var file: URL { Env.support.appendingPathComponent("helper-copies.json") }
    static var git: String { "/usr/bin/git" }

    // MARK: Which repos a job names

    /// The git repos a job names by path (`~/Repos/forge`, `/Users/x/Repos/one`, quoted paths with spaces),
    /// each as its root folder. Never the brain or One's own data (except `work/`, where helpers clone things).
    static func repos(in text: String) -> [String] {
        let home = NSHomeDirectory()
        var found: [String] = []
        let patterns = [#"["'`]((?:~|\$HOME|/)[^"'`\n]+)["'`]"#, #"(?:^|[\s(\[:=])((?:~|\$HOME|/)[^\s"'`),;\]]*)"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                var path = String(text[r]).replacingOccurrences(of: "$HOME", with: home)
                if path.hasPrefix("~") { path = home + path.dropFirst() }
                while let c = path.last, ".,:;!?)]}".contains(c) { path.removeLast() }
                if let root = root(of: path), !found.contains(root), allowed(root) { found.append(root) }
            }
        }
        return found
    }

    /// The nearest folder at or above `path` that holds `.git`. The home folder itself never counts.
    static func root(of path: String) -> String? {
        let fm = FileManager.default
        var u = URL(fileURLWithPath: norm(path))
        let home = norm(NSHomeDirectory())
        for _ in 0..<12 {
            let p = u.path
            if p == home || p == "/" { return nil }
            if fm.fileExists(atPath: p + "/.git") { return p }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    static func allowed(_ path: String) -> Bool {
        let root = norm(path)
        let brain = norm(Brain.root.path)
        let support = norm(Env.support.path)
        if root == brain || root.hasPrefix(brain + "/") { return false }
        if root.hasPrefix(support + "/") && !root.hasPrefix(support + "/work/") { return false }
        return true
    }

    // MARK: Making and removing copies

    /// A new worktree of `repo` for this helper. Nil if git said no (the helper then works as before).
    static func make(repo: String, title: String, helper: UUID) -> Copy? {
        let slug = slugOf(title)
        let short = String(helper.uuidString.prefix(4)).lowercased()
        let parent = (repo as NSString).deletingLastPathComponent
        let name = (repo as NSString).lastPathComponent
        var path = "\(parent)/\(name)-\(slug)"
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = "\(parent)/\(name)-\(slug)-\(n)"
            n += 1
        }
        let branch = "helper/\(slug)-\(short)"
        guard let base = run(["-C", repo, "rev-parse", "HEAD"]).out, !base.isEmpty else { return nil }
        let add = run(["-C", repo, "worktree", "add", "-b", branch, path, base])
        guard add.ok, FileManager.default.fileExists(atPath: path) else {
            log("couldn't make a copy of \(repo) for \"\(title)\": \(add.err.prefix(200))")
            return nil
        }
        let c = Copy(helper: helper.uuidString, repo: repo, path: path, branch: branch, base: base)
        save(load() + [c])
        log("\"\(title)\" got its own copy of \(repo): \(path) (branch \(branch))")
        return c
    }

    /// The helper is gone: remove its copies that hold nothing unsaved. Returns what was kept.
    @discardableResult static func release(helper: String) -> [Copy] {
        var keep: [Copy] = []
        var kept: [Copy] = []
        for c in load() {
            guard c.helper == helper else {
                keep.append(c)
                continue
            }
            if !remove(c) {
                keep.append(c)
                kept.append(c)
            }
        }
        save(keep)
        return kept
    }

    /// At launch: copies whose helper is no longer on the screen.
    static func sweep(alive: Set<String>) {
        for h in Set(load().map(\.helper)) where !alive.contains(h) { release(helper: h) }
    }

    /// True when the copy is gone (or was already). A copy with unsaved changes stays.
    static func remove(_ c: Copy) -> Bool {
        if FileManager.default.fileExists(atPath: c.path) {
            let st = run(["-C", c.path, "status", "--porcelain"])
            guard st.ok, (st.out ?? "x").isEmpty else {
                log("kept \(c.path): it has unsaved changes")
                return false
            }
            let rm = run(["-C", c.repo, "worktree", "remove", c.path])
            guard rm.ok else {
                log("couldn't remove \(c.path): \(rm.err.prefix(200))")
                return false
            }
        }
        _ = run(["-C", c.repo, "worktree", "prune"])
        // Nothing saved on its branch: the branch goes too. Saved work stays on the branch, in the repo.
        if run(["-C", c.repo, "rev-list", "--count", "\(c.base)..\(c.branch)"]).out == "0" {
            _ = run(["-C", c.repo, "branch", "-D", c.branch])
            log("removed \(c.path) and its empty branch \(c.branch)")
        } else {
            log("removed \(c.path); its saved work stays on branch \(c.branch) in \(c.repo)")
        }
        return true
    }

    // MARK: What the helper is told

    static func note(_ copies: [(copy: Copy, other: String)]) -> String {
        guard !copies.isEmpty else { return "" }
        let home = NSHomeDirectory()
        func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        let lines = copies.map { c in
            "- \(tilde(c.copy.repo)) is in use by the helper \"\(c.other)\". Your own copy: \(tilde(c.copy.path)) "
                + "(branch \(c.copy.branch), from commit \(c.copy.base.prefix(8)), the repo's last saved state)."
        }
        return "\n\n(One app note, not from the user: YOUR OWN COPY. Another helper is working in the same project right now, so One "
            + "made you your own copy (a git worktree) to work in:\n" + lines.joined(separator: "\n")
            + "\nDo all your work, builds and commits in your copy, never in the original folder, and don't switch branches there. "
            + "To share your work, push your branch or merge it the way the project usually does. One removes the copy when "
            + "they're done with you; anything not committed is kept.)"
    }

    // MARK: Helpers

    /// One spelling per folder (symlinks resolved, `/private/var` read as `/var`), so the same repo always matches.
    static func norm(_ p: String) -> String { ((p as NSString).standardizingPath as NSString).resolvingSymlinksInPath }
    static func slugOf(_ title: String) -> String {
        let s = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").prefix(4).joined(separator: "-")
        return joined.isEmpty ? "helper" : String(joined.prefix(30))
    }
    static func load() -> [Copy] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Copy].self, from: d)) ?? []
    }
    static func save(_ v: [Copy]) {
        if v.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: file, options: .atomic) }
    }
    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-helpers.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) copies: \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
    /// Runs git (outside the folder lock: One itself). 30 s at most.
    static func run(_ args: [String]) -> (ok: Bool, out: String?, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let o = Pipe()
        let e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (false, nil, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out, err)
    }
}
