// One — a one-button personal assistant (test build 0.2).
// The face is this app. The engine is Hermes, run privately for One via ACP.
// Setup is a conversation the assistant leads. The user never sees a terminal.
import SwiftUI
import AppKit
import AVFoundation
import Speech

// MARK: - Paths and environment

enum Env {
    nonisolated(unsafe) static var selfTest = false
    static var support: URL {
        let base = ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
        let u = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("One", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// One's own Hermes home: separate from any Hermes the user already runs.
    static var hermesHome: URL {
        let u = support.appendingPathComponent(selfTest ? "selftest-hermes" : "hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// One's own copy of Hermes, installed on first launch. Never the user's own Hermes.
    static var engineDir: URL { support.appendingPathComponent("engine", isDirectory: true) }
    static var ownHermes: String { engineDir.appendingPathComponent(".hermes/bin/hermes").path }
    static var hermesPath: String? {
        if FileManager.default.isExecutableFile(atPath: ownHermes) { return ownHermes }
        // Developer fallback (ONE_USE_SYSTEM_HERMES=1): use an existing install.
        guard ProcessInfo.processInfo.environment["ONE_USE_SYSTEM_HERMES"] == "1" || selfTest else { return nil }
        let h = NSHomeDirectory()
        return ["\(h)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func vars() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        let h = NSHomeDirectory()
        e["PATH"] = "\(engineDir.path)/.hermes/bin:\(h)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HERMES_HOME"] = hermesHome.path
        e["PYTHONUNBUFFERED"] = "1"; e["NO_COLOR"] = "1"; e["TERM"] = "dumb"
        // One's folder lock already wraps everything; Chrome can't start a second sandbox inside it.
        e["AGENT_BROWSER_ARGS"] = "--no-sandbox,--disable-dev-shm-usage"
        e["HERMES_YOLO_MODE"] = "1"   // regular people can't judge "script execution" prompts
        // The browser helper keeps its files in ~/.config by default, which the folder lock closes.
        e["BH_HOME"] = support.appendingPathComponent("browser").path
        e["BH_RUNTIME_DIR"] = "/tmp/one-bh-\(getuid())"   // short path: socket names have a length limit
        for k in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "OPENAI_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
            e.removeValue(forKey: k)
        }
        if !selfTest { e.removeValue(forKey: "OPENROUTER_API_KEY") }
        return e
    }
}

final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

/// First launch: installs One's own private copy of Hermes, using Hermes's official installer
/// (bundled in the app), into ~/Library/Application Support/One. No terminal, no questions.
/// HOME points at a scratch folder during the install so it never touches the user's shell files
/// or any Hermes they already have.
enum Installer {
    static var devToolsMissing: Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return true }
        return p.terminationStatus != 0
    }
    /// Shows Apple's own "install developer tools" dialog (needed for git).
    static func askForDevTools() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["--install"]
        try? p.run()
    }
    /// Runs the installer, reporting (finished steps, latest line). Returns nil on success or an error.
    static func run(progress: @escaping @Sendable (Int, String) -> Void) async -> String? {
        guard let script = Bundle.main.url(forResource: "hermes-install", withExtension: "sh") else { return "The installer is missing from the app." }
        let scratch = Env.support.appendingPathComponent("install-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let log = Env.support.appendingPathComponent("install.log")
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script.path, "--non-interactive", "--hermes-home", Env.hermesHome.path, "--dir", Env.engineDir.path]
                p.environment = ["HOME": scratch.path, "USER": NSUserName(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8",
                                 "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
                p.currentDirectoryURL = Env.support
                let o = Pipe(); p.standardOutput = o; p.standardError = o; p.standardInput = FileHandle.nullDevice
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let lh = try? FileHandle(forWritingTo: log)
                let done = Box(0), all = Box("")
                o.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; guard !d.isEmpty else { return }
                    lh?.write(d)
                    let t = String(decoding: d, as: UTF8.self); all.v += t
                    for line in t.split(separator: "\n") {
                        let l = line.trimmingCharacters(in: .whitespaces)
                        if l.hasPrefix("✓") { done.v += 1; progress(done.v, String(l.dropFirst(2))) }
                        else if l.hasPrefix("→") { progress(done.v, String(l.dropFirst(2))) }
                    }
                }
                do { try p.run() } catch { cont.resume(returning: error.localizedDescription); return }
                p.waitUntilExit()
                o.fileHandleForReading.readabilityHandler = nil
                try? lh?.close()
                if p.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: Env.ownHermes) {
                    try? FileManager.default.removeItem(at: scratch)
                    cont.resume(returning: nil)
                } else {
                    let last = all.v.split(separator: "\n").last(where: { $0.contains("✗") || $0.lowercased().contains("fail") || $0.lowercased().contains("error") })
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
            guard let hp = Env.hermesPath else { cont.resume(returning: (-1, "hermes not found")); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hp)
            p.arguments = args
            p.environment = Env.vars()
            p.currentDirectoryURL = Env.support
            let o = Pipe(); p.standardOutput = o; p.standardError = o; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let d = o.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
        }
    }
}

// MARK: - Voice (pre-rendered ElevenLabs lines for onboarding)

@MainActor
final class Voice {
    static let shared = Voice()
    private var player: AVAudioPlayer?
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceMuted"); if newValue { player?.stop() } }
    }
    /// Plays a line and returns how long it lasts (0 if muted or missing).
    @discardableResult
    func play(_ key: String) -> Double {
        guard !muted, let url = Bundle.main.url(forResource: key, withExtension: "mp3"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        player?.stop(); player = p; p.play()
        return p.duration
    }
    func stop() { player?.stop() }
}

// MARK: - The AIs the user can bring

enum Provider: String, CaseIterable, Identifiable {
    case claude, chatgpt, grok, openrouter
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: "Claude"; case .chatgpt: "ChatGPT"; case .grok: "Grok"; case .openrouter: "OpenRouter" }
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
        case .claude: "sparkle"; case .chatgpt: "bubble.left.and.bubble.right"
        case .grok: "bolt"; case .openrouter: "arrow.triangle.branch"
        }
    }
    /// Hermes's own provider id and the model One starts with.
    var hermesID: String {
        switch self { case .claude: "anthropic"; case .chatgpt: "openai-codex"; case .grok: "xai-oauth"; case .openrouter: "openrouter" }
    }
    var defaultModel: String { models[0] }
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

enum SignInEvent: Sendable { case openPage(URL), code(String), needPaste, done(Bool, String) }

final class SignIn: @unchecked Sendable {
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = ""
    private var opened = false, sentCode = false, askedPaste = false
    private let lock = NSLock()

    func start(_ p: Provider, events: @escaping @Sendable (SignInEvent) -> Void) {
        guard let hp = Env.hermesPath else { events(.done(false, "Hermes isn't on this Mac yet.")); return }
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: hp)
        pr.arguments = ["auth", "add", p.hermesID, "--type", "oauth", "--no-browser", "--timeout", "900"]
        pr.environment = Env.vars()
        pr.currentDirectoryURL = Env.support
        let out = Pipe(), inp = Pipe()
        pr.standardOutput = out; pr.standardError = out; pr.standardInput = inp
        input = inp.fileHandleForWriting
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            // Strip terminal color codes so links and codes read cleanly.
            let clean = String(decoding: d, as: UTF8.self)
                .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            self.lock.lock(); self.buffer += clean; self.lock.unlock()
            self.scan(events)
        }
        pr.terminationHandler = { [weak self] t in
            out.fileHandleForReading.readabilityHandler = nil
            let ok = t.terminationStatus == 0
            let tail = self?.buffer.split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            events(.done(ok, ok ? "" : String(tail.prefix(240))))
        }
        do { try pr.run(); proc = pr } catch { events(.done(false, error.localizedDescription)) }
    }

    private func scan(_ events: @Sendable (SignInEvent) -> Void) {
        lock.lock(); let b = buffer; lock.unlock()
        let trimmed = b.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("[y/N]:") || trimmed.hasSuffix("[Y/n]:") || trimmed.hasSuffix("[y/n]:") {
            input?.write(Data("n\n".utf8))   // always a fresh, separate login for One
            lock.lock(); buffer += "\n"; lock.unlock()
        }
        if !opened, let r = b.range(of: #"https://[^\s\)\]>"']+"#, options: .regularExpression),
           let u = URL(string: String(b[r])) {
            opened = true; events(.openPage(u))
        }
        if !sentCode, let r = b.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4,6}\b"#, options: .regularExpression) {
            sentCode = true; events(.code(String(b[r])))
        }
        if !askedPaste, b.contains("Authorization code") { askedPaste = true; events(.needPaste) }
    }

    func paste(_ code: String) { input?.write(Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)) }
    func cancel() { if let p = proc, p.isRunning { p.terminate() } }

    static func isSignedIn(_ p: Provider) async -> Bool {
        let (_, out) = await hermesRun(["auth", "status", p.hermesID], timeout: 60)
        return out.lowercased().contains(": logged in")
    }
    static func makeDefault(_ p: Provider, model: String? = nil) async {
        _ = await hermesRun(["config", "set", "model.provider", p.hermesID])
        _ = await hermesRun(["config", "set", "model.default", model ?? p.defaultModel])
    }
}

// MARK: - The engine: Hermes over ACP (JSON-RPC on stdin/stdout)

final class Engine: @unchecked Sendable {
    static let shared = Engine()
    private let lock = NSLock()
    private var proc: Process?
    private var stdin: FileHandle?
    private var buf = Data()
    private var nextID = 100
    private var waiting: [Int: (Any) -> Void] = [:]
    private var sessionID: String?

    var onText: (@Sendable (String) -> Void)?
    var onTool: (@Sendable (String) -> Void)?
    /// (question, options[(id, label)], answer)
    var onPermission: (@Sendable (String, [(String, String)], @escaping @Sendable (String?) -> Void) -> Void)?

    /// Hermes keeps a background helper per home; restart it so it picks up the current folder limits.
    static func stopStrayGateway() {
        let f = Env.hermesHome.appendingPathComponent("gateway.pid")
        guard let d = try? Data(contentsOf: f),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = j["pid"] as? Int, pid > 1 else { return }
        kill(pid_t(pid), SIGTERM)
        usleep(900_000)
    }

    static func isBrainEdit(_ title: String) -> Bool {
        let prefix = "Approve edit: "
        guard title.hasPrefix(prefix), Brain.exists else { return false }
        let paths = title.dropFirst(prefix.count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let root = Brain.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return !paths.isEmpty && paths.allSatisfy { p in
            let r = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
            return r.hasPrefix(root) && !r.contains("/.git/") && !r.contains("/confidential/")
        }
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true && sessionID != nil }

    func stop() {
        lock.lock(); let p = proc; proc = nil; sessionID = nil
        let w = waiting; waiting = [:]; lock.unlock()
        w.values.forEach { $0(["error": "stopped"]) }
        if let p, p.isRunning { p.terminate() }
    }

    private var starting: Task<String?, Never>?
    /// Starts the engine once; anyone who asks while it's starting waits for that same start.
    func ensureStarted() async -> String? {
        if running { return nil }
        lock.lock()
        if let t = starting { lock.unlock(); return await t.value }
        let t = Task { await self.start() }
        starting = t; lock.unlock()
        let r = await t.value
        lock.lock(); starting = nil; lock.unlock()
        return r
    }

    func start() async -> String? {
        stop()
        guard let hp = Env.hermesPath else { return "Hermes isn't on this Mac yet." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hp)
        Engine.stopStrayGateway()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", Access.profile(), hp, "acp"]
        p.environment = Env.vars()
        let cwd = Brain.exists ? Brain.root : Env.support
        p.currentDirectoryURL = cwd
        let o = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardInput = i
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.feed(d) }
        }
        do { try p.run() } catch { return error.localizedDescription }
        lock.lock(); proc = p; stdin = i.fileHandleForWriting; buf = Data(); lock.unlock()
        let ini = await call("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()], timeout: 120)
        guard ini["result"] != nil else { return "The assistant didn't start." }
        let dir = (Brain.exists ? Brain.root : Env.support).path
        // Pick up the same conversation after a restart, so it remembers what you were doing.
        if let saved = UserDefaults.standard.string(forKey: "sessionID") {
            onText = nil; onTool = nil
            let r = await call("session/load", ["sessionId": saved, "cwd": dir, "mcpServers": [Any]()], timeout: 120)
            if r["error"] == nil, r["result"] != nil, !(r["result"] is NSNull) {
                lock.lock(); sessionID = saved; lock.unlock()
                return nil
            }
        }
        let new = await call("session/new", ["cwd": dir, "mcpServers": [Any]()], timeout: 120)
        guard let r = new["result"] as? [String: Any], let sid = r["sessionId"] as? String else {
            return "The assistant couldn't open a conversation."
        }
        lock.lock(); sessionID = sid; lock.unlock()
        UserDefaults.standard.set(sid, forKey: "sessionID")
        return nil
    }

