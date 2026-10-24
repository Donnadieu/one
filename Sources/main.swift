import Quartz
// One — a one-button personal assistant (test build 0.2).
// The face is this app. The engine is Hermes, run privately for One via ACP.
// Setup is a conversation the assistant leads. The user never sees a terminal.
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import UniformTypeIdentifiers

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

// MARK: - Voice (pre-recorded Kokoro lines: fallback until the live voice is ready)

@MainActor
final class Voice {
    static let shared = Voice()
    private var player: AVAudioPlayer?
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceMuted"); if newValue { player?.stop(); Speaker.shared.stop() } }
    }
    /// Plays a line and returns how long it lasts (0 if muted or missing).
    @discardableResult
    func play(_ key: String) -> Double {
        guard !muted, let url = Bundle.main.url(forResource: key, withExtension: "mp3") else { return 0 }
        Speaker.shared.hush()
        return Speaker.shared.enqueue(url)
    }
    func stop() { Speaker.shared.hush() }
}


// MARK: - Live voice (Kokoro, free and on this Mac): says anything, including names, in the same voice as setup.

final class Speaker: @unchecked Sendable {
    static let shared = Speaker()
    private var proc: Process?
    private var input: FileHandle?
    private var waiting: [String: (URL?, Double) -> Void] = [:]
    private let q = DispatchQueue(label: "one.speaker")
    private var buf = ""
    private(set) var ready = false
    // One always-running audio line, so Bluetooth speakers/headphones never fall asleep
    // and swallow the first words. Nothing is heard while idle (it plays silence).
    private let audio = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var audioUp = false
    private var endsAt = Date.distantPast
    private var queue: [(String, Int)] = []   // (text, generation)
    private var gen = 0
    private var playing = false
    var dir: URL { Env.support.appendingPathComponent("voice", isDirectory: true) }
    var installed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ready").path) }

