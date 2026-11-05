import CoreGraphics
import Foundation
import Security

// MARK: - The off-Mac locked copy (opt-in, storage plan 3g and step 9)

/// Each night, one Apple Archive of the newest instant copy, locked with a key (`aa archive … -key-value`, the
/// profile `hkdf_sha256_aesctr_hmac__symmetric__none`), goes into `iCloud Drive/One Backups/One brain <date>.aea`.
/// The archive is locked as it's written (no readable file ever lands in iCloud). Kept: the 14 newest plus the
/// newest of each month for a year; only files named like that are ever removed.
/// The key: 32 random bytes in the login Keychain (service "One backup key", account = the Mac user), never in a
/// file, never printed. The recovery code (the key in letters and digits) is written once, on first turn-on,
/// to `<support>/backup/recovery-code.txt` (owner-only); One's home card shows it inside One's window and the file
/// goes away once they say they saved it.
enum Offsite {
    static let service = "One backup key"
    static let defaultsKey = "offsiteBackup"
    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    static var folder: URL { Shared.cloud.appendingPathComponent("One Backups", isDirectory: true) }
    static var available: Bool { Shared.available }
    static var home: URL {
        let u = Env.support.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }
    static var codeFile: URL { home.appendingPathComponent("recovery-code.txt") }
    /// Left by `One --offsite on` when it can't reach the Keychain (run by the assistant, inside the folder lock):
    /// One's own app finishes turning the copy on within 5 minutes (`tend`).
    static var requestFile: URL { home.appendingPathComponent("turn-on.request") }
    static var statusFile: URL { home.appendingPathComponent("offsite.json") }
    /// Tests only: the key lives here instead of the Keychain.
    nonisolated(unsafe) static var testKey: Data?

    // MARK: the key