    /// Sends one message; text streams through onText. Returns the stop reason or "error: …".
    func prompt(_ text: String) async -> String {
        lock.lock(); let sid = sessionID; lock.unlock()
        var id = sid
        if id == nil, await ensureStarted() == nil { lock.lock(); id = sessionID; lock.unlock() }
        guard let sid = id else { return "error: not started" }
        let r = await call("session/prompt", ["sessionId": sid, "prompt": [["type": "text", "text": text]]], timeout: 900)
        if let res = r["result"] as? [String: Any] { return res["stopReason"] as? String ?? "end_turn" }
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        return "error: \(r["error"] ?? "no answer")"
    }

    func cancel() {
        lock.lock(); let sid = sessionID; lock.unlock()
        guard let sid else { return }
        write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sid]])
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async -> [String: Any] {
        await withCheckedContinuation { cont in
            lock.lock(); nextID += 1; let id = nextID; lock.unlock()
            let once = Box(false)
            let finish: (Any) -> Void = { v in
                self.lock.lock(); let first = !once.v; once.v = true; self.lock.unlock()
                if first { cont.resume(returning: v as? [String: Any] ?? [:]) }
            }
            lock.lock(); waiting[id] = finish; lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock(); let f = self.waiting.removeValue(forKey: id); self.lock.unlock()
                f?(["error": "timed out"])
            }
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        lock.lock(); let h = stdin; lock.unlock()
        h?.write(d + Data("\n".utf8))
    }

    private func feed(_ d: Data) {
        lock.lock(); buf.append(d); var lines: [Data] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            lines.append(Data(buf[buf.startIndex..<nl])); buf = Data(buf[buf.index(after: nl)...])
        }
        lock.unlock()
        for l in lines { if let j = try? JSONSerialization.jsonObject(with: l) as? [String: Any] { handle(j) } }
    }

    private func handle(_ m: [String: Any]) {
        let method = m["method"] as? String
        if method == nil, let id = m["id"] as? Int {
            lock.lock(); let f = waiting.removeValue(forKey: id); lock.unlock()
            f?(m); return
        }
        let params = m["params"] as? [String: Any] ?? [:]
        if method == "session/update", let u = params["update"] as? [String: Any] {
            switch u["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if let c = u["content"] as? [String: Any], let t = c["text"] as? String { onText?(t) }
            case "tool_call":
                if let t = u["title"] as? String { onTool?(t) }
            default: break
            }
            return
        }
        guard let id = m["id"] else { return }   // a request from Hermes to us
        if method == "session/request_permission" {
            let tc = params["toolCall"] as? [String: Any] ?? [:]
            let title = tc["title"] as? String ?? "Do something on your Mac"
            let opts = (params["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, String)? in
                guard let oid = o["optionId"] as? String else { return nil }
                return (oid, o["name"] as? String ?? oid)
            }
            let reply: @Sendable (String?) -> Void = { choice in
                let outcome: [String: Any] = choice.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
                self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
            }
            // No technical permission prompts: the folder lock and the engine's catastrophic-command floor
            // are the guardrails. Money, sending, posting and deleting are asked in plain words (SOUL.md).
            if let ok = opts.first(where: { $0.0 == "allow_once" || $0.0.hasPrefix("allow") }) { reply(ok.0); return }
            if let ask = onPermission { ask(title, opts, reply) } else { reply(nil) }
        } else {
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported by One"]])
        }
    }
}

// MARK: - Folder access (macOS sandbox around the engine)

enum Access {
    nonisolated(unsafe) static var override: [String]?
    static var folders: [String] {
        if let o = override { return o }
        return (UserDefaults.standard.string(forKey: "folders") ?? "").split(separator: "\n").map(String.init)
    }
    static func set(_ f: [String]) { UserDefaults.standard.set(f.joined(separator: "\n"), forKey: "folders") }
    /// Everything in the home folder is closed except the engine itself, the brain and the folders the user approved.
    static func profile() -> String {
        let h = NSHomeDirectory()
        func q(_ p: String) -> String {
            "(subpath \"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\")"
        }
        let rw = [Env.support.path, Brain.root.path, "\(h)/.cache", "\(h)/Library/Caches"] + folders
        var ro = ["\(h)/.local"]
        if Env.hermesPath != Env.ownHermes { ro += ["\(h)/.hermes/hermes-agent", "\(h)/.hermes/tools", "\(h)/.hermes/node"] }
        return """
        (version 1)
        (allow default)
        (deny file-read-data file-write* (subpath "\(h)"))
        (allow file-read-data \((ro + rw).map(q).joined(separator: " ")))
        (allow file-write* \(rw.map(q).joined(separator: " ")))
        """
    }
}

// MARK: - The brain (built from the AI Brain Starter, kept as local folders)

enum RoomKind: String, CaseIterable, Identifiable {
    case personal, work, cofounder, privateRoom
    var id: String { rawValue }
    var folder: String {
        switch self { case .personal: "personal-room"; case .work: "work-room"; case .cofounder: "cofounder-room"; case .privateRoom: "private-room" }
    }
    var title: String {
        switch self { case .personal: "personal room"; case .work: "work room"; case .cofounder: "co-founder room"; case .privateRoom: "private room" }
    }
    var chip: String {
        switch self { case .personal: "No, start simple"; case .work: "My job"; case .cofounder: "A business I'm starting"; case .privateRoom: "Something just for me" }
    }
    var hub: String {
        switch self { case .personal: "brain/life.md"; case .work: "brain/jobs.md"; case .cofounder: "brain/company.md"; case .privateRoom: "brain/notes.md" }
    }
    var holds: String {
        switch self {
        case .personal: "home, family, health, money, relationships, hobbies, creative work, learning, long-term goals, community."
        case .work: "your own notes about your job or jobs: commitments, people, wins, how you work best."
        case .cofounder: "a business you run or are starting: ideas, buyers, the offer, the pipeline."
        case .privateRoom: "whatever you want kept just for you."
        }
    }
    var never: String {
        switch self {
        case .personal: "a job's work, a business."
        case .work: "your employer's code, data, documents or customer information. Personal life. A business of your own."
        case .cofounder: "personal life, a job's work."
        case .privateRoom: "anything from the other rooms. It never appears in summaries or cross-room answers."
        }
    }
    var rule: String {
        switch self {
        case .personal: "it's the default room: everything personal starts here."
        case .work: "an employer's material never enters the brain. Only your own notes about your work."
        case .cofounder: "it pushes toward buyers and revenue, and it may one day be shared with a partner."
        case .privateRoom: "it's private. Other rooms don't read it, and it's left out of every brief and summary."
        }
    }
    var hubText: String {
        switch self {
        case .personal: "# My life, as it stands\n\n## This week\n- **The one thing that matters:** [not yet]\n- **Dates coming up:** [not yet]\n\n## By area\n| Area | What's active | Next step | Note |\n|---|---|---|---|\n\n## Long projects\n\n## Parked\n"
        case .work: "# My jobs, as they stand\n\n## This week\n- **The one thing that matters:** [not yet]\n\n## By job\n| Job | Hours | What's due | Who I owe | Note |\n|---|---|---|---|---|\n\n## Wins to remember\n"
        case .cofounder: ""
        case .privateRoom: "# Just for me\n\n[not yet]\n"
        }
    }
}

enum Brain {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Env.selfTest ? Env.support.appendingPathComponent("selftest-brain") : docs.appendingPathComponent("My Brain")
    }
    static var starter: URL? { Bundle.main.url(forResource: "brain-starter", withExtension: nil) }
    static var exists: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) }
    static var rooms: [RoomKind] {
        RoomKind.allCases.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.folder).path) }
    }

    /// Creates the brain (once) and any rooms asked for that don't exist yet.
    static func build(owner: String, ai: String, rooms want: [RoomKind]) -> String? {
        let fm = FileManager.default
        guard let st = starter else { return "The brain starter isn't inside the app." }
        if !exists {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            for f in ["AGENTS.md", "BRAIN.md", "HELP.md", "LICENSE.md", "README.md", "CLAUDE.md", "GEMINI.md", "owner.yaml", "starter.yaml", "agents", "skills", "templates"] {
                let src = st.appendingPathComponent(f)
                if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: root.appendingPathComponent(f)) }
            }
            let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let oy = root.appendingPathComponent("owner.yaml")
            if var y = try? String(contentsOf: oy, encoding: .utf8) {
                y = y.replacingOccurrences(of: "name: \"\"   ", with: "name: \"\(owner)\"", options: [], range: y.range(of: "name: \"\"   "))
                y = y.replacingOccurrences(of: "computer: \"\"", with: "computer: \"mac\"")
                y = y.replacingOccurrences(of: "tool: \"\"", with: "tool: \"one-app\"")
                y = y.replacingOccurrences(of: "set_up: \"\"", with: "set_up: \"\(today)\"")
                y += "\n# Kept by the One app: rooms are local folders on this Mac. Backup is the app's job.\nstorage: local\n"
                try? y.write(to: oy, atomically: true, encoding: .utf8)
            }
        }
        var all = Set(rooms); all.insert(.personal); want.forEach { all.insert($0) }
        let ordered = RoomKind.allCases.filter { all.contains($0) }
        for k in ordered where !fm.fileExists(atPath: root.appendingPathComponent(k.folder).path) {
            let dest = root.appendingPathComponent(k.folder)
            let tpl = st.appendingPathComponent(k == .cofounder ? "templates/cofounder-room" : "templates/room")
            do { try fm.copyItem(at: tpl, to: dest) } catch { return "Couldn't make the \(k.title): \(error.localizedDescription)" }
            let others = ordered.filter { $0 != k }.map { "the \($0.title) (`../\($0.folder)/`)" }.joined(separator: ", ")
            let fill: [String: String] = [
                "{{OWNER}}": owner, "{{AI}}": ai, "{{ROOM}}": k.folder, "{{ROOM_TITLE}}": k.title,
                "{{HOLDS}}": k.holds, "{{NEVER}}": k.never, "{{HUB}}": k.hub, "{{RULE}}": k.rule,
                "{{OTHER_ROOMS}}": others.isEmpty ? "No other rooms yet." : "Other rooms: \(others).",
                "{{CONFIDENTIAL}}": "money figures, health detail, other people's private information, anything \(owner) wouldn't want read out loud.",
            ]
            if let en = fm.enumerator(at: dest, includingPropertiesForKeys: nil) {
                for case let f as URL in en where ["md", "yaml", "json"].contains(f.pathExtension) {
                    guard var t = try? String(contentsOf: f, encoding: .utf8), t.contains("{{") else { continue }
                    for (a, b) in fill { t = t.replacingOccurrences(of: a, with: b) }
                    try? t.write(to: f, atomically: true, encoding: .utf8)
                }
            }
            if !k.hubText.isEmpty {
                let hub = dest.appendingPathComponent(k.hub)
                try? fm.createDirectory(at: hub.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: hub.path) { try? k.hubText.write(to: hub, atomically: true, encoding: .utf8) }
            }
            // One row per room in the brain's table.
            let ag = root.appendingPathComponent("AGENTS.md")
            if var t = try? String(contentsOf: ag, encoding: .utf8) {
                let row = "| \(k.title.capitalized) | `\(k.folder)/` | \(ai) | `\(k.hub)` | \(k.holds) | \(k.never) |\n"
                t = t.replacingOccurrences(of: "<!-- add-room adds one row per room above this line -->", with: row + "<!-- add-room adds one row per room above this line -->")
                try? t.write(to: ag, atomically: true, encoding: .utf8)
            }
            let mem = dest.appendingPathComponent("memory")
            try? fm.createDirectory(at: mem, withIntermediateDirectories: true)
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let line = "- Decided (\(owner), \(day)): the \(k.title) was set up in the One app.\n"
            let mf = mem.appendingPathComponent("\(day).md")
            if let h = try? FileHandle(forWritingTo: mf) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: mf, atomically: true, encoding: .utf8) }
        }
        return nil
    }

    /// Mirrors the brain into iCloud Drive (plain copy, newest wins). Returns an error or nil.
    static func backupToICloud() -> String? {
        let icloud = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: icloud.path) else { return "iCloud Drive isn't turned on for this Mac." }
        let dest = icloud.appendingPathComponent(Env.selfTest ? "One selftest backup" : "My Brain (backup)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", "--exclude", ".DS_Store", root.path + "/", dest.path + "/"]
        do { try p.run(); p.waitUntilExit() } catch { return error.localizedDescription }
        return p.terminationStatus == 0 ? nil : "The copy to iCloud didn't finish."
    }
}

// MARK: - Who the assistant is (written into One's own Hermes)

