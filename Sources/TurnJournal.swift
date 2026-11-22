import Foundation
import SQLite3

// MARK: - What they sent is never lost to a restart (main chat, Next up, taps)
//
// Nov 10-22 2026: every engine stop mid-turn (an update install, a folder restart, One quitting or crashing) cut the turn
// in flight. The engine settled it "interrupted" and never ran it again ("this turn was interrupted and will not be run
// again. Send your message again"). One picked its helpers back up (HelperTrail), but the main chat's own retry lived in
// memory only (`runTurn`'s `promptAgain`) and so did every message waiting "Next up" (`followUps`, the outbox): when One
// itself went away with the engine, nothing on disk said they were never answered.
//
// Now a message to the main assistant is written here (`<support>/turns/pending.json`, fsync'd) before it goes to the
// engine, and so is everything waiting next up, including a choice tapped while the assistant or a helper was busy.
// When a turn really ends, its entry goes. At the next launch, once the engine is up (`resumeInterrupted`), what's left
// goes again ONCE: a turn the engine answered after all (One stopped first) shows that answer instead; one older than
// `fresh` is left alone; one cut twice already gets a plain line, never "send it again". The engine half is the plugin
// `tools/overlay/plugins/one-restart-replay` (the engine's own words become `RestartNotice.resumed`; a phone-chat
// message is kept and sent again by the engine itself).

/// The main assistant's turn in flight.
struct JournalTurn: Codable, Equatable {
    var c: Composed
    var hidden: Bool
    var at: Double  // when it went to the engine
    var session: String?
    var tries: Int  // pick-ups after a restart so far
}

struct TurnJournalFile: Codable {
    var main: JournalTurn?
    var queued: [FollowUp] = []
}

@MainActor
enum TurnJournal {
    static let maxTries = 2
    static let fresh: TimeInterval = 2 * 3600
    nonisolated static var file: URL { Env.support.appendingPathComponent("turns/pending.json") }
    static var allowed: Bool { Env.production || Env.selfTest }
    static var main: JournalTurn?
    /// What the last run left, read once; until it's been taken back (`Model.replayPending`) every write keeps it.
    static var boot: TurnJournalFile? = allowed ? read() : nil
    static var restored = false

