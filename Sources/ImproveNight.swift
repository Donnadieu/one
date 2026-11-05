import CryptoKit
import Foundation

// MARK: - One gets better by itself, steps 2 and 3: what one night of review may change, and its undo
// The nightly review (the "Nightly review" routine, NightlyRoutine.swift) is an AI run with nobody watching. These
// rules hold it in code, not in its instructions:
// - before it starts, every folder it may edit (the brain's recipes One's engine reads, the assistant's notes) is
//   copied (APFS clones, `improve/snapshots/<date>/`) and every file's fingerprint is kept;
// - afterwards (`end`), what changed is compared with that copy: in "suggest" mode ANY change is put back; in "edit"
//   mode more than `max_edits_per_night` recipes (5), or one recipe changed more than `max_edits_per_skill` times (1),
//   puts the whole night back;
// - `undo` (\"Undo last night\") puts back exactly the files the night changed, and only those still as it left them;
// - `verdicts`: 7 days after a night, a recipe it changed whose jobs went worse (3+ jobs before and after) is put back.
// Design: Made by Iris, "2026-11-05 One gets better by itself - design.md", sections 3b, 4, 5, 6.

struct NightChange: Codable, Equatable {
    var root: String  // the snapshot's name for the folder ("0", "1", …)
    var rel: String  // path inside that folder
    var skill: String  // the recipe's folder name, or "notes" for the assistant's notes
    var before: String?  // fingerprint before the night (nil = the file didn't exist)
    var after: String?  // fingerprint after the night (nil = the night removed it)
    var undone: String?  // why and when it was put back
}

struct NightRecord: Codable {
    var date: String
    var mode: String
    var began: Double
    var ended: Double?
    var roots: [String: String]  // snapshot name → live folder
    var baseline: [String: [String: String]]  // snapshot name → (path inside → fingerprint)
    var changed: [NightChange] = []
    var note: String?
    var verdicts: [String: String]?  // recipe → what the 7-day check decided
}

enum ImproveNight {
    static var nightsDir: URL { Improve.dir.appendingPathComponent("nights", isDirectory: true) }
    static var snapsDir: URL { Improve.dir.appendingPathComponent("snapshots", isDirectory: true) }
    static var reviewDir: URL { Improve.dir.appendingPathComponent("review", isDirectory: true) }
    static func recordFile(_ date: String) -> URL { nightsDir.appendingPathComponent("\(date).json") }
    static func reviewFile(_ date: String) -> URL { reviewDir.appendingPathComponent("\(date).json") }

    /// The folders a night may edit: the recipes One's engine reads from the brain (assistant/skills and rooms that are
    /// neither private nor shared, `LearnedDirs.wanted`) and the assistant's notes. Never a private or shared room.
    /// The notes are only in it on edit nights (a suggestions-only night never touches them, so the day's own
    /// note-taking is never mistaken for the review's).
    static func editableRoots(mode: String = Improve.settings().mode) -> [URL] {
        LearnedDirs.wanted().map { URL(fileURLWithPath: $0, isDirectory: true) }
            + (mode == "edit" ? [Env.hermesHome.appendingPathComponent("memories", isDirectory: true)] : [])
    }

    // MARK: fingerprints

