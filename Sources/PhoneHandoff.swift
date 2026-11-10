import AppKit
import CryptoKit
import Foundation

// MARK: - Hand-offs from the phone (Claude Design "One Safety Features" 5, Direction A, Omar's pick Nov 9 2026)

/// A helper hit a step only the person can do (a code, a sign-in, a robot check) and they're away from the Mac:
/// One sends them a link in their phone chat that shows ONLY that one hidden-browser page, live, on their phone. They tap
/// through it there and the helper carries on (the engine's own hand-off waits on the same answer file).
///
/// Safety, in code:
/// - one page: One attaches to that one tab's own DevTools socket (never the browser's), streams its picture and
///   passes on only taps, scrolls, typed text and Enter/Backspace/Tab (`allowed`); anything else is dropped and
///   logged. If the tab goes to another site (not the step's own site or its sign-in hosts), the stream ends;
/// - a short life: the link works for 10 minutes, or until the step is done (Done, the page moved on, or answered
///   at the Mac); then the server and the tunnel stop and the phone chat message says it ended;
/// - one phone: the first phone to open it is the only one (PhoneServer refuses a second);
/// - sealed: everything on the wire is AES-GCM with a key that lives only in the link's `#` part, which browsers
///   never send to any server, so the tunnel or relay in between sees only noise;
/// - only to them: the link goes only to their own phone chat (TELEGRAM_HOME_CHANNEL), never a group;
/// - audit: `handoff/<id>.audit.jsonl` + `hermes/logs/one-handoff.log`: created, sent, opened (phone's browser),
///   each input's kind (a tap, "typed 6 characters", never the characters), navigations, ended (why).
/// Off until the Mac can reach the phone: the phone chat set up and a tunnel tool (`cloudflared`, free, no account) on this
/// Mac; without it the helper gives the site's own phone route, as before. (In the cloud a relay replaces the tunnel:
/// design doc, section 5.)
enum PhoneHandoff {
    static let life: TimeInterval = 600
    static let waitBeforeSending: TimeInterval = 60
    static let awayAfter: TimeInterval = 300
    static let keys: Set<String> = ["Enter", "Backspace", "Tab"]

