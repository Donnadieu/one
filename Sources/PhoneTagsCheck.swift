import AppKit
import Foundation

/// `One --test-helpers-stress phone` (tools/phone-tags-check.sh, in preflight on every pull request). Nov 15 2026:
/// in the phone chat the assistant wrote a [helper: …] line and later a [tell-helper: …] line, and nothing started.
/// Replayed here against the stand-in engine (tools/fake-engine.py), through the same files the engine plugin
/// `one-phone-tags` writes (`hermes/one-phone/inbox/<id>.json`, checked on its own by tools/phone-tags-check.py):
///   1. a phone reply with a helper line starts exactly one helper, shown in One, marked as sent from that chat
///   2. the same reply again (the same file, or a re-run turn's copy) starts nothing more and runs the job once
///   3. a tell line from the phone reaches that helper's own conversation
///   4. when it's done, that chat gets its result, once; a helper's question comes with its choices as buttons
///   5. a tell for a helper that doesn't exist says so in that chat; the phone's helper news is kept
extension HelperStress {
    @MainActor
    static func phoneCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        m.shelf = []
        m.followUps = []
        PhoneSent.clear()
        Messenger.standIn = { to, text, choices in PhoneSent.add((to, text, choices)) }
        var sent: [(to: String, text: String, choices: [String])] { PhoneSent.all }
        let fm = FileManager.default
        try? fm.removeItem(at: PhoneTags.dir)
        func hand(_ id: String, _ reply: String) {
            try? fm.createDirectory(at: PhoneTags.inbox, withIntermediateDirectories: true)
            let r = PhoneReply(id: id, platform: Messenger.botChat, chat: "4242", session: "phone-1", at: Date().timeIntervalSince1970, reply: reply)
            if let d = try? JSONEncoder().encode(r) { try? d.write(to: PhoneTags.inbox.appendingPathComponent("\(id).json")) }
        }
        func evs() -> [Event] { events() }
        let ready = await wait(60) { m.isReady }
        check("One is open (the phone's replies wait until it is)", ready)

        print("1. the Nov 15 reply from the phone: one helper line")
        let reply =
            "I'm sending a helper to build it now.\n\n[helper: Phone job | STRESSJOB PH1 secs=4 build the channel]\n\nI'll tell you when it's done."
        hand("r1", reply)
        m.tendPhoneTags()
        let mine = { m.helpers.filter { $0.title == "Phone job" } }
        check("exactly one helper started (\(mine().count))", mine().count == 1)
        check("shown in One, marked as sent from that chat", mine().first?.phone == Messenger.botChat + ":4242")
        check("the reply is used up", ((try? fm.contentsOfDirectory(atPath: PhoneTags.inbox.path)) ?? []).isEmpty)
        let started = await wait(20) { evs().contains { $0.ev == "start" && $0.job == "PH1" } }
        check("it's at work in the engine", started)

        print("2. the same reply again starts nothing more")
        hand("r1", reply)  // the same file again
        m.tendPhoneTags()
        hand("r1-rerun", reply)  // a re-run turn's copy under another name
        m.tendPhoneTags()
        check("still one helper (\(mine().count))", mine().count == 1)

        print("3. a tell from the phone reaches it")
        hand("r2", "[tell-helper: Phone job | STRESSJOB PH1T secs=1 the new angle]\n\nSent to Phone job.")
        m.tendPhoneTags()
        let sid = mine().first?.sid
        let reached = await wait(40) {
            evs().contains { ($0.ev == "start" && $0.job == "PH1T" || $0.ev == "steer" && ($0.text ?? "").contains("PH1T")) && $0.sid == sid }
        }
        check("the message went into that helper's own conversation", reached && sid != nil)
        check("nothing said about it in the phone chat yet", !sent.contains { $0.text.contains("couldn't find") })

        print("4. when it's done, the phone gets its result")
        let done = await wait(40) { sent.contains { $0.text.hasPrefix("Phone job is done.") } }
        check(
            "that chat was sent \"Phone job is done.\" with the result",
            done && sent.contains { $0.to == Messenger.botChat + ":4242" && $0.text.contains("DONE PH1") })
        _ = await wait(15) { mine().first.map { h in h.state == "done" && !m.followUps.contains { $0.helper == h.id } } ?? false }
        try? await Task.sleep(for: .seconds(2))
        let results = sent.filter { $0.text.hasPrefix("Phone job is done.") }.map(\.text)
        check("never the same result twice (\(results.count) sent)", Set(results).count == results.count && !results.isEmpty)
        check(
            "the job ran once (\(evs().filter { $0.ev == "start" && $0.job == "PH1" }.count))",
            evs().filter { $0.ev == "start" && $0.job == "PH1" }.count == 1)
        hand("r3", "Sure.\n[helper: Ask job | STRESSJOB PH2 secs=1 ask=1]")
        m.tendPhoneTags()
        let asked = await wait(30) { sent.contains { $0.text.hasPrefix("Ask job needs your yes.") } }
        let ask = sent.first { $0.text.hasPrefix("Ask job needs your yes.") }
        check("a helper's question goes to the phone", asked)
        check("its choices as buttons (\(ask?.choices ?? []))", ask?.choices == ["Yes, go ahead", "Not now"])
        check("and not as a raw line", !(ask?.text.contains("[choices") ?? true))