    /// Downloads the voice once (about 350 MB), next to One's engine. Safe to call again.
    func install() async -> Bool {
        if installed { return true }
        guard let script = Bundle.main.url(forResource: "install_voice", withExtension: "sh") else { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script.path, Env.support.path]
                p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
                let log = Env.support.appendingPathComponent("voice-install.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
                do { try p.run() } catch { cont.resume(returning: false); return }
                p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    /// Main thread. Starts (or restarts) the audio line.
    func wakeAudio() {
        if !audioUp {
            audioUp = true
            audio.attach(node)
            audio.connect(node, to: audio.mainMixerNode, format: fmt)
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
                self?.endsAt = .distantPast; self?.wakeAudio()
            }
        }
        if !audio.isRunning { audio.prepare(); try? audio.start() }
        if !node.isPlaying { node.play() }
    }
    private func buffer(_ url: URL) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: url),
              let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: inBuf)) != nil else { return nil }
        if f.processingFormat == fmt { return inBuf }
        guard let conv = AVAudioConverter(from: f.processingFormat, to: fmt) else { return nil }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * fmt.sampleRate / f.processingFormat.sampleRate) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return inBuf
        }
        return err == nil ? out : nil
    }
    /// Main thread. Queues a sound right after whatever is playing; returns its length.
    @discardableResult
    func enqueue(_ url: URL) -> Double {
        wakeAudio()
        guard let b = buffer(url) else { return 0 }
        let d = Double(b.frameLength) / fmt.sampleRate
        node.scheduleBuffer(b, completionHandler: nil)
        endsAt = max(endsAt, Date()).addingTimeInterval(d)
        return d
    }
    /// Main thread. Silences now but keeps the line awake.
    func hush() { node.stop(); endsAt = .distantPast; wakeAudio() }

    func start() {
        DispatchQueue.main.async { self.wakeAudio() }
        q.async {
            guard self.proc == nil, self.installed, let script = Bundle.main.url(forResource: "speak", withExtension: "py") else { return }
            let p = Process()
            p.executableURL = self.dir.appendingPathComponent("venv/bin/python")
            p.arguments = ["-I", script.path, self.dir.path, "af_heart"]
            let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
            o.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData; guard let self, !d.isEmpty else { return }
                self.q.async {
                    self.buf += String(decoding: d, as: UTF8.self)
                    while let nl = self.buf.firstIndex(of: "\n") {
                        let line = String(self.buf[..<nl]); self.buf = String(self.buf[self.buf.index(after: nl)...])
                        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = j["id"] as? String else { continue }
                        if id == "ready" { self.ready = true; continue }
                        let cb = self.waiting.removeValue(forKey: id)
                        let url = (j["path"] as? String).map { URL(fileURLWithPath: $0) }
                        cb?(url, j["dur"] as? Double ?? 0)
                    }
                }
            }
            p.terminationHandler = { [weak self] _ in self?.q.async { self?.proc = nil; self?.ready = false; for (_, cb) in self?.waiting ?? [:] { cb(nil, 0) }; self?.waiting = [:] } }
            do { try p.run() } catch { return }
            self.proc = p; self.input = i.fileHandleForWriting
        }
    }

    /// Makes the audio for one line. Calls back with nil if the voice isn't available.
    func render(_ text: String, _ done: @escaping (URL?, Double) -> Void) {
        q.async {
            guard self.ready, let input = self.input else { done(nil, 0); return }
            let id = UUID().uuidString
            self.waiting[id] = done
            let msg = (try? JSONSerialization.data(withJSONObject: ["id": id, "text": text])) ?? Data()
            input.write(msg + Data("\n".utf8))
        }
    }
    /// Says a line now and returns its length in seconds (0 if the live voice isn't ready).
    func sayNow(_ text: String) async -> Double {
        guard ready, !UserDefaults.standard.bool(forKey: "voiceMuted") else { return 0 }
        stop()
        let (url, dur): (URL?, Double) = await withCheckedContinuation { c in render(text) { c.resume(returning: ($0, $1)) } }
        guard let url else { return 0 }
        await MainActor.run { _ = self.enqueue(url) }
        return dur
    }
    /// Reads a reply aloud, sentence by sentence, starting with the first while the rest is still being made.
    private var onFirst: (() -> Void)?
    /// `started` runs when the first sentence starts playing (or right away if there's nothing to say).
    func read(_ reply: String, started: (() -> Void)? = nil) {
        guard ready, !UserDefaults.standard.bool(forKey: "voiceMuted") else { started?(); return }
        stop()
        let g = gen
        let parts = Speaker.spoken(reply)
        guard !parts.isEmpty else { started?(); return }
        onFirst = started
        for sentence in parts { queue.append((sentence, g)) }
        pump()
    }
    private var pending: [(Int, URL?)] = []
    private func pump() {
        // render everything queued, play in order
        let items = queue; queue = []; nextIndex = 0
        var order = 0
        for (t, g) in items {
            let n = order; order += 1
            render(t) { [weak self] url, _ in
                DispatchQueue.main.async {
                    guard let self, g == self.gen else { return }
                    self.pending.append((n, url)); self.pending.sort { $0.0 < $1.0 }
                    self.playNext()
                }
            }
        }
    }
    private var nextIndex = 0
    /// Sentences go straight onto the audio line in order, back to back.
    private func playNext() {
        while let k = pending.firstIndex(where: { $0.0 == nextIndex }) {
            let (_, url) = pending.remove(at: k); nextIndex += 1
            if let url { enqueue(url) }
            if let f = onFirst { onFirst = nil; f() }
        }
    }
    var talking: Bool { Date() < endsAt }
    func stop() {
        gen += 1; pending = []; queue = []; nextIndex = 0
        if let f = onFirst { onFirst = nil; DispatchQueue.main.async { f() } }
        DispatchQueue.main.async { self.hush() }
    }

    /// What's worth saying out loud: plain sentences, no lists of links, code or long tables.
    static func spoken(_ text: String) -> [String] {
        var t = Choices.split(text).body
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "#", "|", ">"] { t = t.replacingOccurrences(of: mark, with: "") }
        let lines = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-—=:".contains($0) } }
            .map { l -> String in
                var l = l
                if let r = l.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) { l.removeSubrange(r) }
                if let last = l.last, !".!?:;".contains(last) { l += "." }
                return l
            }
        var out: [String] = []
        var cur = ""
        for l in lines {
            let parts = l.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression).components(separatedBy: "\n")
            for s in parts where !s.isEmpty {
                if cur.count + s.count < 160 { cur += (cur.isEmpty ? "" : " ") + s } else { if !cur.isEmpty { out.append(cur) }; cur = s }
                if out.count >= 8 { break }
            }
        }
        if !cur.isEmpty && out.count < 8 { out.append(cur) }
        return out
    }
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
    /// Helper sessions (one per background job): where their words go, and which ones this engine has open.
    private var sessionHandlers: [String: (text: @Sendable (String) -> Void, tool: @Sendable (String) -> Void)] = [:]
    private var loaded: Set<String> = []
    private let wlock = NSLock()
    static var workDir: String { (Brain.exists ? Brain.root : Env.support).path }

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
        lock.lock(); let p = proc; proc = nil; sessionID = nil; loaded = []; sessionHandlers = [:]
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
    func prompt(_ text: String, images: [String] = []) async -> String {
        lock.lock(); let sid = sessionID; lock.unlock()
        var id = sid
        if id == nil, await ensureStarted() == nil { lock.lock(); id = sessionID; lock.unlock() }
        guard let sid = id else { return "error: not started" }
        let r = await call("session/prompt", ["sessionId": sid, "prompt": [["type": "text", "text": text]] + images.map { ["type": "image", "data": $0, "mimeType": "image/jpeg"] }], timeout: 900)
        if let res = r["result"] as? [String: Any] { return res["stopReason"] as? String ?? "end_turn" }
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        return "error: \(r["error"] ?? "no answer")"
    }

    /// A new background session for a helper.
    func openSession() async -> String? {
        if await ensureStarted() != nil { return nil }
        let r = await call("session/new", ["cwd": Engine.workDir, "mcpServers": [Any]()], timeout: 120)
        guard let res = r["result"] as? [String: Any], let sid = res["sessionId"] as? String else { return nil }
        lock.lock(); loaded.insert(sid); lock.unlock()
        return sid
    }

    /// Talk to a helper's session (opening it again first if One restarted since).
    func promptSession(_ sid: String, _ text: String, images: [String] = [],
                       onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String) -> Void) async -> String {
        if await ensureStarted() != nil { return "error: not started" }
        lock.lock(); let isOpen = loaded.contains(sid); lock.unlock()
        if !isOpen {
            let r = await call("session/load", ["sessionId": sid, "cwd": Engine.workDir, "mcpServers": [Any]()], timeout: 120)
            guard r["error"] == nil, r["result"] != nil, !(r["result"] is NSNull) else { return "error: couldn't pick this job back up" }
            lock.lock(); loaded.insert(sid); lock.unlock()
        }
        lock.lock(); sessionHandlers[sid] = (onText, onTool); lock.unlock()
        let r = await call("session/prompt", ["sessionId": sid, "prompt": [["type": "text", "text": text]] + images.map { ["type": "image", "data": $0, "mimeType": "image/jpeg"] }], timeout: 1800)
        lock.lock(); sessionHandlers[sid] = nil; lock.unlock()
        if let res = r["result"] as? [String: Any] { return res["stopReason"] as? String ?? "end_turn" }
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        return "error: \(r["error"] ?? "no answer")"
    }

    func cancel(session sid: String) {
        write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sid]])
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
        wlock.lock(); h?.write(d + Data("\n".utf8)); wlock.unlock()
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
            let usid = params["sessionId"] as? String
            lock.lock(); let mainID = sessionID; let hh = usid.flatMap { sessionHandlers[$0] }; lock.unlock()
            let toMain = usid == nil || usid == mainID
            if !toMain && hh == nil { return }      // e.g. history replayed while a session reopens
            let textCB = toMain ? onText : hh?.text, toolCB = toMain ? onTool : hh?.tool
            switch u["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if let c = u["content"] as? [String: Any], let t = c["text"] as? String { textCB?(t) }
            case "tool_call":
                if let t = u["title"] as? String { toolCB?(t) }
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
        // GitHub and git logins the person already has on this Mac (so "connect my GitHub" just works).
        let logins = ["\(h)/.config/gh", "\(h)/.gitconfig", "\(h)/.config/git", "\(h)/.ssh", "\(h)/.git-credentials"]
        let rw = [Env.support.path, Brain.root.path, "\(h)/.cache", "\(h)/Library/Caches", "\(h)/.config/gh"] + folders + Shared.paths
        // The GitHub login token itself sits in the macOS keychain.
        var ro = ["\(h)/.local", "\(h)/Library/Keychains"] + logins
        // git's extra settings files (e.g. ~/.gitconfig-work pulled in by includeIf)
        ro += ((try? FileManager.default.contentsOfDirectory(atPath: h)) ?? []).filter { $0.hasPrefix(".gitconfig") }.map { "\(h)/\($0)" }
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

        Helpers: when they ask for a separate job that takes a while or runs in the background (watching a price, tidying files, digging through receipts, researching, checking something every day), don't do it yourself here. Say in one short line that you're sending a helper, then add a line exactly like:
        [helper: Flight to Quebec | Find the cheapest flight from PHL or EWR to Quebec City (YQB), Dec 20 to 24 2026, and keep an eye on the price.]
        The title is 2 to 4 words. After the | write the whole job with every detail, because the helper can't see this conversation. One line per job. You stay free to keep talking. Quick things (a question, one short lookup) you just do yourself.

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
    @AppStorage("interviewOffered") var interviewOffered = false
    @Published var roomInvites: [URL] = []
    var clashes: [String] = []
    func tendShared() {
        clashes += Shared.tend()
        let inv = Shared.invites()
        if inv.map(\.path) != roomInvites.map(\.path) { roomInvites = inv }
    }
    func joinRoom(_ u: URL) {
        Shared.join(u); roomInvites.removeAll { $0 == u }
        Task { _ = await Engine.shared.start() }
        if let i = Shared.info(u) { bubbles.append(Bubble(fromMe: false, text: "You're in \(i.title) now. Anything \(Shared.others(i).joined(separator: " and ")) adds shows up for both of you. Ask me \"what's new in \(i.title)?\" any time.")) }
    }
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
        let intro = "Nice to meet you, \(userName). This is everything I can reach from your Mac."
        let live = await Speaker.shared.sayNow(intro)
        if live > 0 { try? await Task.sleep(for: .milliseconds(500)) }
        worldCaption = intro
        if live > 0 { speakUntil = Date().addingTimeInterval(live) }
        await hold(live > 0 ? live : speak("worldIntro"), min: 3.6)
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
        // Voice first: live voice says the exact line (with names); the recorded line is the fallback.
        var d = Speaker.shared.ready ? await Speaker.shared.sayNow(text) : 0
        if d == 0 { d = voice.map { Voice.shared.play($0) } ?? 0 }
        let lag = d > 0 ? 0.6 : 0
        if lag > 0 { try? await Task.sleep(for: .milliseconds(Int(lag * 1000))) }
        // ...then the words follow.
        bubbles.append(Bubble(fromMe: false, text: text))
        try? await Task.sleep(for: .milliseconds(Int(max(d - lag, 1.1) * 1000) + 200))
    }
    func me(_ text: String) { Voice.shared.stop(); Speaker.shared.stop(); bubbles.append(Bubble(fromMe: true, text: text)) }

    // Onboarding

    func beginOnboarding() async {
        guard bubbles.isEmpty else { return }
        await say("Let's get you set up.", voice: "setup")
        if Env.hermesPath == nil {
            step = .installing
            await say("First, I'm setting myself up on this Mac. This only happens once. Please hang on while I get ready.", voice: "installing")
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
            Task.detached { if await Speaker.shared.install() { Speaker.shared.start() } }
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
        await say("Want to keep part of your life separate, like a job or a business? I'll give it its own room, where I act differently and keep its notes apart.", voice: "roomsQuestion")
    }

    func roomsChosen(_ simple: Bool) async {
        let extra = simple ? [] : RoomKind.allCases.filter { pickedRooms.contains($0) && $0 != .personal }
        me(extra.isEmpty ? "Start simple" : extra.map(\.chip).joined(separator: ", "))
        busy = true
        let err = Brain.build(owner: userName, ai: assistantName, rooms: extra)
        busy = false
        if let err { await say("I couldn't set up your memory: \(err)") }
        else if extra.isEmpty { await say("Your personal room is ready. If you ever want another one, just ask.", voice: "roomsSimple") }
        else { await say("Done. Each room keeps its own notes, and I act the way you want in each one.", voice: "roomsDone") }
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

    /// Pictures waiting to go with the next message (dragged, pasted, picked or dropped on the orb).
    @Published var pictures: [Picture] = []
    @Published var files: [SharedFile] = []
    /// Talking inside One's window (mic button, or the talk key while One is in front).
    @Published var talkingInApp = false
    @Published var talkNote: String?
    func talkBegin() {
        guard !talkingInApp else { return }
        talkNote = nil
        if busyHere { talkNote = "I'm still on the last thing. Give me a moment."; return }
        talkingInApp = true; Voice.shared.stop(); Speaker.shared.stop(); Listener.shared.begin()
    }
    func talkEnd() {
        guard talkingInApp else { return }
        Listener.shared.finish { heard in
            Task { @MainActor in
                self.talkingInApp = false
                if heard.isEmpty {
                    if Listener.shared.problem == nil { self.talkNote = "I didn't catch that. Hold the mic and talk, then let go." }
                    return
                }
                await self.send(heard)
            }
        }
    }

    // Helpers
    @Published var helpers: [Helper] = Model.savedHelpers() { didSet { saveHelpers() } }
    @Published var openHelper: UUID?
    @Published var shelf: [ShelfItem] = Shelf.load() { didSet { Shelf.save(shelf) } }
    @Published var openedShelf: UUID?
    @Published var draftSeed: String?
    @Published var about: (title: String, url: URL)?
    @Published var viewing: URL?
    func openShelf(_ id: UUID) {
        openedShelf = id
        if let k = shelf.firstIndex(where: { $0.id == id }) { shelf[k].fresh = false }
    }
    func removeShelf(_ id: UUID) {
        if openedShelf == id { openedShelf = nil }
        if let it = shelf.first(where: { $0.id == id }) {
            var h = UserDefaults.standard.stringArray(forKey: "shelfHidden") ?? []
            h.append(it.url.standardizedFileURL.path); UserDefaults.standard.set(h, forKey: "shelfHidden")
        }
        shelf.removeAll { $0.id == id }
    }
    /// Puts any new file in the results folder on the shelf. Runs every few seconds and after each reply.
    func scanShelf() {
        let new = Shelf.adopt(shelf)
        guard !new.isEmpty else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(contentsOf: new, at: 0) }
    }
    func putOnShelf(title: String, body: String, from: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let it = Shelf.keep(title: title, body: body, from: from) else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(it, at: 0) }
    }
    var openedHelper: Helper? { openHelper.flatMap { id in helpers.first { $0.id == id } } }
    /// Is whatever you're talking to right now busy?
    var busyHere: Bool { if let h = openedHelper { return h.state == "working" }; return thinking }
    static func savedHelpers() -> [Helper] {
        guard let d = UserDefaults.standard.data(forKey: "helpers"), var hs = try? JSONDecoder().decode([Helper].self, from: d) else { return [] }
        for k in hs.indices where hs[k].state == "working" { hs[k].state = "stopped"; hs[k].line = "Paused when One closed · tap to pick up" }
        return hs
    }
    func saveHelpers() { UserDefaults.standard.set(try? JSONEncoder().encode(helpers), forKey: "helpers") }
    func update(_ id: UUID, _ f: (inout Helper) -> Void) { if let k = helpers.firstIndex(where: { $0.id == id }) { f(&helpers[k]) } }
    func focusHelper(_ id: UUID) {
        openHelper = openHelper == id ? nil : id
        update(id) { $0.finishedAway = false }
    }
    func dismissHelper(_ id: UUID) {
        if openHelper == id { openHelper = nil }
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { $0.id == id } }
    }
    func clearAway() {
        let gone = helpers.filter { $0.finishedAway && $0.state == "done" }.map(\.id)
        for k in helpers.indices { helpers[k].finishedAway = false }
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { gone.contains($0.id) } }
    }

    func spawnHelper(title: String, task: String) {
        helpers.removeAll { ($0.state == "done" || $0.state == "stopped") && !$0.finishedAway && $0.id != openHelper }
        if helpers.filter({ $0.state == "working" }).count >= 3 {
            bubbles.append(Bubble(fromMe: false, text: "I already have 3 helpers busy. I'll take \"\(title)\" as soon as one is free; ask me again in a bit."))
            return
        }
        while helpers.count >= 4, let k = helpers.firstIndex(where: { $0.state != "working" }) { helpers.remove(at: k) }
        let h = Helper(title: title, task: task, sid: nil, state: "working", line: "Getting started…")
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { helpers.append(h) }
        let id = h.id
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                self.update(id) { $0.state = "done"; $0.line = "Couldn't start"; $0.reply = "I couldn't start this job. Ask \(self.name) again in a minute." }
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Helpers.brief(assistant: self.assistantName, user: self.userName, task: task), images: [])
        }
    }

    func runHelper(_ id: UUID, _ text: String, images: [String]) async {
        guard let sid = helpers.first(where: { $0.id == id })?.sid else { return }
        update(id) { $0.state = "working"; $0.reply = ""; $0.line = "Working on it…"; $0.finishedAway = false; $0.toldNova = false }
        let stop = await Engine.shared.promptSession(sid, text, images: images,
            onText: { s in Task { @MainActor in self.update(id) { $0.reply += s } } },
            onTool: { s in Task { @MainActor in self.update(id) { $0.line = Plain.step(s) } } })
        try? await Task.sleep(for: .milliseconds(150))
        let away = !NSApp.isActive
        update(id) { h in
            if stop.hasPrefix("error") && h.reply.isEmpty { h.reply = "I couldn't finish this (\(stop.dropFirst(7)))." }
            let parts = Choices.split(h.reply)
            if !parts.choices.isEmpty { h.state = "needsYes"; h.line = "Needs your yes" }
            else { h.state = "done"; h.line = "Done · " + Helpers.summary(parts.body, 30) }
            h.finishedAway = away || (self.openHelper != id && h.state == "needsYes")
        }
        if let h = helpers.first(where: { $0.id == id }), !stop.hasPrefix("error") {
            let said = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty {
                var entry = said
                if let a = h.asked, !a.isEmpty, !(h.log ?? []).isEmpty { entry = "**You:** \(a)\n\n" + said }
                update(id) { $0.log = ($0.log ?? []) + [entry] }
            }
            if let h2 = helpers.first(where: { $0.id == id }), h2.state == "done", let log = h2.log, !log.isEmpty {
                // The file keeps the whole report: the first full answer plus every follow-up, never just the last line.
                let body = log.joined(separator: "\n\n---\n\n")
                if let sid = h2.shelfID, let k = shelf.firstIndex(where: { $0.id == sid }) {
                    let text = "# \(h2.title)\n\n\(body)\n\n— \(h2.title) helper, \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
                    try? text.write(to: shelf[k].url, atomically: true, encoding: .utf8)
                    shelf[k].detail = Helpers.summary(log[0], 60); shelf[k].fresh = true; shelf[k].made = Date()
                } else if let it = Shelf.keep(title: h2.title, body: body, from: "\(h2.title) helper") {
                    var it = it; it.detail = Helpers.summary(log[0], 60)
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(it, at: 0) }
                    update(id) { $0.shelfID = it.id }
                }
            }
        }
        if away, let h = helpers.first(where: { $0.id == id }) {
            Floater.shared.note(h.state == "needsYes" ? "\(h.title) needs your yes." : "\(h.title) is done.")
        }
    }

    func sharedNote() -> String { let n = Shared.note(clashes: clashes); clashes = []; return n + Model.githubNote }
    /// If they're signed in to GitHub on this Mac, say so every turn so the assistant never claims it can't.
    static var githubNote: String {
        let h = NSHomeDirectory()
        guard let hosts = try? String(contentsOfFile: "\(h)/.config/gh/hosts.yml", encoding: .utf8), hosts.contains("github.com"),
              let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return "" }
        return "\n\n(One app note, not from the user: GITHUB IS CONNECTED. They're signed in on this Mac; use \(gh) (gh repo list, gh repo clone, gh api) and git directly, including private repos. Clone into \(Env.support.path)/work or the brain. Repos with rooms often link each room as a separate repo (git submodules): clone with --recurse-submodules or clone the room's own repo. Never tell them GitHub can't be connected or ask them to download zips.)"
    }

    /// Extra guidance when they talk about rooms or start the welcome interview (not shown to them).
    func roomNotes(_ text: String) -> String {
        let t = text.lowercased()
        var out = ""
        if t.contains("room") {
            out += "\n\n(One app note, not from the user: ROOMS. A room is one part of their life where you act differently and keep its notes apart. A new room is only for different rules, not a new topic. To add one, follow the brain's skills/add-room/SKILL.md, but local only: no GitHub, git or keys; the One app handles backup. First say in one plain line what a room is. Then ask these one per message, each ending with a [choices: ...] line: 1) what you should be for them in this room, 2) who might ever see it, 3) how private it is, 4) what you should push them toward. Then show the room in a short summary: its name, your job there, who might see it, how private it is, what you push toward, and the rules (on your own: read and draft; needs their yes: send, spend, delete; only them: change these rules), ending with [choices: Make the room | Change something]. Build nothing before 'Make the room'. If it's only a topic, say which room and folder it fits in instead. After making it, offer a short get-to-know-you for that room, run from its skills/setup/SKILL.md, with Skip and That's enough for now on every question.)"
        }
        if t.contains("welcome interview") || t.contains("get to know me") {
            out += "\n\n(One app note, not from the user: WELCOME INTERVIEW. Run the personal room's setup (\(Brain.root.path)/personal-room/skills/setup/SKILL.md) as a friendly get-to-know-you interview. Start with what makes the room's purpose clear: what you should be for them in this room, and what you should push them toward. Then its setup questions. One question per message. End every question with a [choices: ...] line whose last two answers are exactly Skip | That's enough for now. Write each answer into the room as it comes. On 'That's enough for now', thank them, say in one line what you saved, and that they can say 'get to know me' any time to continue.)"
        }
        return out
    }

    /// What Nova should know about her helpers: who's still working, and full results she hasn't seen yet.
    func helperNews() -> String {
        guard !helpers.isEmpty else { return "" }
        var lines: [String] = []
        for k in helpers.indices {
            let h = helpers[k]
            switch h.state {
            case "working": lines.append("- \(h.title): still working (\(h.line)).")
            case "stopped": lines.append("- \(h.title): paused, not finished.")
            default:
                let what = h.state == "needsYes" ? "is waiting for the user's yes" : "is DONE"
                if h.toldNova == true {
                    lines.append("- \(h.title): \(what) (you were already given its result).")
                } else {
                    var r = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.count > 2500 { r = String(r.prefix(2500)) + "…" }
                    lines.append("- \(h.title): \(what). Its result:\n\(r.isEmpty ? "(no text)" : r)")
                    helpers[k].toldNova = true
                }
            }
        }
        return "\n\n(One app note, not from the user: status of your helpers right now. Trust this over anything said earlier.\n" + lines.joined(separator: "\n") + ")"
    }

    /// Turn what you typed/said plus any pictures and files into (what you see, what the engine gets, images).
    private func compose(_ text: String) -> (display: String, engine: String, images: [String])? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = about
        guard !(t.isEmpty && pictures.isEmpty && files.isEmpty && ref == nil) else { return nil }
        about = nil
        if t.isEmpty, let ref { t = "Tell me what's in \"\(ref.title)\" in a few lines, then ask what I'd like to do with it." }
        let pics = pictures; pictures = []
        let docs = files; files = []
        if t.isEmpty {
            t = docs.isEmpty ? (pics.count == 1 ? "What's in this picture?" : "What's in these pictures?")
                             : (pics.count + docs.count == 1 ? "Have a look at this and tell me what it is." : "Have a look at these and tell me what they are.")
        }
        var tags: [String] = []
        if let ref { tags.append("📄 " + ref.title) }
        if !pics.isEmpty { tags.append("🖼 " + (pics.count == 1 ? "1 picture" : "\(pics.count) pictures")) }
        tags += docs.map { "📄 " + $0.name }
        var forEngine = t
        if let ref { forEngine += "\n\n(This is about \"\(ref.title)\". Read it first: \(ref.url.path))" }
        if !docs.isEmpty {
            forEngine += "\n\n(I'm sharing these files. Copies are saved here and you can open them:"
            for d in docs {
                forEngine += "\n- \(d.copy.path)"
                if let tx = d.textCopy { forEngine += " (plain-text version: \(tx.path))" }
            }
            forEngine += ")"
        }
        return (tags.isEmpty ? t : tags.joined(separator: "  ") + "\n" + t, forEngine, pics.map { $0.data.base64EncodedString() })
    }

    /// toNova: the floating orb always talks to Nova, never to an open helper.
    func send(_ text: String, toNova: Bool = false) async {
        if !toNova, let hid = openHelper, let h = openedHelper {
            guard !paused, h.state != "working", let c = compose(text) else { return }
            await ensureEngine()
            update(hid) { $0.asked = c.display }
            await runHelper(hid, c.engine, images: c.images)
            return
        }
        guard !paused, !thinking, let c = compose(text) else { return }
        await ensureEngine()
        me(c.display)
        bubbles.append(Bubble(fromMe: false, text: ""))
        let idx = bubbles.count - 1
        thinking = true; working = nil
        let voiceFirst = Speaker.shared.ready && !UserDefaults.standard.bool(forKey: "voiceMuted")
        heldText = ""
        Engine.shared.onText = { s in Task { @MainActor in
            if voiceFirst { self.heldText += s } else if idx < self.bubbles.count { self.bubbles[idx].text += s }
        } }
        Engine.shared.onTool = { s in Task { @MainActor in self.working = Plain.step(s) } }
        Engine.shared.onPermission = { q, opts, answer in
            Task { @MainActor in self.asks.append(Ask(question: q, options: opts, answer: answer)) }
        }
        // Older conversations started before helpers existed, so remind Nova every turn (not shown to the user).
        let note = "\n\n(One app note, not from the user: if this asks for a separate job that takes a while or keeps watching something, don't do it here. Say in one short line that you're sending a helper, then add a line [helper: Short title | the whole job with every detail]. Quick things you just answer. Any file you make for them (PDF, document, spreadsheet, picture) goes in \(Shelf.folder.path); the app puts it in front of them under Ready for you, so just say it's there, without the folder path.)"
        let stop = await Engine.shared.prompt(c.engine + note + roomNotes(c.engine) + sharedNote() + helperNews(), images: c.images)
        try? await Task.sleep(for: .milliseconds(150))
        var full = voiceFirst ? heldText : (idx < bubbles.count ? bubbles[idx].text : "")
        heldText = ""
        let (clean, jobs) = Helpers.extract(full)
        if !jobs.isEmpty { full = clean; for j in jobs { spawnHelper(title: j.0, task: j.1) } }
        if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            full = stop.hasPrefix("error") ? "I couldn't do that (\(stop.dropFirst(7))). Try again?" : "Done."
        }
        if voiceFirst && !stop.hasPrefix("error") && !paused {
            // Voice first: the words appear just after she starts talking (or after 6s if the voice stalls).
            revealCount += 1; let tk = revealCount
            pendingReveal = (idx, full, tk)
            Speaker.shared.read(full) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Task { @MainActor in self?.reveal(tk) } }
            }
            Task { try? await Task.sleep(for: .seconds(6)); reveal(tk) }
        } else {
            if idx < bubbles.count { bubbles[idx].text = full }
            thinking = false; working = nil
            saveBubbles()
            if !voiceFirst, !stop.hasPrefix("error"), !paused { Speaker.shared.read(full) }
        }
    }

    var heldText = ""
    private var pendingReveal: (idx: Int, text: String, token: Int)?
    private var revealCount = 0
    func reveal(_ token: Int? = nil) {
        guard let p = pendingReveal, token == nil || p.token == token else { return }
        pendingReveal = nil
        if p.idx < bubbles.count { bubbles[p.idx].text = p.text }
        thinking = false; working = nil
        saveBubbles()
    }

    func answer(_ a: Ask, _ choice: String?) { a.answer(choice); asks.removeAll { $0.id == a.id } }

    func toggleStop() {
        paused.toggle()
        if paused { helpers.filter { $0.state == "working" }.compactMap(\.sid).forEach { Engine.shared.cancel(session: $0) } }
        if paused { Speaker.shared.stop(); reveal() }
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
            .lineLimit(3).multilineTextAlignment(.leading)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(WorldLook.cream.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: 0x1E1E22, 0.92)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .frame(maxWidth: 250, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
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



// MARK: - Pictures (drag, paste, pick, or drop on the orb)

struct Picture: Identifiable {
    let id = UUID()
    let name: String
    let data: Data          // JPEG, at most 1600px on the long side
    let thumb: NSImage

    static func from(url: URL) -> Picture? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return from(image: img, name: url.lastPathComponent)
    }
    static func from(image: NSImage, name: String = "Picture") -> Picture? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), k = min(1, 1600 / max(w, h))
        let nw = max(1, Int(w * k)), nh = max(1, Int(h * k))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage(),
              let jpg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return Picture(name: name, data: jpg, thumb: NSImage(cgImage: out, size: NSSize(width: nw, height: nh)))
    }
    /// Pictures from the clipboard (a copied screenshot or image, or copied image files).
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Picture] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
            return urls.compactMap { from(url: $0) }
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] { return imgs.compactMap { from(image: $0) } }
        return []
    }
}