    static func fingerprint(_ f: URL) -> String? {
        guard let d = try? Data(contentsOf: f) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    /// Every plain file under `root` (no links followed, no hidden folders), path inside → fingerprint.
    static func scan(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.standardizedFileURL.path
        guard
            let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return out }
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, let h = fingerprint(f) else { continue }
            out[String(f.standardizedFileURL.path.dropFirst(base.count + 1))] = h
        }
        return out
    }
    static func skill(_ root: URL, _ rel: String) -> String {
        root.lastPathComponent == "memories" ? "notes" : String(rel.split(separator: "/").first ?? Substring(rel))
    }

    // MARK: records

    static func read(_ date: String) -> NightRecord? {
        guard let d = try? Data(contentsOf: recordFile(date)) else { return nil }
        return try? JSONDecoder().decode(NightRecord.self, from: d)
    }
    static func write(_ r: NightRecord) {
        try? FileManager.default.createDirectory(at: nightsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(r).write(to: recordFile(r.date), options: .atomic)
    }
    static func dates() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: nightsDir.path)) ?? []).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    // MARK: begin / end

    /// Copies every folder the night may edit and keeps each file's fingerprint. Runs again only if that night has
    /// no record yet.
    @discardableResult static func begin(date: String, now: Date = Date()) -> NightRecord {
        if let r = read(date), r.ended == nil { return r }
        let fm = FileManager.default
        let snap = snapsDir.appendingPathComponent(date, isDirectory: true)
        try? fm.removeItem(at: snap)
        try? fm.createDirectory(at: snap, withIntermediateDirectories: true)
        var roots: [String: String] = [:]
        var base: [String: [String: String]] = [:]
        for (i, root) in editableRoots().enumerated() where fm.fileExists(atPath: root.path) {
            let k = String(i)
            roots[k] = root.standardizedFileURL.path
            base[k] = scan(root)
            for rel in (base[k] ?? [:]).keys {
                let to = snap.appendingPathComponent(k).appendingPathComponent(rel)
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = History.clone(root.appendingPathComponent(rel).path, to.path)
            }
        }
        let r = NightRecord(
            date: date, mode: Improve.settings().mode, began: now.timeIntervalSince1970, roots: roots, baseline: base)
        write(r)
        prune(now: now)
        return r
    }

    /// Compares the edited folders with the night's copy and applies the limits. Safe to run twice.
    @discardableResult static func end(date: String, now: Date = Date()) -> NightRecord? {
        guard var r = read(date), r.ended == nil else { return read(date) }
        let s = Improve.settings()
        var changes: [NightChange] = []
        var newFolders: Set<String> = []
        for (k, path) in r.roots.sorted(by: { $0.key < $1.key }) {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let before = r.baseline[k] ?? [:]
            let after = scan(root)
            let had = Set(before.keys.map { skill(root, $0) })
            for rel in Set(before.keys).union(after.keys).sorted() where before[rel] != after[rel] {
                let name = skill(root, rel)
                // A whole new recipe folder is the filer or the person, never the review (it may not make recipes).
                guard had.contains(name) else {
                    newFolders.insert(name)
                    continue
                }
                changes.append(NightChange(root: k, rel: rel, skill: name, before: before[rel], after: after[rel]))
            }
        }
        r.changed = changes
        r.ended = now.timeIntervalSince1970
        let skills = Set(changes.map(\.skill))
        if r.mode != "edit", !changes.isEmpty {
            r.note = "suggestions only: \(changes.count) change(s) put back"
            putBack(&r, why: "suggestions-only night")
        } else if skills.count > s.maxEditsPerNight {
            r.note = "\(skills.count) recipes changed, over the limit of \(s.maxEditsPerNight): the whole night was put back"
            putBack(&r, why: "over the nightly limit")
        } else if let over = overPerSkill(skills, since: r.began, limit: s.maxEditsPerSkill) {
            r.note = "'\(over)' was changed more than \(s.maxEditsPerSkill) time(s): the whole night was put back"
            putBack(&r, why: "one recipe changed too often")
        } else {
            r.note = changes.isEmpty ? "nothing changed" : "\(skills.count) recipe(s) changed: \(skills.sorted().joined(separator: ", "))"
        }
        if !newFolders.isEmpty { r.note = (r.note ?? "") + "; new recipe folders left as they are: \(newFolders.sorted().joined(separator: ", "))" }
        write(r)
        return r
    }

    /// A recipe the engine's change log shows edited more often than allowed since `since`.
    static func overPerSkill(_ skills: Set<String>, since: Double, limit: Int) -> String? {
        let log = Env.hermesHome.appendingPathComponent("skills/.curator_ledger.jsonl")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        var n: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in text.split(separator: "\n").suffix(4000) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let name = j["skill"] as? String,
                skills.contains(name), let ts = j["ts"] as? String,
                let t = iso.date(from: ts) ?? plain.date(from: ts), t.timeIntervalSince1970 >= since
            else { continue }
            n[name, default: 0] += 1
        }
        return n.first { $0.value > limit }?.key
    }

    // MARK: putting things back

    /// Puts back every change of the night that is still as the night left it. The current version is kept first in
    /// `snapshots/<date>/put-back/<time>/`, so a put-back can be undone by hand too.
    static func putBack(_ r: inout NightRecord, why: String, only skill: String? = nil, now: Date = Date()) {
        let fm = FileManager.default
        let snap = snapsDir.appendingPathComponent(r.date, isDirectory: true)
        let aside = snap.appendingPathComponent("put-back/\(Int(now.timeIntervalSince1970))", isDirectory: true)
        for i in r.changed.indices where r.changed[i].undone == nil && (skill == nil || r.changed[i].skill == skill) {
            let c = r.changed[i]
            guard let path = r.roots[c.root] else { continue }
            let live = URL(fileURLWithPath: path).appendingPathComponent(c.rel)
            guard fingerprint(live) == c.after else {
                r.changed[i].undone = "left alone: changed again since"
                continue
            }
            if fm.fileExists(atPath: live.path) {
                let keep = aside.appendingPathComponent(c.root).appendingPathComponent(c.rel)
                try? fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = History.clone(live.path, keep.path)
            }
            if c.before != nil {
                let old = snap.appendingPathComponent(c.root).appendingPathComponent(c.rel)
                try? fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: live)
                _ = History.clone(old.path, live.path)
            } else {
                try? fm.removeItem(at: live)  // the night made it; its copy is kept aside above
            }
            r.changed[i].undone = "\(why), \(Improve.iso(now.timeIntervalSince1970))"
        }
    }

    /// "Undo last night": the newest night that changed something. Returns plain lines.
    static func undo(date: String? = nil, now: Date = Date()) -> [String] {
        let pick = date ?? dates().reversed().first { d in read(d)?.changed.contains { $0.undone == nil } == true }
        guard let d = pick, var r = read(d) else { return ["Nothing to undo: no night has changed anything that's still there."] }
        if r.ended == nil, let e = end(date: d, now: now) { r = e }
        let open = r.changed.filter { $0.undone == nil }
        guard !open.isEmpty else { return ["Nothing to undo for \(d): its changes were already put back."] }
        putBack(&r, why: "undo asked for", now: now)
        write(r)
        let back = Set(r.changed.filter { $0.undone?.hasPrefix("undo asked") == true }.map(\.skill)).sorted()
        let left = Set(r.changed.filter { $0.undone?.hasPrefix("left alone") == true }.map(\.skill)).sorted()
        var out = ["Put back what the review changed on \(d): \(back.isEmpty ? "nothing" : back.joined(separator: ", "))."]
        if !left.isEmpty { out.append("Left alone (changed again since): \(left.joined(separator: ", ")).") }
        return out
    }

    /// Keeps night copies for 30 days.
    static func prune(now: Date) {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(atPath: snapsDir.path)) ?? [] {
            guard let day = Improve.day(d), now.timeIntervalSince(day) > 30 * 86400 else { continue }
            try? fm.removeItem(at: snapsDir.appendingPathComponent(d))
        }
    }
}

extension Improve {
    /// The settings file the engine's learning cap reads; written with the defaults when it's missing.
    static func ensureSettings() {
        guard !FileManager.default.fileExists(atPath: settingsFile.path) else { return }
        save(ImproveSettings())
    }
}
