import SwiftUI

// MARK: - One helper at a time on a repo's main: what One shows while a helper waits its turn

/// The engine plugin `one-main-queue` (tools/overlay/plugins/one-main-queue) keeps one line per repo of the helpers
/// putting work on its main (a push to main, a merge, a release), and writes where each one is to
/// `hermes/one-main-queue/waiting.json`. Here One reads it for the orbs: "Waiting for Forge Desktop's main · 2nd in
/// line" (its card adds "It keeps working on its own copy meanwhile."), and "Putting work on Forge Desktop's main"
/// for the one whose turn it is. A stopped helper's place is released by the plugin (it reads the stop mark); here a
/// stopped helper, a turn that ran out and a place nobody asked about for 30 minutes simply show nothing.
enum RepoQueue {
    struct Place: Codable, Equatable {
        var repo: String
        var place: Int
        var ahead: String?
        var root: String?
        var title: String?
        var leaseUntil: Double?
        var at: Double?
        enum CodingKeys: String, CodingKey {
            case repo, place, ahead, root, title, at
            case leaseUntil = "lease_until"
        }
    }
    static var file: URL { Env.hermesHome.appendingPathComponent("one-main-queue/waiting.json") }
    /// Renders only: these places instead of the file.
    nonisolated(unsafe) static var still: [String: Place]?
    nonisolated(unsafe) private static var seen: (at: Date, places: [String: Place]) = (.distantPast, [:])

    /// {engine conversation: its place}, read at most every 2 seconds (the orbs ask many times a second).
    static func places(now: Date = Date()) -> [String: Place] {
        if let still { return still }
        if now.timeIntervalSince(seen.at) < 2 { return seen.places }
        var out: [String: Place] = [:]
        if let d = try? Data(contentsOf: file), let all = try? JSONDecoder().decode([String: Place].self, from: d) {
            let t = now.timeIntervalSince1970
            for (sid, p) in all {
                if p.place <= 1, let l = p.leaseUntil, l < t { continue }  // its turn ran out
                if p.place > 1, let a = p.at, t - a > 30 * 60 { continue }  // nobody asked for 30 minutes
                if StopMark.isMarked(sid) || (p.root.map(StopMark.isMarked) ?? false) { continue }
                out[sid] = p
            }
        }
        seen = (now, out)
        return out
    }
    static func reload() { seen = (.distantPast, [:]) }

    /// Where this working helper is in a line, if it is in one (its own conversation, or a sub-helper's under it).
    static func place(_ h: Helper, now: Date = Date()) -> Place? {
        guard h.state == "working", h.stopping != true, let sid = h.sid else { return nil }
        let all = places(now: now)
        return all[sid] ?? all.values.filter { $0.root == sid }.min { $0.place < $1.place }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }
    static func line(_ p: Place) -> String {
        p.place <= 1 ? "Putting work on \(p.repo)'s main" : "Waiting for \(p.repo)'s main · \(ordinal(p.place)) in line"
    }
    /// The line under its orb while it's in a line, else nil (its usual line shows).
    static func line(_ h: Helper, now: Date = Date()) -> String? { place(h, now: now).map(line) }
    /// Its card's state word: "waiting its turn" (nil: the usual word).
    static func word(_ h: Helper) -> String? { (place(h)?.place ?? 0) > 1 ? "waiting its turn" : nil }
    static let meanwhile = "It keeps working on its own copy meanwhile."
    /// A queue line may take two lines under the orb (it's the one thing to know about that helper).
    static func wraps(_ line: String) -> Bool { line.hasPrefix("Putting work on ") || (line.hasPrefix("Waiting for ") && line.contains("'s main")) }
    /// Under the orb, "· 2nd in line" stays on one line.
    static func keepTogether(_ line: String) -> String {
        guard let r = line.range(of: " · ") else { return line }
        return line[..<r.lowerBound] + " ·\u{00A0}" + line[r.upperBound...].replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

/// In a waiting helper's card, under its line: it isn't stuck, it carries on in its own copy.
struct RepoQueueNote: View {
    let h: Helper
    var indent = true  // under the live step line (its dot): lined up with its words
    var body: some View {
        if RepoQueue.word(h) != nil {
            Text(RepoQueue.meanwhile).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.62)).padding(.leading, indent ? 14 : 0)
        }
    }
}

