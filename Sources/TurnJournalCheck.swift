import Foundation
import SQLite3

/// Part of `One --test-helpers` (HelperCheck.run, preflight on every pull request): the pieces of "a restart never loses
/// what they sent" (TurnJournal.swift) that need no engine. The engine plugin's line is read as a cut-off everywhere One
/// looks; the journal is written whole and read back; a turn the last run left is sent again unless the engine's own
/// record shows it answered, it's stale, or it was cut twice already. End to end: tools/restart-replay-check.sh.
enum TurnJournalCheck {
    @MainActor
    static func run(_ check: (String, Bool) -> Void) {
        let line = RestartNotice.resumed
        check("the engine plugin's line is a cut-off", HelperEnd.of(stop: "end_turn", reply: "Working on it, halfway.\n\n" + line) == .cutOff)
        check(
            "an answer that only mentions it is still an answer",
            HelperEnd.of(stop: "end_turn", reply: "Earlier I said \"\(line)\" and then finished. Here it is: 42.") == .finished)
        check("the main chat's retry sees it too", Engine.dropped("end_turn", text: line, gatewayBefore: nil))
        check("and the nightly review counts it as a cut-off", StepCheck.cutOffOne == line)

        let dir = Env.support.appendingPathComponent("turn-journal-check", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let file = dir.appendingPathComponent("pending.json")
        let c = Composed(
            display: "Book the 7:40 flight", engine: "Book the 7:40 flight\n\n(One app note: x)", images: ["aGk="], typed: "Book the 7:40 flight")
        var tap = FollowUp(c: Composed(display: "Yes, go ahead", engine: "Yes, go ahead", images: [], typed: "Yes, go ahead"), helper: UUID())
        tap.state = .sent
        let now = Date().timeIntervalSince1970
        let t = JournalTurn(c: c, hidden: false, at: now - 30, session: "local-main", tries: 0)
        TurnJournal.write(TurnJournalFile(main: t, queued: [tap]), to: file)
        let back = TurnJournal.read(file)
        check("written whole and read back", back?.main == t && back?.queued == [tap] && back?.queued.first?.state == .sent)
        check("nothing half-written left beside it", (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count == 1)

        let db = dir.appendingPathComponent("state.db")
        check("not answered anywhere: it goes again", TurnJournal.pickup(t, now: now, db: db) == .again)
        var twice = t
        twice.tries = TurnJournal.maxTries
        check("cut twice already: a plain line instead", TurnJournal.pickup(twice, now: now, db: db) == .gaveUp)
        check("older than 2 hours: left alone", TurnJournal.pickup(t, now: now + 3 * 3600, db: db) == .stale)
        let said = TurnJournal.gaveUpLine(c)
        check("that line never asks them to send it again", said.contains("go on") && !said.lowercased().contains("send"))
        var h: OpaquePointer?
        sqlite3_open(db.path, &h)
        sqlite3_exec(
            h,
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL, "
                + "finish_reason TEXT, display_kind TEXT)", nil, nil, nil)
        func add(_ role: String, _ text: String, _ finish: String?, _ kind: String?) {
            let q =
                "INSERT INTO messages (session_id, role, content, timestamp, finish_reason, display_kind) VALUES ('local-main', '\(role)', '\(text)', \(now - 20), "
                + (finish.map { "'\($0)'" } ?? "NULL") + ", " + (kind.map { "'\($0)'" } ?? "NULL") + ")"
            sqlite3_exec(h, q, nil, nil, nil)
        }
        add("user", "Book the 7:40 flight\n\n(One app note: x)", nil, nil)
        add("assistant", line, nil, "failed_turn")
        check("the engine kept it but only cut it: it goes again", TurnJournal.pickup(t, now: now, db: db) == .again)
        add("assistant", "Booked: seat 14C, confirmation QX7.", "stop", nil)
        sqlite3_close(h)
        check(
            "the engine answered it before One stopped: that answer, not a second run",
            TurnJournal.pickup(t, now: now, db: db) == .answered("Booked: seat 14C, confirmation QX7."))
        check("their message isn't shown twice when it goes again", TurnJournal.shown(c, in: [Bubble(fromMe: true, text: c.display)], again: 1))
        check("but is shown the first time", !TurnJournal.shown(c, in: [Bubble(fromMe: true, text: c.display)], again: 0))
        try? FileManager.default.removeItem(at: dir)
    }
}