/// A file you hand to the assistant. It's copied into One's own folder so the assistant can open it
/// without being given access to the folder it came from. PDFs also get a plain-text copy.
struct SharedFile: Identifiable {
    let id = UUID()
    let name: String
    let copy: URL
    let textCopy: URL?
    static let maxBytes = 200 * 1024 * 1024

    static func from(url: URL) -> SharedFile? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes { return nil }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let dir = Env.support.appendingPathComponent("Shared with me/\(day)/\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        var txt: URL? = nil
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: dest), let text = doc.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let t = dest.appendingPathExtension("txt")
            if (try? text.write(to: t, atomically: true, encoding: .utf8)) != nil { txt = t }
        }
        return SharedFile(name: url.lastPathComponent, copy: dest, textCopy: txt)
    }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: copy.path) }
}

@MainActor enum PictureIn {
    static func add(_ p: [Picture]) {
        guard !p.isEmpty else { return }
        Model.shared.pictures.append(contentsOf: p.prefix(max(0, 6 - Model.shared.pictures.count)))
    }
    static func addFiles(_ f: [SharedFile]) {
        guard !f.isEmpty else { return }
        Model.shared.files.append(contentsOf: f.prefix(max(0, 10 - Model.shared.files.count)))
    }
    static func isImage(_ u: URL) -> Bool { (UTType(filenameExtension: u.pathExtension)?.conforms(to: .image)) ?? false }
    /// Pictures go in as pictures; everything else goes in as a file.
    static func addURLs(_ urls: [URL]) -> Int {
        let pics = urls.filter(isImage).compactMap { Picture.from(url: $0) }
        let files = urls.filter { !isImage($0) }.compactMap { SharedFile.from(url: $0) }
        add(pics); addFiles(files)
        let skipped = urls.count - pics.count - files.count
        if skipped > 0 { Floater.shared.note("I can take files, not folders, and nothing over 200 MB.") }
        return pics.count + files.count
    }
    static func pick() {
        let o = NSOpenPanel()
        o.allowsMultipleSelection = true; o.canChooseDirectories = false
        o.message = "Pick pictures or files to give your assistant"
        if o.runModal() == .OK { _ = addURLs(o.urls) }
    }
    static func drop(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for pr in providers {
            if pr.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                any = true
                _ = pr.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    DispatchQueue.main.async { _ = addURLs([u]) }
                }
            } else if pr.canLoadObject(ofClass: NSImage.self) {
                any = true
                _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let pic = Picture.from(image: img) else { return }
                    DispatchQueue.main.async { add([pic]) }
                }
            }
        }
        return any
    }
    /// ⌘V with a picture on the clipboard attaches it (text pastes stay normal).
    static func installPaste() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v",
                  Model.shared.onboarded else { return e }
            let pb = NSPasteboard.general
            let hasText = pb.string(forType: .string) != nil && pb.availableType(from: [.png, .tiff, .fileURL]) == nil
            if hasText { return e }
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                return addURLs(urls) > 0 ? nil : e
            }
            let pics = Picture.fromPasteboard(pb)
            if pics.isEmpty { return e }
            add(pics); return nil
        }
    }
}

struct PictureStrip: View {
    @ObservedObject var m: Model
    var body: some View {
        if !m.pictures.isEmpty || !m.files.isEmpty || m.about != nil {
            HStack(spacing: 8) {
                if let a = m.about {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Asking about").font(.caption2).foregroundStyle(.secondary)
                            Text(a.title).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                        }
                        Button { m.about = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove")
                    }
                    .padding(.horizontal, 10).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                }
                ForEach(m.files) { f in
                    HStack(spacing: 6) {
                        Image(nsImage: f.icon).resizable().frame(width: 26, height: 26)
                        Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .leading)
                        Button { m.files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove")
                    }
                    .padding(.horizontal, 10).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                }
                ForEach(m.pictures) { p in
                    Image(nsImage: p.thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                        .overlay(alignment: .topTrailing) {
                            Button { m.pictures.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }.buttonStyle(.plain).offset(x: 6, y: -6).help("Remove")
                        }
                }
                Spacer()
            }.padding(.horizontal, 6)
        }
    }
}

// MARK: - Push-to-talk key (any key combo or an extra mouse button, chosen by the user)

struct TalkKey: Codable, Equatable {
    var keyCode: UInt32? = nil     // keyboard
    var mods: UInt32 = 0           // Carbon modifier mask
    var mouse: Int? = nil          // extra mouse button number (2 = middle, 3/4 = side)
    var label: String
    static let standard = TalkKey(keyCode: UInt32(kVK_Space), mods: UInt32(optionKey), label: "⌥ Space")
    static var current: TalkKey? {
        get {
            let d = UserDefaults.standard
            if d.bool(forKey: "talkKeyOff") { return nil }
            guard let raw = d.data(forKey: "talkKey"), let k = try? JSONDecoder().decode(TalkKey.self, from: raw) else { return .standard }
            return k
        }
        set {
            let d = UserDefaults.standard
            if let k = newValue { d.set(false, forKey: "talkKeyOff"); d.set(try? JSONEncoder().encode(k), forKey: "talkKey") }
            else { d.set(true, forKey: "talkKeyOff") }
        }
    }
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
    static func name(_ e: NSEvent) -> String {
        let f = e.modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }; if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }; if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            123: "←", 124: "→", 125: "↓", 126: "↑"]
        let k = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return s.isEmpty ? k : s + " " + k
    }
    static func isFunctionKey(_ code: UInt16) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80].contains(code)
    }
}

/// Listens for the chosen key or mouse button anywhere on the Mac. Holding it = holding the orb.
@MainActor final class TalkKeys {
    static let shared = TalkKeys()
    private var hotRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var mouseMonitors: [Any] = []
    private var down = false
    var paused = false   // while choosing a new key

    func apply() {
        if let r = hotRef { UnregisterEventHotKey(r); hotRef = nil }
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }; mouseMonitors = []
        guard let k = TalkKey.current else { return }
        if let code = k.keyCode {
            if !handlerInstalled {
                handlerInstalled = true
                var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                             EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
                InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                    let pressed = GetEventKind(ev) == UInt32(kEventHotKeyPressed)
                    DispatchQueue.main.async { pressed ? TalkKeys.shared.press() : TalkKeys.shared.release() }
                    return noErr
                }, 2, &types, nil, nil)
            }
            RegisterEventHotKey(code, k.mods, EventHotKeyID(signature: OSType(0x4F4E4554), id: 1), GetApplicationEventTarget(), 0, &hotRef)
        } else if let b = k.mouse {
            let handle: (NSEvent) -> Void = { e in
                guard e.buttonNumber == b else { return }
                e.type == .otherMouseDown ? TalkKeys.shared.press() : TalkKeys.shared.release()
            }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp], handler: handle) { mouseMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp], handler: { e in handle(e); return e }) { mouseMonitors.append(l) }
        }
    }
    func press() { guard !paused, !down else { return }; down = true; Floater.shared.keyTalkBegin() }
    func release() { guard down else { return }; down = false; Floater.shared.keyTalkEnd() }
}