/// The engine half (`tools/overlay/plugins/one-main-queue`), installed at every engine start next to the stop plugin
/// (`StopPlugin.sync` calls `sync`). Takes effect at the engine's next start.
enum MainQueuePlugin {
    static let plugin = "one-main-queue"
    static var pluginDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(plugin)", isDirectory: true) }

    @discardableResult static func installPlugin(from src: URL? = Bundle.main.url(forResource: plugin, withExtension: nil)) -> Bool {
        let fm = FileManager.default
        guard let src, fm.fileExists(atPath: src.appendingPathComponent("__init__.py").path) else { return false }
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        for f in ["__init__.py", "plugin.yaml"] {
            let a = src.appendingPathComponent(f)
            let b = pluginDir.appendingPathComponent(f)
            if (try? Data(contentsOf: a)) != (try? Data(contentsOf: b)) {
                try? fm.removeItem(at: b)
                guard (try? fm.copyItem(at: a, to: b)) != nil else { return false }
            }
        }
        return true
    }

    /// What `hermes config set` must change so the plugin is on (other plugins stay as they are).
    static func configFixes(_ config: String) -> [[String]] {
        let on = BrowserGuard.enabledPlugins(config)
        var fixes: [[String]] = []
        if !on.contains(plugin) {
            fixes.append(["config", "set", "plugins.enabled", "[" + (on + [plugin]).map { "\"\($0)\"" }.joined(separator: ", ") + "]", "--force"])
        }
        let off = BrowserGuard.enabledPlugins(config, key: "disabled")
        if off.contains(plugin) {
            fixes.append([
                "config", "set", "plugins.disabled", "[" + off.filter { $0 != plugin }.map { "\"\($0)\"" }.joined(separator: ", ") + "]", "--force",
            ])
        }
        return fixes
    }

    static func sync() async {
        let ok = installPlugin()
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for f in configFixes(cfg) {
            let (code, out) = await hermesRun(f)
            if code != 0 { BrowserGuard.log("main queue: couldn't set \(f[2]): \(out.suffix(200))") }
        }
        if !ok { BrowserGuard.log("main queue: the one-main-queue plugin isn't in this copy of One; helpers aren't lined up on main") }
    }
}

/// Render-only (`--render-world <prefix>`, from a test copy): repo turns, Claude Design "One Safety Features"
/// Direction A: `helper-stop-repo-turn` = one helper putting work on Forge Desktop's main, one waiting 2nd in line
/// (its card open), next to a working one.
struct RepoTurnScene: View {
    static func helper(_ title: String, _ sid: String, _ line: String) -> Helper {
        var h = Helper(title: title, task: "", sid: sid, state: "working", line: line)
        h.seen = true
        return h
    }
    static let places: [String: RepoQueue.Place] = [
        "local-ship": .init(repo: "Forge Desktop", place: 1, ahead: "", root: "local-ship", title: "Ship sign-in fix"),
        "local-export": .init(repo: "Forge Desktop", place: 2, ahead: "Ship sign-in fix", root: "local-export", title: "Add export button"),
    ]
    var body: some View {
        let hs = [
            Self.helper("Canvas price options", "local-canvas", "Reading your files…"),
            Self.helper("Ship sign-in fix", "local-ship", "Pushing to GitHub…"),
            Self.helper("Add export button", "local-export", "Running tests…"),
        ]
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 14) {
                ForEach(Array(hs.enumerated()), id: \.offset) { i, h in
                    VStack(spacing: -10) {
                        HelperOrb(state: h.viewState, t: 21.7 + Double(i) * 3.1, size: 42)
                        HelperTag(title: h.title, line: HelperRings.status(h), look: HelperRings.Look(orb: 42, label: 132, title: 12, line: 10.5))
                    }
                }
            }.frame(width: 250)
            HelperCard(m: Model.shared, h: hs[2]).frame(width: 440)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(WorldLook.bg).environment(\.colorScheme, .dark)
    }
    @MainActor static var renders: [(String, AnyView)] {
        RepoQueue.still = places  // ImageRenderer draws at once: set before the views are built
        return [("helper-stop-repo-turn", AnyView(Self()))]
    }
}
