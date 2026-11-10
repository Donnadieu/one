import Darwin
import Foundation

// MARK: - Phone chat (Telegram): keep the engine's background helper running while a bot is set up

/// Hermes talks to Telegram from its background helper (the gateway). The engine only starts that
/// helper when it needs it, so after a restart a phone bot went quiet until someone started it by
/// hand. While One runs and a bot token is set, this keeps exactly one helper alive in One's home.
/// It never stops a healthy helper (another One's, or one the engine started); it only fills the gap.
enum Messenger {
    static let tokenKey = "TELEGRAM_BOT_TOKEN"
    /// The engine's `sessions.source` for conversations from a phone chat (the score counts them as "phone").
    static let phoneSources: Set<String> = ["telegram", "whatsapp", "signal", "imessage"]
    nonisolated(unsafe) static var proc: Process?
    nonisolated(unsafe) static var lastStart: Date?

    /// True when One's settings name a Telegram bot (an uncommented, non-empty TELEGRAM_BOT_TOKEN).
    static func wanted(_ envText: String) -> Bool {
        envText.split(whereSeparator: \.isNewline).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("TELEGRAM_BOT_TOKEN=") else { return false }
            return !l.dropFirst("TELEGRAM_BOT_TOKEN=".count).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static var configured: Bool {
        let f = Env.hermesHome.appendingPathComponent(".env")
        // Self-heal permissions on every read too: a copy made by hand (manual setup step) or by an
        // older build before this fix may still be group/other-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        return wanted((try? String(contentsOf: f, encoding: .utf8)) ?? "")
    }

    /// A helper is alive in this home (whoever started it).
    static var helperAlive: Bool {
        guard let pid = GatewayGuard.recordedPID(), kill(pid, 0) == 0 else { return false }
        return GatewayGuard.isGateway(GatewayGuard.arguments(of: pid))
    }

    /// Called every few seconds by the app's housekeeping loop.
    nonisolated(unsafe) static var lastNote = ""
    static func note(_ s: String) {
        if s != lastNote {
            lastNote = s
            GatewayGuard.log("phone chat: " + s)
        }
    }

    static func tend() {
        if Env.selfTest || Env.commandLine {
            return note("skipped: test or command-line copy \(CommandLine.arguments.dropFirst())")
        }
        guard configured else { return note("no bot set up") }
        if let p = proc, p.isRunning { return note("helper running (started by One)") }
        if helperAlive { return note("helper running") }
        // Don't hammer: one start per minute at most (a bad token would otherwise loop).
        if let t = lastStart, Date().timeIntervalSince(t) < 60 { return }
        guard let hp = Env.hermesPath else { return note("no engine yet") }
        lastStart = Date()
        let p = Process()
        // Same folder lock as the engine: the helper runs the same tools.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", Access.profile(), hp, "gateway", "run", "--quiet"]
        p.environment = Env.vars()
        // Not the Brain folder: it sits in Documents, and a new or re-signed One waits on a macOS
        // permission prompt there. The bot must come up even when nobody is at the Mac to click Allow.
        p.currentDirectoryURL = Env.support
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            proc = p
            GatewayGuard.log("phone chat: started the background helper \(p.processIdentifier) (Telegram is set up)")
        } catch {
            GatewayGuard.log("phone chat: couldn't start the background helper: \(error.localizedDescription)")
        }
    }

    /// One is quitting: stop the helper it started itself (never anyone else's).
    static func stop() {
        guard let p = proc, p.isRunning else { return }
        p.terminate()
        proc = nil
    }

    // MARK: Messages sent while One was off (0.9.99)

    /// Nov 6-7 2026: One was down 18 hours and the bot threw away everything sent meanwhile (the engine's default).
    /// Now the bot keeps them, and the engine plugin `one-missed-messages` answers the last 2 hours as usual and lists
    /// older ones in one note instead of acting on them (tools/overlay/plugins/one-missed-messages).
    static let missedPlugin = "one-missed-messages"
    static var missedDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(missedPlugin)", isDirectory: true) }
    static let keepQueued = "platforms.telegram.extra.drop_pending_on_cold_boot"