enum Persona {
    static func write(assistant: String, user: String, connections: [String], passwords: String) {
        let who = user.isEmpty ? "the user" : user
        let soul = """
        You are \(assistant.isEmpty ? "the assistant" : assistant), \(who)'s personal assistant. You run on their own Mac, not in the cloud.

        How you talk:
        - Like a helpful friend: short, warm, plain words. No jargon.
        - Never mention Hermes, models, terminals, config files or tools unless they ask how you work.
        - Offer one clear next step, not a menu.
        - When you ask them to decide something, end your message with one last line listing 2 to 4 short answers they can tap, exactly like: [choices: Yes, go ahead | Not now | Change the plan]. Keep each answer under 5 words. Don't list them anywhere else in the message.

        Always ask for a yes first before you: buy anything, move money, send a message or email as them, post anywhere, delete anything, or change a password. Say exactly what you're about to do and what it costs.

        If the Mac is closed or off, you're off. Say so if they ask why you didn't do something.

        Folders you can open: \(Access.folders.isEmpty ? "none yet" : Access.folders.joined(separator: ", ")), plus their brain. Anything else is locked by the Mac. If they ask about another folder, say you don't have access yet and that they can add it with the Folders button.

        Your memory is their brain: the folder "\(Brain.root.path)". Its AGENTS.md says how it works: one room at a time, the personal room by default, a new room only when the rules differ, never just for a topic. Follow it. In this app the rooms are local folders: skip any GitHub, repository, git-crypt or key steps in its skills; backup is handled by the app. When they ask what you remember, read the room first. If they ask how your memory works, say it in plain words: it's theirs, it lives on this Mac as files, and it stays even if they switch AIs.
        """
        try? soul.write(to: Env.hermesHome.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let mem = Env.hermesHome.appendingPathComponent("memories", isDirectory: true)
        try? FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        var facts = ["The user's name is \(user). They call their assistant \(assistant)."]
        if !connections.isEmpty {
            facts.append("They want these connected: \(connections.joined(separator: ", ")). Not connected yet; help them connect each one when it first comes up.")
        }
        if !passwords.isEmpty { facts.append("For logins: \(passwords).") }
        try? facts.joined(separator: "\n§\n").write(to: mem.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
    }
}

// MARK: - App state

/// Tap-to-answer choices the assistant puts on the last line: [choices: A | B | C]
enum Choices {
    static func split(_ text: String) -> (body: String, choices: [String]) {
        var lines = text.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), last.lowercased().hasPrefix("[choice") else { return (text, []) }
        lines.removeLast()
        var inner = last.drop { $0 != ":" }.dropFirst()
        guard inner.hasSuffix("]") else { return (lines.joined(separator: "\n"), []) }   // still streaming in
        inner = inner.dropLast()
        let opts = inner.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (lines.joined(separator: "\n"), Array(opts.prefix(4)))
    }
}

struct Bubble: Identifiable { let id = UUID(); let fromMe: Bool; var text: String }

struct Ask: Identifiable {
    let id = UUID(); let question: String; let options: [(String, String)]
    let answer: @Sendable (String?) -> Void
}

enum Step: Equatable {
    case installing, pickAI, signingIn, nameAssistant, nameUser, rooms, world, connect, whichEmail, passwords, passwordsOK, backup, wrapUp, done
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @AppStorage("onboarded") var onboarded = false
    @AppStorage("assistantName") var assistantName = ""
    @AppStorage("userName") var userName = ""
    @AppStorage("provider") var providerRaw = ""
    @AppStorage("connections") var connectionsRaw = ""
    @AppStorage("passwords") var passwords = ""
    @AppStorage("backup") var backup = ""
    @Published var pickedRooms: Set<RoomKind> = []

    @Published var bubbles: [Bubble] = Model.savedBubbles() { didSet { saveBubbles() } }
    static func savedBubbles() -> [Bubble] {
        guard let raw = UserDefaults.standard.array(forKey: "bubbles") as? [[String: Any]] else { return [] }
        return raw.compactMap { d in (d["t"] as? String).map { Bubble(fromMe: d["me"] as? Bool ?? false, text: $0) } }
    }
    func saveBubbles() {
        guard !thinking else { return }
        UserDefaults.standard.set(bubbles.suffix(40).filter { !$0.text.isEmpty }.map { ["me": $0.fromMe, "t": $0.text] }, forKey: "bubbles")
    }
    @Published var step: Step = .pickAI
    @Published var signedIn: [Provider: Bool] = [:]
    @Published var signInCode: String?
    @Published var signInNeedsPaste = false
    @Published var signInProblem: String?
    @Published var busy = false
    @Published var thinking = false
    @Published var working: String?
    @Published var asks: [Ask] = []
    @Published var paused = false
    @Published var pickedEmails: Set<String> = []
    @Published var pickedConnections: [String] = ["Email", "Calendar", "News", "Files", "Browser", "WhatsApp"].map { _ in "" }.filter { !$0.isEmpty }
    @Published var connectOptions: [String] = ["Email", "Calendar", "News", "Files", "Browser", "WhatsApp"]

    func toggleConnection(_ c: String) {
        if let i = pickedConnections.firstIndex(of: c) { pickedConnections.remove(at: i) } else { pickedConnections.append(c) }
    }
    func addOwnConnection(_ c: String) {
        let c = c.trimmingCharacters(in: .whitespaces); guard !c.isEmpty else { return }
        if !connectOptions.contains(c) { connectOptions.append(c) }
        if !pickedConnections.contains(c) { pickedConnections.append(c) }
    }
    func connectionsChosen() async {
        let list = pickedConnections
        if list.isEmpty { me("Not now"); await wrapUp(); return }
        me(list.joined(separator: ", "))
        list.filter { $0 != "Email" }.forEach(addConnection)
        if list.contains("Email") {
            step = .whichEmail
            await say("Which email do you use? Pick all that apply. You can add as many accounts as you like.", voice: "whichEmail")
        } else {
            await say("Got it. I'll set each one up with you the first time we need it.")
            await askPasswords()
        }
    }
    @Published var switchingAI = false
    @Published var speaking = false
    @Published var installDone = 0
    @Published var installLine = ""
    @Published var installError: String?
    @Published var needDevTools = false
    @Published var worldCaption = ""
    @Published var tourNode: String?
    @Published var touring = false
    @Published var skipTour = false
    @Published var speakUntil = Date.distantPast

