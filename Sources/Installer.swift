import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

/// First launch: installs One's own private copy of Hermes, using Hermes's official installer
/// (bundled in the app), into ~/Library/Application Support/One. No terminal, no questions.
/// HOME points at a scratch folder during the install so it never touches the user's shell files
/// or any Hermes they already have.
enum Installer {
    static var devToolsMissing: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return true }
        return p.terminationStatus != 0
    }
    /// Shows Apple's own "install developer tools" dialog (needed for git).
    static func askForDevTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }
    /// One's additions to the engine (the KeePass password backend). Copies keepass.py and registers it
    /// in base.py by a small text patch, so it survives engine reinstalls and new installs. Safe to run often.
    /// True when the engine already has KeePass plugged in (what applyOverlay sets up).
    static var keepassWired: Bool {
        let vb = Env.engineDir.appendingPathComponent("agent/vault_backends")
        let base = (try? String(contentsOf: vb.appendingPathComponent("base.py"), encoding: .utf8)) ?? ""
        return base.contains("KeePassLoginBackend") && FileManager.default.fileExists(atPath: vb.appendingPathComponent("keepass.py").path)
    }
    @discardableResult static func applyOverlay() -> Bool {
        let fm = FileManager.default
        let vb = Env.engineDir.appendingPathComponent("agent/vault_backends")
        guard let src = Bundle.main.url(forResource: "keepass", withExtension: "py"),
            fm.fileExists(atPath: vb.path)
        else { return false }
        let dst = vb.appendingPathComponent("keepass.py")
        if (try? Data(contentsOf: dst)) != (try? Data(contentsOf: src)) {
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        let basef = vb.appendingPathComponent("base.py")
        guard var t = try? String(contentsOf: basef, encoding: .utf8) else { return false }
        if t.contains("KeePassLoginBackend") { return true }
        let r1 = "    return (OnePasswordLoginBackend, BitwardenLoginBackend)"
        let r2 = "    if name == \"onepassword\":"
        guard t.contains(r1), t.contains(r2) else { return false }
        t = t.replacingOccurrences(
            of: r1,
            with:
                "    from agent.vault_backends.keepass import KeePassLoginBackend\n    return (OnePasswordLoginBackend, BitwardenLoginBackend, KeePassLoginBackend)"
        )
        t = t.replacingOccurrences(
            of: r2,
            with:
                "    if name == \"keepass\":\n        from agent.vault_backends.keepass import find_cli\n        return find_cli(section if isinstance(section, dict) else {}) is not None and bool((section or {}).get(\"database\"))\n"
                + r2)
        return (try? t.write(to: basef, atomically: true, encoding: .utf8)) != nil
    }
    /// Hook appended to the engine's `tools/browser_vault_tool.py`: it loads One's human-step hand-off
    /// (`tools/one_human_step.py`, copied next to it) and never breaks the vault if that fails.
    static let humanStepHook = """

        # One: hand a step only a person can do to the person (tools/one_human_step.py, added by One).
        try:
            from tools.one_human_step import install as _one_human_step_install
            _one_human_step_install(globals())
        except Exception as _one_exc:  # never break the vault
            logger.warning("one_human_step not installed: %s", _one_exc)

        """
    /// Copies the hand-off module into the engine and hooks it into browser_vault (idempotent).
    @discardableResult static func applyHumanStep() -> Bool {
        let fm = FileManager.default
        let tools = Env.engineDir.appendingPathComponent("tools")
        let vault = tools.appendingPathComponent("browser_vault_tool.py")
        guard let src = Bundle.main.url(forResource: "one_human_step", withExtension: "py"),
            fm.fileExists(atPath: vault.path)
        else { return false }
        let dst = tools.appendingPathComponent("one_human_step.py")
        if (try? Data(contentsOf: dst)) != (try? Data(contentsOf: src)) {
            try? fm.removeItem(at: dst)
            guard (try? fm.copyItem(at: src, to: dst)) != nil else { return false }
        }
        guard var t = try? String(contentsOf: vault, encoding: .utf8) else { return false }
        if t.contains("_one_human_step_install") { return true }
        // Only hook a vault that still has the pieces the module wraps.
        guard t.contains("def browser_vault_enter_code("), t.contains("def _handle_vault("), t.contains("BROWSER_VAULT_SCHEMA") else {
            return false
        }
        t += humanStepHook
        return (try? t.write(to: vault, atomically: true, encoding: .utf8)) != nil
    }
    /// Runs the installer, reporting (finished steps, latest line). Returns nil on success or an error.
    static func run(progress: @escaping @Sendable (Int, String) -> Void) async -> String? {
        guard let script = Bundle.main.url(forResource: "hermes-install", withExtension: "sh") else {
            return "The installer is missing from the app."
        }
        let scratch = Env.support.appendingPathComponent("install-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let log = Env.support.appendingPathComponent("install.log")
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                var args = [script.path, "--non-interactive", "--hermes-home", Env.hermesHome.path, "--dir", Env.engineDir.path]
                // Install the Hermes version One was tested with, not whatever is newest (see build.sh HERMES_COMMIT).
                if let c = Bundle.main.url(forResource: "hermes-commit", withExtension: "txt").flatMap({
                    try? String(contentsOf: $0, encoding: .utf8)
                })?
                .trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                    args += ["--commit", c]
                }
                p.arguments = args
                p.environment = [
                    "HOME": scratch.path, "USER": NSUserName(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
                ]
                p.currentDirectoryURL = Env.support
                let o = Pipe()
                p.standardOutput = o
                p.standardError = o
                p.standardInput = FileHandle.nullDevice
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let lh = try? FileHandle(forWritingTo: log)
                let done = Box(0)
                let all = Box("")
                o.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    lh?.write(d)
                    let t = String(decoding: d, as: UTF8.self)
                    all.v += t
                    for line in t.split(separator: "\n") {
                        let l = line.trimmingCharacters(in: .whitespaces)
                        if l.hasPrefix("✓") {
                            done.v += 1
                            progress(done.v, String(l.dropFirst(2)))
                        } else if l.hasPrefix("→") {
                            progress(done.v, String(l.dropFirst(2)))
                        }
                    }
                }
                do { try p.run() } catch {
                    cont.resume(returning: error.localizedDescription)
                    return
                }
                p.waitUntilExit()
                o.fileHandleForReading.readabilityHandler = nil
                try? lh?.close()
                if p.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: Env.ownHermes) {
                    try? FileManager.default.removeItem(at: scratch)
                    applyOverlay()
                    applyHumanStep()
                    BundledSkills.sync()
                    _ = GoogleSignIn.ensureVenv()
                    cont.resume(returning: nil)
                } else {
                    let last = all.v.split(separator: "\n").last(where: {
                        $0.contains("✗") || $0.lowercased().contains("fail") || $0.lowercased().contains("error")
                    })
                    cont.resume(returning: last.map(String.init) ?? "The setup stopped (code \(p.terminationStatus)).")
                }
            }
        }
    }
}

