import Foundation

// MARK: - The engine's own learning stays under limits

/// The engine reviews each finished job in the background and edits skills on its own. Unchecked, that was about
/// 60 to 90 skill edits a day on the owner's Mac, with nothing measuring whether they helped. An engine plugin
/// (`tools/overlay/plugins/one-learning-cap`, installed here at every engine start) holds those background edits to
/// the nightly review's limits: at most `max_edits_per_night` a day (5) and `max_edits_per_skill` per skill (1), read
/// from `<support>/improve/settings.json`. Held edits go to `improve/held-review-edits.jsonl` for the nightly review.
/// The person's own requests, helpers and the nightly review itself are never capped.
/// Design: Made by Iris, "2026-11-05 One gets better by itself - design.md", section 6 point 7.
enum LearningCap {
    static let plugin = "one-learning-cap"
    static var pluginDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(plugin)", isDirectory: true) }

    /// Copies the bundled plugin into One's engine home. False when this copy of One doesn't carry it.
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
            let list = "[" + (on + [plugin]).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.enabled", list, "--force"])
        }
        let off = BrowserGuard.enabledPlugins(config, key: "disabled")
        if off.contains(plugin) {
            let list = "[" + off.filter { $0 != plugin }.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.disabled", list, "--force"])
        }
        return fixes
    }

    /// Called before every engine start (`ensureEngine`), after `BrowserGuard.sync`.
    static func sync() async {
        let ok = installPlugin()
        Improve.ensureSettings()  // the limits the plugin reads
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for f in configFixes(cfg) {
            let (code, out) = await hermesRun(f)
            if code != 0 { BrowserGuard.log("learning cap: couldn't set \(f[2]): \(out.suffix(200))") }
        }
        if !ok { BrowserGuard.log("learning cap: the plugin isn't in this copy of One; the engine's own learning isn't limited") }
    }
}