    func runTour() async {
        guard !touring, worldCaption.isEmpty else { return }
        touring = true; skipTour = false
        func hold(_ d: Double, min: Double) async {
            let end = Date().addingTimeInterval(max(d, min) + 0.35)
            while Date() < end && !skipTour { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func speak(_ key: String) -> Double {
            let d = Voice.shared.play(key); speakUntil = Date().addingTimeInterval(d > 0 ? d : 2.6); return d
        }
        worldCaption = "Nice to meet you, \(userName). This is everything I can reach from your Mac."
        await hold(speak("worldIntro"), min: 3.6)
        for n in worldNodes where !skipTour {
            tourNode = n.id; worldCaption = n.line
            await hold(n.voice.map(speak) ?? 0, min: 3.4)
        }
        if skipTour { Voice.shared.stop() }
        tourNode = nil; touring = false
        worldCaption = "What would you like me to look after?"
        _ = speak("worldPick")
    }

    func setFolders(_ f: [String]) {
        Access.set(f)
        if f.isEmpty { pickedConnections.removeAll { $0 == "Files" } }
        else if !pickedConnections.contains("Files") { pickedConnections.append("Files") }
        if onboarded {
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
            Task { _ = await Engine.shared.start() }
        }
    }

    private var signIn: SignIn?
    var provider: Provider? { Provider(rawValue: providerRaw) }
    var connections: [String] { connectionsRaw.split(separator: ",").map(String.init) }
    var name: String { assistantName.isEmpty ? "Your assistant" : assistantName }

    /// The assistant speaks: the line emerges on screen and, if a voice line exists, is spoken.
    func say(_ text: String, voice: String? = nil) async {
        speaking = true; defer { speaking = false }
        try? await Task.sleep(for: .milliseconds(350))
        bubbles.append(Bubble(fromMe: false, text: text))
        let d = voice.map { Voice.shared.play($0) } ?? 0
        // Let the voice finish (or the text settle) before the next line emerges.
        try? await Task.sleep(for: .milliseconds(Int(max(d, 1.1) * 1000) + 200))
    }
    func me(_ text: String) { Voice.shared.stop(); bubbles.append(Bubble(fromMe: true, text: text)) }

    // Onboarding

    func beginOnboarding() async {
        guard bubbles.isEmpty else { return }
        await say("Let's get you set up. It only takes a couple of minutes.", voice: "setup")
        if Env.hermesPath == nil {
            step = .installing
            await say("First, I'm setting myself up on this Mac. It takes about three minutes, and only happens once.", voice: "installing")
            await install()
            return
        }
        await askAI()
    }

    func install() async {
        installError = nil; needDevTools = false; installDone = 0; installLine = ""
        if Installer.devToolsMissing {
            needDevTools = true
            Installer.askForDevTools()
            await say("Your Mac needs one small Apple add-on first. Click Install on the box that just opened, then press Continue here when it's done.", voice: "devTools")
            return
        }
        let err = await Installer.run { n, line in Task { @MainActor in self.installDone = n; self.installLine = line } }
        if let err {
            installError = err
            await say("Something stopped the setup. Check your internet connection and try again.", voice: "installFailed")
        } else {
            await say("Done. I'm ready.", voice: "installDone")
            await askAI()
        }
    }

    func askAI() async {
        step = .pickAI
        await say("Which AI do you already pay for? I'll use it as my brain. You can switch any time.", voice: "pickAI")
        for p in Provider.allCases { signedIn[p] = await SignIn.isSignedIn(p) }
    }

    func choose(_ p: Provider) async {
        me(p.title)
        providerRaw = p.rawValue
        if signedIn[p] == true { await verify(p); return }
        step = .signingIn; signInCode = nil; signInNeedsPaste = false; signInProblem = nil
        await say("I'm opening \(p.title)'s sign-in page in your browser. Sign in there, then come back here.", voice: "signin")
        let s = SignIn(); signIn = s
        let result: (Bool, String) = await withCheckedContinuation { cont in
            let once = Box(false)
            s.start(p) { ev in
                Task { @MainActor in
                    switch ev {
                    case .openPage(let u): NSWorkspace.shared.open(u)
                    case .code(let c): self.signInCode = c
                    case .needPaste: self.signInNeedsPaste = true
                    case .done(let ok, let msg):
                        if !once.v { once.v = true; cont.resume(returning: (ok, msg)) }
                    }
                }
            }
        }
        signIn = nil; signInCode = nil; signInNeedsPaste = false
        if result.0 { signedIn[p] = true; await verify(p) }
        else {
            step = .pickAI
            await say("That sign-in didn't finish. Want to try again, or pick another one?", voice: "signinFailed")
            if !result.1.isEmpty { signInProblem = result.1 }
        }
    }

    func pasteCode(_ c: String) { signIn?.paste(c); signInNeedsPaste = false }
    func cancelSignIn() { signIn?.cancel() }

    private func verify(_ p: Provider) async {
        busy = true; defer { busy = false }
        await say("You're connected to \(p.title). Let me check I can think with it…", voice: "checking")
        var stop = "error: no model answered"
        let got = Box("")
        for model in p.models {
            await SignIn.makeDefault(p, model: model)
            if let err = await Engine.shared.start() { step = .pickAI; await say("Something went wrong: \(err)"); return }
            got.v = ""
            Engine.shared.onText = { t in got.v += t }
            stop = await Engine.shared.prompt("Reply with exactly one word: ready")
            Engine.shared.onText = nil
            if !stop.hasPrefix("error") && !got.v.isEmpty && !got.v.lowercased().contains("rejected") { break }
            got.v = ""
        }
        if stop.hasPrefix("error") || got.v.isEmpty {
            step = .pickAI
            await say("I signed in, but \(p.title) didn't answer (\(stop)). Try again, or pick another one.")
            return
        }
        if onboarded {
            switchingAI = false; step = .done; bubbles.removeAll()
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
            _ = await Engine.shared.start()
            bubbles.append(Bubble(fromMe: false, text: "All set. I'm using \(p.title) now."))
            return
        }
        step = .nameAssistant
        await say("It works. Now, what would you like to call me? You can rename me any time.", voice: "nameAssistant")
    }

    func nameAssistant(_ n: String) async {
        let n = n.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        me(n); assistantName = n; step = .nameUser
        await say("\(n). I like it. And what should I call you?", voice: "nameUser")
    }

    func nameUser(_ n: String) async {
        let n = n.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        me(n); userName = n; step = .rooms
        await say("Nice to meet you, \(n).", voice: "niceToMeet")
        await say("I also have a memory, and it's yours. It lives on this Mac as plain files, so even if you switch AIs, I still remember.", voice: "memory")
        await say("Everything starts in your personal room: family, home, health, plans.", voice: "personalRoom")
        await say("Is there a part of your life you'd like kept separate from the rest? Each one gets its own room, with its own rules.", voice: "roomsQuestion")
    }

    func roomsChosen(_ simple: Bool) async {
        let extra = simple ? [] : RoomKind.allCases.filter { pickedRooms.contains($0) && $0 != .personal }
        me(extra.isEmpty ? "Start simple" : extra.map(\.chip).joined(separator: ", "))
        busy = true
        let err = Brain.build(owner: userName, ai: assistantName, rooms: extra)
        busy = false
        if let err { await say("I couldn't set up your memory: \(err)") }
        else if extra.isEmpty { await say("Your personal room is ready. If you ever want another one, just ask.", voice: "roomsSimple") }
        else { await say("Done. Your rooms are ready, and each one keeps to its own rules.", voice: "roomsDone") }
        step = .world
    }

    func connect(_ what: String) async {
        let what = what.trimmingCharacters(in: .whitespaces); guard !what.isEmpty else { return }
        me(what)
        let w = what.lowercased()
        if w.contains("email") || w.contains("mail") {
            step = .whichEmail
            await say("Which email do you use? Pick all that apply. You can add as many accounts as you like.", voice: "whichEmail")
        } else if w == "not now" {
            await wrapUp()
        } else {
            addConnection(what)
            await say("Got it: \(what). I'll set that up with you the first time we need it.")
            await askPasswords()
        }
    }

    func emailsChosen() async {
        let list = pickedEmails.sorted()
        guard !list.isEmpty else { return }
        me(list.joined(separator: ", "))
        list.forEach(addConnection)
        await say("To read \(list.joined(separator: " and ")) I'll need to sign in for you.")
        await askPasswords()
    }

    private func askPasswords() async {
        step = .passwords
        await say("When I need to log in somewhere, where should I find your passwords?", voice: "passwords")
    }

    func passwordsChosen(_ choice: String) async {
        me(choice)
        if choice == "Ask me each time" {
            passwords = "ask the user for each login; never store passwords"
            await say("Okay. I'll ask you each time, and I won't keep anything.", voice: "askEach")
            await wrapUp(); return
        }
        step = .passwordsOK
        passwords = choice
        await say("To use \(choice) I need your OK first. I'll only look up a login when a task needs it, and I'll tell you which one.", voice: "passwordsOK")
    }

    func passwordsOK(_ yes: Bool) async {
        me(yes ? "Yes" : "Not now")
        if yes { passwords = "use \(passwords) (permission given \(Date().formatted(date: .abbreviated, time: .omitted)))" }
        else { passwords = "not set up yet; ask before using any password source" }
        await say(yes ? "Thanks. Noted." : "No problem. I'll ask again when it's needed.", voice: yes ? "thanks" : "notNow")
        await wrapUp()
    }

    func backupChosen(_ yes: Bool) async {
        me(yes ? "Yes, back it up" : "Not now")
        if yes {
            busy = true
            let err = await Task.detached { Brain.backupToICloud() }.value
            busy = false
            if let err { backup = "off"; await say("I couldn't turn it on: \(err) We can try again later.") }
            else { backup = "icloud"; await say("Backup is on. I'll keep a copy in your iCloud Drive.", voice: "backupOn") }
        } else {
            backup = "off"
            await say("Okay. Your memory stays only on this Mac. Ask me any time to turn backup on.", voice: "backupOff")
        }
        await wrapUp()
    }

    private func addConnection(_ c: String) {
        var l = connections; if !l.contains(c) { l.append(c) }; connectionsRaw = l.joined(separator: ",")
    }

    private func wrapUp() async {
        if backup.isEmpty {
            step = .backup
            await say("One last thing. Want me to back up your memory to iCloud, so it's safe if something happens to this Mac?", voice: "backupQuestion")
            return
        }
        step = .wrapUp
        busy = true
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        _ = await Engine.shared.start()      // restart so the new name and memory load
        busy = false
        await say("You're all set, \(userName). Here are a few things I can do right now. Tap one, or just ask.", voice: "allSet")
    }

    func finish() { onboarded = true; step = .done; bubbles.removeAll() }

    var suggestions: [String] { [tryItems[0].text, tryItems[4].text, tryItems[3].text] }

    var suggestionsOld: [String] {
        var s: [String] = []
        if connections.contains(where: { ["Gmail", "Outlook", "iCloud Mail", "Yahoo"].contains($0) }) {
            s.append("Every morning, tell me what matters in my email")
        }
        if connections.contains("Calendar") { s.append("What does my week look like?") }
        if connections.contains("News") { s.append("Give me 5 headlines I'd care about") }
        s += ["Plan a Saturday for me nearby", "Help me plan a trip", "Remind me to call someone tomorrow"]
        return Array(s.prefix(3))
    }

    // Talking after setup

    func ensureEngine() async {
        guard onboarded, !Engine.shared.running else { return }
        if backup == "icloud" { Task.detached { _ = Brain.backupToICloud() } }
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        if let e = await Engine.shared.ensureStarted() { bubbles.append(Bubble(fromMe: false, text: "I couldn't start: \(e)")) }
    }

    func send(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paused, !t.isEmpty, !thinking else { return }
        await ensureEngine()
        me(t)
        bubbles.append(Bubble(fromMe: false, text: ""))
        let idx = bubbles.count - 1
        thinking = true; working = nil
        Engine.shared.onText = { s in Task { @MainActor in if idx < self.bubbles.count { self.bubbles[idx].text += s } } }
        Engine.shared.onTool = { s in Task { @MainActor in self.working = s } }
        Engine.shared.onPermission = { q, opts, answer in
            Task { @MainActor in self.asks.append(Ask(question: q, options: opts, answer: answer)) }
        }
        let stop = await Engine.shared.prompt(t)
        try? await Task.sleep(for: .milliseconds(150))
        thinking = false; working = nil; saveBubbles()
        if idx < bubbles.count, bubbles[idx].text.isEmpty {
            bubbles[idx].text = stop.hasPrefix("error") ? "I couldn't do that (\(stop.dropFirst(7))). Try again?" : "Done."
        }
    }

    func answer(_ a: Ask, _ choice: String?) { a.answer(choice); asks.removeAll { $0.id == a.id } }

    func toggleStop() {
        paused.toggle()
        if paused { Engine.shared.cancel(); asks.forEach { $0.answer(nil) }; asks.removeAll(); thinking = false }
    }
}

// MARK: - The world: everything One can reach, floating around it

struct Node: Identifiable, Hashable {
    let id: String; let symbol: String; let line: String; let voice: String?
}

let worldNodes: [Node] = [
    Node(id: "Files", symbol: "folder", line: "I find, sort and tidy the folders you allow.", voice: "tourFiles"),
    Node(id: "Browser", symbol: "safari", line: "I open sites and click through them as you, in your own browser.", voice: "tourBrowser"),
    Node(id: "Email", symbol: "envelope", line: "I read every inbox you have and tell you what matters.", voice: "tourEmail"),
    Node(id: "Calendar", symbol: "calendar", line: "I keep your days straight and warn you before things clash.", voice: "tourCalendar"),
    Node(id: "Phone", symbol: "iphone", line: "Text me from your phone while this Mac does the work.", voice: "tourPhone"),
    Node(id: "Passwords", symbol: "key", line: "I sign in for you with your password manager, only with your OK.", voice: "tourPasswords"),
    Node(id: "Web", symbol: "globe", line: "I look things up for you and come back with a short, clear answer.", voice: "tourWeb"),
    Node(id: "News", symbol: "newspaper", line: "I follow the stories you care about and tell you each morning.", voice: "tourNews"),
]

/// Renders the assistant's Markdown replies: headings, bullet and numbered lists, quotes, code blocks,
/// simple tables and rules, with inline bold/italic/code/links.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 15
    enum Block: Hashable { case heading(Int, String), bullet(Int, String), numbered(Int, String, String), quote(String), code(String), table([[String]]), rule, para(String) }

    static func blocks(_ src: String) -> [Block] {
        var out: [Block] = []; var para: [String] = []; var code: [String]? = nil; var table: [[String]] = []
        func flushPara() { if !para.isEmpty { out.append(.para(para.joined(separator: " "))); para = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for raw in src.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushPara(); flushTable(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") && line.hasSuffix("|") {
                flushPara()
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty { flushPara(); continue }
            let indent = raw.prefix { $0 == " " }.count / 2
            if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushPara(); out.append(.heading(line[r].count - 1, String(line[r.upperBound...])))
            } else if line == "---" || line == "***" || line == "___" {
                flushPara(); out.append(.rule)
            } else if let r = line.range(of: #"^[-*+•] "#, options: .regularExpression) {
                flushPara(); out.append(.bullet(indent, String(line[r.upperBound...])))
            } else if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara(); out.append(.numbered(indent, String(line[r].dropLast(2)), String(line[r.upperBound...])))
            } else if line.hasPrefix(">") {
                flushPara(); out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else { para.append(line) }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara(); flushTable()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let l, let t):
                    Text(Self.inline(t)).font(.system(size: size + CGFloat(max(0, 4 - l)) * 2, weight: .semibold)).padding(.top, 4)
                case .bullet(let ind, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .numbered(let ind, let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .quote(let t):
                    Text(Self.inline(t)).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                case .code(let c):
                    Text(c).font(.system(size: size - 2, design: .monospaced)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                Text(Self.inline(c)).fontWeight(i == 0 ? .semibold : .regular)
                            } }
                            if i == 0 { Divider() }
                        }
                    }
                case .rule: Divider()
                case .para(let t): Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: size))
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
}

/// The assistant itself: the same living rings as the world screen (Claude Design), so it looks
/// like one being everywhere. Breathes when idle, moves like a voice while it works.
struct Orb: View {
    var size: CGFloat = 130
    var active = false
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(WorldLook.start)
            let voice = active ? 0.35 + 0.65 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
            Presence(t: t, lean: .zero, voice: voice, energy: 0)
                .frame(width: 280, height: 280)
                .scaleEffect(size / 100)
                .frame(width: size * 2, height: size * 2)
        }
    }
}

// MARK: - Floating orb (One minimized)
// When One is minimized it becomes a small orb that floats above every window. Hold it to talk
// (let go to send), double-click to open the full window. It glows while One works.

enum FloatState { case idle, listening, working }

struct FloatingOrb: View {
    var state: FloatState
    var size: CGFloat = 72
    /// Fixed time for renders; nil = live animation.
    var fixedT: Double? = nil
    var body: some View {
        if let t = fixedT { face(t) } else {
            TimelineView(.animation) { tl in face(tl.date.timeIntervalSince(WorldLook.start)) }
        }
    }

    private func face(_ t: Double) -> some View {
        let listening = state == .listening, working = state == .working
        let voice: Double = listening ? 0.45 + 0.4 * abs(sin(t * 4.1) * sin(t * 2.3 + 0.7))
                          : working ? 0.3 + 0.35 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
        let energy: Double = working ? 0.45 + 0.25 * sin(t * 2) : listening ? 0.2 : 0
        let k = size / 168                 // outer ring (~68pt + wobble) fits inside the disc
        let glow = working ? 0.30 + 0.10 * sin(t * 2.2) : listening ? 0.26 : 0.10
        return ZStack {
            Circle().fill(WorldLook.bg.opacity(0.96))
                .overlay(Circle().fill(RadialGradient(colors: [WorldLook.cream.opacity(listening ? 0.10 : 0.05), .clear],
                                                      center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.6)))
            Presence(t: t, lean: .zero, voice: voice, energy: energy, line: 1.5 / k)
                .frame(width: 280, height: 280)
                .scaleEffect(k)
                .frame(width: size, height: size)
                .clipShape(Circle())
            Circle().strokeBorder(WorldLook.cream.opacity(listening ? 0.30 : 0.07), lineWidth: 0.75)
            if working {
                // A soft light travelling around the edge: "busy" without a spinner.
                Circle()
                    .trim(from: 0, to: 0.36)
                    .stroke(AngularGradient(colors: [Color(hex: 0xFFE2C2, 0), Color(hex: 0xFFE2C2, 0.55), Color(hex: 0xFFF3E6, 1)],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(130)),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .frame(width: size + 9, height: size + 9)
                    .rotationEffect(.degrees(t * 150 + 115))
            }
        }
        .frame(width: size, height: size)
        .background(
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(hex: 0xFFF1E2, glow), Color(hex: 0xFFF1E2, glow * 0.3), .clear],
                                             center: .center, startRadius: size * 0.45, endRadius: size * (working ? 0.82 : 0.7)))
                if listening {
                    // Two gentle ripples while it hears you.
                    ForEach(0..<2, id: \.self) { i in
                        let p = (t * 0.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(WorldLook.cream.opacity(0.55 * (1 - p)), lineWidth: 1.5 - 0.7 * p)
                            .frame(width: size * (1.1 + 0.32 * p), height: size * (1.1 + 0.32 * p))
                    }
                }
            }
            .frame(width: size * 1.8, height: size * 1.8)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .scaleEffect(listening ? 1.08 : 1)
    }
}

