import AppKit
import SwiftUI

// MARK: - Check: the star path chat — `One --test-star-chat` (CI only, from a test copy)

/// Proves the bot chat redesign (Claude Design "Chosen Star path with summary"), in a real window on the CI runner:
/// - who's speaking: the person's words sit on the right in a capsule; the speaker's on the left, in its colour,
///   its name at the start of each run only; the same for a bot, the assistant and a helper;
/// - collapsing: only the newest day is open, every earlier day is one folded star with its count and first line; a
///   long reply shows 3 lines then "Read all"; the summary card is one line until opened, and opened it pushes the
///   chat down, never over it; a day opened by hand shows its messages;
/// - search: matches are found without case or accents, folded days say how many they hold, matching messages get
///   a halo, stepping to the next match opens its day and asks to scroll there; Back to now folds it all again;
/// - a bot's whole chat is kept in its own file, with times, and survives a reload; a deleted bot's file goes;
/// - a 400-message chat opens quickly, laying out only the newest day.
@MainActor
enum StarChatCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-star-chat") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        exit(run())
    }

    static func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    nonisolated(unsafe) static var fails = 0
    static func check(_ name: String, _ ok: Bool) {
        print("  \(ok ? "✓" : "✗") \(name)")
        if !ok { fails += 1 }
    }

    /// Five days of a bot's chat, a long report among short answers, "Germán" and "county" in a few of them.
    static func history(days: Int = 5, perDay: Int = 6, now: Date = Date()) -> [StarLine] {
        let cal = Calendar.current
        var out: [StarLine] = []
        for d in 0..<days {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: d - days + 1, to: now)!)
            for i in 0..<perDay {
                let at = cal.date(byAdding: .minute, value: 9 * 60 + i * 7, to: day)!
                let me = i % 2 == 0
                var text = me ? "Question \(d)-\(i) about the county plan" : "Answer \(d)-\(i): two posts drafted."
                if !me && i == 3 { text = "**Report \(d)**\n\n" + (1...30).map { "- Line \($0) of the report" }.joined(separator: "\n") }
                if d == 1 && i == 1 { text = "Germán sent the offer letter." }
                if d == 4 && i == 5 { text = "Mailed 200 letters to County homes." }
                out.append(StarLine(id: "l-\(d)-\(i)", me: me, text: text, date: at))
            }
        }
        return out
    }

    static func run() -> Int32 {
        print("Days and folds")
        let now = Date()
        let lines = history(now: now)
        let days = StarPath.days(lines, now: now)
        check("five days, oldest first, the newest called Today", days.count == 5 && days.last?.label == "Today" && days[3].label == "Yesterday")
        check("only the newest day is open at first", StarPath.openByDefault(days) == [days[4].id])
        check("a folded day names its first question", days[0].title.hasPrefix("Question 0-0"))
        let log = ["Morning check done.", "**You:** Write two posts\n\nDone. Two posts are ready."]
        let parsed = StarPath.lines(log: log)
        check(
            "a kept log splits into the person's ask and the answer", parsed.map(\.me) == [false, true, false] && parsed[1].text == "Write two posts")
        check("undated messages come first, as Earlier", StarPath.days(parsed + lines, now: now).first?.label == "Earlier")
        check("a 30-line report folds, a short answer doesn't", StarPath.folds(lines[3].text) && !StarPath.folds(lines[1].text))
        check("search ignores case and accents", StarPath.matches(lines, "german") == ["l-1-1"])
        let hits = StarPath.matches(lines, "COUNTY")
        check("every match is found", hits.count == 16)
        check("busier days get bigger dots", StarPath.dot(12, max: 12) > StarPath.dot(3, max: 12) && StarPath.dot(0, max: 0) == 5)

        print("Summary card")
        var bot = Helper(title: "Growth bot", task: "", sid: "s", state: "needsYes", line: "")
        bot.reply = "Two posts are ready.\n\nPost them to your page?\n\n[choices: Yes, post it | Not now]"
        let s = StarSummary.bot(bot, days: [("Mon", "Drafted 3 posts"), ("Tue", "Ad check"), ("Wed", "2 areas"), ("Today", "2 posts waiting")])
        check("a bot's card: its last 3 days and the question it asks", s.did.count == 3 && s.waiting.first?.what == "Post them to your page?")
        check("its answers are on the card", s.waiting.first?.choices == ["Yes, post it", "Not now"])
        var job = Helper(title: "Business playbook", task: "", state: "done", line: "", started: now)
        job.reply = "Closest match: a portfolio of small apps."
        check("a helper's card is What I found · What I need from you", StarSummary.helper(job).didTitle == "What I found")
        let iris = StarSummary.assistant([job], asks: ["Sign in to Claude"], now: now)
        check("the assistant's card: today's finished helpers and what waits", iris.did.first?.what == "Business playbook" && iris.waiting.count == 1)

        print("A bot's whole chat is kept")
        var keep = Helper(title: "Keeper", task: "", sid: "k", state: "done", line: "")
        keep.bot = BotInfo(name: "Keeper", color: "teal", room: "Work", roomPath: "/tmp", job: "x")
        keep.log = ["Old answer"]
        check(
            "a bot from before starts from its log, undated", BotChat.lines(keep).map(\.text) == ["Old answer"] && BotChat.lines(keep)[0].date == nil)
        for i in 0..<300 { BotChat.add(keep, entry: "**You:** ask \(i)\n\nanswer \(i)", at: now.addingTimeInterval(Double(i))) }
        BotChat.flush()
        BotChat.cache = [:]
        let back = BotChat.lines(keep)
        check(
            "hundreds of messages come back from its file, with times", back.count == 601 && back.last?.text == "answer 299" && back.last?.date != nil
        )
        check("ids stay unique", Set(back.map(\.id)).count == back.count)
        BotChat.remove(keep.id)
        BotChat.flush()
        check("a deleted bot's chat file goes with it", !FileManager.default.fileExists(atPath: BotChat.url(keep.id).path))

        views(lines, now: now)
        print(fails == 0 ? "star chat: all checks passed" : "star chat: \(fails) failed")
        return fails == 0 ? 0 : 1
    }

    // MARK: The views, in a real window

    static func host(_ speaker: StarSpeaker, _ lines: [StarLine], _ summary: StarSummary, _ st: StarState, width: CGFloat = 760) -> NSWindow {
        let v = VStack(alignment: .leading, spacing: 10) {
            StarSummaryCard(summary: summary, speaker: speaker, state: st)
            StarChat(speaker: speaker, lines: lines, state: st)
        }
        .frame(width: width).fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: StarProbe.space)
        .onPreferenceChange(StarProbeKey.self) { r in MainActor.assumeIsolated { StarProbe.rows = r } }
        .environment(\.colorScheme, .dark)
        let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ScrollView { v })
        w.orderFrontRegardless()
        settle(w)
        return w
    }
    static func settle(_ w: NSWindow) {
        for _ in 0..<6 {
            w.contentView?.layoutSubtreeIfNeeded()
            pump(0.05)
        }
    }
    static func rows(_ kind: String) -> [StarProbe.Row] { StarProbe.rows.filter { $0.kind == kind } }

    static func views(_ lines: [StarLine], now: Date) {
        StarProbe.on = true
        let amber = Bots.hex("amber")
        let growth = StarSpeaker(name: "Growth bot", hex: amber, kind: .bot)
        var bot = Helper(title: "Growth bot", task: "", sid: "s", state: "needsYes", line: "")
        bot.reply = "Ready.\n\nPost it?\n\n[choices: Yes | Not now]"
        let summary = StarSummary.bot(bot, days: [("Mon", "Drafted"), ("Tue", "Checked"), ("Today", "Waiting")])
        let st = StarState()
        st.reset(for: "check")
        let w = host(growth, lines, summary, st)
        let width: CGFloat = 760

        print("Who's speaking")
        let mine = rows("me")
        let theirs = rows("them")
        check("the person's and the speaker's messages both show", !mine.isEmpty && !theirs.isEmpty)
        check("the person's words sit on the right", mine.allSatisfy { $0.frame.minX > width * 0.3 && $0.frame.maxX > width * 0.85 })
        check("the speaker's words sit on the left", theirs.allSatisfy { $0.frame.minX < width * 0.15 })
        check("the speaker's words wear its colour", theirs.allSatisfy { $0.hex == amber })
        let today = lines.filter { StarPath.dayKey.string(from: $0.date!) == StarPath.dayKey.string(from: now) }
        let runStarts = today.indices.filter { !today[$0].me && ($0 == 0 || today[$0 - 1].me) }.map { today[$0].id }
        check("its name shows at the start of each run only", Set(theirs.filter(\.named).map(\.id)) == Set(runStarts))
        let iris = StarState()
        iris.reset(for: "iris")
        let w2 = host(.assistant("Iris"), lines, StarSummary.assistant([], asks: ["One thing"]), iris)
        check("the assistant's chat is the same family, in cream", !rows("them").isEmpty && rows("them").allSatisfy { $0.hex == StarSpeaker.cream })
        w2.close()
        let helper = StarState()
        helper.reset(for: "helper")
        let w3 = host(
            StarSpeaker(name: "Business playbook", hex: StarSpeaker.helperTint, kind: .helper), Array(lines.suffix(4)), .helper(bot), helper)
        check(
            "a helper's chat too",
            rows("them").allSatisfy { $0.hex == StarSpeaker.helperTint } && rows("me").allSatisfy { $0.frame.minX > width * 0.3 })
        w3.close()
        _ = host(growth, lines, summary, st).close()  // back to the bot's rows
        settle(w)

        print("Collapsing")
        let past = rows("day")
        check("each earlier day is one folded star", past.count == 4 && past.allSatisfy(\.folded))
        check("only today's messages are laid out", (mine.count + theirs.count) == today.count)
        let report = theirs.first { $0.id == today[3].id }
        check("a long reply shows 3 lines, then Read all", report?.folded == true && (report?.frame.height ?? 999) < 110)
        let card = rows("summary").first
        check("the summary card is one line until opened", card != nil && (card?.frame.height ?? 999) < 52)
        st.summaryOpen = true
        settle(w)
        let open = rows("summary").first
        let firstBelow = StarProbe.rows.filter { $0.kind != "summary" }.map(\.frame.minY).min() ?? 0
        check("opened, it shows what it did and what's waiting", (open?.frame.height ?? 0) > 100)
        check("opened, it pushes the chat down, never over it", firstBelow >= (open?.frame.maxY ?? .infinity) - 0.5)
        st.summaryOpen = false
        let mon = past[1].id
        st.toggle(mon)
        settle(w)
        check("a day opened by hand shows its messages", rows("me").contains { $0.id.hasPrefix("l-1-") })
        check("and its star says Fold", rows("day").first { $0.id == mon }?.folded == false)
        st.backToNow()
        settle(w)
        check("Back to now folds it again and goes to the newest", rows("day").allSatisfy(\.folded) && st.target == StarState.end)

        print("Search")
        st.query = "county"
        st.searching = true
        settle(w)
        let lit = StarProbe.rows.filter(\.halo)
        check("matching messages get a halo", !lit.isEmpty && lit.allSatisfy { r in StarPath.matches(lines, "county").contains(r.id) })
        check("folded days say how many matches they hold", rows("day").filter { $0.matches > 0 }.count == 4)
        st.step(1)
        settle(w)
        let hit = st.hit
        check("the next match opens its day and asks to scroll there", hit == "l-0-0" && st.target == hit && rows("me").contains { $0.id == hit })
        check("that message is lit", StarProbe.rows.first { $0.id == hit }?.halo == true)
        st.query = "german"
        st.step(1)
        settle(w)
        check("a match in a folded day is found too", st.hit == "l-1-1" && rows("them").contains { $0.id == "l-1-1" && $0.halo })
        st.backToNow()
        check("Back to now clears the search", st.query.isEmpty && !st.searching)
        w.close()

        print("Long history stays quick")
        let big = history(days: 40, perDay: 10, now: now)
        let t0 = CACurrentMediaTime()
        let bigState = StarState()
        bigState.reset(for: "big")
        let wb = host(growth, big, summary, bigState)
        let ms = (CACurrentMediaTime() - t0) * 1000
        check(
            String(format: "400 messages open in %.0f ms (under 900), only the newest day laid out", ms),
            ms < 900 && (rows("me").count + rows("them").count) == 10 && rows("day").count == 39)
        wb.close()
        StarProbe.on = false
    }
}