    static func storedKey() -> Data? {
        if Env.selfTest { return testKey ?? ProcessInfo.processInfo.environment["ONE_TEST_BACKUP_KEY"].flatMap { Data(base64Encoded: $0) } }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return d
    }
    static func save(_ k: Data) -> Bool {
        if Env.selfTest {
            testKey = k
            return true
        }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: NSUserName(),
            kSecAttrLabel as String: service, kSecValueData as String: k,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func newKey() -> Data? {
        var b = [UInt8](repeating: 0, count: 32)
        return SecRandomCopyBytes(kSecRandomDefault, 32, &b) == errSecSuccess ? Data(b) : nil
    }

    // MARK: the recovery code: the key in letters and digits people can type (no I, L, O, U)

    static let letters = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static func code(_ k: Data) -> String {
        var bits = 0
        var acc = 0
        var out = ""
        for b in k {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(letters[(acc >> (bits - 5)) & 31])
                bits -= 5
            }
            acc &= (1 << bits) - 1
        }
        if bits > 0 { out.append(letters[(acc << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { i in
            String(out.dropFirst(i).prefix(4))
        }.joined(separator: "-")
    }
    static func key(fromCode c: String) -> Data? {
        var acc = 0
        var bits = 0
        var out = Data()
        for ch in c.uppercased() where ch != "-" && ch != " " {
            let x: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard let v = letters.firstIndex(of: x) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((acc >> (bits - 8)) & 255))
                bits -= 8
                acc &= (1 << bits) - 1
            }
        }
        return out.count == 32 ? out : nil
    }

    // MARK: on and off

    /// Turns the nightly locked copy on. Returns the recovery-code file when a new key was made (only then).
    static func turnOn() -> Result<URL?, History.CopyError> {
        guard available else { return .failure(History.CopyError(text: "iCloud Drive isn't turned on for this Mac.")) }
        var made: URL?
        if storedKey() == nil {
            guard let k = newKey(), save(k) else {
                return .failure(History.CopyError(text: "I couldn't keep the lock's key in this Mac's Keychain."))
            }
            let text =
                "One backup recovery code\n\nSave this code in your password manager. Without it, the locked copy of your brain in iCloud "
                + "can't be opened on another Mac.\n\n\(code(k))\n"
            FileManager.default.createFile(atPath: codeFile.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            made = codeFile
        }
        on = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return .success(made)
    }
    /// The code still waiting to be saved, for the home card (inside One's window only).
    static var pendingCode: String? {
        guard let t = try? String(contentsOf: codeFile, encoding: .utf8) else { return nil }
        return t.split(separator: "\n").last.map(String.init)
    }
    static func codeSaved() { try? FileManager.default.removeItem(at: codeFile) }

    // MARK: the nightly copy

    static let filePattern = try! NSRegularExpression(pattern: #"^One brain (\d{4}-\d{2}-\d{2})\.aea$"#)
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func dateOf(_ name: String) -> Date? {
        guard let m = filePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let r = Range(m.range(at: 1), in: name) else {
            return nil
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(name[r]))
    }

    /// Makes tonight's locked copy now: a fresh instant copy if anything changed, archived and locked straight into
    /// a file in One's folder, then moved into iCloud Drive in one step. Returns the file in iCloud.
    static func runNow(now: Date = Date()) -> Result<URL, History.CopyError> {
        guard available else { return .failure(History.CopyError(text: "iCloud Drive isn't turned on for this Mac.")) }
        guard let k = storedKey() else {
            return .failure(History.CopyError(text: "The lock's key isn't in this Mac's Keychain. Turn the copy on first."))
        }
        let snap: URL
        switch History.take(force: false, now: now) {
        case .success(let t): snap = t.url
        case .failure(let e): return .failure(e)
        }
        let fm = FileManager.default
        let tmp = home.appendingPathComponent("partial-\(getpid()).aea")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let r = aa(["archive", "-d", snap.path, "-o", tmp.path, "-key-value", "base64:" + k.base64EncodedString()])
        guard r.code == 0, fm.fileExists(atPath: tmp.path) else {
            return .failure(History.CopyError(text: "The locked copy didn't finish (\(r.err))."))
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("One brain \(day(now)).aea")
        try? fm.removeItem(at: out)
        do { try fm.moveItem(at: tmp, to: out) } catch { return .failure(History.CopyError(text: "I couldn't put the locked copy in iCloud Drive.")) }
        prune(now: now)
        writeStatus(["day": day(now), "file": out.lastPathComponent, "time": ISO8601DateFormatter().string(from: now)])
        History.log("locked copy \(out.lastPathComponent)")
        return .success(out)
    }

    /// Which locked copies stay: the 14 newest, plus the newest of each month for the last 12 months.
    static func keep(_ names: [String], now: Date) -> Set<String> {
        let dated = names.compactMap { n in dateOf(n).map { (n, $0) } }.sorted { $0.1 > $1.1 }
        var keep = Set(dated.prefix(14).map(\.0))
        var months = Set<DateComponents>()
        let cal = Calendar(identifier: .gregorian)
        for (n, d) in dated where now.timeIntervalSince(d) <= 366 * 86_400 {
            if months.insert(cal.dateComponents([.year, .month], from: d)).inserted { keep.insert(n) }
        }
        return keep
    }
    @discardableResult
    static func prune(now: Date = Date()) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let keep = keep(names, now: now)
        return names.filter { dateOf($0) != nil && !keep.contains($0) }.filter {
            (try? FileManager.default.removeItem(at: folder.appendingPathComponent($0))) != nil
        }
    }

    /// From the hourly loop: once a day, between 2 and 5 in the morning, or the first quiet 10 minutes after that.
    static func tend(now: Date = Date()) {
        if FileManager.default.fileExists(atPath: requestFile.path), case .success = turnOn() {
            try? FileManager.default.removeItem(at: requestFile)
            History.log("locked copy turned on (asked from a chat); recovery code waiting on Home")
        }
        guard on, available else { return }
        let s = status()
        if s["day"] as? String == day(now) { return }
        if let t = (s["tried"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }), now.timeIntervalSince(t) < 3600 { return }
        let hour = Calendar.current.component(.hour, from: now)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard hour >= 2, hour < 5 || idle >= 600 else { return }  // the Keychain is only read once it's really time
        if case .failure(let e) = runNow(now: now) {
            var st = s
            st["tried"] = ISO8601DateFormatter().string(from: now)
            st["error"] = e.text
            writeStatus(st)
            History.log("locked copy failed: \(e.text)")
        }
    }
    static func status() -> [String: Any] {
        guard let d = try? Data(contentsOf: statusFile) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    static func writeStatus(_ s: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) { try? d.write(to: statusFile) }
    }

    // MARK: opening one again

    /// Unlocks `archive` into the empty folder `dir` and counts the files against the copy's own list.
    static func verify(_ archive: URL, into dir: URL, key k: Data) -> (ok: Bool, lines: [String]) {
        let fm = FileManager.default
        if TestWorld.isProduction(dir) { return (false, ["Pick a scratch folder outside Documents and One's own folder."]) }
        if let items = try? fm.contentsOfDirectory(atPath: dir.path), !items.isEmpty { return (false, ["\(dir.path) isn't empty."]) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = aa(["extract", "-d", dir.path, "-i", archive.path, "-key-value", "base64:" + k.base64EncodedString()])
        guard r.code == 0 else { return (false, ["It didn't open with this key (\(r.err))."]) }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
            let meta = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let parts = meta["parts"] as? [[String: Any]]
        else { return (false, ["It opened, but the list of what's inside is missing."]) }
        var ok = true
        var lines: [String] = []
        for p in parts {
            guard let n = p["name"] as? String, let want = p["files"] as? Int else { continue }
            var got = 0
            History.walk(dir.appendingPathComponent(n)) { _, _ in got += 1 }
            ok = ok && got == want
            lines.append("\(n): \(got) files (the copy listed \(want)) \(got == want ? "✓" : "✗")")
        }
        lines.append(ok ? "Everything is there: \(parts.count) parts." : "Some files are missing.")
        return (ok, lines)
    }

    // MARK: command line

    /// `One --offsite on|off|status|now|verify <archive> <empty folder> [--code <recovery code>]`.
    static func cli(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--offsite") else { return nil }
        let verb = k + 1 < args.count ? args[k + 1] : "status"
        switch verb {
        case "on":
            switch turnOn() {
            case .failure(let e) where storedKey() == nil && available:
                // Inside the folder lock the Keychain is out of reach: One's own app finishes it.
                FileManager.default.createFile(atPath: requestFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                print("Asked One to turn it on: it needs this Mac's Keychain, which only One itself can reach (\(e.text))")
                print("While One is open it finishes within 5 minutes; the recovery code then waits in \(codeFile.path).")
                return 0
            case .failure(let e):
                print(e.text)
                return 1
            case .success(let f):
                print("On. Each night One puts one locked copy of your brain in iCloud Drive › One Backups.")
                if let f { print("Your recovery code is in \(f.path). Save it in your password manager.") }
                return 0
            }
        case "off":
            on = false
            print("Off. The locked copies already in iCloud Drive › One Backups stay until you delete them.")
            return 0
        case "now":
            switch runNow() {
            case .failure(let e):
                print(e.text)
                return 1
            case .success(let u):
                print(u.path)
                return 0
            }
        case "verify":
            guard k + 3 < args.count else {
                print("Usage: One --offsite verify <archive> <empty folder> [--code <recovery code>]")
                return 2
            }
            let typed = args.firstIndex(of: "--code").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            guard let lock = typed != nil ? typed.flatMap({ Offsite.key(fromCode: $0) }) : storedKey() else {
                print(
                    typed == nil
                        ? "The lock's key isn't in this Mac's Keychain. Add --code with your recovery code."
                        : "That recovery code doesn't read right.")
                return 1
            }
            let r = verify(URL(fileURLWithPath: args[k + 2]), into: URL(fileURLWithPath: args[k + 3]), key: lock)
            r.lines.forEach { print($0) }
            return r.ok ? 0 : 1
        default:
            let copies = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { dateOf($0) != nil }.sorted()
            print("Locked copy in iCloud: \(on ? "on" : "off")")
            print("iCloud Drive: \(available ? "available" : "not turned on")")
            print("Key in this Mac's Keychain: \(storedKey() == nil ? "no" : "yes")")
            print("Copies: \(copies.count)\(copies.last.map { ", newest \($0)" } ?? "")")
            if let e = status()["error"] as? String { print("Last try: \(e)") }
            if FileManager.default.fileExists(atPath: codeFile.path) { print("Recovery code waiting to be saved: \(codeFile.path)") }
            return 0
        }
    }

    static func aa(_ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        p.arguments = args
        let e = Pipe()
        p.standardError = e
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, error.localizedDescription) }
        let data = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let err = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (p.terminationStatus, err)
    }
}