/// Small plain-words label next to the orb.
struct FloatHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(WorldLook.cream.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: 0x1E1E22, 0.92)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .fixedSize()
    }
}

/// What One is hearing while you hold the orb.
struct FloatTranscript: View {
    let text: String
    var level: Double = 0.6
    var t: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.4]
                        let h = 4 + 8 * shape[i] * (0.75 + 0.25 * level * abs(sin(t * 5 + Double(i) * 1.3)))
                        Capsule().fill(Color(hex: 0xFFE2C2, 0.9)).frame(width: 2, height: h)
                    }
                }.frame(height: 12)
                Text("Listening").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.7))
            }
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(WorldLook.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Let go to send").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.62))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1E1E22, 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Render-only: the floating orb parked in the bottom-right corner of a sample dark desktop.
struct FloatScene: View {
    let state: FloatState
    var t: Double = 12.3
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(hex: 0x2A2F3D), Color(hex: 0x15161C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").fontWeight(.semibold)
                    Text("File"); Text("Edit"); Text("View"); Text("Go"); Spacer(); Text("Fri 23 Oct  9:41")
                }
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14).frame(height: 24).background(Color.black.opacity(0.35))
                Spacer()
            }
            // A background window, for scale
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x23252C))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) { ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0), 0.85)).frame(width: 10, height: 10) } }
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)).frame(width: [220, 180, 240, 150, 200, 120][i], height: 9)
                        }
                    }.padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .frame(width: 330, height: 200)
                .position(x: 200, y: 150)
            HStack(alignment: .center, spacing: state == .listening ? 26 : 18) {
                switch state {
                case .idle: FloatHint(text: "Hold to talk · Double-click to open")
                case .listening: FloatTranscript(text: "Move my call with Dana to Thursday at 3, and let her know", level: 0.7, t: t)
                case .working: FloatHint(text: "Moving your call with Dana…")
                }
                FloatingOrb(state: state, size: 72, fixedT: t)
            }
            .padding(.trailing, 44).padding(.bottom, 44)
        }
        .environment(\.colorScheme, .dark)
    }
}


// MARK: - Push to talk (speech → text on this Mac)

/// Hears you while you hold the orb. Speech is turned into text on the Mac when it can be.
@MainActor final class Listener: ObservableObject {
    static let shared = Listener()
    @Published var listening = false
    @Published var text = ""
    @Published var level: Double = 0
    @Published var problem: String?
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var want = false
    private var gotFinal = false
    private var onFinal: (() -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func begin() {
        want = true; problem = nil; text = ""
        SFSpeechRecognizer.requestAuthorization { s in
            DispatchQueue.main.async {
                guard s == .authorized else { self.fail("I need permission to hear you. Open System Settings, Privacy & Security, Speech Recognition, and turn on One."); return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else { self.fail("I need the microphone. Open System Settings, Privacy & Security, Microphone, and turn on One."); return }
                        if self.want { self.startAudio() }
                    }
                }
            }
        }
    }

    private func fail(_ msg: String) {
        problem = msg; want = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.problem == msg { self.problem = nil } }
    }

    private func startAudio() {
        guard !listening else { return }
        guard let r = recognizer, r.isAvailable else { fail("Talking isn't available right now. You can type instead."); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req; gotFinal = false
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Listener.tap(req) { lv in
            DispatchQueue.main.async { self.level = lv }
        })
        audio.prepare()
        do { try audio.start() } catch { input.removeTap(onBus: 0); fail("I couldn't use the microphone."); return }
        listening = true
        task = r.recognitionTask(with: req, resultHandler: Listener.handler { text, final in
            DispatchQueue.main.async {
                if let text { self.text = text }
                if final { self.gotFinal = true; let f = self.onFinal; self.onFinal = nil; f?() }
            }
        })
    }

    /// Built outside the class's methods so the audio thread never touches main-thread-only state.
    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest, level: @escaping (Double) -> Void) -> AVAudioNodeTapBlock {
        return { buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            level(min(1, Double(sqrt(sum / Float(max(n, 1)))) * 14))
        }
    }
    nonisolated private static func handler(_ cb: @escaping (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { res, err in cb(res?.bestTranscription.formattedString, err != nil || res?.isFinal == true) }
    }

    /// Stop listening; `done` gets what was heard (empty if nothing).
    func finish(_ done: @escaping (String) -> Void) {
        want = false
        guard listening else { done(""); return }
        listening = false
        audio.stop(); audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        var called = false
        let complete = {
            guard !called else { return }; called = true
            self.task?.cancel(); self.task = nil; self.request = nil; self.level = 0
            done(self.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if gotFinal { complete() } else {
            onFinal = complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.onFinal = nil; complete() }
        }
    }
}

// MARK: - Floating orb window (shown when One is minimized or hidden)

@MainActor final class FloatUI: ObservableObject {
    static let shared = FloatUI()
    static let orbBox: CGFloat = 150
    static let cardSize = CGSize(width: 290, height: 220)
    @Published var onRight = false
    @Published var showHint = false
    @Published var reply: String?
    @Published var note: String?
}

struct FloatOrbView: View {
    @ObservedObject var m = Model.shared
    @ObservedObject var l = Listener.shared
    var body: some View {
        FloatingOrb(state: l.listening ? .listening : (m.thinking ? .working : .idle), size: 72)
            .frame(width: FloatUI.orbBox, height: FloatUI.orbBox)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: l.listening)
    }
}

/// A short message card beside the orb (a reply, a problem, a note).
struct FloatNote: View {
    let text: String
    var footer: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 13.5)).foregroundStyle(WorldLook.cream).lineSpacing(2).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.62)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1E1E22, 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

struct FloatCard: View {
    @ObservedObject var m = Model.shared
    @ObservedObject var l = Listener.shared
    @ObservedObject var ui = FloatUI.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !l.listening)) { tl in
            ZStack(alignment: ui.onRight ? .leading : .trailing) {
                Color.clear
                content(tl.date.timeIntervalSince(WorldLook.start)).padding(.horizontal, 12)
            }
        }
        .frame(width: FloatUI.cardSize.width, height: FloatUI.cardSize.height)
        .environment(\.colorScheme, .dark)
    }
    @ViewBuilder func content(_ t: Double) -> some View {
        if l.listening { FloatTranscript(text: l.text.isEmpty ? "I'm listening…" : l.text, level: max(0.3, l.level), t: t) }
        else if let p = l.problem ?? ui.note { FloatNote(text: p) }
        else if m.thinking { FloatHint(text: m.working ?? "Working on it…") }
        else if let r = ui.reply { FloatNote(text: r, footer: "Double-click the orb to see it all") }
        else if ui.showHint { FloatHint(text: "Hold to talk · Double-click to open") }
    }
}

/// Mouse handling for the orb: drag to move, hold to talk, double-click to open One.
final class OrbHost: NSView {
    private var grab = NSPoint.zero, downAt = NSPoint.zero
    private var dragging = false, holding = false
    private var holdTimer: Timer?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let q = convert(point, from: superview)
        return hypot(q.x - bounds.midX, q.y - bounds.midY) < 46 ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        holdTimer?.invalidate()
        if e.clickCount >= 2 { Floater.shared.openMain(); return }
        downAt = NSEvent.mouseLocation; dragging = false
        if let w = window { grab = NSPoint(x: downAt.x - w.frame.minX, y: downAt.y - w.frame.minY) }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, !self.dragging else { return }
            self.holding = true; Floater.shared.beginTalk()
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging && !holding && hypot(p.x - downAt.x, p.y - downAt.y) > 4 { dragging = true; holdTimer?.invalidate() }
        guard dragging, let w = window else { return }
        w.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
        Floater.shared.placeCard()
    }
    override func mouseUp(with e: NSEvent) {
        holdTimer?.invalidate()
        if holding { holding = false; Floater.shared.endTalk() }
        else if dragging { dragging = false; Floater.shared.settle() }
        else if e.clickCount == 1 { Floater.shared.flashHint() }
    }
}

@MainActor final class Floater: NSObject {
    static let shared = Floater()
    private var orb: NSPanel?
    private var card: NSPanel?
    private var replyToken = 0, hintToken = 0

    private var mainWindow: NSWindow? { NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain } }

    func setup() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { n in
            if !(n.object is NSPanel) { self.show() }
        }
        nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { n in
            if !(n.object is NSPanel) { self.hide() }
        }
        // Hiding One (⌘H) would hide the orb too, so turn "hide" into "tuck the window away and show the orb".
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard Model.shared.onboarded else { return }
                self.mainWindow?.orderOut(nil)
                NSApp.unhideWithoutActivation()
                self.show()
            }
        }
    }

    private func panel(_ size: CGSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        return p
    }

    private func build() {
        guard orb == nil else { return }
        let o = panel(CGSize(width: FloatUI.orbBox, height: FloatUI.orbBox))
        let host = OrbHost(frame: NSRect(x: 0, y: 0, width: FloatUI.orbBox, height: FloatUI.orbBox))
        let hv = NSHostingView(rootView: FloatOrbView())
        hv.frame = host.bounds; hv.autoresizingMask = [.width, .height]
        host.addSubview(hv)
        o.contentView = host
        let c = panel(FloatUI.cardSize)
        c.ignoresMouseEvents = true
        c.contentView = NSHostingView(rootView: FloatCard())
        orb = o; card = c
        let d = UserDefaults.standard
        if d.object(forKey: "orbX") != nil {
            o.setFrameOrigin(NSPoint(x: d.double(forKey: "orbX"), y: d.double(forKey: "orbY")))
        } else if let v = NSScreen.main?.visibleFrame {
            o.setFrameOrigin(NSPoint(x: v.maxX - FloatUI.orbBox + 10, y: v.maxY - FloatUI.orbBox + 10))
        }
        clamp()
    }

    func show() {
        guard Model.shared.onboarded else { return }
        build()
        placeCard()
        orb?.orderFrontRegardless(); card?.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "orbHintSeen") { UserDefaults.standard.set(true, forKey: "orbHintSeen") }
        flashHint()
    }

    func hide() {
        if Listener.shared.listening { Listener.shared.finish { _ in } }
        orb?.orderOut(nil); card?.orderOut(nil)
    }

    func openMain() {
        hide()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let w = mainWindow { if w.isMiniaturized { w.deminiaturize(nil) }; w.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the orb fully on a screen.
    private func clamp() {
        guard let o = orb else { return }
        let f = o.frame, pad: CGFloat = 30   // the glow can hang off the edge, the orb itself can't
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? NSScreen.main
        guard let v = scr?.visibleFrame else { return }
        let x = min(max(f.minX, v.minX - pad), v.maxX - f.width + pad)
        let y = min(max(f.minY, v.minY - pad), v.maxY - f.height + pad)
        o.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func settle() {
        clamp(); placeCard()
        if let f = orb?.frame { UserDefaults.standard.set(f.minX, forKey: "orbX"); UserDefaults.standard.set(f.minY, forKey: "orbY") }
    }

    func placeCard() {
        guard let o = orb?.frame, let c = card else { return }
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: o.midX, y: o.midY)) } ?? NSScreen.main
        let onRight = o.midX < (scr?.frame.midX ?? 0)
        if FloatUI.shared.onRight != onRight { FloatUI.shared.onRight = onRight }
        let sz = FloatUI.cardSize, inset: CGFloat = 32   // tuck the card into the orb's glow
        let x = onRight ? o.maxX - inset : o.minX - sz.width + inset
        c.setFrame(NSRect(x: x, y: o.midY - sz.height / 2, width: sz.width, height: sz.height), display: true)
    }

    func flashHint() {
        hintToken += 1; let tk = hintToken
        FloatUI.shared.showHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if self.hintToken == tk { FloatUI.shared.showHint = false } }
    }

    func beginTalk() {
        let ui = FloatUI.shared
        ui.reply = nil; ui.note = nil; ui.showHint = false
        if Model.shared.thinking { note("I'm still on the last thing. Give me a moment."); return }
        Listener.shared.begin()
    }

    func endTalk() {
        Listener.shared.finish { heard in
            guard !heard.isEmpty else {
                if Listener.shared.problem == nil { self.note("I didn't catch that. Hold the orb and talk, then let go.") }
                return
            }
            Task { @MainActor in
                await Model.shared.send(heard)
                self.showReply()
            }
        }
    }

    private func note(_ s: String) {
        FloatUI.shared.note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if FloatUI.shared.note == s { FloatUI.shared.note = nil } }
    }

    private func showReply() {
        guard let b = Model.shared.bubbles.last, !b.fromMe else { return }
        var t = Choices.split(b.text).body
        for mark in ["**", "__", "`", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 220 { t = String(t.prefix(217)) + "…" }
        replyToken += 1; let tk = replyToken
        FloatUI.shared.reply = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if self.replyToken == tk { FloatUI.shared.reply = nil } }
    }
}

