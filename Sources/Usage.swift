import Foundation
import SQLite3

// MARK: - What each job used of the AI plan's week

/// Two layers (design: docs/design/safety-features.md, "2. A usage budget per job"):
/// 1. exact per job, from the engine's `state.db`: the input, output and cache tokens of a helper's conversation and
///    every conversation under it (its sub-helpers), weighted like the price list into "units";
/// 2. the plan's own meter (the week's % used, with its reset time), read through the engine's own code
///    (`tools/usage_meter.py`) every 5 minutes while something works. Units per 1% of the week = units One sent
///    between two readings ÷ how much the week's % moved (median of the last 10), kept in `Support/One/usage.json`.
/// A job's share of the week = its units ÷ that. Until there is a measured number it uses Nov 9's (marked "about").
/// The plan's meter also counts use outside One (Claude Code, claude.ai), so a job's share is One's own use.
enum Usage {
    /// Weights from the price list: output 5×, writing the cache 1.25×, reading it 0.1× an input token.
    static func units(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) -> Double {
        input + 5 * output + 1.25 * cacheWrite + 0.1 * cacheRead
    }
    static let sum = "SUM(input_tokens + 5 * output_tokens + 1.25 * cache_write_tokens + 0.1 * cache_read_tokens)"
    static var db: URL { Env.hermesHome.appendingPathComponent("state.db") }

    /// A helper's conversation and every one under it (sub-helpers, theirs), in units. Read only.
    static func tree(_ sid: String, db: URL = Usage.db) -> Double {
        guard let d = ReadOnlyDB(db.path) else { return 0 }
        var v = 0.0
        d.each(
            "WITH RECURSIVE t(id) AS (SELECT ? UNION SELECT s.id FROM sessions s JOIN t ON s.parent_session_id = t.id) "
                + "SELECT \(sum) FROM sessions WHERE id IN (SELECT id FROM t)", [sid]
        ) { st in v = ReadOnlyDB.num(st, 0) }
        return v
    }
    /// Everything One ever sent, in units (the meter's calibration compares how this moved with the week's %).
    static func total(db: URL = Usage.db) -> Double {
        guard let d = ReadOnlyDB(db.path) else { return 0 }
        var v = 0.0
        d.each("SELECT \(sum) FROM sessions") { st in v = ReadOnlyDB.num(st, 0) }
        return v
    }

    struct Reading: Codable, Equatable {
        var t: Double
        var provider: String
        var week: Double  // percent used, 0…100
        var reset: Double?
        var units: Double  // Usage.total() at that moment
    }
    struct Store: Codable, Equatable {
        var readings: [Reading] = []
        var perPercent: [Double] = []  // measured units per 1% of the week, newest last
    }
    /// Nov 9, 2026: "Finish NotArc" (16 conversations) was about 34.3 M units and about 27% of the week.
    static let defaultPerPercent = 1_270_000.0
    static var file: URL { Env.support.appendingPathComponent("usage.json") }
    static func load() -> Store {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }
    static func save(_ s: Store) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) } }

    /// A new meter reading: when the week moved by at least 1% since the last reading of the same plan (within
    /// 6 hours, and not across a reset), it gives one measured sample.
    static func add(_ r: Reading, to s: inout Store) {
        if let p = s.readings.last(where: { $0.provider == r.provider }), r.t - p.t < 6 * 3600, r.week - p.week >= 1,
            r.units > p.units
        {
            s.perPercent.append((r.units - p.units) / (r.week - p.week))
            if s.perPercent.count > 10 { s.perPercent.removeFirst(s.perPercent.count - 10) }
        }
        s.readings.append(r)
        if s.readings.count > 50 { s.readings.removeFirst(s.readings.count - 50) }
    }
    /// Units per 1% of the week: the median of what was measured, else Nov 9's number.
    static func perPercent(_ s: Store) -> (value: Double, measured: Bool) {
        let v = s.perPercent.filter { $0 > 0 }.sorted()
        guard !v.isEmpty else { return (defaultPerPercent, false) }
        return (v[v.count / 2], true)
    }
    /// A job's share of the week (0.08 = 8%).
    static func share(units: Double, _ s: Store) -> Double { units / perPercent(s).value / 100 }

    /// The plan's meter, read through the engine's own code (never in a check: Env.selfTest = no network).
    static func meter(_ provider: String) -> (week: Double, reset: Date?)? {
        guard !Env.selfTest, let py = enginePython(),
            let script = Bundle.main.url(forResource: "usage_meter", withExtension: "py")
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-I", script.path, provider, Env.engineDir.path]
        p.currentDirectoryURL = Env.engineDir
        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = Env.hermesHome.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(40)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate() }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ws = j["windows"] as? [[String: Any]],
            let w = ws.first(where: { ($0["label"] as? String)?.lowercased().contains("week") == true && ($0["scope"] as? String) != "model" }),
            let used = w["used"] as? Double
        else { return nil }
        return (used, (w["reset"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
    static func enginePython() -> String? {
        let base = Env.hermesHome.appendingPathComponent("installs")
        let fm = FileManager.default
        for i in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let envs = base.appendingPathComponent("\(i)/environments")
            for e in (try? fm.contentsOfDirectory(atPath: envs.path)) ?? [] {
                let py = envs.appendingPathComponent("\(e)/venv/bin/python").path
                if fm.isExecutableFile(atPath: py) { return py }
            }
        }
        return nil
    }
}