/// Runs a short Hermes command (status, config) and returns its output.
func hermesRun(_ args: [String], timeout: TimeInterval = 90) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            guard let hp = Env.hermesPath else {
                cont.resume(returning: (-1, "hermes not found"))
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hp)
            p.arguments = args
            p.environment = Env.vars()
            p.currentDirectoryURL = Env.support
            let o = Pipe()
            p.standardOutput = o
            p.standardError = o
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let d = o.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
        }
    }
}

// MARK: - The AIs the user can bring

enum Provider: String, CaseIterable, Identifiable {
    case claude, chatgpt, grok, openrouter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .grok: "Grok"
        case .openrouter: "OpenRouter"
        }
    }
    var subtitle: String {
        switch self {
        case .claude: "If you pay for Claude Pro or Max"
        case .chatgpt: "If you pay for ChatGPT Plus or Pro"
        case .grok: "If you pay for SuperGrok or X Premium+"
        case .openrouter: "Don't have one? Pay as you go, any AI"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "bubble.left.and.bubble.right"
        case .grok: "bolt"
        case .openrouter: "arrow.triangle.branch"
        }
    }
    /// Hermes's own provider id and the model One starts with.
    var hermesID: String {
        switch self {
        case .claude: "anthropic"
        case .chatgpt: "openai-codex"
        case .grok: "xai-oauth"
        case .openrouter: "openrouter"
        }
    }
    var defaultModel: String { models[0] }
    /// The three plain choices people see: Smartest, Balanced, Fastest.
    var tiers: [(String, String)] {
        switch self {
        case .claude: [("Smartest", "claude-opus-5-5"), ("Balanced", "claude-sonnet-5"), ("Fastest", "claude-haiku-5-5")]
        case .chatgpt: [("Smartest", "gpt-6.1-sol"), ("Balanced", "gpt-6-sol"), ("Fastest", "gpt-5.4-mini")]
        case .grok: [("Smartest", "grok-4.6"), ("Balanced", "grok-4.20-0309-reasoning"), ("Fastest", "grok-4.20-0309-non-reasoning")]
        case .openrouter:
            [("Smartest", "anthropic/claude-opus-5.5"), ("Balanced", "anthropic/claude-sonnet-5.5"), ("Fastest", "google/gemini-3-flash-preview")]
        }
    }
    /// Tried in order until one answers (plans don't all allow the same models).
    var models: [String] {
        switch self {
        case .claude: ["claude-sonnet-5", "claude-opus-5", "claude-sonnet-4-6"]
        case .chatgpt: ["gpt-6-sol", "gpt-5.6-sol", "gpt-6-luna", "gpt-5.6-terra"]
        case .grok: ["grok-4.6", "grok-4.20-0309-reasoning"]
        case .openrouter: ["openrouter/auto"]
        }
    }
}

