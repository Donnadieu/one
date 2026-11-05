import Foundation

// MARK: - The shortcut guard (storage design 3c item 7)
//
// On Nov 4 2026 a chat that faked HOME made shortcuts (symbolic links) inside One's engine folder that pointed back
// at themselves (`skills/skills -> skills`), and `google_client_secret.json` became a link to itself. The engine read
// every skill about 33 times and Google sign-in lost its file. At every launch, before the engine starts, One walks
// its engine home and the brain WITHOUT following links, removes any link that points to itself or to one of its own
// parent folders, and logs one line each to `hermes/logs/one-link-guard.log`. A link to anywhere else is never
// touched. `One --link-guard [--dry-run]` runs it by hand.

enum LinkGuard {
    struct Found: Equatable {
        var path: String
        var target: String
        var why: String
        var warning: String?
    }

    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-link-guard.log") }
    /// Never walked (big, rebuildable, never ours to tidy).
    static let skipAnywhere: Set<String> = [".git", "node_modules", ".venv", "venv", "site-packages", "__pycache__"]
    /// Skipped at the top of the engine home only: the engine's Python, its tools and caches (tens of thousands of files).
    static let skipInHome: Set<String> = ["installs", "tools", "cache", "browser"]
    static let budget = 300_000

    static func roots() -> [URL] {
        [Env.hermesHome, Brain.root] + Shared.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Every bad link under the roots. Never follows a link.
    static func scan(_ roots: [URL]) -> [Found] {
        var out: [Found] = []
        var left = budget
        for r in roots {
            let top = r.standardizedFileURL.path == Env.hermesHome.standardizedFileURL.path ? skipInHome : []
            walk(r.path, depth: 0, skipTop: top, into: &out, left: &left)
        }
        return out
    }

    static func walk(_ dir: String, depth: Int, skipTop: Set<String>, into out: inout [Found], left: inout Int) {
        guard depth < 40, left > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for n in names.sorted() {
            left -= 1
            if left <= 0 { return }
            let p = dir + "/" + n
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK {
                if let f = check(link: p) { out.append(f) }
            } else if kind == S_IFDIR, !skipAnywhere.contains(n), !(depth == 0 && skipTop.contains(n)) {
                walk(p, depth: depth + 1, skipTop: [], into: &out, left: &left)
            }
        }
    }

    static func real(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// `/a/./b/../c` → `/a/c`, without touching the disk (so a link loop can't send it round).
    static func lexical(_ p: String) -> String {
        var parts: [Substring] = []
        for c in p.split(separator: "/") where c != "." && !c.isEmpty {
            if c == ".." { _ = parts.popLast() } else { parts.append(c) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A link that points to itself, or to its own folder or a folder above it. nil for anything else.
    static func check(link p: String) -> Found? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { return nil }
        let parent = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        let parentReal = real(parent) ?? lexical(parent)
        let me = parentReal + "/" + name
        let target = lexical(dest.hasPrefix("/") ? dest : parentReal + "/" + dest)
        let targetParent = (target as NSString).deletingLastPathComponent
        let canon = (real(targetParent) ?? targetParent) + "/" + (target as NSString).lastPathComponent
        if target == me || canon == me {
            return Found(
                path: p, target: dest, why: "points to itself",
                warning: "if \(name) was a file, its content is gone; put it back from where it first came from")
        }
        guard let t = real(target) else { return nil }  // missing, or loops through other links: not ours to judge
        if t == parentReal || parentReal.hasPrefix(t == "/" ? "/" : t + "/") {
            return Found(path: p, target: dest, why: t == parentReal ? "points to the folder it's in" : "points to a folder above it (\(t))")
        }
        return nil
    }

    static func line(_ f: Found, removed: Bool) -> String {
        let when = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let w = f.warning.map { ". Warning: \($0)" } ?? ""
        return "\(when) \(removed ? "removed" : "could not remove") \(f.path) -> \(f.target) (\(f.why))\(w)"
    }

    static func log(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let l = text + "\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(l.utf8))
            try? h.close()
        } else {
            try? l.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    /// Finds the bad links and (unless `dryRun`) removes each one, one log line each.
    @discardableResult static func run(roots: [URL] = roots(), dryRun: Bool = false) -> [Found] {
        let found = scan(roots)
        guard !dryRun else { return found }
        for f in found { log(line(f, removed: unlink(f.path) == 0)) }
        return found
    }

    /// Before the engine starts: the guard, the engine's skill walks, room.yaml for older brains, `assistant/`.
    static func atLaunch() async {
        await Task.detached {
            LinkGuard.run()
            SkillWalkFix.apply()
            if Brain.exists {
                RoomPrivacy.migrate()
                BrainLayout.ensure()
            }
            RoomPrivacy.refresh()
        }.value
    }

    /// `One --link-guard [--dry-run]`, and the checks and render that go with it (StorageCheck.swift).
    static func cli(_ args: [String]) {
        StorageCheck.main(args)
        guard args.contains("--link-guard") else { return }
        let dry = args.contains("--dry-run")
        let found = run(dryRun: dry)
        for f in found {
            print("\(dry ? "would remove" : "removed") \(f.path) -> \(f.target) (\(f.why))\(f.warning.map { ". Warning: \($0)" } ?? "")")
        }
        print(found.isEmpty ? "no shortcut loops found" : "\(found.count) shortcut loop(s) \(dry ? "found" : "removed")")
        exit(0)
    }
}

// MARK: - The engine's two skill walks never loop

/// The engine walks its skill folders with `os.walk(..., followlinks=True)` and no record of where it has been
/// (`agent/skill_utils.py` `iter_skill_index_files`, `agent/prompt_builder.py` `_build_skills_manifest`), so a link
/// back up reads every skill again and again. Links themselves are kept on purpose (a skill folder linked in from
/// elsewhere is a supported setup), so instead of `followlinks=False` each walk skips a folder whose real path it
/// already walked. A text patch, applied at launch and with the KeePass overlay; if the engine's text changed it
/// skips and logs, never breaks.
enum SkillWalkFix {
    static let mark = "# One: skip a folder already walked (a link back up would loop)"
    static let targets = [
        ("agent/skill_utils.py", "for root, dirs, files in os.walk(str(skills_dir), followlinks=True):"),
        ("agent/prompt_builder.py", "for root, dirs, files in os.walk(skills_dir_str, followlinks=True):"),
    ]

    /// The patched text, the same text when already patched, or nil when the loop isn't there exactly once.
    static func patch(_ text: String, loop: String) -> String? {
        if text.contains(mark) { return text }
        var lines = text.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == loop }
        guard hits.count == 1, let i = hits.first else { return nil }
        let pad = String(lines[i].prefix { $0 == " " })
        let body = pad + "    "
        lines.insert(pad + "_one_seen = set()  " + mark, at: i)
        lines.insert(
            contentsOf: [
                body + "_one_real = os.path.realpath(root)",
                body + "if _one_real in _one_seen:",
                body + "    dirs[:] = []",
                body + "    continue",
                body + "_one_seen.add(_one_real)",
            ], at: i + 2)
        return lines.joined(separator: "\n")
    }

    /// Patches both files in the engine. Returns one plain line per file; anything not patched is logged.
    @discardableResult static func apply(engine: URL = Env.engineDir) -> [String] {
        var out: [String] = []
        for (file, loop) in targets {
            let f = engine.appendingPathComponent(file)
            guard let t = try? String(contentsOf: f, encoding: .utf8) else {
                out.append("\(file): not found")
                continue
            }
            guard let p = patch(t, loop: loop) else {
                out.append("\(file): the walk changed, left as is")
                LinkGuard.log("skill walk: \(file) didn't have the expected walk; left as is")
                continue
            }
            if p == t {
                out.append("\(file): ok")
            } else if (try? p.write(to: f, atomically: true, encoding: .utf8)) != nil {
                out.append("\(file): patched")
            } else {
                out.append("\(file): couldn't write")
                LinkGuard.log("skill walk: couldn't write \(file)")
            }
        }
        return out
    }
}