struct TalkKeySheet: View {
    var done: () -> Void
    @State var key: TalkKey? = TalkKey.current
    @State var recording = false
    @State var warn: String?
    @State var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push to talk").font(.title2.weight(.semibold))
            Text("Hold this key or button anywhere on your Mac, talk, then let go to send.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(recording ? "Press a key or a mouse button…" : (key?.label ?? "Off"))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(minWidth: 220, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(recording ? 0.14 : 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(recording ? 0.4 : 0.12)))
                Button(recording ? "Cancel" : "Change") { recording ? stop() : record() }
            }
            if let warn { Text(warn).foregroundStyle(.orange).font(.callout) }
            Text("Good choices: a key like F5, a combo like ⌥ Space, or a side button on your mouse.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Turn off") { stop(); key = nil; TalkKey.current = nil; TalkKeys.shared.apply() }
                Button("Use ⌥ Space") { stop(); key = .standard; TalkKey.current = .standard; TalkKeys.shared.apply() }
                Spacer()
                Button("Done") { stop(); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 470)
        .onDisappear { stop() }
    }
    func record() {
        warn = nil; recording = true; TalkKeys.shared.paused = true
        if let r = TalkKey.current, r.keyCode != nil { TalkKey.current = nil; TalkKeys.shared.apply(); TalkKey.current = r }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { e in
            if e.type == .otherMouseDown {
                let n = e.buttonNumber
                save(TalkKey(mouse: n, label: n == 2 ? "Middle mouse button" : "Mouse button \(n + 1)")); return nil
            }
            if e.keyCode == 53 { stop(); return nil }   // Esc cancels
            let mods = TalkKey.carbonMods(e.modifierFlags)
            if mods == 0 && !TalkKey.isFunctionKey(e.keyCode) {
                warn = "That key is used for typing. Add ⌥, ⌃ or ⌘, or use an F key."; return nil
            }
            save(TalkKey(keyCode: UInt32(e.keyCode), mods: mods, label: TalkKey.name(e))); return nil
        }
    }
    func save(_ k: TalkKey) { key = k; TalkKey.current = k; stop() }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false; TalkKeys.shared.paused = false; TalkKeys.shared.apply()
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
        FloatingOrb(state: l.listening ? .listening : (m.thinking || m.helpers.contains { $0.state == "working" } ? .working : .idle), size: 72)
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
    override func viewDidMoveToWindow() { registerForDraggedTypes([.fileURL, .png, .tiff]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let pb = s.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return MainActor.assumeIsolated { let n = PictureIn.addURLs(urls); if n > 0 { Floater.shared.gotPictures(n) }; return n > 0 }
        }
        let pics = Picture.fromPasteboard(pb)
        guard !pics.isEmpty else { return false }
        MainActor.assumeIsolated { PictureIn.add(pics); Floater.shared.gotPictures(pics.count) }
        return true
    }
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
        // Stage Manager turns the yellow button into "move to the side strip", which still counts as visible.
        // So: whenever you're in another app, the orb is there; come back to One and it goes away.
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.show() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in if !(self.mainWindow?.isMiniaturized ?? false) && !Listener.shared.listening && !self.keyTalk { self.hide() } }
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
        // .auxiliary + .canJoinAllApplications: Stage Manager leaves the orb on screen instead of tucking it into One's stage.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .auxiliary, .canJoinAllApplications]
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

    private var keyTalk = false
    /// Push-to-talk key held: show the orb (even over One) and listen.
    private var keyInApp = false
    func keyTalkBegin() {
        if NSApp.isActive, let w = mainWindow, w.isVisible, !w.isMiniaturized {
            keyInApp = true; Model.shared.talkBegin(); return
        }
        keyInApp = false
        build(); placeCard()
        orb?.orderFrontRegardless(); card?.orderFrontRegardless()
        keyTalk = true
        beginTalk()
    }
    func keyTalkEnd() {
        if keyInApp { keyInApp = false; Model.shared.talkEnd(); return }
        Listener.shared.finish { heard in
            guard !heard.isEmpty else {
                if Listener.shared.problem == nil { self.note("I didn't catch that. Hold the key and talk, then let go.") }
                self.tuckIfOneInFront(after: 4); return
            }
            Task { @MainActor in
                await Model.shared.send(heard, toNova: true)
                if NSApp.isActive { self.tuckIfOneInFront(after: 0) } else { self.showReply() }
            }
        }
    }
    private func tuckIfOneInFront(after s: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            if NSApp.isActive && !Listener.shared.listening && !Model.shared.thinking { self.keyTalk = false; self.hide() }
        }
    }
    func gotPictures(_ n: Int) {
        note(n == 1 ? "Got it. Hold me and say what to do with it." : "Got all \(n). Hold me and say what to do with them.")
    }

    func endTalk() {
        Listener.shared.finish { heard in
            guard !heard.isEmpty else {
                if Listener.shared.problem == nil { self.note("I didn't catch that. Hold the orb and talk, then let go.") }
                return
            }
            Task { @MainActor in
                await Model.shared.send(heard, toNova: true)
                self.showReply()
            }
        }
    }

    func note(_ s: String) {
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




/// Turns the engine's technical step titles ("browser_exec: import time…") into plain words.
enum Plain {
    static func step(_ title: String) -> String {
        let parts = title.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let tool = parts.first ?? "", arg = parts.count > 1 ? parts[1] : ""
        func file() -> String {
            let a = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            let n = (a.components(separatedBy: " ").first ?? a).split(separator: "/").last.map(String.init) ?? ""
            return n.isEmpty ? "a file" : n
        }
        func cut(_ x: String, _ n: Int = 60) -> String { x.count > n ? String(x.prefix(n - 1)) + "…" : x }
        // Browser steps start with a one-line comment that says what they do.
        if let c = arg.range(of: "# ") {
            let line = arg[c.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            let clean = line.components(separatedBy: CharacterSet(charactersIn: "#;")).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if clean.count > 3, tool.hasPrefix("browser") { return cut(clean) + "…" }
        }
        switch tool {
        case let t where t.hasPrefix("browser"): return "Using the browser…"
        case "web_search": return arg.isEmpty ? "Searching the web…" : "Searching the web for “\(cut(arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), 40))”…"
        case "web_extract": return "Reading a web page…"
        case "read_file": return "Reading \(cut(file(), 40))…"
        case "write_file", "patch": return "Saving \(cut(file(), 40))…"
        case "search_files": return "Looking through your files…"
        case "vision_analyze": return "Looking at the picture…"
        case "session_search": return "Remembering what we talked about…"
        case "terminal", "execute_code": return "Working on your Mac…"
        case "manage_connections": return "Checking your connections…"
        case "text_to_speech": return "Getting my voice ready…"
        case "todo", "todo_list": return "Planning the steps…"
        default: return "Working on it…"
        }
    }
}

// MARK: - Helpers: Nova sends out a helper for each separate job; each is its own engine session.

struct Helper: Identifiable, Codable {
    var id = UUID()
    var title: String
    var task: String
    var sid: String?
    var state: String            // working, needsYes, done, stopped
    var line: String
    var reply: String = ""
    var asked: String?
    var finishedAway = false
    var toldNova: Bool?          // has Nova been given this result yet?
    var log: [String]?           // everything this helper reported, oldest first (kept for its file)
    var shelfID: UUID?           // its card on the Ready for you shelf
    var viewState: HelperState {
        switch state { case "working": .working; case "needsYes": .needsYes; case "stopped": .stopped; default: .done }
    }
}

enum Helpers {
    /// Pull "[helper: Title | job]" lines out of Nova's reply.
    static func extract(_ text: String) -> (String, [(String, String)]) {
        var jobs: [(String, String)] = [], keep: [String] = []
        for l in text.components(separatedBy: "\n") {
            let tl = l.trimmingCharacters(in: .whitespaces)
            if tl.lowercased().hasPrefix("[helper:"), tl.hasSuffix("]") {
                let parts = tl.dropFirst(8).dropLast().split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { jobs.append((parts[0], parts[1])) }
            } else { keep.append(l) }
        }
        while let last = keep.last, last.trimmingCharacters(in: .whitespaces).isEmpty { keep.removeLast() }
        return (keep.joined(separator: "\n"), jobs)
    }
    /// Hide helper lines while a reply is still streaming in.
    static func strip(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[helper") }.joined(separator: "\n")
    }
    static func short(_ s: String, _ n: Int = 34) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
    static func summary(_ body: String, _ n: Int = 40) -> String {
        var t = body
        for mark in ["**", "__", "`", "#", "> "] { t = t.replacingOccurrences(of: mark, with: "") }
        let first = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Done"
        return short(first, n)
    }
    static func brief(assistant: String, user: String, task: String) -> String {
        """
        You're one of \(assistant.isEmpty ? "the assistant" : assistant)'s helpers, sent to do one job in the background while \(user.isEmpty ? "they" : user) keep talking to \(assistant.isEmpty ? "the assistant" : assistant). Don't send helpers yourself; do the job.

        The job: \(task)

        Do it now. Finish with a short message (2 to 4 lines): what you found or did, in plain words. If you need their yes before going further (money, sending, posting, deleting), stop and ask, ending with a [choices: ...] line. If the job is to keep watching something, do the first check now, say what you found, and say how you'll keep watching.
        """
    }
}

struct NovaWithHelpers: View {
    @ObservedObject var m: Model
    static let slots: [CGPoint] = [CGPoint(x: -168, y: -34), CGPoint(x: 168, y: -34), CGPoint(x: -150, y: 76), CGPoint(x: 150, y: 76)]
    var body: some View {
        let shown = Array(m.helpers.prefix(4).enumerated())
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: m.helpers.isEmpty)) { tl in
            let t = tl.date.timeIntervalSince(WorldLook.start)
            ZStack {
                Orb(size: 92, active: m.thinking).opacity(m.openHelper == nil ? 1 : 0.5)
                    .contentShape(Circle())
                    .onTapGesture { if m.openHelper != nil { withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil } } }
                    .help(m.openHelper == nil ? "" : "Back to \(m.name)")
                    .onHover { inside in if m.openHelper != nil { inside ? NSCursor.pointingHand.push() : NSCursor.pop() } }
                ForEach(shown, id: \.element.id) { i, h in
                    let p = Self.slots[i]
                    Button { m.focusHelper(h.id) } label: {
                        VStack(spacing: -10) {
                            HelperOrb(state: h.viewState, t: t + Double(i) * 3.1, size: 42)
                            HelperLabel(title: Helpers.short(h.title, 24), line: Helpers.short(h.line, 32), warm: h.state == "needsYes")
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(h.state == "working" ? h.line : "Tap to see this job")
                    .offset(x: p.x + sin(t * 0.4 + Double(i) * 1.7) * 4, y: p.y + sin(t * 0.55 + Double(i) * 2.3) * 5)
                    .opacity(m.openHelper == nil || m.openHelper == h.id ? 1 : 0.5)
                    .transition(.asymmetric(insertion: .scale(scale: 0.2).combined(with: .opacity),
                                            removal: .offset(x: -p.x, y: -p.y).combined(with: .scale(scale: 0.1)).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity).frame(height: m.helpers.isEmpty ? 150 : 250)
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: m.helpers.map(\.id))
    }
}

struct HelperCard: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        let parts = Choices.split(h.reply)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(h.title).font(.headline)
                Text("· " + (h.state == "working" ? "working" : h.state == "needsYes" ? "needs your yes" : h.state == "stopped" ? "paused" : "done"))
                    .foregroundStyle(h.state == "needsYes" ? Color.orange : Color.secondary)
                Spacer()
                Button { m.openHelper = nil } label: { Label(m.name, systemImage: "chevron.left") }
                    .buttonStyle(.bordered).controlSize(.small).help("Back to \(m.name)")
            }
            if let a = h.asked, !a.isEmpty { Text(a).font(.callout).foregroundStyle(Color.accentColor) }
            if h.reply.isEmpty {
                Text(h.state == "working" ? h.line : "Nothing yet.").foregroundStyle(.secondary)
            } else {
                MarkdownText(text: parts.body, size: 15).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !parts.choices.isEmpty && h.state != "working" {
                ChoiceRow(choices: parts.choices, disabled: m.paused) { c in Task { await m.send(c) } } onOther: {}
            }
            if h.state == "done" || h.state == "stopped" {
                HStack {
                    Spacer()
                    Button("Got it") { m.dismissHelper(h.id) }.buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xF0A04B, h.state == "needsYes" ? 0.55 : 0), lineWidth: 1.2))
    }
}

struct AwayCard: View {
    @ObservedObject var m: Model
    let hs: [Helper]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHILE YOU WERE GONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(hs) { h in
                Button { m.focusHelper(h.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: h.state == "needsYes" ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(h.state == "needsYes" ? Color.orange : Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title).font(.callout.weight(.semibold))
                            Text(h.state == "needsYes" ? "Needs your yes. Tap to answer." : Helpers.summary(Choices.split(h.reply).body, 140))
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Got it") { m.clearAway() } }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
    }
}



// MARK: - Ready for you: what Nova and her helpers made, kept on a shelf and saved as real files.

struct ShelfItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var from: String
    var path: String
    var made = Date()
    var fresh = true
    var url: URL { URL(fileURLWithPath: path) }
    var icon: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "csv", "xlsx", "numbers": return "tablecells"
        case "docx", "doc", "pages", "rtf": return "doc.text"
        default: break
        }
        let t = (title + " " + detail).lowercased()
        if t.contains("flight") || t.contains("trip") || t.contains("hotel") { return "airplane" }
        if t.contains("receipt") || t.contains("$") || t.contains("budget") { return "receipt" }
        if t.contains("email") || t.contains("reply") || t.contains("draft") { return "envelope" }
        if t.contains("folder") || t.contains("download") || t.contains("files") { return "folder" }
        return "doc.text"
    }
    var when: String {
        let c = Calendar.current
        if Date().timeIntervalSince(made) < 120 { return "just now" }
        let f = DateFormatter()
        f.dateFormat = c.isDateInToday(made) ? "h:mm a" : (c.isDateInYesterday(made) ? "'yesterday'" : "EEE")
        return f.string(from: made)
    }
}

enum Shelf {
    static var who: String { let n = UserDefaults.standard.string(forKey: "assistantName") ?? ""; return n.isEmpty ? "your assistant" : n }
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Env.selfTest ? Env.support.appendingPathComponent("selftest-made") : docs.appendingPathComponent("Made by \(Shelf.who)")
    }
    static func load() -> [ShelfItem] {
        guard let d = UserDefaults.standard.data(forKey: "shelf"), var v = try? JSONDecoder().decode([ShelfItem].self, from: d) else { return [] }
        // The assistant was renamed: move results from the old "Made by …" folder into the new one.
        let fm = FileManager.default
        for k in v.indices where !v[k].path.hasPrefix(folder.path + "/") {
            let old = URL(fileURLWithPath: v[k].path)
            guard fm.fileExists(atPath: old.path), old.deletingLastPathComponent().lastPathComponent.hasPrefix("Made by ") else { continue }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(old.lastPathComponent)
            if (try? fm.moveItem(at: old, to: dest)) != nil {
                v[k].path = dest.path
                let dir = old.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0 != ".DS_Store" }.isEmpty) == true { try? fm.removeItem(at: dir) }
            }
        }
        let kept = v.filter { FileManager.default.fileExists(atPath: $0.path) }
        save(kept)
        return kept
    }
    static func save(_ v: [ShelfItem]) { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: "shelf") }
    /// Save a finished result as a file in Documents › Made by Nova.
    /// Files the assistant made directly (PDFs, documents…) that aren't on the shelf yet.
    static func adopt(_ have: [ShelfItem]) -> [ShelfItem] {
        let fm = FileManager.default
        let known = Set(have.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "shelfHidden") ?? [])
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var out: [ShelfItem] = []
        for u in items {
            let path = u.standardizedFileURL.path
            guard !known.contains(path), !hidden.contains(path),
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !u.lastPathComponent.hasSuffix(".part"), !u.lastPathComponent.hasPrefix("~") else { continue }
            let made = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var title = u.deletingPathExtension().lastPathComponent
            if let r = title.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) { title.removeSubrange(r) }
            let kind = u.pathExtension.uppercased()
            out.append(ShelfItem(title: title, detail: kind.isEmpty ? "A file \(who) made" : "\(kind) · ready to share", from: who, path: path, made: made, fresh: true))
        }
        return out.sorted { $0.made > $1.made }
    }
    static func keep(title: String, body: String, from: String) -> ShelfItem? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(f.string(from: Date())) \(safe).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(f.string(from: Date())) \(safe) \(n).md"); n += 1 }
        let text = "# \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n— \(from), \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return ShelfItem(title: title, detail: Helpers.summary(body, 60), from: from, path: url.path)
    }
}

struct ShelfCardView: View {
    let item: ShelfItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(Color(hex: 0xFFE2C2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("\(item.from) · \(item.when)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if item.fresh { Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 6, height: 6).padding(.top, 4) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(item.fresh ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, item.fresh ? 0.22 : 0.07)))
        .shadow(color: Color(hex: 0xFFE2C2, item.fresh ? 0.12 : 0), radius: 10)
        .contentShape(Rectangle())
    }
}

struct ShelfPanel: View {
    @ObservedObject var m: Model
    var body: some View {
        let fresh = m.shelf.filter(\.fresh).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ready for you").font(.system(size: 13, weight: .semibold))
                if fresh > 0 {
                    Text("\(fresh) new").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color(hex: 0x141416))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFFE2C2)))
                }
                Spacer()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(m.shelf) { it in
                        ShelfCardView(item: it)
                            .onTapGesture { m.openShelf(it.id) }
                            .onDrag { NSItemProvider(contentsOf: it.url) ?? NSItemProvider() }
                            .help("Click to open. Drag into Mail or Messages to share.")
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                                Button("Take off the shelf (the file stays)") { m.removeShelf(it.id) }
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            Button { NSWorkspace.shared.open(Shelf.folder) } label: {
                HStack(spacing: 5) { Image(systemName: "folder").font(.system(size: 10)); Text("All saved in Documents › Made by \(Shelf.who)").font(.system(size: 10.5)) }
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.07)))
        .padding(.vertical, 14).padding(.trailing, 14)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: m.shelf.map(\.id))
    }
}


/// Any note or file the assistant links to opens here, inside One, instead of in another app.
struct FileViewer: View {
    @ObservedObject var m: Model
    let url: URL
    var body: some View {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "I couldn't open this file. It may have been moved or deleted."
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        var title = url.deletingPathExtension().lastPathComponent
        if let f = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[f].hasPrefix("# ") { title = String(lines[f].dropFirst(2)); lines.remove(at: f) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeometryReader { g in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.viewing = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xFFE2C2))
                        Text(title).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button { m.viewing = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Close")
                    }.padding(.horizontal, 22).padding(.vertical, 16)
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    ScrollView {
                        MarkdownText(text: text.isEmpty ? "Nothing written here yet." : text, size: 15).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 18)
                    }
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    HStack(spacing: 8) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.bordered)
                        Button { m.viewing = nil; m.openHelper = nil; m.about = (title, url); m.draftSeed = "" } label: { Label("Ask \(m.name) about it", systemImage: "bubble.left") }.buttonStyle(.bordered)
                        Spacer()
                    }.padding(.horizontal, 22).padding(.vertical, 14)
                }
                .frame(width: min(720, g.size.width - 60), height: max(320, g.size.height - 70))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x1E1E22, 0.99)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.14)))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            }
        }
    }
    static let readable: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml", "log"]
}

/// PDFs: Apple's own PDF reader, scrolls with the trackpad and mouse wheel.
struct PDFReader: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        v.displaysPageBreaks = true; v.backgroundColor = NSColor(white: 0.12, alpha: 1)
        v.document = PDFDocument(url: url); return v
    }
    func updateNSView(_ v: PDFView, context: Context) { if v.document?.documentURL != url { v.document = PDFDocument(url: url) } }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true; v.previewItem = url as NSURL; return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL } }
}

struct ShelfOpened: View {
    @ObservedObject var m: Model
    let item: ShelfItem
    var body: some View {
        let body = (try? String(contentsOf: item.url, encoding: .utf8)) ?? "This file was moved or deleted."
        let shown = body.components(separatedBy: "\n").drop { $0.hasPrefix("# ") || $0.isEmpty }.joined(separator: "\n")
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.openedShelf = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).foregroundStyle(Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 17, weight: .semibold))
                            Text("\(item.from) · \(item.when)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { m.openedShelf = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Close")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    if !FileViewer.readable.contains(item.url.pathExtension.lowercased()) {
                        Group {
                            if item.url.pathExtension.lowercased() == "pdf" { PDFReader(url: item.url) } else { QuickLookView(url: item.url) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                    ScrollView {
                        MarkdownText(text: shown, size: 15)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.vertical, 18)
                    }
                    }
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    HStack(spacing: 8) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                            .buttonStyle(.bordered)
                        Button { m.openedShelf = nil; m.openHelper = nil; m.about = (item.title, item.url); m.draftSeed = "" } label: { Label("Ask \(m.name) about it", systemImage: "bubble.left") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text("Drag the card into Mail or Messages to share it.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                }
                .frame(width: min(720, g.size.width - 60), height: max(320, g.size.height - 70))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x1E1E22, 0.99)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.14)))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            }
        }
    }
}





