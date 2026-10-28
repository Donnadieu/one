import Foundation

// MARK: - `One --chrome-check`: does the copy of their own Chrome really work? Plain words the assistant reads out.

/// Connections › Browser › Chrome copies the sign-ins of their own Chrome (MyChrome). This checks the
/// result end to end without reading their Chrome (the assistant runs it inside the folder lock):
/// what the last copy found (`browser/my-chrome.json`: profile, cookie count, well-known sign-ins,
/// names only) against what the hidden browser can really read now. Never prints a cookie value.
enum ChromeCheck {
    /// The copy's report, written by `MyChrome.sync()`.
    static var report: [String: Any]? {
        (try? Data(contentsOf: MyChrome.reportFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Hermes's and the copier's reasons, in words a regular person understands.
    static func plain(_ why: String) -> String {
        let w = why.lowercased()
        if w.contains("no-chrome-folder") || w.contains("was not found") {
            return "I couldn't find Chrome's saved sign-ins on this Mac. Open Chrome once, sign in to your sites there, then ask me again."
        }
        if w.contains("chrome-folder-unreadable") || w.contains("operation not permitted") {
            return
                "I wasn't allowed to read Chrome's folder from here. Ask me to use your Chrome; One does the copy itself."
        }
        if w.contains("lock") {
            return
                "Chrome was busy saving your sign-ins, so I couldn't copy them this time. Ask me to try again in a moment. You don't need to quit Chrome."
        }
        if w.contains("no space") || w.contains("disk full") {
            return "Your Mac's disk is full, so I couldn't copy Chrome's sign-ins. Free up some space, then ask me to try again."
        }
        if w.contains("real_profile_pin") {
            return "I was set to copy a Chrome profile that isn't on this Mac anymore. Ask me to try again and I'll copy the one you use now."
        }
        if w.contains("hidden browser is still open") { return "My hidden browser was busy. Ask me to try again in a moment." }
        if w.contains("missing a piece") { return why + " Updating One fixes it." }
        let short = why.split(whereSeparator: \.isNewline).first.map(String.init) ?? why
        return "I couldn't copy Chrome's sign-ins. What went wrong: \(short.prefix(160))"
    }

    static let keychainHelp =
        "Your Mac didn't let Chrome unlock your saved sign-ins. It asks once, in a box about \u{201C}Chrome Safe Storage\u{201D} (it can hide behind other windows), and it got Deny or no answer. Ask me to try again; when your Mac asks, type your Mac password and click Always Allow."

    struct Result {
        var ok: Bool
        var lines: [String]
        var code: Int32
    }

    /// The live view: which of the copied sign-ins the hidden browser can really use.
    static func evaluate(report r: [String: Any]?, live: [[String: Any]]?, connected: Bool, otherBrowser: Bool) -> Result {
        let how = "Ask me to use your Chrome and I'll connect it right here."
        guard connected else {
            if otherBrowser {
                return Result(
                    ok: false, lines: ["I'm using a hidden browser of my own, not your Chrome, so your Chrome sign-ins aren't there. " + how], code: 2
                )
            }
            return Result(ok: false, lines: ["Your Chrome isn't connected yet. " + how], code: 2)
        }
        guard let r else {
            return Result(ok: false, lines: ["Your Chrome is connected, but I have no record of the copy yet. Ask me to connect it again."], code: 1)
        }
        if r["ok"] as? Bool != true {
            return Result(ok: false, lines: ["The last copy of your Chrome didn't work. " + plain((r["error"] as? String) ?? "unknown")], code: 1)
        }
        let signs = (r["signs"] as? [[String: Any]]) ?? []
        let copied = (r["cookies"] as? Int) ?? 0
        var head = "Your Chrome is connected"
        if let t = (r["checked"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            head += ". I copied its sign-ins \(t.formatted(date: .abbreviated, time: .shortened))"
        }
        if let n = r["profile_name"] as? String, !n.isEmpty, ((r["profiles"] as? [Any])?.count ?? 1) > 1 {
            head += " from your Chrome profile \u{201C}\(n)\u{201D}"
        }
        guard let live else {
            return Result(ok: false, lines: [head + ".", "My hidden browser is starting up right now. Ask me again in a minute."], code: 1)
        }
        let readable = live.filter { !(($0["value"] as? String) ?? "").isEmpty }
        func has(_ s: [String: Any]) -> Bool {
            let d = ((s["domain"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return readable.contains { c in
                (c["name"] as? String) == (s["name"] as? String)
                    && ((c["domain"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) == d
            }
        }
        let here = signs.filter(has).compactMap { $0["site"] as? String }
        let missing = signs.filter { !has($0) }.compactMap { $0["site"] as? String }
        // Copied sign-ins, but the hidden browser can read almost none of them: the Keychain said no.
        if copied >= 20 && (readable.count * 10 < copied) && (signs.isEmpty || here.isEmpty) {
            return Result(ok: false, lines: [head + ".", keychainHelp], code: 1)
        }
        var lines = [head + "."]
        if here.isEmpty {
            lines.append(
                "It works, but your Chrome wasn't signed in to any of the sites I check (Google, Amazon, Facebook, LinkedIn, GitHub and others). Sign in to them in Chrome, then ask me to refresh the copy."
            )
        } else {
            lines.append("Signed in, in my hidden browser: " + here.joined(separator: ", ") + ".")
        }
        if !missing.isEmpty { lines.append("Copied but not working here yet: " + missing.joined(separator: ", ") + ". Ask me to refresh the copy.") }
        lines.append("Other sites you're signed in to in Chrome work too; I only list the ones I know how to check.")
        return Result(ok: true, lines: lines, code: 0)
    }

    static func current() async -> Result {
        let p = BrowserKeeper.plan
        let live: [[String: Any]]? = MyChrome.isCopy(p) ? await BrowserKeeper.cookies(p!.port) : nil
        return evaluate(report: report, live: live, connected: MyChrome.isCopy(p), otherBrowser: p != nil)
    }

    /// Right after Connect: nil when the sign-ins really work, else what to do, in plain words.
    static func verify() async -> String? {
        var r = await current()
        // The browser may still be loading its cookies; give it a few seconds before deciding.
        for _ in 0..<6 where !r.ok {
            try? await Task.sleep(for: .seconds(2))
            r = await current()
        }
        return r.ok ? nil : r.lines.last
    }

    /// `One --chrome-check`. Exit 0 = works, 1 = something to fix (said in the text), 2 = not connected.
    static func run() async -> Int32 {
        let r = await current()
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        print("Chrome check (One \(v)): " + (r.ok ? "working" : r.code == 2 ? "not connected" : "needs a fix"))
        r.lines.forEach { print($0) }
        return r.code
    }

    /// `One --chrome-connect`: the Connect tap without the window (tests; it must run outside the folder lock).
    static func connectFromCommandLine() async -> Int32 {
        if let e = await MyChrome.connect() { print("Connect said: " + e) } else { print("Connect: done") }
        return await run()
    }
}