        print("5. a tell for nobody, and the phone's news")
        hand("r4", "[tell-helper: Nobody | hi]\nSent.")
        m.tendPhoneTags()
        let missed = await wait(5) { sent.contains { $0.text.contains("I couldn't find a helper called \"Nobody\"") } }
        check("the phone is told there's no such helper", missed)
        m.writePhoneNews()
        let news = (try? String(contentsOf: PhoneTags.newsFile, encoding: .utf8)) ?? ""
        check("the news names the helpers and where they came from", news.contains("Phone job, sent from this chat") && news.contains("Ask job"))
        check("and asks to pass the answer on", news.contains("[tell-helper: Ask job | their answer]"))
        Messenger.standIn = nil
        print(fails == 0 ? "phone-tags ok" : "phone-tags FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}

/// What the stand-in phone chat was sent (from any thread).
enum PhoneSent {
    nonisolated(unsafe) private static var items: [(to: String, text: String, choices: [String])] = []
    private static let lock = NSLock()
    static func add(_ x: (to: String, text: String, choices: [String])) { lock.withLock { items.append(x) } }
    static func clear() { lock.withLock { items = [] } }
    static var all: [(to: String, text: String, choices: [String])] { lock.withLock { items } }
}

// MARK: - part of `One --test-helpers`: what a phone chat is shown, sent and remembered (no engine)

extension HelperCheck {
    @MainActor
    static func phoneTags(_ check: (String, Bool) -> Void) {
        // The phone shows exactly what One's own chat shows: the plugin's cut (tools/phone-tags-check.py) is checked
        // against the same cases.
        let path =
            ProcessInfo.processInfo.environment["ONE_PHONE_TAGS_CASES"] ?? FileManager.default.currentDirectoryPath
            + "/tests/fixtures/phone-tags/shown.json"
        let cases =
            (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        check("the phone-chat cases are there (\(cases.count))", cases.count >= 8)
        for c in cases {
            let reply = c["reply"] ?? ""
            let shown = Helpers.strip(Helpers.read(reply).said)
            check(
                "phone shows what One shows: \(c["name"] ?? "?")\(shown == c["shown"] ? "" : " (One: \(shown.debugDescription))")",
                shown == c["shown"])
        }
        let nov15 = cases.first { ($0["name"] ?? "").hasPrefix("the Nov 15 reply") }?["reply"] ?? ""
        let r = Helpers.read(nov15)
        check(
            "the Nov 15 phone reply starts its helper, whole",
            r.jobs.count == 1 && r.jobs[0].0 == "Science explainer channel" && r.jobs[0].1.contains("visibility are right"))

        // Each reply acts once.
        try? FileManager.default.removeItem(at: PhoneTags.actedFile)
        check("a reply is acted on the first time", PhoneTags.claim("abc"))
        check("never a second time", !PhoneTags.claim("abc"))
        check("but the same words a day later are a new reply", PhoneTags.claim("abc", now: Date().addingTimeInterval(PhoneTags.replayWindow + 60)))

        // What the phone is sent when a helper it sent ends.
        var h = Helper(title: "Hotels", task: "Find a hotel.", sid: "s", state: "done", line: "Done")
        h.reply = "The Auberge at $189 a night.\n[learned: x]"
        check("done: the result itself, no hidden tags", PhoneTags.report(h)?.text == "Hotels is done.\n\nThe Auberge at $189 a night.")
        h.state = "needsYes"
        h.reply = "Book the Auberge?\n[choices: Book it | Not now]"
        let ask = PhoneTags.report(h)
        check(
            "a question: its words, its choices as buttons",
            ask?.choices == ["Book it", "Not now"] && ask?.text.contains("Book the Auberge?") == true)
        check("and never the raw choices line", ask?.text.contains("[choices") == false)
        h.state = "stopped"
        h.resumeQueued = true
        check("cut off and picking back up: nothing sent", PhoneTags.report(h) == nil)
        h.resumeQueued = nil
        h.stoppedByYou = true
        check("stopped on purpose: nothing sent", PhoneTags.report(h) == nil)
        h.state = "working"
        check("still working: nothing sent", PhoneTags.report(h) == nil)
        h.state = "done"
        h.reply = String(repeating: "word ", count: 2000)
        let long = PhoneTags.report(h)?.text ?? ""
        check("a long result fits one message and says where the rest is", long.count < 3600 && long.hasSuffix("under Ready for you on your Mac."))
        check("the same result gives the same mark", PhoneTags.mark(h, long) == PhoneTags.mark(h, long))
        check("a test never reaches the real phone chat", !Messenger.send("hi", to: Messenger.botChat + ":1"))
    }
}
