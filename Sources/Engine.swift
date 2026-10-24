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

    /// Hermes keeps a background helper per home; restart it so it picks up the current folder limits.
    static func stopStrayGateway() {
        let f = Env.hermesHome.appendingPathComponent("gateway.pid")
        guard let d = try? Data(contentsOf: f),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let pid = j["pid"] as? Int, pid > 1
        else { return }
        kill(pid_t(pid), SIGTERM)
        usleep(900_000)
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

    private var starting: Task<String?, Never>?
    /// Starts the engine once; anyone who asks while it's starting waits for that same start.
    func ensureStarted() async -> String? {
        if running { return nil }
        lock.lock()
        if let t = starting {
            lock.unlock()
            return await t.value
        }
        let t = Task { await self.start() }
        starting = t
        lock.unlock()
        let r = await t.value
        lock.lock()
        starting = nil
        lock.unlock()
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
        let o = Pipe()
        let i = Pipe()
        p.standardOutput = o
        p.standardInput = i
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.feed(d) }
        }
        do { try p.run() } catch { return error.localizedDescription }
        lock.lock()
        proc = p
        stdin = i.fileHandleForWriting
        buf = Data()
        lock.unlock()
        let ini = await call("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()], timeout: 120)
        guard ini["result"] != nil else { return "The assistant didn't start." }
        let dir = (Brain.exists ? Brain.root : Env.support).path
        // Pick up the same conversation after a restart, so it remembers what you were doing.
        if !Env.selfTest, let saved = UserDefaults.standard.string(forKey: "sessionID") {
            onText = nil
            onTool = nil
            let r = await call("session/load", ["sessionId": saved, "cwd": dir, "mcpServers": [Any]()], timeout: 120)
            if r["error"] == nil, r["result"] != nil, !(r["result"] is NSNull) {
                lock.lock()
                sessionID = saved
                lock.unlock()
                return nil
            }
        }
        let new = await newSession(dir)
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

    /// Right after a cold start the engine's background helper can answer "draining" for a few
    /// seconds while it finishes its own startup; wait it out instead of failing the first message.
    private func newSession(_ dir: String) async -> [String: Any] {
        var r: [String: Any] = [:]
        for attempt in 0..<12 {
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
            let r = await call("session/load", ["sessionId": sid, "cwd": Engine.workDir, "mcpServers": [Any]()], timeout: 120)
            guard r["error"] == nil, r["result"] != nil, !(r["result"] is NSNull) else { return "error: couldn't pick this job back up" }
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
        h?.write(d + Data("\n".utf8))
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
            switch u["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if let c = u["content"] as? [String: Any], let t = c["text"] as? String { textCB?(t) }
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
