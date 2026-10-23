// One — a one-button personal assistant (test build 0.2).
// The face is this app. The engine is Hermes, run privately for One via ACP.
// Setup is a conversation the assistant leads. The user never sees a terminal.
import SwiftUI
import AppKit
import AVFoundation

// MARK: - Paths and environment

enum Env {
    nonisolated(unsafe) static var selfTest = false
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
    static var hermesPath: String? {
        let h = NSHomeDirectory()
        return ["\(h)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func vars() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        let h = NSHomeDirectory()
        e["PATH"] = "\(h)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HERMES_HOME"] = hermesHome.path
        e["PYTHONUNBUFFERED"] = "1"; e["NO_COLOR"] = "1"; e["TERM"] = "dumb"
        for k in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "OPENAI_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
            e.removeValue(forKey: k)
        }
        if !selfTest { e.removeValue(forKey: "OPENROUTER_API_KEY") }
        return e
    }
}

final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

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
    var defaultModel: String {
        switch self {
        case .claude: "claude-sonnet-5"; case .chatgpt: "gpt-5.5"
        case .grok: "grok-4.6"; case .openrouter: "openrouter/auto"
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
    static func makeDefault(_ p: Provider) async {
        _ = await hermesRun(["config", "set", "model.provider", p.hermesID])
        _ = await hermesRun(["config", "set", "model.default", p.defaultModel])
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

    var running: Bool { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true && sessionID != nil }

    func stop() {
        lock.lock(); let p = proc; proc = nil; sessionID = nil
        let w = waiting; waiting = [:]; lock.unlock()
        w.values.forEach { $0(["error": "stopped"]) }
        if let p, p.isRunning { p.terminate() }
    }

    func start() async -> String? {
        stop()
        guard let hp = Env.hermesPath else { return "Hermes isn't on this Mac yet." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hp)
        p.arguments = ["acp"]
        p.environment = Env.vars()
        p.currentDirectoryURL = Env.support
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
        let new = await call("session/new", ["cwd": Env.support.path, "mcpServers": [Any]()], timeout: 120)
        guard let r = new["result"] as? [String: Any], let sid = r["sessionId"] as? String else {
            return "The assistant couldn't open a conversation."
        }
        lock.lock(); sessionID = sid; lock.unlock()
        return nil
    }

    /// Sends one message; text streams through onText. Returns the stop reason or "error: …".
    func prompt(_ text: String) async -> String {
        lock.lock(); let sid = sessionID; lock.unlock()
        guard let sid else { return "error: not started" }
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
            if let ask = onPermission { ask(title, opts, reply) } else { reply(nil) }
        } else {
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported by One"]])
        }
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

        Always ask for a yes first before you: buy anything, move money, send a message or email as them, post anywhere, delete anything, or change a password. Say exactly what you're about to do and what it costs.

        If the Mac is closed or off, you're off. Say so if they ask why you didn't do something.
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

struct Bubble: Identifiable { let id = UUID(); let fromMe: Bool; var text: String }

struct Ask: Identifiable {
    let id = UUID(); let question: String; let options: [(String, String)]
    let answer: @Sendable (String?) -> Void
}

enum Step: Equatable {
    case pickAI, signingIn, nameAssistant, nameUser, connect, whichEmail, passwords, passwordsOK, wrapUp, done
}

@MainActor
final class Model: ObservableObject {
    @AppStorage("onboarded") var onboarded = false
    @AppStorage("assistantName") var assistantName = ""
    @AppStorage("userName") var userName = ""
    @AppStorage("provider") var providerRaw = ""
    @AppStorage("connections") var connectionsRaw = ""
    @AppStorage("passwords") var passwords = ""

    @Published var bubbles: [Bubble] = []
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
    @Published var switchingAI = false
    @Published var speaking = false

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
        await say("First, which AI do you already pay for? I'll use it as my brain. You can switch any time.", voice: "pickAI")
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
        await SignIn.makeDefault(p)
        await say("You're connected to \(p.title). Let me check I can think with it…", voice: "checking")
        if let err = await Engine.shared.start() { step = .pickAI; await say("Something went wrong: \(err)"); return }
        let got = Box("")
        Engine.shared.onText = { t in got.v += t }
        let stop = await Engine.shared.prompt("Reply with exactly one word: ready")
        Engine.shared.onText = nil
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
        me(n); userName = n; step = .connect
        await say("Nice to meet you, \(n).", voice: "niceToMeet")
        await say("Want me to connect anything? People usually start with one of these. Or just tell me in your own words.", voice: "connect")
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

    private func addConnection(_ c: String) {
        var l = connections; if !l.contains(c) { l.append(c) }; connectionsRaw = l.joined(separator: ",")
    }

    private func wrapUp() async {
        step = .wrapUp
        busy = true
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        _ = await Engine.shared.start()      // restart so the new name and memory load
        busy = false
        await say("You're all set, \(userName). Here are a few things I can do right now. Tap one, or just ask.", voice: "allSet")
    }

    func finish() { onboarded = true; step = .done; bubbles.removeAll() }

    var suggestions: [String] {
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
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        if let e = await Engine.shared.start() { bubbles.append(Bubble(fromMe: false, text: "I couldn't start: \(e)")) }
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
        thinking = false; working = nil
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

// MARK: - Screens

struct RootView: View {
    @StateObject var m = Model()
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
            Text(b.text.isEmpty ? "…" : b.text).textSelection(.enabled)
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
                Text(b.text)
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
        VStack(spacing: 0) {
            Stage(bubbles: m.bubbles, busy: m.busy)
            answerArea.padding(24).frame(maxWidth: .infinity)
                .opacity(m.speaking ? 0 : 1).blur(radius: m.speaking ? 8 : 0)
                .allowsHitTesting(!m.speaking)
                .animation(.easeOut(duration: 0.9), value: m.speaking)
                .id(m.step).transition(.opacity.combined(with: .offset(y: 10)))
                .animation(.easeOut(duration: 0.8), value: m.step)
        }
        .background(Mist())
        .task { if m.switchingAI { m.bubbles.removeAll(); m.step = .pickAI; await m.say("Which AI should I use?") } else { await m.beginOnboarding() } }
    }

    @ViewBuilder var answerArea: some View {
        switch m.step {
        case .pickAI:
            VStack(spacing: 10) {
                ForEach(Provider.allCases) { p in
                    Button { Task { await m.choose(p) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: p.symbol).font(.title2).frame(width: 34)
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
        case .connect:
            VStack(spacing: 12) {
                HStack { ForEach(["Email", "Calendar", "News", "Not now"], id: \.self) { c in Chip(label: c) { Task { await m.connect(c) } } } }
                field("Or tell me, like \"my bank\" or \"WhatsApp\"") { await m.connect($0) }
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
        case .done:
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
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(greeting), \(m.userName).").font(.system(size: 28, weight: .semibold))
                        Text("\(m.name) is here.").foregroundStyle(.secondary)

                        if !m.asks.isEmpty {
                            Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange).padding(.top, 8)
                            ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                        }
                        if m.bubbles.isEmpty {
                            Text("TRY").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8)
                            ForEach(m.suggestions, id: \.self) { s in
                                Button { Task { await m.send(s) } } label: {
                                    Text(s).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                                }.buttonStyle(.plain)
                            }
                        }
                        ForEach(m.bubbles) { BubbleView(b: $0).id($0.id) }
                        if m.thinking {
                            HStack { ProgressView().controlSize(.small); Text(m.working ?? "Thinking…").foregroundStyle(.secondary) }
                        }
                    }.padding(28)
                }.onChange(of: m.bubbles.last?.text) { _, _ in
                    if let l = m.bubbles.last { proxy.scrollTo(l.id, anchor: .bottom) }
                }
            }
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
            HStack(spacing: 12) {
                TextField("Ask \(m.name)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.title3).lineLimit(1...4)
                    .padding(12).background(RoundedRectangle(cornerRadius: 22).stroke(.quaternary))
                    .onSubmit(go).disabled(m.paused)
                Button(action: go) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
                    .buttonStyle(.plain).disabled(m.paused || m.thinking || draft.isEmpty)
            }.padding(16)
        }
        .toolbar {
            ToolbarItem { Button { m.switchingAI = true } label: { Label("Switch AI", systemImage: "switch.2") } }
            ToolbarItem {
                Button { m.toggleStop() } label: {
                    Label(m.paused ? "Turn on" : "Stop", systemImage: m.paused ? "play.circle.fill" : "stop.circle.fill")
                }.tint(m.paused ? .green : .red)
            }
        }
        .navigationTitle(m.name)
        .task { await m.ensureEngine() }
    }
    func go() { let t = draft; draft = ""; Task { await m.send(t) } }
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

struct OneApp: App {
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
                Persona.write(assistant: "Juno", user: "Omar", connections: ["Gmail"], passwords: "use 1Password")
                let t0 = Date()
                if let e = await Engine.shared.start() { print("engine start failed:", e); return }
                print("engine started in \(Int(Date().timeIntervalSince(t0)))s")
                let out = Box("")
                Engine.shared.onText = { out.v += $0 }
                Engine.shared.onTool = { print("  tool:", $0) }
                Engine.shared.onPermission = { q, opts, ans in print("  permission asked:", q, opts.map(\.0)); ans("deny") }
                for q in ["Who are you, and what's my name? One sentence.",
                          "What did I say I want connected? Short.",
                          "What's in my Downloads folder? List 3 names."] {
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
