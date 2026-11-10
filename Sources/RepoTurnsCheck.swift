import Foundation

/// `One --test-repo-turns` (preflight, CI only, a test copy, ONE_SUPPORT_DIR set to an empty folder): every repo job
/// gets its own copy, also a repo named only by name (RepoIndex: "Forge Desktop", `Donnadieu/one`, "the One repo",
/// never an everyday "one" or a 2-letter name), a job that names its own copy gets no second one; and the orb line
/// for a helper waiting its turn on a repo's main (RepoQueue, from the engine plugin's `waiting.json`). The engine
/// side of the queue is checked by tools/main-queue-check.py.
enum RepoTurnsCheck {
    static func main(_ args: [String]) {
        guard args.contains("--test-repo-turns") else { return }
        TestWorld.enter()
        _ = MainActor.assumeIsolated {
            Task { @MainActor in exit(await run()) }
        }
        RunLoop.main.run()
    }

    static func repo(_ path: String, origin: String?) -> Bool {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var steps = [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "t@example.com"],
            ["config", "commit.gpgsign", "false"],
        ]
        if let origin { steps.append(["remote", "add", "origin", origin]) }
        for a in steps { _ = HelperRepos.run(["-C", path] + a) }
        try? "hi\n".write(toFile: path + "/README.md", atomically: true, encoding: .utf8)
        _ = HelperRepos.run(["-C", path, "add", "."])
        return HelperRepos.run(["-C", path, "commit", "-q", "-m", "first"]).ok
    }

    @MainActor static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ got: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(ok || got.isEmpty ? "" : "  (got: \(got))")")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let m = Model.shared
        m.helpers = []
        let root = RepoIndex.root
        check("names are looked up in the scratch folder, never the person's ~/Repos", root.hasPrefix(Env.support.path), root)
        let forgeDesktop = HelperRepos.norm(root + "/forge-desktop")
        let forge = HelperRepos.norm(root + "/forge")
        let one = HelperRepos.norm(root + "/one-assistant")
        let oneClone = HelperRepos.norm(root + "/one-assistant-safety-features")
        let notarc = HelperRepos.norm(root + "/NotArc")
        let site = HelperRepos.norm(root + "/site")
        let made = [
            repo(forgeDesktop, origin: "https://github.com/Donnadieu/forge-desktop.git"), repo(forge, origin: "git@github.com:Donnadieu/forge.git"),
            repo(one, origin: "git@github.com:Donnadieu/one.git"), repo(oneClone, origin: "https://github.com/Donnadieu/one"),
            repo(notarc, origin: nil), repo(site, origin: nil), repo(root + "/ui", origin: nil),
        ]
        check("throwaway repos to name", !made.contains(false))
        let wt = HelperRepos.norm(root + "/one-assistant-repo-turns")
        _ = HelperRepos.run(["-C", one, "worktree", "add", "-q", "-b", "repo-turns", wt])
        check("…and a helper's copy (worktree) of one of them", HelperRepos.mainRepo(of: wt) == one, HelperRepos.mainRepo(of: wt) ?? "none")

        print("1. repos named by name")
        func find(_ s: String) -> [String] { RepoIndex.find(in: s).map { ($0 as NSString).lastPathComponent } }
        let cases: [(String, [String])] = [
            ("Fix Forge Desktop's tray icon", ["forge-desktop"]),
            ("forge-desktop: add an export button", ["forge-desktop"]),
            ("Ship it in FORGE DESKTOP", ["forge-desktop"]),
            ("Move the Forge cards", ["forge"]),
            ("Compare Forge and Forge Desktop", ["forge", "forge-desktop"]),
            ("Rebase Donnadieu/one on main", ["one-assistant"]),
            ("Open a PR on https://github.com/Donnadieu/one/pulls", ["one-assistant"]),
            ("Fix the One repo's README", ["one-assistant"]),
            ("Finish NotArc release", ["NotArc"]),
            ("Update the site repo", ["site"]),
            ("Make one change to the settings, then one more", []),
            ("Fix the site header", []),
            ("Redo the ui", []),
            ("Forgery desktop wallpaper", []),
            ("Work in ~/Repos/one-assistant-repo-turns on its branch", []),
        ]
        for (text, want) in cases {
            let got = find(text)
            check("\"\(text)\" → \(want.isEmpty ? "nothing" : want.joined(separator: ", "))", got == want, got.joined(separator: ", "))
        }
        check("a helper's copy is never indexed as a repo of its own", !RepoIndex.all().contains { $0.path == wt })
        check("a repo named by name is found with the paths", HelperRepos.repos(in: "Fix Forge Desktop's tray").contains(forgeDesktop))

        print("2. every repo job gets its own copy")
        let a = Helper(title: "Tray fix", task: "Fix Forge Desktop's tray icon.", sid: "local-a", state: "working", line: "")
        m.helpers = [a]
        let na = await m.helperStartNotes(a.id, title: a.title, task: a.task)
        let ca = HelperRepos.load().first { $0.helper == a.id.uuidString }
        check(
            "a helper alone in a repo named by name gets its own copy",
            ca?.repo == forgeDesktop && ca.map { FileManager.default.fileExists(atPath: $0.path + "/README.md") } == true, ca?.path ?? "none")
        check("…and is told to work only there", na.contains("YOUR OWN COPY") && na.contains("forge-desktop-tray-fix") && !na.contains("in use by"))
        check("…and that putting work on main may wait its turn", na.contains("waits its turn"))
        check(
            "…its steps say so", m.helpers.first?.trail?.contains(HelperRepos.trailLine(forgeDesktop, other: false)) == true,
            m.helpers.first?.trail?.joined(separator: " | ") ?? "")
        check("…the person's own checkout is left alone", HelperRepos.run(["-C", forgeDesktop, "symbolic-ref", "--short", "HEAD"]).out == "main")
        let b = Helper(
            title: "Repo turns", task: "Your worktree: \(wt), branch repo-turns. Never touch \(one).", sid: "local-b", state: "working", line: "")
        m.helpers = [a, b]
        let before = HelperRepos.load().count
        _ = await m.helperStartNotes(b.id, title: b.title, task: b.task)
        check("a job that names its own copy works there: no second copy", HelperRepos.load().count == before, "\(HelperRepos.load().map(\.path))")
        check(
            "…it's on record as working in that copy", m.helpers.first { $0.id == b.id }?.repos == [wt],
            "\(m.helpers.first { $0.id == b.id }?.repos ?? [])")
        HelperRepos.release(helper: a.id.uuidString)
        check("the copy goes when they're done with the helper", ca.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        m.helpers = []

        print("3. whose turn it is on main")
        check("2nd in line", RepoQueue.line(.init(repo: "Forge Desktop", place: 2)) == "Waiting for Forge Desktop's main · 2nd in line")
        check("first in line", RepoQueue.line(.init(repo: "Forge Desktop", place: 1)) == "Putting work on Forge Desktop's main")
        check(
            "ordinals",
            [1, 2, 3, 4, 11, 12, 13, 21, 22, 103].map(RepoQueue.ordinal) == [
                "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "103rd",
            ])
        let now = Date().timeIntervalSince1970
        let waiting: [String: Any] = [
            "local-ship": ["repo": "Forge Desktop", "place": 1, "ahead": "", "root": "local-ship", "lease_until": now + 600, "at": now],
            "local-export": ["repo": "Forge Desktop", "place": 2, "ahead": "Ship sign-in fix", "root": "local-export", "at": now],
            "20261109_sub": ["repo": "NotArc", "place": 3, "ahead": "x", "root": "local-parent", "at": now],
            "local-late": ["repo": "Forge Desktop", "place": 1, "root": "local-late", "lease_until": now - 5, "at": now - 900],
            "local-gone": ["repo": "NotArc", "place": 2, "root": "local-gone", "at": now - 3600],
            "local-stopped": ["repo": "NotArc", "place": 2, "root": "local-stopped", "at": now],
        ]
        try? FileManager.default.createDirectory(at: RepoQueue.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: waiting).write(to: RepoQueue.file)
        StopMark.mark("local-stopped", title: "Stopped one")
        RepoQueue.reload()
        func h(_ sid: String, _ state: String = "working") -> Helper { Helper(title: sid, task: "", sid: sid, state: state, line: "Running tests…") }
        let export = h("local-export")
        check(
            "the waiting helper's orb says so", HelperRings.status(export) == "Waiting for Forge Desktop's main · 2nd in line",
            HelperRings.status(export))
        check("…also mid-step (its live line)", m.progressLine(export, now: Date(), short: true) == "Waiting for Forge Desktop's main · 2nd in line")
        check(
            "…its card says it's waiting its turn and carries on",
            RepoQueue.word(export) == "waiting its turn" && RepoQueue.meanwhile.contains("own copy"))
        check("…and its line may wrap under the orb", RepoQueue.wraps(HelperRings.status(export)) && !RepoQueue.wraps("Running tests…"))
        check("…keeping \"2nd in line\" together", RepoQueue.keepTogether(HelperRings.status(export)).hasSuffix("·\u{00A0}2nd\u{00A0}in\u{00A0}line"))
        check(
            "the one whose turn it is",
            HelperRings.status(h("local-ship")) == "Putting work on Forge Desktop's main" && RepoQueue.word(h("local-ship")) == nil)
        check(
            "a sub-helper's place shows on its helper", HelperRings.status(h("local-parent")) == "Waiting for NotArc's main · 3rd in line",
            HelperRings.status(h("local-parent")))
        check("a turn that ran out shows the usual line", HelperRings.status(h("local-late")) == "Running tests…")
        check("…so does a place nobody asked about for 30 minutes", HelperRings.status(h("local-gone")) == "Running tests…")
        check("…and a stopped helper's", HelperRings.status(h("local-stopped")) == "Running tests…")
        check("a finished helper shows its usual line", HelperRings.status(h("local-export", "done")) == "Done")
        check("a helper in no line keeps its own", HelperRings.status(h("local-other")) == "Running tests…")
        StopMark.lift("local-stopped")

        print("4. the engine plugin")
        let fixes = MainQueuePlugin.configFixes("plugins:\n  enabled:\n    - one-stop\n")
        check("it's switched on next to the others", fixes.first?.contains("[\"one-stop\", \"one-main-queue\"]") == true, "\(fixes)")
        check(
            "…and nothing to change once it is", MainQueuePlugin.configFixes("plugins:\n  enabled:\n    - one-stop\n    - one-main-queue\n").isEmpty)
        check(
            "it's bundled and installs into the engine",
            MainQueuePlugin.installPlugin() && FileManager.default.fileExists(atPath: MainQueuePlugin.pluginDir.path + "/__init__.py"))

        print(fails == 0 ? "repo turns ok" : "repo turns: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
