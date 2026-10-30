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

    /// Hermes keeps a background helper (gateway) per home. Restart it only when it's stale: orphaned,
    /// or left by the engine this process just replaced. A healthy one serving another engine (the
    /// person's live One while a test copy runs) is never touched; killing it failed their message.
    static func stopStrayGateway(previousEngine: pid_t? = nil, caller: String = "stop") {
        GatewayGuard.stopIfStale(previousEngine: previousEngine, caller: caller)
    }

    /// pid of the engine process this object runs, if any.
    var enginePID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return proc?.isRunning == true ? proc?.processIdentifier : nil
    }

    static func isBrainEdit(_ title: String) -> Bool {
        let prefix = "Approve edit: "
        guard title.hasPrefix(prefix), Brain.exists else { return false }
        let paths = title.dropFirst(prefix.count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let root = Brain.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return !paths.isEmpty
            && paths.allSatisfy { p in
                let r = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
                return r.hasPrefix(root) && !r.contains("/.git/") && !r.contains("/confidential/")
            }
    }

    /// The main conversation's id (the same id the engine's skill log uses).
    var mainSession: String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return proc?.isRunning == true && sessionID != nil
    }

    func stop() {
        lock.lock()
        let p = proc
        proc = nil
        sessionID = nil
        loaded = []
        sessionHandlers = [:]
        let w = waiting
        waiting = [:]
        lock.unlock()
        w.values.forEach { $0(["error": "stopped"]) }
        if let p, p.isRunning { p.terminate() }
    }

    static let gone = "engine stopped"
    private func ended(_ dead: Process) {
        lock.lock()
        guard proc === dead else {
            lock.unlock()
            return  // stopped on purpose (stop(), a restart): already handled there
        }
        proc = nil
        stdin = nil
        sessionID = nil
        loaded = []
        sessionHandlers = [:]
        let w = waiting
        waiting = [:]
        lock.unlock()
        w.values.forEach { $0(["error": ["message": Engine.gone]]) }
        onPhase?(.gone)  // crashed or killed: One shows it's getting ready and starts it again
    }

    /// Stops the engine and its background helper so the next start builds a fresh folder lock.
    /// The helper must go too: a new engine reuses a running one, which keeps the old lock.
    func stopForNewAccess() async {
        let previous = enginePID
        onPhase?(.starting)  // a restart is under way from this moment, not only once the new start begins
        stop()
        _ = await Task.detached { GatewayGuard.stopForNewAccess(previousEngine: previous) }.value
    }

    private var starting: Task<String?, Never>?
    /// Starts the engine once; anyone who asks while it's starting waits for that same start.
    func ensureStarted() async -> String? {
        if running { return nil }
        lock.lock()
        if let t = starting {
            lock.unlock()
            let r = await t.value
            return r == Engine.replaced ? await ensureStarted() : r  // Try again replaced it: wait for the new one
        }
        let t = Task { await self.start() }
        starting = t
        lock.unlock()
        let r = await t.value
        lock.lock()
        if starting == t { starting = nil }
        lock.unlock()
        return r == Engine.replaced ? await ensureStarted() : r
    }

    var isStarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return starting != nil
    }

    /// Try again while a start hangs: a fresh start replaces it (the old one gives up at its next step), and
    /// everyone waiting on the old one waits on this one instead.
    func startOver() async -> String? {
        lock.lock()
        let t = Task { await self.start() }
        starting = t
        lock.unlock()
        let r = await t.value
        lock.lock()
        if starting == t { starting = nil }
        lock.unlock()
        return r
    }

    static let replaced = "replaced by a new start"
    private var generation = 0
    private func stale(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen != generation
    }

    /// Is this process already inside a folder lock? (Then sandbox-exec refuses to apply another one.)
    nonisolated static var insideLock: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 71
    }

    /// Where the engine is, for One's "getting ready" state (StartupGate.swift): every start, every crash.
    enum Phase: Sendable {
        case starting, started
        case failed(String)
        case gone
    }
    var onPhase: (@Sendable (Phase) -> Void)?

    /// Every start goes through here (launch, a folder change, a new model, a crash), so One always knows
    /// when it's getting ready and when it's ready again.
    func start() async -> String? {
        onPhase?(.starting)
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let r = await startEngine(gen)
        if r == Engine.replaced { return r }  // a newer start speaks for itself
        onPhase?(r.map { .failed($0) } ?? .started)
        return r
    }

    private func startEngine(_ gen: Int) async -> String? {
        let previous = enginePID
        stop()
        await LocalModels.wakeIfSelected()
        guard let hp = Env.hermesPath else { return "Hermes isn't on this Mac yet." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hp)
        Engine.stopStrayGateway(previousEngine: previous, caller: "engine start")
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let profile = Access.profile()
        FolderWatch.engineStarted(profile: profile)
        p.arguments = ["-p", profile, hp, "acp"]
        if Env.selfTest && (Env.testEngine != nil || Engine.insideLock) {
            // A test run by the assistant itself is already inside the folder lock, where a second lock
            // can't be applied: the test engine runs under that same lock.
            p.executableURL = URL(fileURLWithPath: hp)
            p.arguments = ["acp"]
        }
        p.environment = Env.vars()
        let cwd = Brain.exists ? Brain.root : Env.support
        p.currentDirectoryURL = cwd
        let o = Pipe()
        let i = Pipe()
        p.standardOutput = o
        p.standardInput = i
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        if Env.selfTest {  // a check's engine: keep what it said, so a failed start can be read
            let f = Env.hermesHome.appendingPathComponent("logs/engine-stderr.log")
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: f.path, contents: nil)
            if let h = FileHandle(forWritingAtPath: f.path) { p.standardError = h }
        }
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.feed(d) }
        }
        // The engine went away by itself (crashed, killed): every call still waiting fails now instead of
        // hanging for up to 30 minutes, and the helpers it cut off start it again (Model.helperCutOff).
        p.terminationHandler = { [weak self] dead in self?.ended(dead) }
        // A write to an engine that just died must fail quietly: by default it kills One itself (SIGPIPE, exit 141),
        // which took every helper down with it (found by `make helpers-check`).
        signal(SIGPIPE, SIG_IGN)
        do { try p.run() } catch { return error.localizedDescription }
        lock.lock()
        proc = p
        stdin = i.fileHandleForWriting
        buf = Data()
        lock.unlock()
        let ini = await call("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()], timeout: 120)
        if stale(gen) { return Engine.replaced }
        guard ini["result"] != nil else { return "The assistant didn't start." }
        let dir = (Brain.exists ? Brain.root : Env.support).path
        // Pick up the same conversation after a restart, so it remembers what you were doing.
        if !Env.selfTest, let saved = UserDefaults.standard.string(forKey: "sessionID") {
            onText = nil
            onTool = nil
            let loaded = await loadSession(saved, dir, gen: gen)
            if stale(gen) { return Engine.replaced }
            if loaded {
                lock.lock()
                sessionID = saved
                lock.unlock()
                return nil
            }
            // Really gone: the next message carries the end of what was on screen (Model.send).
            lostConversation = true
        }
        let new = await newSession(dir, gen: gen)
        if stale(gen) { return Engine.replaced }
        guard let r = new["result"] as? [String: Any], let sid = r["sessionId"] as? String else {
            if Env.selfTest { print("session/new answered:", new) }  // tests: show why
            return "The assistant couldn't open a conversation."
        }
        lock.lock()
        sessionID = sid
        lock.unlock()
        if !Env.selfTest { UserDefaults.standard.set(sid, forKey: "sessionID") }
        return nil
    }

    /// Set when a saved conversation couldn't be reopened and a new one was started instead.
    var lostConversation = false

    /// Reopens a saved conversation. Right after a restart the background helper answers
    /// "draining: not_ready" for a few seconds; wait that out instead of starting a new chat
    /// (giving up on the first try made the assistant forget the conversation at every restart).
    private func loadSession(_ sid: String, _ dir: String, gen: Int? = nil) async -> Bool {
        for attempt in 0..<15 {
            if let gen, stale(gen) { return false }
            let r = await call("session/load", ["sessionId": sid, "cwd": dir, "mcpServers": [Any]()], timeout: 120)
            if r["error"] == nil, r["result"] != nil, !(r["result"] is NSNull) { return true }
            let e = "\(r["error"] ?? "")".lowercased()
            let notYet = ["draining", "not_ready", "starting", "unavailable", "timed out"].contains { e.contains($0) }
            guard notYet, attempt < 14 else { return false }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// Start a new conversation on purpose ("Start fresh"). Memory and notes stay.
    func startFresh() async -> Bool {
        if await ensureStarted() != nil { return false }
        let r = await newSession(Engine.workDir)
        guard let res = r["result"] as? [String: Any], let sid = res["sessionId"] as? String else { return false }
        lock.lock()
        sessionID = sid
        lock.unlock()
        lostConversation = false
        if !Env.selfTest { UserDefaults.standard.set(sid, forKey: "sessionID") }
        return true
    }

    /// Right after a cold start the engine's background helper can answer "draining" for a few
    /// seconds while it finishes its own startup; wait it out instead of failing the first message.
    private func newSession(_ dir: String, gen: Int? = nil) async -> [String: Any] {
        var r: [String: Any] = [:]
        for attempt in 0..<12 {
            if let gen, stale(gen) { break }
            r = await call("session/new", ["cwd": dir, "mcpServers": [Any]()], timeout: 120)
            let busy = "\(r["error"] ?? "")".lowercased().contains("draining")
            guard r["result"] == nil, busy, attempt < 11 else { break }
            try? await Task.sleep(for: .seconds(3))
        }
        return r
    }

    /// Sends one message; text streams through onText. Returns the stop reason or "error: …".
    func prompt(_ text: String, images: [String] = []) async -> String {
        lock.lock()
        let sid = sessionID
        lock.unlock()
        var id = sid
        if id == nil, await ensureStarted() == nil {
            lock.lock()
            id = sessionID
            lock.unlock()
        }
        guard let sid = id else { return "error: not started" }
        let r = await call(
            "session/prompt",
            [
                "sessionId": sid,
                "prompt": [["type": "text", "text": text]] + images.map { ["type": "image", "data": $0, "mimeType": "image/jpeg"] },
            ], timeout: 900)
        if let res = r["result"] as? [String: Any] { return res["stopReason"] as? String ?? "end_turn" }
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        return "error: \(r["error"] ?? "no answer")"
    }

    /// After the engine's background helper died mid-turn: wait until it answers again, then send the
    /// same message once more. "Not ready yet" answers didn't run anything, so they're waited out.
    func promptAgain(_ text: String, images: [String] = []) async -> String {
        var stop = "error: not started"
        for attempt in 0..<20 {
            if !running { _ = await ensureStarted() }
            stop = await prompt(text, images: images)
            let e = stop.lowercased()
            let notYet = ["draining", "not_ready", "starting", "unavailable", "shutting down", "not started"].contains { e.contains($0) }
            guard e.hasPrefix("error"), notYet, attempt < 19 else { break }
            try? await Task.sleep(for: .seconds(3))
        }
        return stop
    }

    /// True when a turn failed because the background helper went away under it (not a real error).
    static func dropped(_ stop: String, text: String, gatewayBefore: pid_t?) -> Bool {
        if text.contains("Gateway shutting down") || text.contains("this turn was interrupted") { return true }
        guard stop.hasPrefix("error") else { return false }
        let e = stop.lowercased()
        if ["shutting down", "interrupted", "draining", "not_ready", "stopped"].contains(where: { e.contains($0) }) { return true }
        // A generic "Internal error" counts only if the gateway really changed or died during the turn.
        guard let g = gatewayBefore else { return false }
        return GatewayGuard.recordedPID() != g || kill(g, 0) != 0
    }

    /// A new background session for a helper.
    func openSession() async -> String? {
        if await ensureStarted() != nil { return nil }
        let r = await newSession(Engine.workDir)
        guard let res = r["result"] as? [String: Any], let sid = res["sessionId"] as? String else { return nil }
        lock.lock()
        loaded.insert(sid)
        lock.unlock()
        return sid
    }

    /// Picks the brain for one conversation (ACP session/set_model), before its first prompt. False if the engine said no.
    func setModel(_ sid: String, _ model: String, timeout: TimeInterval = 8) async -> Bool {
        let r = await call("session/set_model", ["sessionId": sid, "modelId": model], timeout: timeout)
        return r["error"] == nil && r["result"] != nil
    }

    /// A copy of a conversation (ACP session/fork): checks talk to the copy, never the original.
    func forkSession(_ sid: String) async -> String? {
        if await ensureStarted() != nil { return nil }
        let r = await call("session/fork", ["sessionId": sid, "cwd": Engine.workDir, "mcpServers": [Any]()], timeout: 120)
        guard let res = r["result"] as? [String: Any], let new = res["sessionId"] as? String else { return nil }
        lock.lock()
        loaded.insert(new)
        lock.unlock()
        return new
    }

    /// Reopen a helper's old conversation after a restart. False if the engine can't load it.
    func reopenSession(_ sid: String) async -> Bool {
        if await ensureStarted() != nil { return false }
        lock.lock()
        let isOpen = loaded.contains(sid)
        lock.unlock()
        if isOpen { return true }
        guard await loadSession(sid, Engine.workDir) else { return false }
        lock.lock()
        loaded.insert(sid)
        lock.unlock()
        return true
    }

    /// Talk to a helper's session (opening it again first if One restarted since).
    func promptSession(
        _ sid: String, _ text: String, images: [String] = [],
        onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String) -> Void
    ) async -> String {
        if await ensureStarted() != nil { return "error: not started" }
        lock.lock()
        let isOpen = loaded.contains(sid)
        lock.unlock()
        if !isOpen {
            guard await loadSession(sid, Engine.workDir) else { return "error: couldn't pick this job back up" }
            lock.lock()
            loaded.insert(sid)
            lock.unlock()
        }
        lock.lock()
        sessionHandlers[sid] = (onText, onTool)
        lock.unlock()
        let r = await call(
            "session/prompt",
            [
                "sessionId": sid,
                "prompt": [["type": "text", "text": text]] + images.map { ["type": "image", "data": $0, "mimeType": "image/jpeg"] },
            ], timeout: 1800)
        lock.lock()
        sessionHandlers[sid] = nil
        lock.unlock()
        if let res = r["result"] as? [String: Any] { return res["stopReason"] as? String ?? "end_turn" }
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        return "error: \(r["error"] ?? "no answer")"
    }

    /// What the engine prints when it takes a mid-turn message. Counted per session, never shown.
    static let steerAck = "⏩ Steer queued for the active turn"
    private var steerAcks: [String: Int] = [:]
    /// Anything at all came back on the main conversation (words, thoughts, steps): its turn is under way.
    var onActivity: (@Sendable () -> Void)?
    /// Every step event on any conversation (which one, what kind, the step's id and status): helpers' progress.
    var onPulse: (@Sendable (_ sid: String, _ kind: String, _ call: String?, _ status: String?) -> Void)?

    /// Hands a message to the turn running on a session, without stopping it or starting a second one:
    /// the engine's own mid-turn steer, which puts it right after the latest step ("[OUT-OF-BAND USER
    /// MESSAGE …]"). If it lands after the last step, the engine answers it before the turn ends.
    /// "taken": the running turn took it. "ran": no turn was left, so the engine answered it as its own
    /// (its words stream like any reply). "error: …": nothing was delivered.
    func steer(_ text: String, session: String? = nil) async -> String {
        lock.lock()
        let sid = session ?? sessionID
        let before = sid.map { steerAcks[$0, default: 0] } ?? 0
        lock.unlock()
        guard let sid else { return "error: not started" }
        let r = await call("session/prompt", ["sessionId": sid, "prompt": [["type": "text", "text": "/steer " + text]]], timeout: 1800)
        if let e = r["error"] as? [String: Any] { return "error: \(e["message"] ?? "unknown")" }
        if let e = r["error"] { return "error: \(e)" }
        lock.lock()
        let after = steerAcks[sid, default: 0]
        lock.unlock()
        return after > before ? "taken" : "ran"
    }

    func cancel(session sid: String) {
        write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sid]])
    }

    func cancel() {
        lock.lock()
        let sid = sessionID
        lock.unlock()
        guard let sid else { return }
        write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sid]])
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async -> [String: Any] {
        await withCheckedContinuation { cont in
            lock.lock()
            nextID += 1
            let id = nextID
            lock.unlock()
            let once = Box(false)
            let finish: (Any) -> Void = { v in
                self.lock.lock()
                let first = !once.v
                once.v = true
                self.lock.unlock()
                if first { cont.resume(returning: v as? [String: Any] ?? [:]) }
            }
            lock.lock()
            waiting[id] = finish
            lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock()
                let f = self.waiting.removeValue(forKey: id)
                self.lock.unlock()
                f?(["error": "timed out"])
            }
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        lock.lock()
        let h = stdin
        lock.unlock()
        wlock.lock()
        try? h?.write(contentsOf: d + Data("\n".utf8))  // throws (never raises) if the engine is gone
        wlock.unlock()
    }

    private func feed(_ d: Data) {
        lock.lock()
        buf.append(d)
        var lines: [Data] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            lines.append(Data(buf[buf.startIndex..<nl]))
            buf = Data(buf[buf.index(after: nl)...])
        }
        lock.unlock()
        for l in lines { if let j = try? JSONSerialization.jsonObject(with: l) as? [String: Any] { handle(j) } }
    }

    private func handle(_ m: [String: Any]) {
        let method = m["method"] as? String
        if method == nil, let id = m["id"] as? Int {
            lock.lock()
            let f = waiting.removeValue(forKey: id)
            lock.unlock()
            f?(m)
            return
        }
        let params = m["params"] as? [String: Any] ?? [:]
        if method == "session/update", let u = params["update"] as? [String: Any] {
            let usid = params["sessionId"] as? String
            lock.lock()
            let mainID = sessionID
            let hh = usid.flatMap { sessionHandlers[$0] }
            lock.unlock()
            let toMain = usid == nil || usid == mainID
            if !toMain && hh == nil { return }  // e.g. history replayed while a session reopens
            let textCB = toMain ? onText : hh?.text
            let toolCB = toMain ? onTool : hh?.tool
            let kind = u["sessionUpdate"] as? String
            if let s = usid, !toMain { onPulse?(s, kind ?? "", u["toolCallId"] as? String, u["status"] as? String) }
            if toMain, ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].contains(kind ?? "") { onActivity?() }
            switch kind {
            case "agent_message_chunk":
                guard let c = u["content"] as? [String: Any], let t = c["text"] as? String else { break }
                if t.hasPrefix(Engine.steerAck), let s = usid ?? mainID {
                    lock.lock()
                    steerAcks[s, default: 0] += 1
                    lock.unlock()
                    break
                }
                textCB?(t)
            case "tool_call":
                if let t = u["title"] as? String { toolCB?(t) }
            default: break
            }
            return
        }
        guard let id = m["id"] else { return }  // a request from Hermes to us
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
            if let ok = opts.first(where: { $0.0 == "allow_once" || $0.0.hasPrefix("allow") }) {
                reply(ok.0)
                return
            }
            if let ask = onPermission { ask(title, opts, reply) } else { reply(nil) }
        } else {
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported by One"]])
        }
    }
}