// The world, as designed in Claude Design ("One World"): a quiet dark room, the assistant as a living
// set of soft rings in the middle, and everything it can reach drifting upright around it.

extension Color {
    init(hex: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }
}

enum WorldLook {
    static let bg = Color(hex: 0x141416)
    static let cream = Color(hex: 0xF4EFE8)
    static let W: CGFloat = 620, H: CGFloat = 440, CX: CGFloat = 310, CY: CGFloat = 220, RX: CGFloat = 222, RY: CGFloat = 150
    static let start = Date()
    /// Item centers: an upright orbit, one full turn every 200 s, with a little float on each.
    static func positions(_ t: Double) -> [CGPoint] {
        let off = t * (2 * .pi / 200)
        return (0..<worldNodes.count).map { i in
            let th = off + Double(i) * 2 * .pi / Double(worldNodes.count) - .pi / 2
            return CGPoint(x: CX + RX * cos(th) + sin(t * 0.37 + Double(i) * 2.1) * 3,
                           y: CY + RY * sin(th) + sin(t * 0.6 + Double(i) * 1.3) * 4)
        }
    }
    static func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// The assistant: seven soft, wobbling rings that breathe, lean toward what it's talking about,
/// move with its voice and pulse when something connects.
struct Presence: View {
    let t: Double; let lean: CGPoint; let voice: Double; let energy: Double
    /// Ring stroke width; bigger when the rings are drawn scaled down (floating orb) so they stay crisp.
    var line: CGFloat = 1.1
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let breath = 1 + 0.035 * sin(t * .pi * 2 / 5)
            let amp = 1.8 + voice * 3.6 + energy * 4
            let glowC = CGPoint(x: c.x + lean.x, y: c.y + lean.y)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [Color(.sRGB, red: 1, green: 236 / 255, blue: 214 / 255, opacity: 0.10 + voice * 0.05 + energy * 0.06), .clear]),
                                           center: glowC, startRadius: 10, endRadius: 130))
            for k in stride(from: 6, through: 0, by: -1) {
                let kd = Double(k)
                let base = (40 + kd * 4.6) * breath
                let o = CGPoint(x: c.x + lean.x * kd / 7, y: c.y + lean.y * kd / 7)
                var path = Path()
                for sidx in 0...120 {
                    let a = Double(sidx) / 120 * 2 * .pi
                    let w1 = 0.55 * sin(3 * a + t * 0.7 + kd * 0.9)
                    let w2 = 0.3 * sin(5 * a - t * 0.9 + kd * 1.7)
                    let w3 = 0.15 * sin(2 * a + t * 1.3)
                    let r = base + amp * (1 + kd * 0.18) * (w1 + w2 + w3)
                    let pt = CGPoint(x: o.x + cos(a) * r, y: o.y + sin(a) * r)
                    if sidx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                if k == 0 {
                    ctx.fill(path, with: .radialGradient(Gradient(colors: [Color(.sRGB, red: 1, green: 246 / 255, blue: 236 / 255, opacity: 0.20),
                                                                          Color(.sRGB, red: 1, green: 246 / 255, blue: 236 / 255, opacity: 0.03)]),
                                                         center: CGPoint(x: o.x - 8, y: o.y - 10), startRadius: 2, endRadius: base * 1.1))
                }
                let hue = (32 + kd * 26) / 360
                ctx.stroke(path, with: .color(Color(hue: hue, saturation: 0.30, brightness: 0.95).opacity(0.62 - kd * 0.07)), lineWidth: line)
            }
        }
    }
}

struct WorldTile: View {
    let n: Node; let selected: Bool; let lit: Bool; let hover: Bool
    var body: some View {
        let strong = selected || lit
        VStack(spacing: 8) {
            Image(systemName: n.symbol).font(.system(size: 19, weight: .light))
                .foregroundStyle(selected ? Color(hex: 0x141416) : (strong || hover ? .white : WorldLook.cream.opacity(0.85)))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? WorldLook.cream : WorldLook.cream.opacity(lit ? 0.14 : hover ? 0.09 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(WorldLook.cream.opacity(selected ? 0 : lit ? 0.35 : hover ? 0.22 : 0.10), lineWidth: 1))
                .shadow(color: Color(hex: 0xFFECD6, selected ? 0.45 : lit ? 0.35 : 0), radius: 14)
            Text(n.id).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(strong ? .white : WorldLook.cream.opacity(0.72)).fixedSize()
        }
        .frame(width: 88, height: 82, alignment: .top)
        .animation(.easeOut(duration: 0.45), value: selected)
        .animation(.easeOut(duration: 0.45), value: lit)
    }
}

/// One frame of the stage (620 x 440 design units). Pure function of time, so it can be rendered to a PNG too.
struct WorldCanvas: View {
    let t: Double
    let lit: Int?                    // the item being talked about in the tour
    let picking: Bool
    let linked: [String: Double]     // item -> time it was tapped
    let speaking: Bool
    var hover: String? = nil
    var tap: (Node) -> Void = { _ in }
    var onHover: (String?) -> Void = { _ in }

    var body: some View {
        let pos = WorldLook.positions(t)
        let prog: [Double] = worldNodes.map { n in linked[n.id].map { min(1, max(0, (t - $0) / 0.8)) } ?? 0 }
        let lastDone = worldNodes.compactMap { linked[$0.id].map { $0 + 0.8 } }.filter { $0 <= t }.max()
        let energy = lastDone.map { exp(-(t - $0) * 1.8) } ?? 0
        let voice = speaking ? 0.35 + 0.65 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
        var lean = CGPoint.zero
        if let l = lit {
            let dx = pos[l].x - WorldLook.CX, dy = pos[l].y - WorldLook.CY, d = max(hypot(dx, dy), 1)
            lean = CGPoint(x: dx / d * 5, y: dy / d * 5)
        }
        return ZStack(alignment: .topLeading) {
            Presence(t: t, lean: lean, voice: voice, energy: energy)
                .frame(width: 280, height: 280)
                .position(x: WorldLook.CX, y: WorldLook.CY)
            Canvas { ctx, _ in
                for (i, n) in worldNodes.enumerated() where prog[i] > 0 {
                    let (x, y) = (pos[i].x, pos[i].y)
                    let dx = x - WorldLook.CX, dy = y - WorldLook.CY, d = max(hypot(dx, dy), 1)
                    let ux = dx / d, uy = dy / d
                    let sx = WorldLook.CX + ux * 70, sy = WorldLook.CY + uy * 70
                    let sxx: CGFloat = abs(ux) > 1e-3 ? 34 / abs(ux) : 1e9
                    let syy: CGFloat = uy < -1e-3 ? 56 / -uy : (uy > 1e-3 ? 32 / uy : 1e9)
                    let cl = min(sxx, syy)
                    let ex = x - ux * cl, ey = y - uy * cl
                    let bend = 14 * CGFloat(sin(t * 0.5 + Double(i)))
                    let mx = (sx + ex) / 2 - uy * bend, my = (sy + ey) / 2 + ux * bend
                    var path = Path()
                    path.move(to: CGPoint(x: ex, y: ey))
                    path.addQuadCurve(to: CGPoint(x: sx, y: sy), control: CGPoint(x: mx, y: my))
                    let e = WorldLook.ease(prog[i])
                    ctx.stroke(path.trimmedPath(from: 0, to: e), with: .color(WorldLook.cream.opacity(0.2 + 0.35 * e)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    if prog[i] >= 1 {
                        let f = (t * 0.35 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                        let u = CGFloat(f), a0 = (1 - u) * (1 - u), a1 = 2 * (1 - u) * u, a2 = u * u
                        let qx = a0 * ex + a1 * mx + a2 * sx
                        let qy = a0 * ey + a1 * my + a2 * sy
                        ctx.fill(Path(ellipseIn: CGRect(x: qx - 2, y: qy - 2, width: 4, height: 4)),
                                 with: .color(Color(hex: 0xFFF6EC, sin(f * .pi) * 0.9)))
                    }
                    _ = n
                }
            }
            .frame(width: WorldLook.W, height: WorldLook.H)
            .allowsHitTesting(false)
            ForEach(Array(worldNodes.enumerated()), id: \.element.id) { i, n in
                let sel = linked[n.id] != nil, isLit = lit == i
                let op: Double = picking ? 1 : (lit == nil ? 0.7 : (isLit ? 1 : 0.32))
                WorldTile(n: n, selected: sel, lit: isLit, hover: picking && hover == n.id)
                    .opacity(op).animation(.easeOut(duration: 0.6), value: op)
                    .contentShape(Rectangle())
                    .onTapGesture { if picking { tap(n) } }
                    .onHover { onHover($0 ? n.id : nil) }
                    .position(x: pos[i].x, y: pos[i].y + 15)
            }
        }
        .frame(width: WorldLook.W, height: WorldLook.H)
    }
}

struct WorldStage: View {
    @ObservedObject var m: Model
    @State var folderSheet = false
    @State var hover: String?
    @State var linkedAt: [String: Double] = [:]
    var picking: Bool { !m.touring }
    var litIndex: Int? { m.tourNode.flatMap { id in worldNodes.firstIndex { $0.id == id } } }
    var body: some View {
        ZStack {
            WorldLook.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text(m.tourNode ?? " ").font(.system(size: 12, weight: .medium)).tracking(0.4)
                        .foregroundStyle(WorldLook.cream.opacity(0.5)).opacity(m.tourNode == nil ? 0 : 1)
                    Text(m.worldCaption).font(.system(size: 22, weight: .medium)).tracking(-0.2)
                        .foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Text("Tap to connect. You can change this anytime.").font(.system(size: 13))
                        .foregroundStyle(WorldLook.cream.opacity(0.6)).opacity(picking ? 1 : 0)
                }
                .frame(minHeight: 120).padding(.top, 28).padding(.horizontal, 24)
                .id(m.worldCaption).transition(.opacity.combined(with: .offset(y: -6)))
                .animation(.easeOut(duration: 0.32), value: m.worldCaption)
                GeometryReader { geo in
                    let k = min(geo.size.width / WorldLook.W, geo.size.height / WorldLook.H, 1.2)
                    TimelineView(.animation) { tl in
                        WorldCanvas(t: tl.date.timeIntervalSince(WorldLook.start), lit: litIndex, picking: picking,
                                    linked: linkedAt, speaking: Date() < m.speakUntil, hover: hover,
                                    tap: tapped, onHover: { hover = $0 })
                    }
                    .scaleEffect(k)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                ZStack {
                    Button("Skip tour") { m.skipTour = true }.buttonStyle(.plain)
                        .foregroundStyle(WorldLook.cream.opacity(0.55)).opacity(m.touring ? 1 : 0)
                    VStack(spacing: 12) {
                        Button { Task { await m.connectionsChosen() } } label: {
                            Text(m.pickedConnections.isEmpty ? "Connect" : "Connect \(m.pickedConnections.count)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x141416))
                                .frame(minWidth: 150).padding(.vertical, 11)
                                .background(Capsule().fill(WorldLook.cream))
                        }.buttonStyle(.plain).opacity(m.pickedConnections.isEmpty ? 0.35 : 1).disabled(m.pickedConnections.isEmpty)
                        Button("Not now") { m.pickedConnections = []; Task { await m.connectionsChosen() } }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    }.opacity(picking ? 1 : 0).allowsHitTesting(picking)
                }.frame(height: 90).padding(.bottom, 26).animation(.easeOut(duration: 0.6), value: m.touring)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $folderSheet) { FolderSheet(m: m) { folderSheet = false; syncLinks() } }
        .onChange(of: m.pickedConnections) { _, _ in syncLinks() }
        .task { await m.runTour() }
    }
    func syncLinks() {
        let now = Date().timeIntervalSince(WorldLook.start)
        for id in m.pickedConnections where linkedAt[id] == nil { linkedAt[id] = now }
        for id in linkedAt.keys where !m.pickedConnections.contains(id) { linkedAt[id] = nil }
    }
    func tapped(_ n: Node) {
        if n.id == "Files" { folderSheet = true } else { m.toggleConnection(n.id) }
    }
}

struct FolderSheet: View {
    @ObservedObject var m: Model
    let done: () -> Void
    @State var folders: [String] = Access.folders
    let common = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which folders can I see?").font(.title2.bold())
            Text("Everything else stays locked. You can change this any time.").foregroundStyle(.secondary)
            HStack {
                ForEach(common, id: \.self) { f in
                    Chip(label: (f as NSString).lastPathComponent, selected: folders.contains(f)) { toggle(f) }
                }
            }
            Button("Choose another folder…", action: pick)
            ForEach(folders.filter { !common.contains($0) }, id: \.self) { f in
                HStack {
                    Image(systemName: "folder").font(.system(size: 13, weight: .light))
                    Text((f as NSString).abbreviatingWithTildeInPath)
                    Spacer()
                    Button("Remove") { toggle(f) }.buttonStyle(.link)
                }
            }
            Spacer()
            HStack { Spacer(); Button("Done") { m.setFolders(folders); done() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480, height: 360)
    }
    func toggle(_ p: String) { if let i = folders.firstIndex(of: p) { folders.remove(at: i) } else { folders.append(p) } }
    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK { for u in panel.urls where !folders.contains(u.path) { folders.append(u.path) } }
    }
}

struct TryItem: Hashable { let symbol: String; let tag: String; let text: String }

let tryItems: [TryItem] = [
    TryItem(symbol: "folder", tag: "Files", text: "Tidy my Downloads into folders that make sense"),
    TryItem(symbol: "doc.text.magnifyingglass", tag: "Files", text: "Find every receipt from this year and add them up"),
    TryItem(symbol: "safari", tag: "Browser", text: "Log in to a site for me and check my account"),
    TryItem(symbol: "airplane", tag: "Watch", text: "Watch a flight price and tell me when it drops"),
    TryItem(symbol: "sunrise", tag: "Every day", text: "Every morning at 7, send me my day on my phone"),
    TryItem(symbol: "hammer", tag: "Research", text: "Compare 3 contractors near me and save it to my Desktop"),
    TryItem(symbol: "envelope", tag: "Email", text: "Read my last 50 emails and tell me who's waiting on me"),
    TryItem(symbol: "brain", tag: "Memory", text: "Remember what I like, then plan my weekend around it"),
]

// MARK: - Screens

struct RootView: View {
    @StateObject var m = Model.shared
    @State var started = false
    var body: some View {
        Group {
            if m.onboarded && !m.switchingAI { HomeView(m: m) }
            else if !started && m.bubbles.isEmpty && !m.onboarded { WelcomeView { started = true } }
            else { OnboardingView(m: m) }
        }
        .frame(minWidth: 560, minHeight: 680)
        .onAppear { if m.onboarded { m.step = .done } }
    }
}

struct WelcomeView: View {
    var start: () -> Void
    @State var shown = 0
    let lines: [(String, String)] = [
        ("Hi. I'm your assistant.", "welcome1"),
        ("I live on this Mac, not in the cloud.", "welcome2"),
        ("I ask before I do anything that matters.", "welcome3"),
        ("If this Mac is closed or off, I'm off too.", "welcome4"),
    ]
    var body: some View {
        ZStack {
            Mist()
            VStack(spacing: 28) {
                Spacer()
                Emerging(text: lines[0].0, visible: shown >= 1).font(.system(size: 36, weight: .semibold))
                VStack(spacing: 12) {
                    ForEach(1..<lines.count, id: \.self) { i in
                        Emerging(text: lines[i].0, visible: shown >= i + 1)
                    }
                }.font(.title3).foregroundStyle(.secondary)
                Spacer()
                BigButton(label: "Start") { Voice.shared.stop(); start() }
                    .keyboardShortcut(.defaultAction)
                    .opacity(shown > lines.count ? 1 : 0).blur(radius: shown > lines.count ? 0 : 12)
                    .scaleEffect(shown > lines.count ? 1 : 0.85)
                    .animation(.easeOut(duration: 1.4), value: shown)
                Button(Voice.shared.muted ? "Turn voice on" : "Mute voice") {
                    Voice.shared.muted.toggle(); shown = shown + 0
                }.buttonStyle(.link).font(.caption).opacity(shown > lines.count ? 0.7 : 0)
                Spacer()
            }.padding(40)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            for (i, l) in lines.enumerated() {
                shown = i + 1
                let d = Voice.shared.play(l.1)
                try? await Task.sleep(for: .milliseconds(Int(max(d, 1.3) * 1000) + 250))
            }
            shown = lines.count + 1
        }
    }
}

/// Text that rises out of a blur, like something surfacing through water.
struct Emerging: View {
    let text: String; let visible: Bool
    var body: some View {
        Text(text).multilineTextAlignment(.center)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 14)
            .scaleEffect(visible ? 1 : 0.94)
            .offset(y: visible ? 0 : 14)
            .animation(.easeOut(duration: 1.5), value: visible)
    }
}

/// Soft, slowly drifting light behind the conversation.
struct Mist: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<3 {
                    let k = Double(i)
                    let x = size.width * (0.5 + 0.28 * sin(t * 0.07 + k * 2.1))
                    let y = size.height * (0.45 + 0.22 * cos(t * 0.05 + k * 1.7))
                    let r = min(size.width, size.height) * (0.55 + 0.1 * sin(t * 0.09 + k))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)),
                             with: .color(Color.accentColor.opacity(0.10)))
                }
            }.blur(radius: 70)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct BigButton: View {
    let label: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(Color.accentColor).frame(width: 120, height: 120)
                .overlay(Text(label).font(.title2.bold()).foregroundStyle(.white)).shadow(radius: 8)
        }.buttonStyle(.plain)
    }
}

