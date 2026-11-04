import Darwin
import Foundation

// MARK: - Phone chat (Telegram): keep the engine's background helper running while a bot is set up

/// Hermes talks to Telegram from its background helper (the gateway). The engine only starts that
/// helper when it needs it, so after a restart a phone bot went quiet until someone started it by
/// hand. While One runs and a bot token is set, this keeps exactly one helper alive in One's home.
/// It never stops a healthy helper (another One's, or one the engine started); it only fills the gap.
enum Messenger {
    static let tokenKey = "TELEGRAM_BOT_TOKEN"
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
        let a = GatewayGuard.arguments(of: pid)
        return a.contains("gateway") && a.contains("run")
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
}