// MARK: - Sign-in, driven through Hermes's own login flows

enum SignInEvent: Sendable {
    case openPage(URL)
    case code(String)
    case needPaste
    case done(Bool, String)
}

final class SignIn: @unchecked Sendable {
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = ""
    private var opened = false, sentCode = false, askedPaste = false
    private let lock = NSLock()

    func start(_ p: Provider, events: @escaping @Sendable (SignInEvent) -> Void) {
        guard let hp = Env.hermesPath else {
            events(.done(false, "Hermes isn't on this Mac yet."))
            return
        }
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: hp)
        pr.arguments = ["auth", "add", p.hermesID, "--type", "oauth", "--no-browser", "--timeout", "900"]
        pr.environment = Env.vars()
        pr.currentDirectoryURL = Env.support
        let out = Pipe()
        let inp = Pipe()
        pr.standardOutput = out
        pr.standardError = out
        pr.standardInput = inp
        input = inp.fileHandleForWriting
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            // Strip terminal color codes so links and codes read cleanly.
            let clean = String(decoding: d, as: UTF8.self)
                .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            self.lock.lock()
            self.buffer += clean
            self.lock.unlock()
            self.scan(events)
        }
        pr.terminationHandler = { [weak self] t in
            out.fileHandleForReading.readabilityHandler = nil
            let ok = t.terminationStatus == 0
            let tail = self?.buffer.split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            events(.done(ok, ok ? "" : String(tail.prefix(240))))
        }
        do {
            try pr.run()
            proc = pr
        } catch { events(.done(false, error.localizedDescription)) }
    }

    private func scan(_ events: @Sendable (SignInEvent) -> Void) {
        lock.lock()
        let b = buffer
        lock.unlock()
        let trimmed = b.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("[y/N]:") || trimmed.hasSuffix("[Y/n]:") || trimmed.hasSuffix("[y/n]:") {
            input?.write(Data("n\n".utf8))  // always a fresh, separate login for One
            lock.lock()
            buffer += "\n"
            lock.unlock()
        }
        if !opened, let r = b.range(of: #"https://[^\s\)\]>"']+"#, options: .regularExpression),
            let u = URL(string: String(b[r]))
        {
            opened = true
            events(.openPage(u))
        }
        if !sentCode, let r = b.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4,6}\b"#, options: .regularExpression) {
            sentCode = true
            events(.code(String(b[r])))
        }
        if !askedPaste, b.contains("Authorization code") {
            askedPaste = true
            events(.needPaste)
        }
    }

    func paste(_ code: String) { input?.write(Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)) }
    func cancel() { if let p = proc, p.isRunning { p.terminate() } }

    static func isSignedIn(_ p: Provider) async -> Bool {
        let (_, out) = await hermesRun(["auth", "status", p.hermesID], timeout: 60)
        return out.lowercased().contains(": logged in")
    }
    /// Routines ("check this every morning", "watch this price"): the engine's editor tool set leaves out
    /// scheduling, so One adds it back. Their results land in hermes/cron/output, which One reads aloud.
    static func enableRoutines() async {
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        if cfg.contains("  acp:\n    - hermes-acp\n    - cronjob") { return }
        _ = await hermesRun(["config", "set", "platform_toolsets.acp", "[\"hermes-acp\", \"cronjob\"]"])
    }
    static func makeDefault(_ p: Provider, model: String? = nil) async {
        _ = await hermesRun(["config", "set", "model.provider", p.hermesID])
        _ = await hermesRun(["config", "set", "model.default", model ?? p.defaultModel])
    }
}

