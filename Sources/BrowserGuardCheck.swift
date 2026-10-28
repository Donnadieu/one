import Foundation

// MARK: - `One --test-browser` (part 2): no browser window without their yes

/// Run inside `BrowserCheck.run()` with ONE_SUPPORT_DIR pointing at a scratch folder. Starts no browser.
enum BrowserGuardCheck {
    static func run(_ expect: (Bool, String) -> Void) {
        let fm = FileManager.default
        // The engine's browser tools stay hidden.
        expect(Env.vars()["AGENT_BROWSER_HEADED"] == "false", "the engine's browser tools are told to stay hidden")
        let cfg = """
            plugins:
              clone_timeout_seconds: 300
              enabled:
                - other-plugin
              disabled: [one-browser-guard, x]
            browser:
              cdp_url: http://localhost:9223
              headed: true
            model:
              default: x
            """
        expect(BrowserGuard.enabledPlugins(cfg) == ["other-plugin"], "reads plugins.enabled")
        let fixes = BrowserGuard.configFixes(cfg)
        expect(
            fixes.contains(["config", "set", "plugins.enabled", #"["other-plugin", "one-browser-guard"]"#, "--force"]),
            "switches the guard on, keeping other plugins")
        expect(fixes.contains(["config", "set", "plugins.disabled", #"["x"]"#, "--force"]), "takes the guard off the disabled list")
        expect(fixes.contains(["config", "set", "browser.headed", "false", "--force"]), "turns a headed browser setting back off")
        let good = "plugins:\n  enabled:\n    - one-browser-guard\nbrowser:\n  headed: false\n"
        expect(BrowserGuard.configFixes(good).isEmpty, "a guarded config is left alone")
        expect(BrowserGuard.configFixes("plugins:\n  enabled: [one-browser-guard]\nbrowser:\n  headed: false\n").isEmpty, "inline lists are read too")

        // The plugin lands in the engine's home and the folder lock keeps the engine from changing it or the yes folder.
        let src = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("tools/overlay/plugins/one-browser-guard")
        let bundled = Bundle.main.url(forResource: BrowserGuard.plugin, withExtension: nil)
        expect(BrowserGuard.installPlugin(from: bundled ?? src), "the guard plugin is installed into the engine's home")
        expect(fm.fileExists(atPath: BrowserGuard.pluginDir.appendingPathComponent("__init__.py").path), "plugin file in place")
        let profile = Access.profile()
        let deny = profile.components(separatedBy: "\n").last { $0.contains("(deny file-write*") } ?? ""
        expect(
            deny.contains(BrowserGuard.allowDir.path) && deny.contains(BrowserGuard.pluginDir.path),
            "the folder lock lets the engine read but never write the yes folder or the guard")
        expect(
            profile.range(of: "(allow file-write*")!.lowerBound
                < profile.range(of: "(deny file-write* (subpath \"\(BrowserGuard.allowDir.path)")!.lowerBound,
            "that rule comes last, so it wins")

        // SOUL and helpers carry the rule and the plain ask.
        expect(BrowserGuard.soul.contains("I need to open <browser> to <reason>. Can I?"), "SOUL has the plain ask")
        expect(Helpers.helperNote.contains("NO VISIBLE BROWSER WINDOWS"), "every helper prompt carries the rule")

        // Only their yes to the ask unlocks one window.
        try? fm.removeItem(at: BrowserGuard.allowDir)
        let ask = "I need to open Arc to read your work calendar, since it's only signed in there. Can I?"
        expect(BrowserGuard.heard("Yes", after: "Here's the plan. Can I go ahead?") == nil, "a yes to something else unlocks nothing")
        expect(BrowserGuard.heard("No, stay hidden", after: ask) == nil, "a no unlocks nothing")
        let id = BrowserGuard.heard("Yes, open it", after: ask)
        let f = id.map { BrowserGuard.allowDir.appendingPathComponent("\($0).json") }
        let j = f.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(j?["browser"] as? String == "Arc", "their yes allows that browser")
        let exp = (j?["expires"] as? Double) ?? 0
        expect(exp > Date().timeIntervalSince1970 && exp < Date().timeIntervalSince1970 + 1000, "for a short time only")
        let log = (try? String(contentsOf: BrowserGuard.logFile, encoding: .utf8)) ?? ""
        expect(log.contains("their yes in chat"), "the yes is logged")
    }
}