    enum Input: Equatable {
        case tap(Double, Double)  // 0…1 of the picture
        case scroll(Double)
        case text(String)
        case key(String)
        case done, notNow
    }
    /// The only things a phone may send. Anything else = nil (dropped, logged).
    static func allowed(_ d: Data) -> Input? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = j["t"] as? String, j.count <= 3 else { return nil }
        switch t {
        case "tap":
            guard let x = j["x"] as? Double, let y = j["y"] as? Double, (0...1).contains(x), (0...1).contains(y) else { return nil }
            return .tap(x, y)
        case "scroll":
            guard let dy = j["dy"] as? Double, abs(dy) <= 3000 else { return nil }
            return .scroll(dy)
        case "text":
            guard let s = j["s"] as? String, !s.isEmpty, s.count <= 200, !s.contains(where: { $0.isNewline }) else { return nil }
            return .text(s)
        case "key":
            guard let k = j["k"] as? String, keys.contains(k) else { return nil }
            return .key(k)
        case "done": return .done
        case "notnow": return .notNow
        default: return nil
        }
    }
    /// What the audit says about an input: its kind only, never what was typed.
    static func auditWords(_ i: Input) -> String {
        switch i {
        case .tap(let x, let y): "tap at \(Int(x * 100))%,\(Int(y * 100))%"
        case .scroll: "scroll"
        case .text(let s): "typed \(s.count) characters"
        case .key(let k): "pressed \(k)"
        case .done: "tapped Done"
        case .notNow: "tapped Not now"
        }
    }
    /// The DevTools calls one input becomes, for a page `w`×`h` CSS pixels.
    static func cdp(_ i: Input, w: Double, h: Double) -> [(String, [String: Any])] {
        switch i {
        case .tap(let x, let y):
            let p: [String: Any] = ["x": x * w, "y": y * h, "button": "left", "clickCount": 1]
            return [
                ("Input.dispatchMouseEvent", p.merging(["type": "mouseMoved"]) { a, _ in a }),
                ("Input.dispatchMouseEvent", p.merging(["type": "mousePressed"]) { a, _ in a }),
                ("Input.dispatchMouseEvent", p.merging(["type": "mouseReleased"]) { a, _ in a }),
            ]
        case .scroll(let dy):
            return [("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": w / 2, "y": h / 2, "deltaX": 0, "deltaY": dy])]
        case .text(let s): return [("Input.insertText", ["text": s])]
        case .key(let k):
            let code: Int = k == "Enter" ? 13 : k == "Tab" ? 9 : 8
            let base: [String: Any] = ["key": k, "code": k, "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code]
            return [
                ("Input.dispatchKeyEvent", base.merging(["type": "rawKeyDown"]) { a, _ in a }),
                ("Input.dispatchKeyEvent", base.merging(["type": "keyUp"]) { a, _ in a }),
            ]
        case .done, .notNow: return []
        }
    }

    // MARK: The one page's site

    /// The registrable part of a host: "www.amazon.com" -> "amazon.com", "a.b.co.uk" -> "b.co.uk".
    static func site(_ host: String) -> String {
        let p = host.lowercased().split(separator: ".").map(String.init)
        guard p.count > 2 else { return p.joined(separator: ".") }
        let two = p.suffix(2).joined(separator: ".")
        let short = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "com.mx", "co.in"]
        return short.contains(two) ? p.suffix(3).joined(separator: ".") : two
    }
    /// Sign-in hosts a site's own steps go through.
    static let signIn: [String: Set<String>] = [
        "google.com": ["accounts.google.com"], "youtube.com": ["accounts.google.com"], "gmail.com": ["accounts.google.com"],
        "apple.com": ["appleid.apple.com", "idmsa.apple.com"], "icloud.com": ["appleid.apple.com", "idmsa.apple.com"],
        "microsoft.com": ["login.microsoftonline.com", "login.live.com"], "live.com": ["login.microsoftonline.com", "login.live.com"],
        "github.com": [], "amazon.com": [], "claude.ai": ["accounts.google.com"], "anthropic.com": ["accounts.google.com"],
    ]
    /// May the phone keep watching this page? Its own site, or that site's sign-in hosts. Anything else ends it.
    static func stays(_ url: URL, stepSite: String) -> Bool {
        guard let host = url.host?.lowercased() else { return url.scheme == "about" }
        if site(host) == stepSite { return true }
        return signIn[stepSite]?.contains(host) == true
    }

    // MARK: The link and the seal

    struct Link {
        let room: String  // 128 bits, hex: in the path
        let key: SymmetricKey  // 256 bits: only in the #fragment
        var keyText: String {
            key.withUnsafeBytes { Data($0) }.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        func url(base: String) -> String { base + "/h/" + room + "#k=" + keyText }
    }
    static func newLink() -> Link {
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Link(room: b.map { String(format: "%02x", $0) }.joined(), key: SymmetricKey(size: .bits256))
    }
    /// nonce (12) + sealed text + tag (16): what WebCrypto's AES-GCM opens with iv = the first 12 bytes.
    static func seal(_ d: Data, _ k: SymmetricKey) -> Data? { try? AES.GCM.seal(d, using: k).combined }
    static func open(_ d: Data, _ k: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: k)
    }

    // MARK: Audit

    static func audit(_ id: String, _ event: String, _ extra: [String: Any] = [:]) {
        var j: [String: Any] = ["t": Date().timeIntervalSince1970, "event": event]
        j.merge(extra) { a, _ in a }
        let line =
            ((try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? event) + "\n"
        let f = HumanStep.dir.appendingPathComponent("\(id).audit.jsonl")
        try? FileManager.default.createDirectory(at: HumanStep.dir, withIntermediateDirectories: true)
        append(line, to: f)
        append(
            "\(ISO8601DateFormatter().string(from: Date())) \(id) \(event)\(extra.isEmpty ? "" : " \(extra)")\n",
            to: Env.hermesHome.appendingPathComponent("logs/one-handoff.log"))
    }
    static func append(_ s: String, to f: URL) {
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? Data(s.utf8).write(to: f)
        }
    }

    // MARK: When to send

    /// Seconds since the last key, click or mouse move on this Mac.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// Send the link now? The step has waited a minute unanswered, or they're away from the Mac (or there's no screen).
    static func due(waited: TimeInterval, idle: Double, screen: Bool = NSScreen.main != nil) -> Bool {
        waited >= waitBeforeSending || idle >= awayAfter || !screen
    }
    static var tunnelTool: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var ready: Bool { Messenger.configured && (tunnelTool != nil) }
    static func message(title: String, site: String, kind: String) -> String {
        let what =
            kind == "code" ? "needs a code" : kind == "sign_in" ? "needs you to sign in" : kind == "check" ? "needs a quick check" : "needs you"
        return "\(site.capitalizedFirst) \(what) for \(title). Tap to open the page. Works once, for 10 minutes."
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A free, account-less tunnel to the loopback server for the life of one hand-off (`cloudflared tunnel --url`).
final class PhoneTunnel: @unchecked Sendable {
    private var p: Process?
    /// Starts it and returns its https address, or nil after 25 s.
    func start(port: UInt16, tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        self.p = p
        var seen = ""
        let deadline = Date().addingTimeInterval(25)
        let h = err.fileHandleForReading
        while Date() < deadline, p.isRunning {
            let d = h.availableData
            if d.isEmpty { break }
            seen += String(decoding: d, as: UTF8.self)
            if let r = seen.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                // Keep draining its output so it never blocks on a full pipe.
                DispatchQueue.global().async { while p.isRunning, !h.availableData.isEmpty {} }
                return String(seen[r])
            }
        }
        stop()
        return nil
    }
    func stop() {
        if let p, p.isRunning { p.terminate() }
        p = nil
    }
}
