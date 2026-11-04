import Foundation

// MARK: - No browser window on their screen without their yes

/// The rule: no assistant, helper or routine opens a visible browser window unless the person said yes to
/// that exact window first. Work happens in the hidden browsers (One's on 9223, others headless).
/// Enforced in four places:
/// - the engine's browser tools are kept headless (`browser.headed: false`, `AGENT_BROWSER_HEADED=false`);
/// - an engine plugin (`tools/overlay/plugins/one-browser-guard`, installed here at every engine start)
///   blocks terminal / execute_code / browser_exec commands that would open, show or drive a visible browser
///   (`open -a`, AppleScript, a browser started without --headless) and logs each block;
/// - One's own hidden-browser keeper always starts Chrome with --headless=new (`BrowserKeeper`);
/// - only a yes typed or tapped in One's chat unlocks one window, once: One (outside the folder lock) writes
///   `guard/allow/<id>.json`, a folder the engine can read but not write (`Access.profile`).
enum BrowserGuard {
    static let plugin = "one-browser-guard"
    static var dir: URL { Env.support.appendingPathComponent("guard", isDirectory: true) }
    static var allowDir: URL { dir.appendingPathComponent("allow", isDirectory: true) }
    static var askFile: URL { dir.appendingPathComponent("ask.json") }
    static var pluginDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(plugin)", isDirectory: true) }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-browser-guard.log") }
    /// The plain ask the assistant uses (also in SOUL and the block message).
    static let ask = "I need to open <browser> to <reason>. Can I?"

    static let soul = """
        Browsers: never open a visible browser window unless they said yes to that exact window first. Work in the background on the hidden browsers (One's on port 9223, Project Ledger's on 9333, both headless). Never start a browser with `open`, AppleScript or without --headless, and never quit, restart or bring up their own browser. If a job truly needs a window, ask in plain words: "\(ask)" (say the browser and the reason), end with [choices: Yes, open it | No, stay hidden], and wait. A routine can't ask anyone: it skips that step and says so in its report. One blocks visible browser windows by itself; their yes lets one window through, once.
        """

    /// Added to every helper prompt.
    static let note =
        "\n\n(One app note, not from the user: NO VISIBLE BROWSER WINDOWS. Browse only in the background on the hidden browsers (One's on port 9223, Project Ledger's on 9333, headless). Never `open -a` a browser, never AppleScript one, never start one without --headless, never quit or restart their own browser. If the job truly needs a window, ask \"\(ask)\" ending with [choices: Yes, open it | No, stay hidden], and wait. One blocks and logs any visible browser launch.)"

    // MARK: Install into the engine (at every engine start)

    /// Copies the bundled plugin into One's Hermes home. Returns false when the app doesn't carry it.
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
        try? fm.createDirectory(at: allowDir, withIntermediateDirectories: true)
        return true
    }

    /// Items of `plugins.<key>` in config.yaml (block list or inline list).
    static func enabledPlugins(_ config: String, key: String = "enabled") -> [String] {
        var inPlugins = false
        var inEnabled = false
        var out: [String] = []
        for raw in config.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inPlugins = t.hasPrefix("plugins:")
                inEnabled = false
                continue
            }
            guard inPlugins else { continue }
            if indent == 2 {
                inEnabled = t.hasPrefix("\(key):")
                if inEnabled, let open = t.firstIndex(of: "["), let close = t.lastIndex(of: "]"), open < close {
                    out += t[t.index(after: open)..<close].split(separator: ",").map(clean).filter { !$0.isEmpty }
                    inEnabled = false
                }
                continue
            }
            if inEnabled, t.hasPrefix("- ") { out.append(clean(t.dropFirst(2))) }
        }
        return out
    }
    static func clean<S: StringProtocol>(_ s: S) -> String {
        String(s.split(separator: "#").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }
    /// `browser.headed` as written, or nil when it isn't set.
    static func headed(_ config: String) -> String? {
        var inBrowser = false
        for line in config.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") {
                inBrowser = t.hasPrefix("browser:")
            } else if inBrowser, line.hasPrefix("  headed:") {
                return clean(t.dropFirst(7))
            }
        }
        return nil
    }

    /// What `hermes config set` must change so the guard is on and the browser tools stay hidden.
    static func configFixes(_ config: String) -> [[String]] {
        var fixes: [[String]] = []
        let on = enabledPlugins(config)
        if !on.contains(plugin) {
            let list = "[" + (on + [plugin]).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.enabled", list, "--force"])
        }
        let off = enabledPlugins(config, key: "disabled")
        if off.contains(plugin) {
            let list = "[" + off.filter { $0 != plugin }.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            fixes.append(["config", "set", "plugins.disabled", list, "--force"])
        }
        if headed(config)?.lowercased() != "false" { fixes.append(["config", "set", "browser.headed", "false", "--force"]) }
        return fixes
    }

    /// Called before every engine start (`ensureEngine`).
    static func sync() async {
        let ok = installPlugin()
        let cfgFile = Env.hermesHome.appendingPathComponent("config.yaml")
        let cfg = (try? String(contentsOf: cfgFile, encoding: .utf8)) ?? ""
        for f in configFixes(cfg) {
            let (code, out) = await hermesRun(f)
            if code != 0 { log("couldn't set \(f[2]): \(out.suffix(200))") }
        }
        if !ok { log("the guard plugin isn't in this copy of One; visible browser launches aren't blocked") }
    }

    // MARK: Their yes in the chat

    /// The browser named in the assistant's ask ("I need to open Arc to …"), or "any".
    static func browserIn(_ reply: String) -> String {
        let l = reply.lowercased()
        let names = [
            ("google chrome", "Chrome"), ("chrome", "Chrome"), ("chromium", "Chromium"), ("arc", "Arc"), ("safari", "Safari"),
            ("firefox", "Firefox"), ("brave", "Brave"), ("edge", "Edge"), ("opera", "Opera"), ("vivaldi", "Vivaldi"),
        ]
        guard let r = l.range(of: "i need to open ") else { return "any" }
        let after = l[r.upperBound...].prefix(40)
        return names.first { after.hasPrefix($0.0) }?.1 ?? "any"
    }

    /// True when this reply is the assistant's plain ask for a window.
    static func isAsk(_ reply: String) -> Bool {
        let l = reply.lowercased()
        return l.contains("i need to open ") && l.contains("can i?")
    }

    static func isYes(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("yes") || t == "open it" || t == "ok, open it" || t == "go ahead" || t == "sure"
    }

    /// They said yes to the assistant's ask: one window of that browser, for the next 15 minutes.
    /// Returns the id written, or nil when this message isn't that yes.
    @discardableResult static func heard(_ text: String, after reply: String, now: Date = Date()) -> String? {
        guard isYes(text), isAsk(reply) else { return nil }
        var browser = browserIn(reply)
        if browser == "any", let d = try? Data(contentsOf: askFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let b = j["browser"] as? String, now.timeIntervalSince1970 - ((j["at"] as? Double) ?? 0) < 7200,
            !["a browser", "your browser"].contains(b)
        {
            browser = b
        }
        let id = "yes-" + UUID().uuidString.prefix(8).lowercased()
        // Only the derived decision is persisted — never a snippet of what the person typed, even
        // though they're only saying yes to a browser window: it could still be sensitive if pasted.
        let j: [String: Any] = ["id": id, "browser": browser, "expires": now.timeIntervalSince1970 + 900, "approved": true]
        try? FileManager.default.createDirectory(at: allowDir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: j), (try? d.write(to: allowDir.appendingPathComponent("\(id).json"))) != nil
        else { return nil }
        try? FileManager.default.removeItem(at: askFile)
        log("their yes in chat (\(id)): one visible \(browser) window allowed for 15 minutes")
        return id
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

    /// Paths the engine may read but never write (added last to the folder lock, so they win).
    static var lockedPaths: [String] { [allowDir.path, pluginDir.path] }
}