/// Sign in with Google from One itself: a small Python helper opens the browser and saves the login
/// where the Google skill reads it (hermes/google_tokens/<email>.json). Returns the email, or nil.
enum GoogleSignIn {
    /// On by default. The Google app is published but unverified: people see Google's "not verified" screen once,
    /// and at most 100 people can sign in until Google's review. Without the bundled client file it falls back to the Mac's accounts.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "googleSignIn") && Bundle.main.url(forResource: "google_client_secret", withExtension: "json") != nil
    }
    static var venv: URL { Env.support.appendingPathComponent("tools-venv") }
    static func ensureVenv() -> Bool {
        let py = venv.appendingPathComponent("bin/python")
        if FileManager.default.isExecutableFile(atPath: py.path),
            shell(py.path, ["-c", "import google_auth_oauthlib, googleapiclient"]) == 0
        {
            return true
        }
        let tools = Env.hermesHome.appendingPathComponent("tools")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []
        guard let uvDir = names.first(where: { $0.hasPrefix("uv-") }), let pyDir = names.first(where: { $0.hasPrefix("python-") }) else {
            return false
        }
        let uv = tools.appendingPathComponent("\(uvDir)/uv").path
        guard shell(uv, ["venv", "-q", "--python", tools.appendingPathComponent("\(pyDir)/bin/python3").path, venv.path]) == 0 else { return false }
        var env = Env.vars()
        env["VIRTUAL_ENV"] = venv.path
        guard
            shell(
                uv,
                [
                    "pip", "install", "-q", "google-api-python-client", "google-auth-oauthlib", "google-auth-httplib2", "websockets", "requests",
                    "pyyaml",
                ], env: env) == 0
        else { return false }
        linkTools()
        return true
    }
    /// Skills call `$HOME/.cache/one-py/bin/python`: a path with no spaces that points at One's tools Python.
    static func linkTools() {
        guard !Env.selfTest, ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] == nil else { return }
        let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/one-py")
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == venv.path { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: venv)
    }
    @discardableResult static func shell(_ exe: String, _ args: [String], env: [String: String]? = nil, out: Pipe? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        p.standardOutput = out ?? FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    static func run() async -> String? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                guard let script = Bundle.main.url(forResource: "google_signin", withExtension: "py"),
                    let secret = Bundle.main.url(forResource: "google_client_secret", withExtension: "json")
                        ?? Optional(Env.hermesHome.appendingPathComponent("google_client_secret.json")),
                    FileManager.default.fileExists(atPath: secret.path), ensureVenv()
                else {
                    c.resume(returning: nil)
                    return
                }
                let o = Pipe()
                let rc = shell(venv.appendingPathComponent("bin/python").path, ["-I", script.path, secret.path, Env.hermesHome.path], out: o)
                let txt = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let email = (try? JSONSerialization.jsonObject(with: Data(txt.utf8)) as? [String: String])?["email"]
                c.resume(returning: rc == 0 ? email : nil)
            }
        }
    }
}
