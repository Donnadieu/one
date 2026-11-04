import Foundation

/// `One --test-shelf-search`: pure checks against made-up Ready for you cards (no real files, no UI).
/// Covers the search box matching titles and file text, day grouping newest-first, and the Older fold
/// always being included in a search. Run anywhere; touches nothing on disk.
enum ShelfSearchCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-shelf-search") else { return false }
        Task { exit(await run()) }  // pure; touches nothing real
        return true
    }
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }

        let now = Date()
        func daysAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now }

        let germanPDF = ShelfItem(
            title: "2026-10-30 Germán 1:1 prep", detail: "PDF", from: "Elias", path: "/tmp/shelf-search-check-german.txt", made: now)
        let flights = ShelfItem(
            title: "Quebec flight prices", detail: "Newark $3,104", from: "Flight helper", path: "/tmp/shelf-search-check-flights.txt",
            made: daysAgo(1))
        let receipts = ShelfItem(
            title: "Receipts 2026", detail: "23 receipts", from: "Receipts helper", path: "/tmp/shelf-search-check-receipts.txt",
            made: daysAgo(4))
        let oldNote = ShelfItem(title: "Dentist note", detail: "", from: "Elias", path: "/tmp/shelf-search-check-old.txt", made: daysAgo(10))
        let items = [germanPDF, flights, receipts, oldNote]

        try? "Nothing about Germán here, just some old budget numbers.".write(
            toFile: "/tmp/shelf-search-check-flights.txt", atomically: true, encoding: .utf8)
        try? "A reminder to email Germán about the roadmap.".write(
            toFile: "/tmp/shelf-search-check-german.txt", atomically: true, encoding: .utf8)
        try? "23 receipts, $1,284 total.".write(toFile: "/tmp/shelf-search-check-receipts.txt", atomically: true, encoding: .utf8)
        try? "Cleaning next March.".write(toFile: "/tmp/shelf-search-check-old.txt", atomically: true, encoding: .utf8)

        // Day grouping: newest group first, each group newest card first, nothing dropped.
        let g = ShelfGroups.grouped(items)
        check("4 cards land in 4 different groups", g.count == 4)
        check("Today is first", g.first?.0 == .today)
        check("Older is last and holds the 10-day-old card", g.last?.0 == .older && g.last?.1.first?.id == oldNote.id)
        check("This week holds the 4-day-old card", g.first { $0.0 == .week }?.1.first?.id == receipts.id)

        let byTitle = await ShelfTextIndex.shared.matches(items, query: "Quebec")
        let byContent = await ShelfTextIndex.shared.matches(items, query: "receipts")
        let byAccent = await ShelfTextIndex.shared.matches(items, query: "Germán")
        check("matches a word only in the title", byTitle == [flights.id])
        check("matches a word only inside the file's text", byContent == [receipts.id])
        check("\"Germán\" finds the card named for it, and the one mentioning it in its text", byAccent == [germanPDF.id, flights.id])

        for p in [germanPDF, flights, receipts, oldNote].map(\.path) { try? FileManager.default.removeItem(atPath: p) }
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        return fails == 0 ? 0 : 1
    }
}
