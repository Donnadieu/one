import SwiftUI

// MARK: - Earlier messages, a page at a time (Claude Design "Chat Directions", A+ · Quiet scroll + find, Omar Nov 5 2026)
// Before: "Scroll up for earlier" laid out every saved message at once (500 messages, ~45,000 pt, 5-10 s).
// Now the chat shows a window of the timeline: 20 earlier messages when you start scrolling up, 20 more each
// time the top comes into view (the message you were reading stays where it was), at most `maxRows` at once.
// The timeline is everything ever said: the kept day files (ChatArchive) before the in-memory chat, then the
// in-memory turns before the current exchange. Find and "jump to a day" move the window anywhere in it.

@MainActor final class ChatPager: ObservableObject {
    static let shared = ChatPager()
    static let page = 20
    static let maxRows = 120

    /// Earlier messages are showing (the orb steps aside, the day pill and "Back to now" show).
    @Published var open = false
    /// Everything said before the current exchange, oldest first.
    @Published private(set) var timeline: [Bubble] = []
    /// The window of `timeline` on screen: `lo..<hi`.
    @Published private(set) var lo = 0
    @Published private(set) var hi = 0
    /// The message a search or a day jump landed on, softly lit for a moment.
    @Published var lit: UUID?
    /// A scroll the chat should make next (HomeView carries it out with its ScrollViewReader).
    @Published var scroll: Scroll?
    @Published private(set) var loadingArchive = false

    struct Scroll: Equatable {
        let target: String
        let anchor: UnitPoint
        let n = UUID()
    }

    private var live: [Bubble] = []
    private var archived: [Bubble] = []
    private(set) var archiveRead = false
    /// Where the top of home's page sits in the chat's viewport (0 = scrolled to the top).
    var pageTop: CGFloat = 0
    /// When the chat last moved by itself (a jump or a page): the top doesn't load more until the person scrolls.
    var movedAt = Date.distantPast

    var rows: [Bubble] { lo < hi && hi <= timeline.count ? Array(timeline[lo..<hi]) : [] }
    var atNow: Bool { hi >= timeline.count }
    var moreAbove: Bool { lo > 0 || !archiveRead }

    /// The in-memory turns before the current exchange changed (a new message was sent, or One just opened).
    func sync(live new: [Bubble]) {
        let wasNow = atNow
        let oldCount = timeline.count
        live = new
        rebuild()
        if wasNow {
            let grew = timeline.count - oldCount
            hi = timeline.count
            if !open { lo = hi } else { lo = min(max(0, lo + min(grew, 0)), hi) }
        }
        clamp()
    }

    private func rebuild() {
        let start = live.first?.date ?? Date()
        timeline = archived.filter { $0.date < start } + live
    }

    private func clamp() {
        hi = min(max(hi, 0), timeline.count)
        lo = min(max(lo, 0), hi)
    }

    /// Reads the kept day files once (off the main thread), then puts them before the in-memory chat.
    func readArchive(then: (() -> Void)? = nil) {
        guard !archiveRead, !loadingArchive else {
            then?()
            return
        }
        loadingArchive = true
        let before = live.first?.date ?? Date()
        Task.detached(priority: .userInitiated) {
            let old = ChatArchive.before(before)
            await MainActor.run {
                let added = old.count
                self.archived = old
                self.archiveRead = true
                self.loadingArchive = false
                self.rebuild()
                self.lo += added
                self.hi += added
                self.clamp()
                then?()
            }
        }
    }

    /// Start showing earlier messages: the last page before the current exchange.
    func openNow() {
        guard !timeline.isEmpty || !archiveRead else { return }
        open = true
        hi = timeline.count
        lo = max(0, hi - Self.page)
        movedAt = Date()
        scroll = Scroll(target: "now", anchor: .top)
        readArchive()
    }

