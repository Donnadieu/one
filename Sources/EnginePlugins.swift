import Foundation

// MARK: - One's own engine plugins (installed at every engine start)
// One ships small engine plugins in `tools/overlay/plugins/<name>` (bundled into Resources/<name> by build.sh). At every
// engine start they're copied into `<hermes home>/plugins/<name>` and named in `plugins.enabled` (other entries kept).
// The folder lock makes each plugin folder read-only to the engine (`BrowserGuard.lockedPaths`), so the engine can't
// change the rules it runs under.

enum EnginePlugins {
    static func dir(_ name: String) -> URL { Env.hermesHome.appendingPathComponent("plugins/\(name)", isDirectory: true) }

    /// Copies a bundled plugin into One's Hermes home. Returns false when the app doesn't carry it.
    @discardableResult static func install(_ name: String, from src: URL? = nil) -> Bool {
        let fm = FileManager.default
        guard let src = src ?? Bundle.main.url(forResource: name, withExtension: nil),
            fm.fileExists(atPath: src.appendingPathComponent("__init__.py").path)
        else { return false }
        let to = dir(name)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for f in ["__init__.py", "plugin.yaml"] {
            let a = src.appendingPathComponent(f)
            let b = to.appendingPathComponent(f)
            if (try? Data(contentsOf: a)) != (try? Data(contentsOf: b)) {
                try? fm.removeItem(at: b)
                guard (try? fm.copyItem(at: a, to: b)) != nil else { return false }
            }
        }
        return true
    }

    /// Items of `plugins.<key>` in config.yaml (block list or inline list).
    static func listed(_ config: String, key: String = "enabled") -> [String] {
        var inPlugins = false
        var inList = false
        var out: [String] = []
        for raw in config.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inPlugins = t.hasPrefix("plugins:")
                inList = false
                continue
            }
            guard inPlugins else { continue }
            if indent == 2 {
                inList = t.hasPrefix("\(key):")
                if inList, let open = t.firstIndex(of: "["), let close = t.lastIndex(of: "]"), open < close {
                    out += t[t.index(after: open)..<close].split(separator: ",").map(clean).filter { !$0.isEmpty }
                    inList = false
                }
                continue
            }
            if inList, t.hasPrefix("- ") { out.append(clean(t.dropFirst(2))) }
        }
        return out
    }
    static func clean<S: StringProtocol>(_ s: S) -> String {
        String(s.split(separator: "#").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// The `hermes config set` calls that turn `name` on: in `plugins.enabled` (keeping every other entry), out of
    /// `plugins.disabled`.
    static func enableFixes(_ config: String, _ name: String) -> [[String]] {
        var fixes: [[String]] = []
        let on = listed(config)
        if !on.contains(name) {
            let list = "[" + (on + [name]).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.enabled", list, "--force"])
        }
        let off = listed(config, key: "disabled")
        if off.contains(name) {
            let list = "[" + off.filter { $0 != name }.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.disabled", list, "--force"])
        }
        return fixes
    }

    static var configFile: URL { Env.hermesHome.appendingPathComponent("config.yaml") }

    /// Installs and turns on a plugin. Returns false when the app doesn't carry it.
    @discardableResult
    static func sync(_ name: String, from src: URL? = nil, run: HermesRunner = { await hermesRun($0) }, log: (String) -> Void) async -> Bool {
        let ok = install(name, from: src)
        let cfg = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        for f in enableFixes(cfg, name) {
            let (code, out) = await run(f)
            if code != 0 { log("couldn't set \(f[2]): \(out.suffix(200))") }
        }
        return ok
    }
}

/// Runs a short engine command (`hermes …`): the real one, or a stand-in in checks.
typealias HermesRunner = @Sendable ([String]) async -> (Int32, String)

// MARK: - The engine's own learning, under the nightly review's limits

/// The engine's after-each-job review (`agent/background_review.py`) edits skills on its own, about 60 times a day with
/// no limit. Omar (Nov 4 2026) put it under the nightly review's limits: the plugin `one-learning-cap` holds a review's
/// `skill_manage` write past `max_edits_per_night` a day or `max_edits_per_skill` per skill (from `improve/settings.json`)
/// and logs it to `improve/held-review-edits.jsonl` for the nightly review. The person's own requests, helpers and the
/// nightly review are never capped. Checked by `tools/learning-cap-check.py` (preflight).
enum LearningCap {
    static let plugin = "one-learning-cap"
    static var pluginDir: URL { EnginePlugins.dir(plugin) }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-learning-cap.log") }

    /// Called before every engine start (`ensureEngine`). The settings file is written with its defaults when missing,
    /// so the plugin and the person read the same numbers.
    static func sync(from src: URL? = nil, run: HermesRunner = { await hermesRun($0) }) async {
        if !FileManager.default.fileExists(atPath: Improve.settingsFile.path) { Improve.save(Improve.settings()) }
        let ok = await EnginePlugins.sync(plugin, from: src, run: run, log: log)
        if !ok { log("the learning cap isn't in this copy of One; the engine's own skill edits aren't limited") }
    }

    static func log(_ s: String) {
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) one: \(s)\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