    /// What `hermes config set` must change: the plugin on, and Telegram keeping what was sent while One was off.
    static func missedFixes(_ config: String) -> [[String]] {
        var fixes: [[String]] = []
        let on = BrowserGuard.enabledPlugins(config)
        if !on.contains(missedPlugin) {
            fixes.append([
                "config", "set", "plugins.enabled", "[" + (on + [missedPlugin]).map { "\"\($0)\"" }.joined(separator: ", ") + "]", "--force",
            ])
        }
        let off = BrowserGuard.enabledPlugins(config, key: "disabled")
        if off.contains(missedPlugin) {
            fixes.append([
                "config", "set", "plugins.disabled", "[" + off.filter { $0 != missedPlugin }.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
                "--force",
            ])
        }
        if !config.contains("drop_pending_on_cold_boot: false") { fixes.append(["config", "set", keepQueued, "false", "--force"]) }
        return fixes
    }

    /// Copies the bundled plugin into One's engine home. False when this copy of One doesn't carry it.
    @discardableResult static func installMissed(from src: URL? = Bundle.main.url(forResource: missedPlugin, withExtension: nil)) -> Bool {
        let fm = FileManager.default
        guard let src, fm.fileExists(atPath: src.appendingPathComponent("__init__.py").path) else { return false }
        try? fm.createDirectory(at: missedDir, withIntermediateDirectories: true)
        for f in ["__init__.py", "plugin.yaml"] {
            let a = src.appendingPathComponent(f)
            let b = missedDir.appendingPathComponent(f)
            if (try? Data(contentsOf: a)) != (try? Data(contentsOf: b)) {
                try? fm.removeItem(at: b)
                guard (try? fm.copyItem(at: a, to: b)) != nil else { return false }
            }
        }
        return true
    }

    /// Before every engine start (through `PhoneVoice.sync`). The bot picks the setting up at its next start.
    static func sync() async {
        guard !Env.selfTest else { return }
        if !installMissed() { GatewayGuard.log("phone chat: the missed-messages plugin isn't in this copy of One") }
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for f in missedFixes(cfg) {
            let (code, out) = await hermesRun(f)
            if code != 0 { GatewayGuard.log("phone chat: couldn't set \(f[2]): \(out.suffix(200))") }
        }
    }
}

// MARK: - The phone hand-off link (PhoneSession.swift): sent only to their own chat, edited when it ends

extension Messenger {
    /// A value from One's engine settings (`hermes/.env`), never logged.
    static func envValue(_ key: String) -> String? {
        let text = (try? String(contentsOf: Env.hermesHome.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix(key + "=") else { continue }
            let v = l.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
    static func bot(_ method: String, _ body: [String: Any]) -> [String: Any]? {
        guard let token = envValue(tokenKey), let u = URL(string: "https://api.telegram.org/bot\(token)/\(method)"),
            let d = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = d
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return out
    }
    /// The hand-off link as one message with an "Open the page" button, to their home chat only. Its message id.
    static func sendLink(_ text: String, url: String) -> Int? {
        guard let chat = envValue("TELEGRAM_HOME_CHANNEL") else { return nil }
        let r = bot("sendMessage", ["chat_id": chat, "text": text, "reply_markup": ["inline_keyboard": [[["text": "Open the page", "url": url]]]]])
        return (r?["result"] as? [String: Any])?["message_id"] as? Int
    }
    /// The same message once the link has ended (the button goes).
    static func editLink(_ id: Int, _ text: String) {
        guard let chat = envValue("TELEGRAM_HOME_CHANNEL") else { return }
        _ = bot("editMessageText", ["chat_id": chat, "message_id": id, "text": text])
    }
}
