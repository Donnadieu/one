import Foundation

// MARK: - Repos a job names by name ("Forge Desktop", "Donnadieu/one", "the One repo")

/// A small index of the person's repos, so a job that says "Fix Forge Desktop's tray" (no path) still gets its own
/// copy (HelperRepos). Every main checkout in `~/Repos/*/` (a folder with its own `.git` folder: a helper's copy
/// has a `.git` file and is left out) is known by its folder name ("forge-desktop" reads as "Forge Desktop") and by
/// its GitHub owner/name from `origin` ("Donnadieu/one", read from `.git/config`, no git run).
/// Matching: whole words, any case, a hyphen or underscore read as a space; the longest name wins where two overlap
/// ("Forge Desktop" is forge-desktop, not forge). A name shorter than 3 letters never matches; a 3-letter or everyday
/// name ("one", "site") only when the job says "<name> repo" or owner/name. Two clones of one GitHub repo: the one
/// with the shortest folder name. Paths in the job are left to `HelperRepos.repos(in:)`. Never the brain or One's
/// own data (`HelperRepos.allowed`).
enum RepoIndex {
    struct Repo: Equatable {
        var path: String
        var names: [String]  // plain words, lowercased: "forge desktop", "donnadieu/one", "one"
    }
    nonisolated(unsafe) static var override: String?
    /// `~/Repos`; tests and renders use a folder inside their own scratch One folder (under `work/`, where repos may be).
    static var root: String { override ?? (Env.selfTest ? Env.support.path + "/work/Repos" : NSHomeDirectory() + "/Repos") }
    static let everyday: Set<String> = [
        "one", "app", "apps", "site", "web", "www", "api", "docs", "notes", "home", "test", "tests", "demo", "core", "main",
        "work", "tools", "code", "data", "blog", "server", "client", "backend", "frontend", "mobile", "desktop", "scripts",
        "config", "dotfiles", "website", "assistant", "project", "projects", "play", "sandbox", "old", "new", "temp", "tmp",
    ]

    /// Plain words: lowercased, "-" and "_" read as spaces, one space between words.
    static func words(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    /// The `origin` url in a repo's `.git/config`.
    static func origin(_ gitDir: String) -> String? {
        guard let cfg = try? String(contentsOfFile: gitDir + "/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in cfg.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inOrigin = l == "[remote \"origin\"]" }
            if inOrigin, l.hasPrefix("url"), let eq = l.firstIndex(of: "=") {
                return l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    /// "owner/name" from a GitHub url (https, ssh, with or without .git), lowercased.
    static func slug(_ url: String) -> String? {
        guard let r = url.range(of: #"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#, options: .regularExpression) else { return nil }
        let parts = url[r].split(whereSeparator: { $0 == ":" || $0 == "/" }).map(String.init)
        guard parts.count >= 3 else { return nil }
        var name = parts[parts.count - 1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return "\(parts[parts.count - 2])/\(name)".lowercased()
    }

    /// Every main checkout under `root`, each with the names it's known by.
    static func all(in root: String = root) -> [Repo] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let folders = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted { ($0.count, $0) < ($1.count, $1) }
        var out: [Repo] = []
        var slugs = Set<String>()
        for f in folders where !f.hasPrefix(".") {
            let path = HelperRepos.norm(root + "/" + f)
            guard fm.fileExists(atPath: path + "/.git", isDirectory: &isDir), isDir.boolValue, HelperRepos.allowed(path) else { continue }
            var names = [words(f)]
            // Shortest folder first: a second clone of the same GitHub repo is only known by its folder name.
            if let s = origin(path + "/.git").flatMap(slug), slugs.insert(s).inserted {
                names.append(s)
                if let n = s.split(separator: "/").last.map({ words(String($0)) }), !names.contains(n) { names.append(n) }
            }
            out.append(Repo(path: path, names: names))
        }
        return out
    }

    /// The repos a job names by name, in the order it names them.
    static func find(in text: String, root: String = root) -> [String] {
        let repos = all(in: root)
        guard !repos.isEmpty else { return [] }
        // Paths are HelperRepos' (`~/Repos/one-repo-turns` must not read as "the One repo"); links stay (github.com/x/y).
        let noPaths = text.replacingOccurrences(of: #"(?:^|(?<=[\s("'`\[=]))(?:~|\$HOME|/)[^\s"'`),;\]]*"#, with: " ", options: .regularExpression)
        let t = words(noPaths)
        var hits: [(range: Range<String.Index>, path: String)] = []
        for r in repos {
            for n in r.names where n.count >= 3 {
                let bare = !n.contains("/") && (n.count == 3 || everyday.contains(n))
                let esc = NSRegularExpression.escapedPattern(for: n).replacingOccurrences(of: " ", with: "\\s+")
                let pattern = "(?<![a-z0-9])" + esc + (bare ? "(?:['’]s)?\\s+(?:repo|repository|codebase)\\b" : "(?![a-z0-9])")
                var from = t.startIndex
                while from < t.endIndex, let m = t.range(of: pattern, options: .regularExpression, range: from..<t.endIndex) {
                    hits.append((m, r.path))
                    from = m.upperBound
                }
            }
        }
        // The longest name wins where two overlap; then in the order the job says them.
        var kept: [(range: Range<String.Index>, path: String)] = []
        for h in hits.sorted(by: {
            t.distance(from: $0.range.lowerBound, to: $0.range.upperBound) > t.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
        })
        where !kept.contains(where: { $0.range.overlaps(h.range) }) {
            kept.append(h)
        }
        var out: [String] = []
        for h in kept.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where !out.contains(h.path) { out.append(h.path) }
        return out
    }
}