struct BubbleView: View {
    let b: Bubble
    var body: some View {
        HStack {
            if b.fromMe { Spacer(minLength: 80) }
            Group { if b.fromMe || b.text.isEmpty { Text(b.text.isEmpty ? "…" : b.text) } else { MarkdownText(text: Choices.split(b.text).body, size: 17) } }
                .textSelection(.enabled)
                .font(b.fromMe ? .body : .title3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(b.fromMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .foregroundStyle(b.fromMe ? .white : .primary)
            if !b.fromMe { Spacer(minLength: 80) }
        }
    }
}

/// Shows the last few things said: the newest line surfaces in the middle, older ones fade away above it.
struct Stage: View {
    let bubbles: [Bubble]; let busy: Bool
    @State var appeared: Set<UUID> = []
    var body: some View {
        let recent = Array(bubbles.suffix(4))
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            ForEach(Array(recent.enumerated()), id: \.element.id) { i, b in
                let age = recent.count - 1 - i        // 0 = newest
                let on = appeared.contains(b.id)
                Group { if b.fromMe { Text(b.text) } else { MarkdownText(text: Choices.split(b.text).body, size: age == 0 ? 20 : 16) } }
                    .font(b.fromMe ? .title3 : (age == 0 ? .system(size: 26, weight: .medium) : .title3))
                    .foregroundStyle(b.fromMe ? Color.accentColor : .primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .opacity(on ? max(0.12, 1 - Double(age) * 0.32) : 0)
                    .blur(radius: on ? Double(age) * 0.8 : 14)
                    .scaleEffect(on ? 1 : 0.94)
                    .offset(y: on ? 0 : 16)
                    .onAppear { withAnimation(.easeOut(duration: 1.5)) { _ = appeared.insert(b.id) } }
            }
            if busy { ProgressView().controlSize(.small).padding(.top, 6) }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 1.0), value: bubbles.count)
    }
}

struct Chip: View {
    let label: String; var selected = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .foregroundStyle(selected ? .white : .primary)
                .overlay(Capsule().stroke(.quaternary))
        }.buttonStyle(.plain)
    }
}

struct OnboardingView: View {
    @ObservedObject var m: Model
    @State var text = ""
    @State var paste = ""
    var body: some View {
        Group { if m.step == .world { WorldStage(m: m) } else { VStack(spacing: 0) {
            Stage(bubbles: m.bubbles, busy: m.busy)
            answerArea.padding(24).frame(maxWidth: .infinity)
                .opacity(m.speaking ? 0 : 1).blur(radius: m.speaking ? 8 : 0)
                .allowsHitTesting(!m.speaking)
                .animation(.easeOut(duration: 0.9), value: m.speaking)
                .id(m.step).transition(.opacity.combined(with: .offset(y: 10)))
                .animation(.easeOut(duration: 0.8), value: m.step)
        } } }
        .background(Mist())
        .task { if m.switchingAI { m.bubbles.removeAll(); m.step = .pickAI; await m.say("Which AI should I use?") } else { await m.beginOnboarding() } }
    }

    @ViewBuilder var answerArea: some View {
        switch m.step {
        case .installing:
            VStack(spacing: 14) {
                if m.needDevTools {
                    Button("Continue") { Task { await m.install() } }.buttonStyle(.borderedProminent).controlSize(.large)
                } else if let e = m.installError {
                    Text(e).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    Button("Try again") { Task { await m.install() } }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    ProgressView(value: Double(min(m.installDone, 26)), total: 26).frame(maxWidth: 320)
                    Text(m.installLine.isEmpty ? "Starting…" : m.installLine)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 380)
                }
            }
        case .pickAI:
            VStack(spacing: 10) {
                ForEach(Provider.allCases) { p in
                    Button { Task { await m.choose(p) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: p.symbol).font(.system(size: 20, weight: .light)).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.headline)
                                Text(m.signedIn[p] == true ? "Already signed in" : p.subtitle)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(12).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    }.buttonStyle(.plain).disabled(m.busy)
                }
                if let p = m.signInProblem { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if m.switchingAI { Button("Never mind") { m.switchingAI = false; m.step = .done; m.bubbles.removeAll() }.buttonStyle(.link) }
            }
        case .signingIn:
            VStack(spacing: 14) {
                if let c = m.signInCode {
                    Text("If the page asks for a code, enter:").foregroundStyle(.secondary)
                    Text(c).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
                if m.signInNeedsPaste {
                    Text("Paste the code the page shows you:").foregroundStyle(.secondary)
                    HStack {
                        TextField("Code", text: $paste).textFieldStyle(.roundedBorder).onSubmit(sendPaste)
                        Button("Continue", action: sendPaste).buttonStyle(.borderedProminent)
                    }.frame(maxWidth: 420)
                }
                if m.signInCode == nil && !m.signInNeedsPaste {
                    HStack { ProgressView().controlSize(.small); Text("Waiting for you to sign in…").foregroundStyle(.secondary) }
                }
                Button("Cancel") { m.cancelSignIn() }.buttonStyle(.link)
            }
        case .nameAssistant:
            VStack(spacing: 12) {
                HStack { ForEach(["Juno", "Max", "Sage", "Nova"], id: \.self) { n in Chip(label: n) { Task { await m.nameAssistant(n) } } } }
                field("Or type a name") { await m.nameAssistant($0) }
            }
        case .nameUser:
            field("Your name") { await m.nameUser($0) }
        case .rooms:
            VStack(spacing: 12) {
                Button("No, start simple") { Task { await m.roomsChosen(true) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("or pick any that should be kept separate").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([RoomKind.work, .cofounder, .privateRoom]) { k in
                        Chip(label: k.chip, selected: m.pickedRooms.contains(k)) {
                            if m.pickedRooms.contains(k) { m.pickedRooms.remove(k) } else { m.pickedRooms.insert(k) }
                        }
                    }
                }
                if !m.pickedRooms.isEmpty {
                    Button("Continue") { Task { await m.roomsChosen(false) } }.buttonStyle(.borderedProminent)
                }
            }.disabled(m.busy)
        case .backup:
            HStack(spacing: 16) {
                Button("Yes, back it up") { Task { await m.backupChosen(true) } }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") { Task { await m.backupChosen(false) } }.controlSize(.large)
            }.disabled(m.busy)
        case .connect:
            VStack(spacing: 12) {
                Text("Pick as many as you like").font(.caption).foregroundStyle(.secondary)
                let opts = m.connectOptions
                VStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: opts.count, by: 4)), id: \.self) { r in
                        HStack { ForEach(opts[r..<min(r + 4, opts.count)], id: \.self) { c in
                            Chip(label: c, selected: m.pickedConnections.contains(c)) { m.toggleConnection(c) }
                        } }
                    }
                }
                field("Or add your own, like \"my bank\"") { m.addOwnConnection($0) }
                HStack(spacing: 16) {
                    Button("Continue") { Task { await m.connectionsChosen() } }
                        .buttonStyle(.borderedProminent).disabled(m.pickedConnections.isEmpty)
                    Button("Not now") { m.pickedConnections = []; Task { await m.connectionsChosen() } }.buttonStyle(.link)
                }
            }
        case .whichEmail:
            VStack(spacing: 12) {
                HStack {
                    ForEach(["Gmail", "Outlook", "iCloud Mail", "Yahoo"], id: \.self) { e in
                        Chip(label: e, selected: m.pickedEmails.contains(e)) {
                            if m.pickedEmails.contains(e) { m.pickedEmails.remove(e) } else { m.pickedEmails.insert(e) }
                        }
                    }
                }
                Button("Continue") { Task { await m.emailsChosen() } }
                    .buttonStyle(.borderedProminent).disabled(m.pickedEmails.isEmpty)
            }
        case .passwords:
            let hasOP = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/op")
            VStack(spacing: 10) {
                HStack {
                    Chip(label: hasOP ? "1Password (found on this Mac)" : "1Password") { Task { await m.passwordsChosen("1Password") } }
                    Chip(label: "Bitwarden") { Task { await m.passwordsChosen("Bitwarden") } }
                }
                HStack {
                    Chip(label: "My Mac's Keychain") { Task { await m.passwordsChosen("your Mac's Keychain") } }
                    Chip(label: "Ask me each time") { Task { await m.passwordsChosen("Ask me each time") } }
                }
            }
        case .passwordsOK:
            HStack(spacing: 16) {
                Button("Yes") { Task { await m.passwordsOK(true) } }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") { Task { await m.passwordsOK(false) } }.controlSize(.large)
            }
        case .wrapUp:
            VStack(spacing: 10) {
                ForEach(m.suggestions, id: \.self) { s in
                    Button { m.finish(); Task { await m.send(s) } } label: {
                        Text(s).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    }.buttonStyle(.plain).disabled(m.busy)
                }
                Button("I'll look around first") { m.finish() }.buttonStyle(.link).disabled(m.busy)
            }
        case .done, .world:
            EmptyView()
        }
    }

    func sendPaste() { let p = paste; paste = ""; m.pasteCode(p) }

    func field(_ placeholder: String, _ go: @escaping (String) async -> Void) -> some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.title3)
            .padding(10).background(RoundedRectangle(cornerRadius: 20).stroke(.quaternary))
            .onSubmit { let t = text; text = ""; Task { await go(t) } }
            .frame(maxWidth: 440)
    }
}

