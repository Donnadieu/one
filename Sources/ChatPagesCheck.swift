import AppKit
import SwiftUI

// MARK: - Check: earlier messages a page at a time — `One --test-chat-pages` (CI only, from a test copy)

/// Proves the parts of "A+ · Quiet scroll + find" that don't need a person scrolling:
/// - the chat is kept by day (ChatArchive): days written, merged (never shrunk), read back in order;
/// - ChatPager: closed shows nothing, opening shows the last 20, each top-of-list load adds 20 above and asks to
///   keep the old first row in place, at most `maxRows` at once, the kept days come before the in-memory chat,
///   a jump lands on the message (lit) and a day jump on the day's first message, Back to now closes;
/// - Find: matches newest first with the hit cut out for bold; the day list names Today and Yesterday;
/// - a folded message hands the text view only its first lines (the wait before was laying out whole reports);
/// - a routine report is told apart from a reply with a bold heading;
/// - a page of 20 long messages lays out quickly (it took seconds for everything before).
@MainActor
enum ChatPagesCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-chat-pages") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        exit(run())
    }

    static func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        let cal = Calendar.current
        let now = Date()
        func at(_ daysAgo: Int, _ minute: Int) -> Date {
            cal.date(byAdding: .minute, value: minute, to: cal.startOfDay(for: cal.date(byAdding: .day, value: -daysAgo, to: now)!))!
        }

        print("Chat kept by day")
        check("only a test in its own folder may keep the chat here", ChatArchive.allowed && !TestWorld.isProduction(Env.support))
        let old = (0..<30).map { Bubble(fromMe: $0 % 2 == 0, text: "old \($0)\($0 == 7 ? " flight to Montreal" : "")", date: at(3, 60 + $0)) }
        ChatArchive.write(old)
        let threeDaysAgo = ChatArchive.day.string(from: at(3, 0))
        check("a day file is written", ChatArchive.days() == [threeDaysAgo])
        var grown = old
        grown[29].text = "old 29, finished"
        ChatArchive.lastWritten = [:]
        ChatArchive.write(Array(grown.suffix(5)))  // only the last few are still in memory
        let back = ChatArchive.before(now)
        check("a day is merged, never shrunk", back.count == 30)
        check("the in-memory copy wins (a reply that grew)", back.last?.text == "old 29, finished")
        check("read back oldest first", back.first?.text == "old 0")

        print("A page at a time")
        let live =
            (0..<200).map { Bubble(fromMe: $0 % 2 == 0, text: "msg \($0)\($0 == 150 ? " the flight is at 7:15" : "")", date: at(1, $0)) }
            + (0..<40).map { Bubble(fromMe: $0 % 2 == 0, text: "today \($0)", date: at(0, $0)) }
        let p = ChatPager()
        p.sync(live: live)
        check("closed: nothing earlier shows", p.rows.isEmpty && !p.open)
        p.openNow()
        check("open: the last 20 earlier messages", p.rows.count == 20 && p.rows.last?.text == "today 39")
        check("open: the chat keeps the current exchange in view", p.scroll?.target == "now")
        for _ in 0..<40 where p.loadingArchive { pump(0.05) }
        check("the kept days come before the in-memory chat", p.timeline.count == 270 && p.timeline.first?.text == "old 0")
        let firstBefore = p.rows.first!.id
        p.older(keepAt: 0.1)
        check("scrolling to the top adds 20 above", p.rows.count == 40)
        check("…and keeps the old first row where it was", p.scroll?.target == "top-\(firstBefore)" && abs((p.scroll?.anchor.y ?? 0) - 0.1) < 0.001)
        for _ in 0..<10 { p.older(keepAt: 0) }
        check("never more than \(ChatPager.maxRows) at once", p.rows.count <= ChatPager.maxRows)
        for _ in 0..<20 { p.older(keepAt: 0) }
        check("all the way back reaches the first kept message", p.rows.first?.text == "old 0" && !p.moreAbove)

        print("Find and jump")
        let (n, hits) = p.find("flight")
        check("find counts every match", n == 2)
        check("newest first, the hit cut out for bold", hits.first?.hit == "flight" && hits.first?.after.hasPrefix(" is at 7:15") == true)
        check("find needs two letters", p.find("f").0 == 0)
        let target = live[150].id
        p.jump(to: target)
        check("a jump shows the message, lit", p.rows.contains { $0.id == target } && p.lit == target)
        check("…with a few before it", p.rows.first?.id == p.timeline[p.timeline.firstIndex { $0.id == target }! - 6].id)
        check("after a jump the newest isn't on screen yet", !p.atNow)
        let hiBefore = p.rows.count
        p.newer()
        check("scrolling down after a jump adds 20 below", p.rows.count == hiBefore + 20)
        p.jump(toDay: threeDaysAgo)
        check("a day jump starts at that day's first message", p.rows.first?.text == "old 0")
        let days = p.dayList().map(\.label)
        check("the day list names Today and Yesterday, newest first", days.first == "Today" && days.dropFirst().first == "Yesterday")
        p.close()
        check("Back to now closes earlier messages", !p.open && p.rows.isEmpty && p.scroll?.target == "page-top")
        p.sync(live: live + [Bubble(fromMe: true, text: "new")])
        check("a new message while closed stays closed", p.rows.isEmpty)

        print("Folding and routine reports")
        let report = (0..<214).map { "line \($0) of the email triage report, with enough words to wrap a little" }.joined(separator: "\n")
        let head = LongFold.head(report)
        check("a folded message hands over only its first lines", head.count <= 900 && head.components(separatedBy: "\n").count <= LongFold.keep + 4)
        check("a short message is never cut", LongFold.head("Hello there") == "Hello there")
        try? FileManager.default.createDirectory(at: Env.hermesHome.appendingPathComponent("cron"), withIntermediateDirectories: true)
        try? #"{"jobs":[{"name":"Morning brief"}]}"#.write(
            to: Env.hermesHome.appendingPathComponent("cron/jobs.json"), atomically: true, encoding: .utf8)
        RoutineReport.cached = (.distantPast, [])
        check("a routine report is one line with Open", RoutineReport("**Morning brief**\n\nRain after 3. Dentist Monday.")?.title == "Morning brief")
        check("a reply with a bold heading stays a reply", RoutineReport("**What you decided**\n\n1. Free for 30 days.") == nil)
        check("a long report under a bold title counts too", RoutineReport("**Email triage**\n\n" + report) != nil)

        print("Speed")
        ChatText.still = false
        let long = (0..<ChatPager.page).map {
            Bubble(fromMe: $0 % 3 == 0, text: $0 % 3 == 0 ? "short question \($0)" : "**Email triage**\n\n" + report)
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        let t0 = Date()
        let host = NSHostingView(
            rootView: ScrollView { HistoryStrip(m: Model.shared, turns: long, open: .constant(true)).padding(20) }.frame(width: 700, height: 700)
                .environment(\.colorScheme, .dark))
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        let took = Date().timeIntervalSince(t0)
        print(String(format: "    a page of 20 long messages: %.2f s", took))
        check("a page of 20 long messages lays out in under 1.5 s", took < 1.5)

        print(fails == 0 ? "chat pages: all checks passed" : "chat pages: \(fails) check(s) failed")
        return fails == 0 ? 0 : 1
    }
}