    /// The top came into view: 20 more above. `top` is where the first row's top sits in the viewport (0…1),
    /// so it stays exactly there and nothing jumps.
    func older(keepAt top: CGFloat) {
        guard open else { return }
        guard lo > 0 else {
            if !archiveRead { readArchive { if self.lo > 0 { self.older(keepAt: top) } } }
            return
        }
        let first = timeline[lo].id
        lo = max(0, lo - Self.page)
        if hi - lo > Self.maxRows { hi = lo + Self.maxRows }
        movedAt = Date()
        scroll = Scroll(target: "top-\(first)", anchor: UnitPoint(x: 0.5, y: min(max(top, 0), 1)))
    }

    /// The bottom came into view after a jump: 20 more below (nothing above moves, so no anchor is needed).
    func newer() {
        guard open, hi < timeline.count else { return }
        hi = min(timeline.count, hi + Self.page)
    }

    /// Go to one message (a search result): a few before it, a page after it, lit for a moment.
    func jump(to id: UUID) {
        guard let k = timeline.firstIndex(where: { $0.id == id }) else { return }
        open = true
        lo = max(0, k - 6)
        hi = min(timeline.count, k + Self.page)
        lit = id
        movedAt = Date()
        scroll = Scroll(target: "top-\(id)", anchor: UnitPoint(x: 0.5, y: 0.3))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.lit == id { self.lit = nil }
        }
    }

    /// Go to the start of a day.
    func jump(toDay d: String) {
        guard let k = timeline.firstIndex(where: { ChatArchive.day.string(from: $0.date) == d }) else { return }
        open = true
        lo = k
        hi = min(timeline.count, k + Self.page)
        movedAt = Date()
        scroll = Scroll(target: "top-\(timeline[k].id)", anchor: .top)
    }

    /// Back to now: earlier messages tuck away and the orb comes back.
    func close() {
        open = false
        hi = timeline.count
        lo = hi
        lit = nil
        scroll = Scroll(target: "page-top", anchor: .top)
    }

    // MARK: Find and days

    struct Match: Identifiable {
        let id: UUID
        let day: String
        let before: String
        let hit: String
        let after: String
    }

    /// Messages containing `q`, newest first: (total, the first `limit`).
    func find(_ q: String, limit: Int = 6) -> (Int, [Match]) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return (0, []) }
        var total = 0
        var out: [Match] = []
        for b in timeline.reversed() {
            guard let r = b.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            total += 1
            guard out.count < limit else { continue }
            let pre = b.text[..<r.lowerBound].suffix(28)
            let post = b.text[r.upperBound...].prefix(70)
            func flat<S: StringProtocol>(_ s: S) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "") }
            out.append(
                Match(
                    id: b.id, day: Self.shortDay(b.date), before: (pre.count == 28 ? "…" : "") + flat(pre), hit: String(b.text[r]),
                    after: flat(post)))
        }
        return (total, out)
    }

    /// Days with messages, newest first: the last few by name, older ones as one row per month.
    func dayList() -> [(label: String, day: String, count: Int)] {
        var counts: [String: Int] = [:]
        for b in timeline { counts[ChatArchive.day.string(from: b.date), default: 0] += 1 }
        let days = counts.keys.sorted(by: >)
        var out: [(String, String, Int)] = []
        var months = Set<String>()
        for (i, d) in days.enumerated() {
            guard let date = ChatArchive.day.date(from: d) else { continue }
            if i < 5 {
                out.append((Self.longDay(date), d, counts[d] ?? 0))
            } else {
                let mf = DateFormatter()
                mf.dateFormat = "MMMM yyyy"
                let m = mf.string(from: date)
                guard !months.contains(m) else { continue }
                months.insert(m)
                out.append(("Earlier in \(m)", d, days.filter { $0.hasPrefix(String(d.prefix(7))) }.reduce(0) { $0 + (counts[$1] ?? 0) }))
            }
        }
        return out
    }

    static func longDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }
    static func shortDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}