struct HomeView: View {
    @ObservedObject var m: Model
    @State var draft = ""
    @State var folderSheet = false
    @FocusState var typing: Bool
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var lastReply: Bubble? { m.bubbles.last.flatMap { $0.fromMe ? nil : $0 } }
    var body: some View {
        ZStack {
            Mist()
            ScrollView {
                VStack(spacing: 18) {
                    Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).padding(.top, 18)
                    Orb(size: 92, active: m.thinking).frame(height: 150)
                    if m.thinking {
                        Text(m.working ?? "Working on it…").foregroundStyle(.secondary).transition(.opacity)
                    }
                    if !m.asks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                            ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                        }
                    }
                    if let ask = lastAsk {
                        VStack(spacing: 12) {
                            Text(ask.text).font(.callout).foregroundStyle(Color.accentColor).multilineTextAlignment(.center)
                            if let r = lastReply, !r.text.isEmpty {
                                let parts = Choices.split(r.text)
                                MarkdownText(text: parts.body, size: 16)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                    .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                                    .id(r.id).transition(.opacity.combined(with: .offset(y: 10)))
                                if !parts.choices.isEmpty && !m.thinking {
                                    ChoiceRow(choices: parts.choices, disabled: m.paused) { c in Task { await m.send(c) } }
                                        onOther: { typing = true }
                                        .transition(.opacity)
                                }
                            }
                        }.animation(.easeOut(duration: 0.9), value: lastReply?.text.isEmpty)
                    }
                    askBox.padding(.top, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(lastAsk == nil ? "THINGS ONLY I CAN DO FROM YOUR MAC" : "TRY SOMETHING ELSE")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(tryItems, id: \.self) { it in
                                Button { Task { await m.send(it.text) } } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Image(systemName: it.symbol).font(.system(size: 14, weight: .light))
                                            Text(it.tag.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                        }
                                        Text(it.text).font(.callout).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
                                }.buttonStyle(.plain).disabled(m.thinking || m.paused)
                            }
                        }
                    }
                }.padding(.horizontal, 28).padding(.bottom, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
        }
        .toolbar {
            ToolbarItem { Button { folderSheet = true } label: { Label("Folders", systemImage: "folder") } }
            ToolbarItem { Button { m.switchingAI = true } label: { Label("Switch AI", systemImage: "arrow.triangle.2.circlepath") } }
            ToolbarItem {
                Button { m.toggleStop() } label: {
                    Label(m.paused ? "Turn on" : "Stop", systemImage: m.paused ? "play.circle" : "stop.circle")
                }.tint(m.paused ? .green : .red)
            }
        }
        .navigationTitle(m.name)
        .sheet(isPresented: $folderSheet) { FolderSheet(m: m) { folderSheet = false } }
        .task { await m.ensureEngine() }
    }
    var askBox: some View {
        HStack(spacing: 12) {
            TextField(lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…", text: $draft)
                .textFieldStyle(.plain).font(.title3).focused($typing)
                .padding(12).padding(.horizontal, 4).background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(typing ? 0.28 : 0.1)))
                .onSubmit(go).disabled(m.paused)
            Button(action: go) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32, weight: .light)) }
                .buttonStyle(.plain).disabled(m.paused || m.thinking || draft.isEmpty)
        }
    }
    func go() { let t = draft; draft = ""; Task { await m.send(t) } }
}

/// The assistant's suggested answers as buttons, plus a way to just say something else.
struct ChoiceRow: View {
    let choices: [String]; var disabled = false
    let pick: (String) -> Void
    var onOther: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                Button { pick(c) } label: {
                    Text(c).font(.callout.weight(i == 0 ? .semibold : .regular))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(i == 0 ? WorldLook.bg : .primary)
                        .background(Capsule().fill(i == 0 ? WorldLook.cream : Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.white.opacity(i == 0 ? 0 : 0.16)))
                }.buttonStyle(.plain)
            }
            Button(action: onOther) {
                Text("Something else…").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 9)
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }.disabled(disabled)
    }
}

struct AskCard: View {
    let a: Ask; let answer: (String?) -> Void
    func isNo(_ id: String) -> Bool { id.hasPrefix("deny") || id.hasPrefix("reject") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.question).font(.headline)
            HStack {
                ForEach(a.options, id: \.0) { o in
                    Button(o.0 == "allow_once" ? "Yes" : (isNo(o.0) ? "No" : o.1)) { answer(o.0) }
                        .buttonStyle(.borderedProminent).tint(isNo(o.0) ? .gray : .accentColor)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
}

final class OneDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Floater.shared.setup() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Floater.shared.openMain(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.stop()
        Engine.stopStrayGateway()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct OneApp: App {
    @NSApplicationDelegateAdaptor(OneDelegate.self) var delegate
    var body: some Scene { WindowGroup("One") { RootView() }.windowResizability(.contentSize) }
}

// MARK: - Entry, with headless tests the agent can run

@main
struct Entry {
    static func runHeadless(_ body: @escaping @Sendable () async -> Void) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await body(); sem.signal() }
        sem.wait(); exit(0)
    }

    static func main() {
        let args = CommandLine.arguments
        if let k = args.firstIndex(of: "--render-world"), k + 1 < args.count {
            let out = args[k + 1]
            MainActor.assumeIsolated {
                let views: [(String, AnyView)] = [
                    ("tour", AnyView(WorldCanvas(t: 30, lit: 1, picking: false, linked: [:], speaking: true).background(WorldLook.bg))),
                    ("md", AnyView(MarkdownText(text: "## Downloads, tidied\n\nI moved **42 files** into 5 folders:\n\n1. **Receipts** (12)\n2. *Screenshots* (18)\n3. Installers (`.dmg`, 6)\n\n- Kept on top: `resume.pdf`\n  - nested item\n\n| Folder | Files |\n|---|---|\n| Receipts | 12 |\n| Screenshots | 18 |\n\n> Nothing was deleted.\n\nSee [Finder](https://apple.com) for details.", size: 16).padding(18).frame(width: 520).background(RoundedRectangle(cornerRadius: 18).fill(Color.gray.opacity(0.15))).padding(20).background(WorldLook.bg).environment(\.colorScheme, .dark))),
                    ("choices", AnyView(VStack(alignment: .leading, spacing: 12) {
                        MarkdownText(text: Choices.split("I'll sort **555 files** into 12 folders by type. Nothing gets deleted.\n\n[choices: Yes, go ahead | Not now | Change the plan]").body, size: 16).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
                        ChoiceRow(choices: Choices.split("x\n[choices: Yes, go ahead | Not now | Change the plan]").choices) { _ in }
                    }.padding(24).frame(width: 600).background(WorldLook.bg).environment(\.colorScheme, .dark))),
                    ("orb", AnyView(Orb(size: 92, active: false).frame(width: 300, height: 300).background(WorldLook.bg))),
                    ("float-idle", AnyView(FloatScene(state: .idle))),
                    ("float-listen", AnyView(FloatScene(state: .listening))),
                    ("float-work", AnyView(FloatScene(state: .working))),
                    ("picked", AnyView(WorldCanvas(t: 60, lit: nil, picking: true, linked: ["Email": 50, "Files": 52, "Calendar": 59.6], speaking: false).background(WorldLook.bg))),
                ]
                for (name, v) in views {
                    let r = ImageRenderer(content: v.frame(width: 620, height: 440)); r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(out)-\(name).png")); print("wrote \(out)-\(name).png")
                    }
                }
            }
            exit(0)
        }
        if args.contains("--install-test") {
            // Fresh-user test: set ONE_SUPPORT_DIR to an empty folder and OPENROUTER_API_KEY.
            runHeadless {
                let t0 = Date()
                print("devtools missing:", Installer.devToolsMissing)
                let err: String? = Env.hermesPath != nil ? nil : await Installer.run { n, line in if line.hasPrefix("Install") || n % 5 == 0 { print("  [\(n)] \(line)") } }
                if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] {
                    try? "OPENROUTER_API_KEY=\(k)\n".write(to: Env.hermesHome.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
                }
                print("install:", err ?? "ok", "in \(Int(Date().timeIntervalSince(t0)))s", "hermes:", Env.hermesPath ?? "missing")
                guard err == nil else { return }
                await SignIn.makeDefault(.openrouter)
                _ = await hermesRun(["config", "set", "model.default", "openai/gpt-4o-mini"])
                Access.override = []
                Persona.write(assistant: "Juno", user: "EK", connections: [], passwords: "ask each time")
                if let e = await Engine.shared.start() { print("engine:", e); return }
                Engine.shared.onText = { print($0, terminator: "") }
                for q in ["Who are you and what's my name? One sentence.", "List 3 files in my Downloads folder."] {
                    print("\nQ:", q); print("A:", terminator: " ")
                    let stop = await Engine.shared.prompt(q); print(" [\(stop)]")
                }
                Engine.stopStrayGateway()
            }
        }
        if args.contains("--reset") {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            print("reset onboarding"); exit(0)
        }
        if args.contains("--selftest") {
            // Uses a throwaway Hermes home and an OPENROUTER_API_KEY from the environment.
            Env.selfTest = true
            runHeadless {
                print("hermes:", Env.hermesPath ?? "missing")
                for p in Provider.allCases { print("[\(p.title)] signed in (selftest home):", await SignIn.isSignedIn(p)) }
                await SignIn.makeDefault(.openrouter)
                try? FileManager.default.removeItem(at: Brain.root)
                print("brain:", Brain.build(owner: "Omar", ai: "Juno", rooms: [.work]) ?? "built at \(Brain.root.path)")
                print("rooms:", Brain.rooms.map(\.folder))
                print("backup:", Brain.backupToICloud() ?? "copied to iCloud Drive")
                Access.override = []
                Persona.write(assistant: "Juno", user: "Omar", connections: ["Gmail"], passwords: "use 1Password")
                let t0 = Date()
                if let e = await Engine.shared.start() { print("engine start failed:", e); return }
                print("engine started in \(Int(Date().timeIntervalSince(t0)))s")
                let out = Box("")
                Engine.shared.onText = { out.v += $0 }
                Engine.shared.onTool = { print("  tool:", $0) }
                Engine.shared.onPermission = { q, opts, ans in print("  permission asked:", q, opts.map(\.0)); ans("deny") }
                for q in ["Who are you, and what's my name? One sentence.",
                          "How does your memory work, and which rooms do I have? Two short sentences.",
                          "Remember that my daughter's birthday is March 3.",
                          "List 3 file names in my Downloads folder."] {
                    out.v = ""
                    let t1 = Date()
                    let stop = await Engine.shared.prompt(q)
                    print("Q: \(q)\nA (\(Int(Date().timeIntervalSince(t1)))s, \(stop)): \(out.v.prefix(300))")
                }
                Engine.shared.stop()
            }
        }
        if let i = args.firstIndex(of: "--signin-probe"), i + 1 < args.count, let p = Provider(rawValue: args[i + 1]) {
            // Starts a real sign-in, prints what the app would show, then cancels.
            Env.selfTest = true
            runHeadless {
                let s = SignIn()
                let seen = Box([String]())
                s.start(p) { ev in
                    switch ev {
                    case .openPage(let u): seen.v.append("would open page: \(u.absoluteString.prefix(90))")
                    case .code(let c): seen.v.append("would show code: \(c)")
                    case .needPaste: seen.v.append("would ask to paste a code")
                    case .done(let ok, let m): seen.v.append("finished ok=\(ok) \(m.prefix(120))")
                    }
                }
                try? await Task.sleep(for: .seconds(25))
                s.cancel()
                try? await Task.sleep(for: .seconds(2))
                seen.v.forEach { print($0) }
            }
        }
        OneApp.main()
    }
}