// MARK: - Updates: checks GitHub releases, downloads the new app, swaps it and reopens. Brain, rooms and settings live outside the app and are never touched.

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "Donnadieu/one"
    @Published var available: (version: String, notes: String, zip: URL)?
    @Published var state: String?   // "Downloading…", errors
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    func check() async {
        guard let u = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=10") else { return }
        var req = URLRequest(url: u); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        var best: (String, String, URL)?
        for r in list where (r["draft"] as? Bool) != true {
            let tag = ((r["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Updater.newer(tag, than: best?.0 ?? current),
                  let zip = (r["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == "One.zip" })?["browser_download_url"] as? String,
                  let zu = URL(string: zip) else { continue }
            best = (tag, (r["body"] as? String) ?? "", zu)
        }
        if let best, UserDefaults.standard.string(forKey: "updateSkipped") != best.0 || available == nil {
            available = (best.0, best.1, best.2)
        }
    }
    func loop() {
        Task { while true { await check(); try? await Task.sleep(for: .seconds(6 * 3600)) } }
    }
    /// Downloads, unpacks, then a tiny script waits for One to quit, swaps the app and reopens it.
    func install() async {
        guard let a = available else { return }
        let m = Model.shared
        if m.thinking || m.helpers.contains(where: { $0.state == "working" }) {
            state = "I'll update as soon as I finish what I'm doing."
            while m.thinking || m.helpers.contains(where: { $0.state == "working" }) { try? await Task.sleep(for: .seconds(5)) }
        }
        state = "Downloading the new version…"
        let dir = Env.support.appendingPathComponent("update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: a.zip), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            state = "The download didn't work. Check the internet and try again."; return
        }
        let zip = dir.appendingPathComponent("One.zip")
        try? FileManager.default.moveItem(at: tmp, to: zip)
        state = "Getting it ready…"
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, dir.path]
                try? p.run(); p.waitUntilExit(); c.resume(returning: p.terminationStatus == 0)
            }
        }
        let newApp = dir.appendingPathComponent("One.app")
        guard ok, FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/One").path) else {
            state = "The new version looked broken, so I kept this one. Try again later."; return
        }
        let target = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
        pkill -f "\(Env.engineDir.path)" 2>/dev/null; pkill -f "\(Env.support.path)/voice" 2>/dev/null
        xattr -dr com.apple.quarantine "\(newApp.path)" 2>/dev/null
        rm -rf "\(target).old" && mv "\(target)" "\(target).old" && mv "\(newApp.path)" "\(target)" && rm -rf "\(target).old" || { [ -d "\(target)" ] || mv "\(target).old" "\(target)"; }
        \(ProcessInfo.processInfo.environment["ONE_UPDATE_NO_REOPEN"] == "1" ? "echo done > \"\(dir.path)/swapped\"" : "open \"\(target)\"")
        """
        let sh = dir.appendingPathComponent("swap.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [sh.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { state = "I couldn't start the update."; return }
        state = "Restarting…"
        Engine.shared.stop()
        try? await Task.sleep(for: .milliseconds(400))
        NSApp.terminate(nil)
    }
    func later() { if let a = available { UserDefaults.standard.set(a.version, forKey: "updateSkipped") }; available = nil }
}

struct UpdateCard: View {
    @ObservedObject var u = Updater.shared
    var body: some View {
        if let a = u.available {
            VStack(alignment: .leading, spacing: 10) {
                Label("A new version of One is ready (\(a.version))", systemImage: "arrow.down.circle.fill").font(.headline)
                let notes = a.notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).joined(separator: "\n")
                if !notes.isEmpty { MarkdownText(text: notes, size: 13).foregroundStyle(.secondary) }
                Text("It only takes a moment. Your memory, rooms and settings stay exactly as they are.").font(.caption).foregroundStyle(.secondary)
                if let st = u.state { Text(st).font(.callout) }
                HStack(spacing: 8) {
                    Button("Update now") { Task { await u.install() } }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                        .disabled(u.state != nil && !(u.state ?? "").contains("try again") && !(u.state ?? "").contains("Try again") && !(u.state ?? "").contains("couldn't"))
                    Button("Later") { u.later() }.buttonStyle(.bordered)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Shared rooms: a room kept in iCloud Drive and shared through Apple's own Share menu.
// No accounts to make. Clashes are avoided by design: each person adds new entries, nobody rewrites
// someone else's; the summary is rebuilt from entries; real clashes are kept as copies and merged.

struct RoomError: Error { let text: String }
struct SharedRoomInfo: Codable { var title: String; var createdBy: String; var created: String; var members: [String] }

enum Shared {
    static var cloud: URL {
        if let t = ProcessInfo.processInfo.environment["ONE_CLOUD_DIR"] { return URL(fileURLWithPath: t, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var available: Bool { FileManager.default.fileExists(atPath: cloud.path) }
    static var base: URL { cloud.appendingPathComponent("One Rooms", isDirectory: true) }
    static var paths: [String] {
        get { (UserDefaults.standard.stringArray(forKey: "sharedRooms") ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "sharedRooms") }
    }
    static var me: String { let n = UserDefaults.standard.string(forKey: "userName") ?? ""; return n.isEmpty ? "Me" : n }
    static var ai: String { let n = UserDefaults.standard.string(forKey: "assistantName") ?? ""; return n.isEmpty ? "the assistant" : n }
    static func info(_ u: URL) -> SharedRoomInfo? {
        guard let d = try? Data(contentsOf: u.appendingPathComponent("one-room.json")) else { return nil }
        return try? JSONDecoder().decode(SharedRoomInfo.self, from: d)
    }
    static func writeInfo(_ i: SharedRoomInfo, _ u: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(i).write(to: u.appendingPathComponent("one-room.json"), options: .atomic)
    }
    static func others(_ i: SharedRoomInfo) -> [String] { i.members.filter { $0.lowercased() != me.lowercased() } }
    static func label(_ i: SharedRoomInfo) -> String {
        let o = others(i)
        return o.isEmpty ? "shared, waiting for someone to join" : "shared with " + o.joined(separator: ", ")
    }

    static let howItWorks = """
    # How this shared room works

    This room is shared between a few people through iCloud Drive. Each person has their own assistant (in the One app), and each assistant works only for its own person.

    ## So nobody overwrites anybody
    - Everything new goes in `entries/` as its own file, named `YYYY-MM-DD HHMM Name - short title.md` and starting with `By Name`.
    - Nobody edits or deletes an entry someone else wrote. To change your mind, add a new entry.
    - `summary.md` is rebuilt as a whole from the entries. Don't patch it by hand.
    - If two people change the same file at the same time, the app keeps both as `… (other version).md`. The assistant merges them and says so.

    ## Rules
    - Nothing from anyone's other rooms comes in here without that person's OK.
    - No assistant sends, spends or deletes anything on behalf of another member.
    - Changing these rules needs everyone in the room to agree.
    - Anyone can leave at any time and keep their own copy.
    """

    /// Makes a shared room (new, or by moving an existing local room into iCloud Drive). Returns its folder or an error.
    static func make(title: String, moving local: URL?) -> Result<URL, RoomError> {
        let fm = FileManager.default
        guard available else { return .failure(RoomError(text: "iCloud Drive is off on this Mac. Turn it on in System Settings › your name › iCloud › iCloud Drive.")) }
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty else { return .failure(RoomError(text: "The room needs a name.")) }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var dest = base.appendingPathComponent(safe, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = base.appendingPathComponent("\(safe) \(n)", isDirectory: true); n += 1 }
        do {
            if let local { try fm.moveItem(at: local, to: dest) } else { try fm.createDirectory(at: dest, withIntermediateDirectories: true) }
        } catch { return .failure(RoomError(text: "Couldn't make the room: \(error.localizedDescription)")) }
        let entries = dest.appendingPathComponent("entries", isDirectory: true)
        try? fm.createDirectory(at: entries, withIntermediateDirectories: true)
        try? howItWorks.write(to: dest.appendingPathComponent("HOW THIS ROOM WORKS.md"), atomically: true, encoding: .utf8)
        let sum = dest.appendingPathComponent("summary.md")
        if !fm.fileExists(atPath: sum.path) {
            try? "# \(title)\n\nWhat this room is about, rebuilt from the entries by the assistants.\n\n[nothing yet]\n".write(to: sum, atomically: true, encoding: .utf8)
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let first = "# Room opened\n\nBy \(me)\n\n\(me) opened this shared room\(local == nil ? "" : ", bringing in their notes from before").\n"
        try? first.write(to: entries.appendingPathComponent("\(f.string(from: Date())) \(me) - room opened.md"), atomically: true, encoding: .utf8)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        writeInfo(SharedRoomInfo(title: title, createdBy: me, created: day, members: [me]), dest)
        if let local { replaceRow(oldFolder: local.lastPathComponent, title: title, path: dest) } else { addRow(title: title, path: dest) }
        paths = paths + [dest.path]
        return .success(dest)
    }

    /// Adds someone else's room (accepted through iCloud) to this brain.
    static func join(_ u: URL) {
        guard var i = info(u) else { return }
        if !i.members.contains(where: { $0.lowercased() == me.lowercased() }) { i.members.append(me); writeInfo(i, u) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("entries"), withIntermediateDirectories: true)
        try? "# Joined\n\nBy \(me)\n\n\(me) joined the room.\n".write(to: u.appendingPathComponent("entries/\(f.string(from: Date())) \(me) - joined.md"), atomically: true, encoding: .utf8)
        addRow(title: i.title, path: u)
        paths = paths + [u.path]
    }
    static func leave(_ u: URL) {
        paths = paths.filter { $0 != u.path }
        var d = UserDefaults.standard.stringArray(forKey: "sharedDismissed") ?? []
        d.append(u.path); UserDefaults.standard.set(d, forKey: "sharedDismissed")
    }

    /// Rooms other people shared with this Mac's iCloud that aren't in the brain yet.
    static func invites() -> [URL] {
        guard available else { return [] }
        let fm = FileManager.default
        let known = Set(paths), dismissed = Set(UserDefaults.standard.stringArray(forKey: "sharedDismissed") ?? [])
        var out: [URL] = []
        for dir in [cloud, base] {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
                guard !known.contains(u.path), !dismissed.contains(u.path), let i = info(u) else { continue }
                if i.createdBy.lowercased() == me.lowercased() && i.members.count <= 1 { continue }
                out.append(u)
            }
        }
        return out
    }

    /// Keeps shared files downloaded and turns iCloud edit clashes into side-by-side copies. Returns new clash notes.
    static func tend() -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        for p in paths {
            let root = URL(fileURLWithPath: p)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en {
                let name = f.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = f.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    try? fm.startDownloadingUbiquitousItem(at: real)
                    continue
                }
                guard f.pathExtension == "md", let vs = NSFileVersion.unresolvedConflictVersionsOfItem(at: f), !vs.isEmpty else { continue }
                let stem = f.deletingPathExtension().lastPathComponent
                for (k, v) in vs.enumerated() {
                    let who = v.localizedNameOfSavingComputer ?? "another Mac"
                    let copy = f.deletingLastPathComponent().appendingPathComponent("\(stem) (other version\(vs.count > 1 ? " \(k + 1)" : "") from \(who)).md")
                    try? fm.copyItem(at: v.url, to: copy)
                    v.isResolved = true
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: f)
                notes.append(f.path)
            }
        }
        return notes
    }

    static func invite(_ u: URL) {
        guard let v = NSApp.keyWindow?.contentView else { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
        let picker = NSSharingServicePicker(items: [u])
        picker.show(relativeTo: NSRect(x: v.bounds.midX, y: 60, width: 1, height: 1), of: v, preferredEdge: .minY)
    }

    // The brain's table of rooms (AGENTS.md) gets a row pointing at the shared folder.
    static func addRow(title: String, path: URL) {
        let ag = Brain.root.appendingPathComponent("AGENTS.md")
        guard var t = try? String(contentsOf: ag, encoding: .utf8), !t.contains(path.path) else { return }
        let row = "| \(title) (shared) | `\(path.path)` | \(ai) | `summary.md` | what this room's members work on together; read its HOW THIS ROOM WORKS.md | anything from the other rooms without the owner's OK |\n"
        t = t.replacingOccurrences(of: "<!-- add-room adds one row per room above this line -->", with: row + "<!-- add-room adds one row per room above this line -->")
        try? t.write(to: ag, atomically: true, encoding: .utf8)
    }
    static func replaceRow(oldFolder: String, title: String, path: URL) {
        let ag = Brain.root.appendingPathComponent("AGENTS.md")
        guard var t = try? String(contentsOf: ag, encoding: .utf8) else { return }
        t = t.components(separatedBy: "\n").filter { !$0.contains("`\(oldFolder)/`") }.joined(separator: "\n")
        try? t.write(to: ag, atomically: true, encoding: .utf8)
        addRow(title: title, path: path)
    }

    /// What the assistant must know every turn about shared rooms (not shown to the user).
    static func note(clashes: [String]) -> String {
        let rooms = paths.compactMap { p -> String? in
            guard let i = info(URL(fileURLWithPath: p)) else { return nil }
            return "\"\(i.title)\" at \(p) (members: \(i.members.joined(separator: ", ")))"
        }
        guard !rooms.isEmpty else { return "" }
        var t = "\n\n(One app note, not from the user: SHARED ROOMS, kept in sync with other people through iCloud: \(rooms.joined(separator: "; ")). In a shared room: put each new thing in its own new file in entries/ named 'YYYY-MM-DD HHMM \(me) - short title.md' starting with 'By \(me)'. Never edit or delete a file someone else wrote. Rebuild summary.md as a whole after adding entries; never patch it. Nothing from \(me)'s other rooms goes in without \(me)'s OK. You work only for \(me): never act for the other members. When \(me) asks what's new, read the entries by others since last time.)"
        if !clashes.isEmpty {
            t += "\n\n(One app note: two people changed these at the same time; the other version sits next to each one as '… (other version …).md'. Merge each into the original, delete the copy, and tell \(me) in one line what you combined: \(clashes.joined(separator: "; ")).)"
        }
        return t
    }
}

// MARK: - Your rooms: a live map of the brain, one cluster per room, one dot per note.

struct RoomNote: Identifiable { let id: String; let title: String; let room: Int; let hub: Bool; var links: [String] }
struct RoomInfo: Identifiable { let id: String; let title: String; let color: Color; var notes: [RoomNote]; var crossed: [Int: Int]; var shared: String? = nil }
struct LaidNote { let n: RoomNote; let p: CGPoint; let r: CGFloat; let color: Color; let degree: Int }

enum RoomMap {
    static let palette: [UInt32] = [0xFFE2C2, 0x9FC9B0, 0xA9C1E8, 0xE6A9C4, 0xD8D08F, 0xC9B2E8]
    static let skipFiles: Set<String> = ["AGENTS.md", "CLAUDE.md", "GEMINI.md", "README.md", "UNLOCK-CHECK.md"]
    static let skipDirs: Set<String> = ["skills", "agents", "templates", "confidential", ".git", "node_modules"]
    static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]\|#]+)"#)
    static let mdLink = try! NSRegularExpression(pattern: #"\]\(([^)\s]+\.md)\)"#)

    static func roomFolders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Brain.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let rooms = items.filter { $0.lastPathComponent.hasSuffix("-room") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
        return rooms.sorted { a, b in
            if a.lastPathComponent == "personal-room" { return true }
            if b.lastPathComponent == "personal-room" { return false }
            return a.lastPathComponent < b.lastPathComponent
        } + Shared.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static func roomTitle(_ url: URL) -> String {
        if let i = Shared.info(url) { return i.title }
        return roomTitle(url.lastPathComponent)
    }
    static func roomTitle(_ folder: String) -> String {
        if let k = RoomKind.allCases.first(where: { $0.folder == folder }) { return k.title.prefix(1).uppercased() + k.title.dropFirst() }
        let base = folder.replacingOccurrences(of: "-room", with: "").replacingOccurrences(of: "-", with: " ")
        return base.prefix(1).uppercased() + base.dropFirst() + " room"
    }
    static func noteTitle(_ url: URL, _ text: String) -> String {
        for l in text.split(separator: "\n").prefix(20) where l.hasPrefix("# ") { return String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
    }
    static func matches(_ re: NSRegularExpression, _ t: String) -> [String] {
        re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range(at: 1), in: t).map { String(t[$0]) } }
    }
    static func load() -> [RoomInfo] {
        let fm = FileManager.default
        let folders = roomFolders()
        var out: [RoomInfo] = []
        var allTexts: [Int: [String]] = [:]
        for (ri, r) in folders.enumerated() {
            let folder = r.lastPathComponent
            let sharedInfo = Shared.info(r)
            let hubPath = sharedInfo != nil ? r.appendingPathComponent("summary.md").path : RoomKind.allCases.first { $0.folder == folder }.map { r.appendingPathComponent($0.hub).path }
            var notes: [RoomNote] = [], texts: [String: String] = [:]
            if let en = fm.enumerator(at: r, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let f as URL in en {
                    if skipDirs.contains(f.lastPathComponent) { en.skipDescendants(); continue }
                    guard notes.count < 200, f.pathExtension == "md", !skipFiles.contains(f.lastPathComponent),
                          let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
                    texts[f.path] = t
                    notes.append(RoomNote(id: f.path, title: noteTitle(f, t), room: ri, hub: f.path == hubPath, links: []))
                }
            }
            var byStem: [String: String] = [:]
            for n in notes { byStem[URL(fileURLWithPath: n.id).deletingPathExtension().lastPathComponent.lowercased()] = n.id }
            for k in notes.indices {
                let t = texts[notes[k].id] ?? ""
                var ls = Set<String>()
                for w in matches(wiki, t) { if let id = byStem[w.trimmingCharacters(in: .whitespaces).lowercased()] { ls.insert(id) } }
                for l in matches(mdLink, t) {
                    let target = URL(fileURLWithPath: l, relativeTo: URL(fileURLWithPath: notes[k].id).deletingLastPathComponent()).standardizedFileURL.path
                    if texts[target] != nil { ls.insert(target) }
                    else if let id = byStem[URL(fileURLWithPath: l).deletingPathExtension().lastPathComponent.lowercased()] { ls.insert(id) }
                }
                ls.remove(notes[k].id)
                notes[k].links = Array(ls)
            }
            if !notes.contains(where: \.hub) {
                notes.insert(RoomNote(id: "room:" + r.path, title: roomTitle(r), room: ri, hub: true, links: []), at: 0)
            }
            allTexts[ri] = Array(texts.values)
            out.append(RoomInfo(id: folder, title: roomTitle(r), color: Color(hex: palette[ri % palette.count]), notes: notes, crossed: [:], shared: sharedInfo.map(Shared.label)))
        }
        // "(from <room>)" lines: facts that crossed between rooms.
        for i in out.indices {
            for j in out.indices where j != i {
                let base = out[j].id.replacingOccurrences(of: "-room", with: "")
                let n = (allTexts[i] ?? []).reduce(0) { $0 + $1.lowercased().components(separatedBy: "(from \(base)").count - 1 }
                if n > 0 { out[i].crossed[j] = n }
            }
        }
        return out
    }
    static func layout(_ rooms: [RoomInfo], _ size: CGSize) -> [LaidNote] {
        let n = max(rooms.count, 1)
        let w = size.width, h = size.height
        var centers: [CGPoint] = []
        if n == 1 { centers = [CGPoint(x: w / 2, y: h / 2)] }
        else if n == 2 { centers = [CGPoint(x: w * 0.3, y: h * 0.55), CGPoint(x: w * 0.72, y: h * 0.42)] }
        else { for i in 0..<n { let a = Double(i) / Double(n) * 2 * .pi - .pi / 2; centers.append(CGPoint(x: w / 2 + cos(a) * w * 0.3, y: h / 2 + sin(a) * h * 0.3)) } }
        let spread = min(w / CGFloat(n == 1 ? 2.4 : Double(n) + 1.2), h / (n <= 2 ? 2.6 : 3.4))
        var out: [LaidNote] = []
        for (ri, room) in rooms.enumerated() {
            let c = centers[ri]
            var degree: [String: Int] = [:]
            for x in room.notes { for l in x.links { degree[l, default: 0] += 1; degree[x.id, default: 0] += 1 } }
            let others = room.notes.filter { !$0.hub }
            for x in room.notes where x.hub { out.append(LaidNote(n: x, p: c, r: 9, color: room.color, degree: degree[x.id] ?? 0)) }
            for (i, x) in others.enumerated() {
                let a = Double(i) * 2.39996 + Double(ri)
                let d = spread * CGFloat(sqrt((Double(i) + 1.2) / Double(others.count + 1))) * 0.95
                let dg = degree[x.id] ?? 0
                out.append(LaidNote(n: x, p: CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.85), r: dg > 0 ? 5 : 3.5, color: room.color, degree: dg))
            }
        }
        return out
    }
}

struct RoomsView: View {
    @ObservedObject var m: Model
    var close: () -> Void
    @State var rooms: [RoomInfo] = []
    @State var picked: String?
    @State var hover: String?
    @State var sharing = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Your rooms").font(.title3.weight(.semibold))
                    Text("Each room is a part of your life where \(m.name) acts differently and keeps the notes apart.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { sharing = true } label: { Label("Share a room", systemImage: "person.2") }
                        .help("Work on a room together with someone")
                    Button { close(); Task { await m.send("I'd like to add a room.", toNova: true) } } label: { Label("Room", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                        .help("Add a room")
                    Button("Done") { close() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                if rooms.isEmpty {
                    Spacer(); Text("Your rooms show up here once setup is done.").foregroundStyle(.secondary); Spacer()
                } else {
                    GeometryReader { g in
                        let laid = RoomMap.layout(rooms, g.size)
                        let at = Dictionary(laid.map { ($0.n.id, $0) }, uniquingKeysWith: { a, _ in a })
                        let labelled = laid.count <= 14 ? Set(laid.map(\.n.id)) : Set(laid.sorted { $0.degree > $1.degree }.prefix(10).filter { $0.degree > 0 }.map(\.n.id))
                        Canvas { ctx, _ in
                            // facts that crossed between rooms
                            for (i, r) in rooms.enumerated() {
                                for (j, n) in r.crossed where j > i || rooms[j].crossed[i] == nil {
                                    guard let a = laid.first(where: { $0.n.room == i && $0.n.hub }), let b = laid.first(where: { $0.n.room == j && $0.n.hub }) else { continue }
                                    let mid = CGPoint(x: (a.p.x + b.p.x) / 2, y: min(a.p.y, b.p.y) - 60)
                                    var path = Path(); path.move(to: a.p); path.addQuadCurve(to: b.p, control: mid)
                                    ctx.stroke(path, with: .color(Color(hex: 0xF4EFE8, 0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                                    ctx.draw(Text(n == 1 ? "1 fact crossed" : "\(n) facts crossed").font(.system(size: 10)).foregroundColor(Color(hex: 0xF4EFE8, 0.5)), at: CGPoint(x: mid.x, y: mid.y + 22))
                                }
                            }
                            for l in laid {
                                let hub = laid.first { $0.n.room == l.n.room && $0.n.hub }
                                if let hub, !l.n.hub {
                                    var p = Path(); p.move(to: hub.p); p.addLine(to: l.p)
                                    ctx.stroke(p, with: .color(l.color.opacity(0.12)), lineWidth: 0.8)
                                }
                                for t in l.n.links { if let o = at[t] {
                                    var p = Path(); p.move(to: l.p); p.addLine(to: o.p)
                                    ctx.stroke(p, with: .color(l.color.opacity(0.4)), lineWidth: 1)
                                } }
                            }
                            for l in laid {
                                let on = l.n.id == picked || l.n.id == hover
                                if l.n.hub || on {
                                    ctx.fill(Path(ellipseIn: CGRect(x: l.p.x - l.r * 2.4, y: l.p.y - l.r * 2.4, width: l.r * 4.8, height: l.r * 4.8)), with: .color(l.color.opacity(on ? 0.28 : 0.14)))
                                }
                                ctx.fill(Path(ellipseIn: CGRect(x: l.p.x - l.r, y: l.p.y - l.r, width: l.r * 2, height: l.r * 2)), with: .color(l.color.opacity(l.degree > 0 || l.n.hub ? 0.95 : 0.55)))
                                if l.n.hub || on || labelled.contains(l.n.id) {
                                    let txt = ctx.resolve(Text(l.n.title).font(.system(size: l.n.hub ? 12.5 : 11, weight: l.n.hub ? .semibold : .regular)).foregroundColor(Color(hex: 0xF4EFE8, l.n.hub || on ? 0.95 : 0.75)))
                                    let sz = txt.measure(in: CGSize(width: 220, height: 40))
                                    let pt = CGPoint(x: l.p.x, y: l.p.y + l.r * 2.4 + 8)
                                    ctx.fill(Path(roundedRect: CGRect(x: pt.x - sz.width / 2 - 4, y: pt.y - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2), cornerRadius: 5), with: .color(Color(hex: 0x141416, 0.85)))
                                    ctx.draw(txt, at: pt)
                                }
                            }
                            for (i, r) in rooms.enumerated() {
                                guard let hub = laid.first(where: { $0.n.room == i && $0.n.hub }) else { continue }
                                let maxY = laid.filter { $0.n.room == i }.map(\.p.y).max() ?? hub.p.y
                                let count = r.notes.filter { !$0.id.hasPrefix("room:") }.count
                                ctx.draw(Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundColor(r.color), at: CGPoint(x: hub.p.x, y: maxY + 30))
                                if let sh = r.shared {
                                    ctx.draw(Text(Image(systemName: "person.2.fill")).font(.system(size: 10)).foregroundColor(r.color), at: CGPoint(x: hub.p.x, y: hub.p.y - 22))
                                    ctx.draw(Text(sh).font(.system(size: 10.5)).foregroundColor(r.color.opacity(0.8)), at: CGPoint(x: hub.p.x, y: maxY + 62))
                                }
                                ctx.draw(Text(count == 1 ? "1 note" : "\(count) notes").font(.system(size: 10.5)).foregroundColor(Color(hex: 0xF4EFE8, 0.5)), at: CGPoint(x: hub.p.x, y: maxY + 46))
                            }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { ph in
                            if case .active(let pt) = ph { hover = nearest(pt, laid) } else { hover = nil }
                        }
                        .onTapGesture(coordinateSpace: .local) { pt in if let n = nearest(pt, laid), !n.hasPrefix("room:") { picked = n } }
                    }
                }
            }
            if let id = picked, let note = rooms.flatMap(\.notes).first(where: { $0.id == id }) {
                NotePanel(note: note, rooms: rooms) { picked = $0 }
                    .frame(width: 290).padding(.vertical, 14).padding(.trailing, 14)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(Color(hex: 0x141416))
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $sharing, onDismiss: { rooms = RoomMap.load() }) { ShareRoomSheet(m: m) { sharing = false } }
        .onAppear {
            rooms = RoomMap.load()
            picked = rooms.first?.notes.first { $0.hub && !$0.id.hasPrefix("room:") }?.id
        }
    }
    func nearest(_ pt: CGPoint, _ laid: [LaidNote]) -> String? {
        let best = laid.min { hypot($0.p.x - pt.x, $0.p.y - pt.y) < hypot($1.p.x - pt.x, $1.p.y - pt.y) }
        guard let best, hypot(best.p.x - pt.x, best.p.y - pt.y) < 18 else { return nil }
        return best.n.id
    }
}


struct ShareRoomSheet: View {
    @ObservedObject var m: Model
    var close: () -> Void
    @State var choice = "new"
    @State var name = ""
    @State var made: URL?
    @State var error: String?
    var shareable: [URL] {
        RoomMap.roomFolders().filter { !$0.path.hasPrefix(Shared.cloud.path) && !["personal-room", "private-room"].contains($0.lastPathComponent) }
    }
    var alreadyShared: [URL] { RoomMap.roomFolders().filter { $0.path.hasPrefix(Shared.cloud.path) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let made {
                Label("The room is ready", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Color(hex: 0x9FC9B0))
                Text("Now invite them. Pick Messages or Mail, and make sure **Collaborate** is chosen, not \"Send copy\". They need One on their Mac too. When they accept, the room shows up in their One and both of you can add to it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { Shared.invite(made) } label: { Label("Invite someone", systemImage: "person.badge.plus") }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([made]) }
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
                Text("If Collaborate doesn't appear: in Finder, right-click the folder › Share › Share Folder.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Share a room").font(.title3.weight(.semibold))
                Text("You and someone you trust both add to the same room, each with your own assistant. It stays in sync through iCloud, so there's nothing to sign up for. You each add new notes, nobody overwrites the other, and \(m.name) merges anything that clashes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $choice) {
                    ForEach(alreadyShared, id: \.path) { u in Text(RoomMap.roomTitle(u) + " (already shared: invite someone)").tag(u.path) }
                    Text("A new room").tag("new")
                    ForEach(shareable, id: \.path) { u in Text("My " + RoomMap.roomTitle(u).lowercased() + " (moves into iCloud)").tag(u.path) }
                }.pickerStyle(.radioGroup).labelsHidden()
                if choice == "new" {
                    TextField("What should the room be called? For example: Our business", text: $name).textFieldStyle(.roundedBorder)
                }
                Text("Your personal and private rooms can't be shared. Nothing from your other rooms goes in without your OK.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button(alreadyShared.contains { $0.path == choice } ? "Invite someone" : "Make it shared") { go() }.keyboardShortcut(.defaultAction)
                        .disabled(choice == "new" && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { if let u = alreadyShared.first, made == nil { choice = u.path } }
    }
    func go() {
        if let u = alreadyShared.first(where: { $0.path == choice }) {
            made = u; Shared.invite(u); return
        }
        let local = choice == "new" ? nil : URL(fileURLWithPath: choice)
        let title = local.map { RoomMap.roomTitle($0) } ?? name.trimmingCharacters(in: .whitespaces)
        switch Shared.make(title: title, moving: local) {
        case .failure(let e): error = e.text
        case .success(let u):
            made = u
            Task { _ = await Engine.shared.start() }
            Shared.invite(u)
        }
    }
}

struct NotePanel: View {
    let note: RoomNote
    let rooms: [RoomInfo]
    var go: (String) -> Void
    var body: some View {
        let raw = (try? String(contentsOfFile: note.id, encoding: .utf8)) ?? ""
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        if let f = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[f].hasPrefix("# ") { lines.remove(at: f) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let room = rooms[note.room]
        let all = room.notes
        let linked = Array(Set(note.links + all.filter { $0.links.contains(note.id) }.map(\.id))).compactMap { id in all.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(room.color).frame(width: 7, height: 7)
                Text(room.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(note.title).font(.system(size: 16, weight: .semibold))
            ScrollView {
                MarkdownText(text: text.isEmpty ? "Nothing written here yet." : text, size: 13).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !linked.isEmpty {
                Text("LINKED NOTES").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                FlowChips(items: linked.prefix(8).map { ($0.id, $0.title) }, tap: go)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.id)]) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.08)))
    }
}

struct FlowChips: View {
    let items: [(String, String)]
    var tap: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(items[i..<min(i + 2, items.count)], id: \.0) { it in
                        Button { tap(it.0) } label: {
                            Text(it.1).font(.system(size: 11)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Rooms map + add a room (render-only design preview)
struct MapNode { let p: CGPoint; let r: CGFloat; let label: String?; let hub: Bool }

enum MapData {
    static func cluster(_ c: CGPoint, _ hub: String, _ named: [String], extra: Int, seed: Double, spread: CGFloat) -> [MapNode] {
        var v = [MapNode(p: c, r: 9, label: hub, hub: true)]
        let total = named.count + extra
        for i in 0..<total {
            let a = Double(i) / Double(total) * 2 * .pi + seed
            let d = spread * (0.55 + 0.45 * CGFloat(abs(sin(Double(i) * 2.7 + seed))))
            let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.8)
            v.append(MapNode(p: p, r: i < named.count ? 5 : 3, label: i < named.count ? named[i] : nil, hub: false))
        }
        return v
    }
    static func place(_ c: CGPoint, _ hub: String, _ named: [(String, CGFloat, CGFloat)], _ dots: [(CGFloat, CGFloat)]) -> [MapNode] {
        [MapNode(p: c, r: 9, label: hub, hub: true)]
        + named.map { MapNode(p: CGPoint(x: c.x + $0.1, y: c.y + $0.2), r: 5, label: $0.0, hub: false) }
        + dots.map { MapNode(p: CGPoint(x: c.x + $0.0, y: c.y + $0.1), r: 3, label: nil, hub: false) }
    }
    static let personal = place(CGPoint(x: 205, y: 250), "Life",
        [("Family", -120, -40), ("Health", -60, -112), ("Quebec trip", 92, -86), ("Money", 128, 10), ("Home", 70, 104), ("Kids' school", -90, 92)],
        [(-150, 30), (-20, -140), (20, 130), (150, 70), (-40, 150), (130, -40), (-130, -95), (0, 70), (45, -45)])
    static let business = place(CGPoint(x: 455, y: 205), "Company",
        [("Ideas", -62, -70), ("Buyers", 68, -56), ("The offer", 70, 56), ("Pipeline", -40, 78)],
        [(10, -95), (100, 0), (-95, 10), (30, 100), (-10, -40)])
}

struct RoomGraph: View {
    var t: Double = 4
    var body: some View {
        Canvas { ctx, _ in
            func draw(_ nodes: [MapNode], _ tint: Color) {
                let hub = nodes[0]
                for (i, n) in nodes.enumerated().dropFirst() {
                    var path = Path(); path.move(to: hub.p); path.addLine(to: n.p)
                    ctx.stroke(path, with: .color(tint.opacity(0.22)), lineWidth: 1)
                    if i > 1, i % 3 == 0 {
                        var q = Path(); q.move(to: n.p); q.addLine(to: nodes[i - 1].p)
                        ctx.stroke(q, with: .color(tint.opacity(0.14)), lineWidth: 0.8)
                    }
                }
                for n in nodes {
                    let sel = n.label == "Quebec trip"
                    if n.hub || sel {
                        ctx.fill(Path(ellipseIn: CGRect(x: n.p.x - n.r * 2.4, y: n.p.y - n.r * 2.4, width: n.r * 4.8, height: n.r * 4.8)), with: .color(tint.opacity(sel ? 0.25 : 0.14)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: n.p.x - n.r, y: n.p.y - n.r, width: n.r * 2, height: n.r * 2)), with: .color(tint.opacity(n.label == nil ? 0.5 : 0.95)))
                    if let l = n.label {
                        let txt = ctx.resolve(Text(l).font(.system(size: n.hub ? 12.5 : 11, weight: n.hub ? .semibold : .regular)).foregroundColor(WorldLook.cream.opacity(n.hub ? 0.95 : 0.8)))
                        let sz = txt.measure(in: CGSize(width: 200, height: 40))
                        let at = CGPoint(x: n.p.x, y: n.p.y + n.r + 11)
                        ctx.fill(Path(roundedRect: CGRect(x: at.x - sz.width / 2 - 4, y: at.y - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2), cornerRadius: 5), with: .color(WorldLook.bg.opacity(0.85)))
                        ctx.draw(txt, at: at)
                    }
                }
            }
            // the one dated line that crossed between rooms
            var x = Path(); x.move(to: MapData.personal[3].p)
            x.addQuadCurve(to: MapData.business[0].p, control: CGPoint(x: 360, y: 40))
            ctx.stroke(x, with: .color(WorldLook.cream.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            draw(MapData.personal, Color(hex: 0xFFE2C2))
            draw(MapData.business, Color(hex: 0x9FC9B0))
        }
    }
}

struct MapScene: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            WorldLook.bg
            RoomGraph()
            // room names
            VStack(alignment: .leading, spacing: 1) {
                Text("Personal room").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xFFE2C2))
                Text("15 notes").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }.position(x: 92, y: 400)
            VStack(alignment: .leading, spacing: 1) {
                Text("Business room").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x9FC9B0))
                Text("9 notes").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }.position(x: 500, y: 340)
            Text("1 date crossed: “trip Dec 20–24”").font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.45))
                .position(x: 360, y: 74)
            // top bar
            HStack(spacing: 10) {
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)); Text("Nova") }
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                Text("Your rooms").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                Spacer()
                HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)); Text("Room") }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.bg)
                    .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(WorldLook.cream))
            }
            .padding(.horizontal, 18).frame(width: 580).position(x: 290, y: 28)
            // the opened note
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 7, height: 7)
                    Text("Personal room").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.55))
                }
                Text("Quebec trip").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                Text("December 20–24, four of us: Omar, his wife, and the kids (7 and 3).\n\nFlights: Newark is cheapest at $3,104 for all four. Hotel pick: Le Germain, $289 a night, family room in Old Quebec.")
                    .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LINKED NOTES").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.45))
                    HStack(spacing: 6) {
                        ForEach(["Family", "Money"], id: \.self) { n in
                            Text(n).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.85))
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
                Spacer()
                Text("Open in Finder").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.75))
            }
            .padding(16).frame(width: 220, height: 400, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.08)))
            .position(x: 700, y: 225)
        }
        .frame(width: 820, height: 450)
        .environment(\.colorScheme, .dark)
    }
}

struct RoomAddScene: View {
    var confirm = false
    var t: Double = 12
    var body: some View {
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 10, endRadius: 260)
            Presence(t: t, lean: .zero, voice: 0.3, energy: 0.15).frame(width: 280, height: 280).scaleEffect(0.36).position(x: 310, y: 62)
            if !confirm {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Spacer(); Text("I want a room for my business").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Color.white.opacity(0.08))) }
                    Text("Good idea. A room is a part of your life where I act differently and keep the notes apart from everything else. Four quick questions, then you'll see it before I make it.")
                        .font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.92)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(0..<4) { i in Capsule().fill(WorldLook.cream.opacity(i == 0 ? 0.9 : 0.18)).frame(width: i == 0 ? 22 : 8, height: 5) }
                        Text("1 of 4").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5)).padding(.leading, 4)
                    }
                    Text("What should I be for you in this room?").font(.system(size: 15, weight: .semibold)).foregroundStyle(WorldLook.cream)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            chip("A co-founder who pushes me", main: true); chip("An assistant who keeps things organized")
                        }
                        HStack(spacing: 8) { chip("A coach who asks hard questions"); chip("Say it your way…") }
                    }
                }
                .padding(20).frame(width: 520, alignment: .leading)
                .position(x: 310, y: 270)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0x9FC9B0)).frame(width: 9, height: 9)
                        Text("Business room").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Spacer()
                        Text("Here's the room. Look right?").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.55))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        row("person.2", "My job here", "Your co-founder. I push you to make progress.")
                        row("eye", "Who might see it", "Just you, for now.")
                        row("lock", "How private", "Kept apart from your personal room. Only a date or number crosses, with your OK.")
                        row("arrow.up.right", "What I push you toward", "Talking to buyers and hitting deadlines.")
                    }
                    Divider().overlay(WorldLook.cream.opacity(0.1))
                    HStack(alignment: .top, spacing: 14) {
                        rule("On my own", "read, draft")
                        rule("Needs your yes", "send, spend, delete")
                        rule("Only you", "change these rules")
                    }
                    HStack(spacing: 8) {
                        Text("Make the room").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(WorldLook.cream))
                        chip("Change something")
                    }.padding(.top, 2)
                }
                .padding(18).frame(width: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.1)))
                .position(x: 310, y: 268)
            }
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
    }
    func chip(_ s: String, main: Bool = false) -> some View {
        Text(s).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WorldLook.cream)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(main ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(main ? 0.3 : 0.14)))
            .fixedSize()
    }
    func row(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color(hex: 0x9FC9B0)).frame(width: 18)
            Text(k).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9)).frame(width: 165, alignment: .leading)
            Text(v).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
    }
    func rule(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.5))
            Text(v).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.85))
        }
    }
}

// MARK: - "Ready for you" shelf (render-only design preview): what Nova and her helpers made.
struct ShelfCard: View {
    let icon: String; let title: String; let detail: String; let from: String; var fresh = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color(hex: 0xFFE2C2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.95))
                Text(detail).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Text(from).font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.45))
            }
            Spacer(minLength: 0)
            if fresh { Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 6, height: 6).padding(.top, 4) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(fresh ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(fresh ? 0.22 : 0.07)))
        .shadow(color: Color(hex: 0xFFE2C2, fresh ? 0.12 : 0), radius: 10)
    }
}

struct ShelfScene: View {
    var t: Double = 21.7
    var open = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.36, y: 0.48), startRadius: 10, endRadius: 280)
            Text("Good afternoon, Omar.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .position(x: 290, y: 34)
            Presence(t: t, lean: .zero, voice: 0.2, energy: 0.15).frame(width: 280, height: 280).scaleEffect(0.6).position(x: 290, y: 224)
            Text("Nova").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.8)).position(x: 290, y: 290)
            HelperOrb(state: .working, t: t, size: 40).position(x: 140, y: 150)
            HelperLabel(title: "Flight to Quebec", line: "Checking Google Flights…").position(x: 140, y: 198)
            // done helper flying to the shelf
            Path { p in p.move(to: CGPoint(x: 330, y: 250)); p.addQuadCurve(to: CGPoint(x: 548, y: 112), control: CGPoint(x: 450, y: 160)) }
                .stroke(LinearGradient(colors: [WorldLook.cream.opacity(0), WorldLook.cream.opacity(0.3)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1, 6]))
            HStack {
                Text("Talk to Nova…").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.5))
                Spacer(); Image(systemName: "mic").foregroundStyle(WorldLook.cream.opacity(0.65))
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 340)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.1)))
            .position(x: 290, y: 404)

            // the shelf
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ready for you").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                    Text("2 new").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFFE2C2)))
                    Spacer()
                }.padding(.bottom, 2)
                ShelfCard(icon: "receipt", title: "Receipts 2026", detail: "23 receipts · $1,284 total", from: "Receipts helper · just now", fresh: true)
                ShelfCard(icon: "airplane", title: "Quebec flight prices", detail: "Newark $3,104 · Philadelphia $3,416", from: "Flight helper · 1:17 PM", fresh: true)
                ShelfCard(icon: "envelope", title: "Reply to the school", detail: "Draft, not sent", from: "Nova · yesterday")
                ShelfCard(icon: "folder", title: "Downloads, tidied", detail: "9 folders · nothing deleted", from: "Downloads helper · Mon")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text("All saved in Documents › Made by Nova").font(.system(size: 10.5))
                }.foregroundStyle(WorldLook.cream.opacity(0.5))
            }
            .padding(14).frame(width: 250, height: 410, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.07)))
            .position(x: 680, y: 225)

            if open {
                Color.black.opacity(0.45)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "receipt").foregroundStyle(Color(hex: 0xFFE2C2))
                        Text("Receipts 2026").font(.system(size: 15, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Spacer()
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    }
                    Text("23 receipts from this year, $1,284 in total.").font(.system(size: 13.5)).foregroundStyle(WorldLook.cream.opacity(0.9))
                    VStack(spacing: 6) {
                        ForEach([("Amazon", "Mar 4", "$212.40"), ("Apple", "Jun 18", "$129.00"), ("Costco", "Aug 2", "$318.40"), ("Target", "Sep 9", "$64.15")], id: \.0) { r in
                            HStack { Text(r.0); Spacer(); Text(r.1).foregroundStyle(WorldLook.cream.opacity(0.5)); Text(r.2).frame(width: 70, alignment: .trailing) }
                                .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85))
                        }
                        Text("+ 19 more").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                    HStack(spacing: 8) {
                        Text("Open in Numbers").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(WorldLook.cream))
                        ForEach(["Show in Finder", "Ask Nova about it"], id: \.self) { c in
                            Text(c).font(.system(size: 12, weight: .medium)).foregroundStyle(WorldLook.cream)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.14)))
                        }
                    }
                    Text("Tip: drag the card into Mail or Messages to share it.").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45))
                }
                .padding(18).frame(width: 420)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x1E1E22, 0.98)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .position(x: 410, y: 225)
            }
        }
        .frame(width: 820, height: 450)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Helpers (render-only design preview): Nova in the middle, each separate job as a small orb around her.

enum HelperState { case working, needsYes, done, stopped }

struct HelperOrb: View {
    let state: HelperState
    let t: Double
    var size: CGFloat = 46
    var body: some View {
        let warm = state == .needsYes
        ZStack {
            if warm {
                ForEach(0..<2, id: \.self) { i in
                    let p = (t * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(Color(hex: 0xF0A04B, 0.85 * (1 - p)), lineWidth: 1.6)
                        .frame(width: size * (1.1 + 0.45 * p), height: size * (1.1 + 0.45 * p))
                }
            }
            FloatingOrb(state: state == .working ? .working : .idle, size: size, fixedT: t)
                .saturation(state == .done || state == .stopped ? 0.3 : 1)
            if warm {
                Circle().fill(RadialGradient(colors: [Color(hex: 0xF0A04B, 0.55), Color(hex: 0xF0A04B, 0.1)], center: .center, startRadius: 2, endRadius: size * 0.55))
                    .frame(width: size, height: size).blendMode(.plusLighter)
            }
            if state == .done {
                Circle().fill(WorldLook.cream).frame(width: 16, height: 16)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WorldLook.bg))
                    .offset(x: size * 0.36, y: -size * 0.36)
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
    }
}

struct HelperLabel: View {
    let title: String; let line: String; var warm = false
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(warm ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.92))
            Text(line).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(warm ? 0.8 : 0.66))
        }.multilineTextAlignment(.center).fixedSize()
    }
}

struct HelpersScene: View {
    var t: Double = 21.7
    var open = false     // a helper tapped: its little conversation shown
    var body: some View {
        let novaY: CGFloat = open ? 336 : 214
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: novaY / 440), startRadius: 10, endRadius: 280)
            Text("Good afternoon, Omar.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .position(x: 310, y: 30)
            // Nova
            Presence(t: t, lean: .zero, voice: open ? 0 : 0.25, energy: 0.15)
                .frame(width: 280, height: 280).scaleEffect(open ? 0.42 : 0.6).position(x: 310, y: novaY)
                .opacity(open ? 0.5 : 1)
            Text("Nova").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(open ? 0.45 : 0.8))
                .position(x: 310, y: novaY + (open ? 56 : 66))

            if open {
                // Tapped "Flight to Quebec": the orb comes forward and you talk to that job directly.
                HelperOrb(state: .working, t: t, size: 30).position(x: 310, y: 66)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Flight to Quebec").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Text("· working").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
                        Spacer()
                        HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)); Text("Nova") }
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
                            .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Text("PHL → YQB, Dec 20–24. Cheapest right now: $248 on United, 1 stop. I'll check every morning and tell you if it drops.")
                        .font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.88)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("make it Dec 21 instead").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.9))
                        Spacer()
                        Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.65))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .padding(14).frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1E1E22, 0.97)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .position(x: 310, y: 194)
                // the other helpers step back, still visible
                HelperOrb(state: .needsYes, t: t, size: 30).opacity(0.75).position(x: 520, y: 336)
                HelperLabel(title: "Downloads", line: "Needs your yes", warm: true).scaleEffect(0.9).position(x: 520, y: 374)
                HelperOrb(state: .done, t: t, size: 26).opacity(0.7).position(x: 100, y: 336)
                HelperLabel(title: "Receipts", line: "Done").scaleEffect(0.9).position(x: 100, y: 370)
            } else {
                // working: flight watch (upper left)
                HelperOrb(state: .working, t: t).position(x: 132, y: 132)
                HelperLabel(title: "Flight to Quebec", line: "Checking Google Flights…").position(x: 132, y: 184)
                // needs a yes (upper right)
                HelperOrb(state: .needsYes, t: t).position(x: 492, y: 150)
                HelperLabel(title: "Downloads", line: "Needs your yes · tap to answer", warm: true).position(x: 492, y: 202)
                // done: drifting back in to Nova
                HelperOrb(state: .done, t: t, size: 36).position(x: 420, y: 292)
                HelperLabel(title: "Receipts", line: "Done · $1,284 this year").position(x: 420, y: 334)
                // Talk to Nova any time, even while helpers work
                HStack {
                    Text("Talk to Nova…").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Image(systemName: "mic").foregroundStyle(WorldLook.cream.opacity(0.65))
                }
                .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 360)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.1)))
                .position(x: 310, y: 404)
            }
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
    }
}

struct AwayScene: View {
    var t: Double = 33.1
    var body: some View {
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: 0.28), startRadius: 10, endRadius: 260)
            Presence(t: t, lean: .zero, voice: 0.4, energy: 0.2).frame(width: 280, height: 280).scaleEffect(0.5).position(x: 310, y: 112)
            VStack(alignment: .leading, spacing: 12) {
                Text("While you were gone").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.8))
                ForEach([("airplane", "The flight to Quebec dropped to $214. Want me to hold it?"),
                         ("folder", "Your Downloads are sorted into 9 folders. Nothing was deleted."),
                         ("receipt", "Your receipts this year add up to $1,284.")], id: \.1) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: r.0).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFFE2C2)).frame(width: 18)
                        Text(r.1).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Text("Hold the flight").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(WorldLook.cream))
                    ForEach(["Show the folders", "Not now"], id: \.self) { c in
                        Text(c).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WorldLook.cream)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.14)))
                    }
                }.padding(.top, 4)
            }
            .padding(20).frame(width: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.08)))
            .position(x: 310, y: 300)
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
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
                let d = Voice.shared.play(l.1)
                if d > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                shown = i + 1
                try? await Task.sleep(for: .milliseconds(Int(max(d - 0.5, 1.3) * 1000) + 250))
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
    @State var talkKeySheet = false
    @State var roomsSheet = false
    @AppStorage("voiceMuted") var voiceOff = false
    @ObservedObject var l = Listener.shared
    @State var micDownAt: Date?
    @State var micLatched = false
    @State var dropping = false
    @FocusState var typing: Bool
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var lastReply: Bubble? { m.bubbles.last.flatMap { $0.fromMe ? nil : $0 } }
    var body: some View {
        HStack(spacing: 0) {
        ZStack {
            Mist()
            ScrollView {
                VStack(spacing: 18) {
                    Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).padding(.top, 18)
                    NovaWithHelpers(m: m)
                    if m.thinking && m.openHelper == nil {
                        Text(m.working ?? "Working on it…").foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).transition(.opacity)
                    }
                    if m.openHelper == nil { UpdateCard() }
                    if m.openHelper == nil, let inv = m.roomInvites.first, let info = Shared.info(inv) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("\(info.createdBy) invited you into a room", systemImage: "person.2.fill").font(.headline)
                            Text("\"\(info.title)\": a room you both add to, each with your own assistant. It stays in sync through iCloud. Nothing from your other rooms goes in without your OK.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Add it to my brain") { m.joinRoom(inv) }
                                    .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                Button("Not now") { Shared.leave(inv); m.roomInvites.removeAll { $0 == inv } }.buttonStyle(.bordered)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                    }
                    if m.openHelper == nil && !m.interviewOffered && !m.thinking && Brain.exists {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Want me to get to know you?").font(.headline)
                            Text("A few questions, one at a time, so I know what your personal room is for and how to help. You can skip any question, or stop whenever you like.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Let's start") { m.interviewOffered = true; Task { await m.send("Let's do the welcome interview. Get to know me.", toNova: true) } }
                                    .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                Button("Maybe later") {
                                    m.interviewOffered = true
                                    m.bubbles.append(Bubble(fromMe: false, text: "Any time. Just say \"get to know me\"."))
                                }.buttonStyle(.bordered)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                    }
                    if m.openHelper == nil, case let away = m.helpers.filter({ $0.finishedAway }), !away.isEmpty {
                        AwayCard(m: m, hs: away).transition(.opacity)
                    }
                    if !m.asks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                            ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                        }
                    }
                    if let h = m.openedHelper {
                        HelperCard(m: m, h: h).transition(.opacity.combined(with: .offset(y: 8)))
                    } else if let ask = lastAsk {
                        VStack(spacing: 12) {
                            Text(ask.text).font(.callout).foregroundStyle(Color.accentColor).multilineTextAlignment(.center)
                            if let r = lastReply, !r.text.isEmpty {
                                let parts = Choices.split(Helpers.strip(r.text))
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
            if !m.shelf.isEmpty { ShelfPanel(m: m).background(Mist()).transition(.move(edge: .trailing)) }
        }
        .frame(minWidth: m.shelf.isEmpty ? 560 : 830)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m.shelf.isEmpty)
        .overlay {
            if let id = m.openedShelf, let it = m.shelf.first(where: { $0.id == id }) {
                ShelfOpened(m: m, item: it).transition(.opacity)
            }
        }
        .overlay { if let u = m.viewing { FileViewer(m: m, url: u).transition(.opacity) } }
        .environment(\.openURL, OpenURLAction { u in
            var f: URL? = u.isFileURL ? u : nil
            if f == nil, u.scheme == nil, u.path.hasPrefix("/") { f = URL(fileURLWithPath: u.path) }
            if let f, FileViewer.readable.contains(f.pathExtension.lowercased()) { m.viewing = f; return .handled }
            if let f { NSWorkspace.shared.activateFileViewerSelecting([f]); return .handled }
            return .systemAction
        })
        .onChange(of: m.draftSeed) { _, v in if let v { if !v.isEmpty { draft = v }; m.draftSeed = nil; typing = true } }
        .safeAreaInset(edge: .bottom) {
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
        }
        .toolbar {
            ToolbarItem {
                Button { voiceOff.toggle(); if voiceOff { Speaker.shared.stop(); Voice.shared.stop() } } label: {
                    Label(voiceOff ? "Voice off" : "Voice on", systemImage: voiceOff ? "speaker.slash" : "speaker.wave.2")
                }.help(voiceOff ? "Let \(m.name) talk" : "Stop \(m.name) from talking")
            }
            ToolbarItem { Button { roomsSheet = true } label: { Label("Rooms", systemImage: "circle.hexagongrid") }.help("See your rooms") }
            ToolbarItem { Button { talkKeySheet = true } label: { Label("Push to talk", systemImage: "mic") }.help("Choose a push-to-talk key") }
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
        .sheet(isPresented: $talkKeySheet) { TalkKeySheet { talkKeySheet = false } }
        .sheet(isPresented: $roomsSheet) { RoomsView(m: m) { roomsSheet = false } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { PictureIn.drop($0) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(Text("Drop pictures or files here").font(.title3.weight(.medium)).padding(12).background(Capsule().fill(.ultraThinMaterial)))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .task { await m.ensureEngine() }
    }
    /// Hold the mic to talk (let go to send), or click once to start and again to send.
    var micButton: some View {
        let on = m.talkingInApp
        return ZStack {
            if on { Circle().fill(Color(hex: 0xFFE2C2, 0.18)).frame(width: 40 + 14 * l.level, height: 40 + 14 * l.level) }
            Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 20, weight: on ? .regular : .light))
                .foregroundStyle(on ? Color(hex: 0xFFE2C2) : Color.primary)
        }
        .frame(width: 34, height: 34).contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard micDownAt == nil else { return }
                micDownAt = Date()
                if micLatched { return }
                m.talkBegin()
            }
            .onEnded { _ in
                let held = Date().timeIntervalSince(micDownAt ?? Date()); micDownAt = nil
                if micLatched { micLatched = false; m.talkEnd(); return }
                if held < 0.35 && m.talkingInApp { micLatched = true; return }   // a click: keep listening until the next click
                m.talkEnd()
            })
        .help("Hold to talk, or click to start and click again to send")
        .disabled(m.paused)
        .animation(.easeOut(duration: 0.12), value: l.level)
    }
    @ViewBuilder var talkLine: some View {
        if m.talkingInApp {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color(hex: 0xFFE2C2))
                Text(l.text.isEmpty ? "I'm listening…" : l.text).lineLimit(3)
                Spacer()
                Text(micLatched ? "Click the mic to send" : "Let go to send").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .transition(.opacity)
        } else if let n = l.problem ?? m.talkNote {
            Text(n).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if m.talkNote == n { m.talkNote = nil } } }
        }
    }
    var askBox: some View {
        VStack(spacing: 8) {
        talkLine
        PictureStrip(m: m)
        HStack(spacing: 12) {
            Button { PictureIn.pick() } label: { Image(systemName: "paperclip").font(.system(size: 20, weight: .light)) }
                .buttonStyle(.plain).help("Add a picture or file (or drag it in, or paste it)").disabled(m.paused)
            TextField(m.about != nil ? "What do you want to know? Or just press send." : m.openedHelper.map { "Talk to \($0.title)…" } ?? (lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…"), text: $draft)
                .textFieldStyle(.plain).font(.title3).focused($typing)
                .padding(12).padding(.horizontal, 4).background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(typing ? 0.28 : 0.1)))
                .onSubmit(go).disabled(m.paused)
            micButton
            Button(action: go) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32, weight: .light)) }
                .buttonStyle(.plain).disabled(m.paused || m.busyHere || (draft.isEmpty && m.pictures.isEmpty && m.files.isEmpty && m.about == nil))
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--print-profile") { print(Access.profile()); exit(0) }
        if CommandLine.arguments.contains("--check-update") {
            Task { @MainActor in
                await Updater.shared.check()
                print("current", Updater.shared.current, "available", Updater.shared.available.map { "\($0.version) \($0.zip)" } ?? "none"); exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--auto-update") {
            Task { @MainActor in await Updater.shared.check(); print("found", Updater.shared.available?.version ?? "none"); await Updater.shared.install(); print("state", Updater.shared.state ?? "") }
        }
        else if !Env.selfTest { Task { @MainActor in Updater.shared.loop() } }
        if CommandLine.arguments.contains("--test-shared") {
            Env.selfTest = true   // brain goes to a scratch copy, never the real one
            // Two people, one cloud folder: Omar makes a room, Sam joins, both add entries.
            let d = UserDefaults.standard
            d.set("Omar", forKey: "userName"); d.set([String](), forKey: "sharedRooms")
            var out: [String] = []
            switch Shared.make(title: "Our business", moving: nil) {
            case .failure(let e): out.append("make failed: \(e.text)")
            case .success(let u):
                out.append("made \(u.lastPathComponent), files: " + ((try? FileManager.default.contentsOfDirectory(atPath: u.path).sorted().joined(separator: ", ")) ?? ""))
                out.append("invites for Omar (should be 0): \(Shared.invites().count)")
                d.set("Sam", forKey: "userName"); d.set([String](), forKey: "sharedRooms")
                let inv = Shared.invites()
                out.append("invites for Sam (should be 1): \(inv.count)")
                if let r = inv.first { Shared.join(r) }
                out.append("members now: \(Shared.info(u)?.members ?? [])")
                out.append("Sam's rooms: \(Shared.paths.map { URL(fileURLWithPath: $0).lastPathComponent })")
                out.append("entries: " + ((try? FileManager.default.contentsOfDirectory(atPath: u.appendingPathComponent("entries").path).sorted().joined(separator: " | ")) ?? ""))
                out.append("label for Sam: \(Shared.label(Shared.info(u)!))")
                out.append("sandbox allows it: \(Access.profile().contains(u.path))")
                out.append("note has rules: \(Shared.note(clashes: []).contains("Never edit or delete a file someone else wrote"))")
            }
            print(out.joined(separator: "\n")); exit(0)
        }
        Task { @MainActor in
            var tick = 0
            while true {
                Model.shared.scanShelf()
                if tick % 5 == 0 { Model.shared.tendShared() }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
        if Speaker.shared.installed { Speaker.shared.start() }
        else if Env.hermesPath != nil { Task.detached { if await Speaker.shared.install() { Speaker.shared.start() } } }
        MainActor.assumeIsolated { Floater.shared.setup(); PictureIn.installPaste(); TalkKeys.shared.apply() }
    }
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
                    ("hint-long", AnyView(ZStack(alignment: .trailing) { Color(hex: 0x2A2F3D); HStack(spacing: 18) { FloatHint(text: Plain.step("browser_exec: # Checking Google Flights for PHL to Quebec City on Dec 20\nimport time click_at_xy(448, 375)")); FloatingOrb(state: .working, size: 72, fixedT: 9) }.padding(.trailing, 40) }.environment(\.colorScheme, .dark))),
                    ("live-rooms", AnyView(RoomsView(m: Model.shared) {})),
                    ("reader-noscroll", AnyView(ZStack { Color(hex: 0x141416); MarkdownText(text: (try? String(contentsOf: Shelf.folder.appendingPathComponent("2026-10-23 Quebec trip planning.md"), encoding: .utf8)) ?? "missing", size: 15).padding(22) }.environment(\.colorScheme, .dark))),
                    ("reader", AnyView(ZStack { Color(hex: 0x141416); FileViewer(m: Model.shared, url: Shelf.folder.appendingPathComponent("2026-10-23 Quebec trip planning.md")) }.environment(\.colorScheme, .dark))),
                    ("map", AnyView(MapScene())),
                    ("room-add", AnyView(RoomAddScene())),
                    ("room-confirm", AnyView(RoomAddScene(confirm: true))),
                    ("shelf", AnyView(ShelfScene())),
                    ("shelf-open", AnyView(ShelfScene(open: true))),
                    ("helpers", AnyView(HelpersScene())),
                    ("helper-open", AnyView(HelpersScene(open: true))),
                    ("away", AnyView(AwayScene())),
                    ("float-idle", AnyView(FloatScene(state: .idle))),
                    ("float-listen", AnyView(FloatScene(state: .listening))),
                    ("float-work", AnyView(FloatScene(state: .working))),
                    ("picked", AnyView(WorldCanvas(t: 60, lit: nil, picking: true, linked: ["Email": 50, "Files": 52, "Calendar": 59.6], speaking: false).background(WorldLook.bg))),
                ]
                for (name, v) in views {
                    let r = ImageRenderer(content: v.frame(width: name == "live-rooms" || name == "reader" ? 960 : (name.hasPrefix("shelf") || name == "map" ? 820 : 620), height: name == "live-rooms" || name == "reader" ? 600 : (name.hasPrefix("shelf") || name == "map" ? 450 : 440))); r.scale = 2
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