    static func read(_ u: URL = file) -> TurnJournalFile? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(TurnJournalFile.self, from: d)
    }

    /// Written aside, flushed to the disk itself (F_FULLFSYNC), then renamed over the old one.
    static func write(_ j: TurnJournalFile, to u: URL = file) {
        guard let d = try? JSONEncoder().encode(j) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = u.deletingLastPathComponent().appendingPathComponent(".pending-\(getpid()).json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d) else { return }
        let fd = open(tmp.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        _ = rename(tmp.path, u.path)
    }

    static func save(_ m: Model) {
        guard allowed else { return }
        var j = TurnJournalFile(main: main, queued: m.followUps)
        if !restored, let b = boot {  // not taken back yet: never written over
            j.main = j.main ?? b.main
            j.queued = b.queued.filter { q in !j.queued.contains { $0.id == q.id } } + j.queued
        }
        write(j)
    }

    /// Before the turn goes to the engine. The same message again keeps its first time and its count.
    static func begin(_ c: Composed, hidden: Bool, tries: Int, model m: Model) {
        let same = main.map { $0.c.engine == c.engine } ?? false
        main = JournalTurn(
            c: c, hidden: hidden, at: same ? main!.at : Date().timeIntervalSince1970, session: Engine.shared.mainSession,
            tries: max(tries, same ? main!.tries : 0))
        save(m)
    }

    /// The turn is over. Kept only when the engine went away under it (its pick-up comes at the next launch).
    static func end(stop: String, said: String, gateway: pid_t?, model m: Model) {
        guard main != nil else { return }
        if stop.hasPrefix("error"), Engine.dropped(stop, text: said, gatewayBefore: gateway) { return }
        main = nil
        save(m)
    }

    /// Their message is already on the screen (a pick-up after One opened again): it isn't shown twice.
    static func shown(_ c: Composed, in bubbles: [Bubble], again: Int) -> Bool {
        again > 0 && bubbles.last(where: { $0.fromMe })?.text == c.display
    }

    enum Pickup: Equatable {
        case again
        case answered(String)
        case stale
        case gaveUp
    }

    /// What to do with the turn the last run left in flight.
    static func pickup(_ t: JournalTurn, now: Double = Date().timeIntervalSince1970, db: URL = Env.hermesHome.appendingPathComponent("state.db"))
        -> Pickup
    {
        if let a = answer(t, db: db) { return .answered(a) }
        if now - t.at > fresh { return .stale }
        return t.tries >= maxTries ? .gaveUp : .again
    }

    /// The engine's own record: was this message answered after all (One stopped after the engine finished)?
    static func answer(_ t: JournalTurn, db: URL) -> String? {
        guard let sid = t.session, let d = ReadOnlyDB(db.path) else { return nil }
        let head = String(t.c.engine.prefix(60))
        var asked: Int64?
        d.each(
            "SELECT id FROM messages WHERE session_id=? AND role='user' AND timestamp>=? AND substr(content,1,?)=? ORDER BY id LIMIT 1",
            [sid, t.at - 5, head.unicodeScalars.count, head]
        ) { st in asked = sqlite3_column_int64(st, 0) }
        guard let asked else { return nil }
        var reply: String?
        d.each(
            "SELECT content FROM messages WHERE session_id=? AND id>? AND role='assistant' AND finish_reason='stop' "
                + "AND coalesce(display_kind,'')='' AND length(content)>0 ORDER BY id LIMIT 1",
            [sid, Int(asked)]
        ) { st in reply = sqlite3_column_text(st, 0).map { String(cString: $0) } }
        guard let reply, !RestartNotice.cut(reply), !RestartNotice.has(reply) else { return nil }
        return reply
    }

    static func gaveUpLine(_ c: Composed) -> String {
        let t = c.typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return "One restarted twice while I was answering “\(t.count > 80 ? t.prefix(80) + "…" : t)”, so I stopped there. "
            + "Say “go on” and I'll pick it back up."
    }

    static func log(_ line: String) { Helpers.log("restart pick-up: \(line)") }
}

@MainActor
extension Model {
    /// Once per launch, when the engine is up: what the last run left unanswered goes again, once, in order, ahead of
    /// anything sent since. Helpers pick themselves back up (HelperTrail); a message that went into a helper's cut turn
    /// rides with that pick-up (`Helper.pending`), so it's never sent twice.
    func replayPending() {
        guard TurnJournal.allowed, !TurnJournal.restored else { return }
        let saved = TurnJournal.boot ?? TurnJournalFile()
        TurnJournal.restored = true
        TurnJournal.boot = nil
        var back: [FollowUp] = []
        if let t = saved.main {
            switch TurnJournal.pickup(t) {
            case .again:
                var f = FollowUp(c: t.c, helper: nil, hidden: t.hidden)
                f.tries = t.tries + 1
                back.append(f)
                TurnJournal.log("sent again (\(f.tries)): \(t.c.typed.prefix(80))")
            case .answered(let reply):
                let r = Helpers.strip(reply)
                if !bubbles.contains(where: { !$0.fromMe && $0.text == r }) { bubbles.append(Bubble(fromMe: false, text: r)) }
                TurnJournal.log("answered before One stopped: \(t.c.typed.prefix(80))")
            case .stale: TurnJournal.log("too old to send again: \(t.c.typed.prefix(80))")
            case .gaveUp:
                if !t.hidden { bubbles.append(Bubble(fromMe: false, text: TurnJournal.gaveUpLine(t.c))) }
                TurnJournal.log("cut \(t.tries + 1) times, not sent again: \(t.c.typed.prefix(80))")
            }
        }
        TurnJournal.main = nil
        for var f in saved.queued where !followUps.contains(where: { $0.id == f.id }) {
            if let hid = f.helper {
                guard let h = helpers.first(where: { $0.id == hid }), h.stoppedByYou != true else { continue }
                if f.state == .sent, (h.pending ?? "").contains(f.engine) { continue }  // goes with its pick-up
            }
            f.state = .next  // it may not have been seen
            back.append(f)
        }
        guard !back.isEmpty else { return TurnJournal.save(self) }
        followUps.insert(contentsOf: back, at: 0)
        outbox.insert(contentsOf: back.filter { $0.helper == nil }.map { .message($0.id) }, at: 0)
        TurnJournal.save(self)
        sendWaiting()
    }
}

/// The engine half (`tools/overlay/plugins/one-restart-replay`), installed at every engine start next to the stop plugin
/// (`StopPlugin.sync` calls `sync`). Takes effect at the engine's next start.
enum RestartReplayPlugin {
    static let plugin = "one-restart-replay"
    static var pluginDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(plugin)", isDirectory: true) }

    @discardableResult static func installPlugin(from src: URL? = Bundle.main.url(forResource: plugin, withExtension: nil)) -> Bool {
        Messenger.installMissed(from: src, name: plugin)
    }

    static func sync() async {
        let ok = installPlugin()
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for f in Messenger.missedFixes(cfg, plugins: [plugin]).filter({ $0[2] != Messenger.keepQueued }) {
            let (code, out) = await hermesRun(f)
            if code != 0 { BrowserGuard.log("restart pick-up: couldn't set \(f[2]): \(out.suffix(200))") }
        }
        if !ok { BrowserGuard.log("restart pick-up: the one-restart-replay plugin isn't in this copy of One") }
    }
}
