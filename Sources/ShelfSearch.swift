import SwiftUI

// MARK: - Ready for you: a search box (title + the text inside each file) and day grouping,
// so hundreds of cards stay easy to scan. Nothing is ever deleted or moved on disk.

/// Caches each file's text, keyed by path + the file's own modification date, so typing in the
/// search box never re-reads every file on each key press: a changed file is read again, nothing else is.
actor ShelfTextIndex {
    static let shared = ShelfTextIndex()
    private var cache: [String: (mtime: Date, text: String)] = [:]

    private nonisolated func mtime(of path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Lowercased title + file text for one card, read once and reused until the file changes.
    func text(for item: ShelfItem) -> String {
        let path = item.path
        let m = mtime(of: path)
        if let hit = cache[path], hit.mtime == m { return hit.text }
        let body = (ShelfCopy.hasText(item.url) ? ShelfCopy.text(of: item.url) : nil) ?? ""
        let t = (item.title + " " + body).lowercased()
        cache[path] = (m, t)
        return t
    }

    /// Clears a file's cached text (call after it changes on disk outside the file picker, if ever needed).
    func forget(_ path: String) { cache[path] = nil }

    /// Ids of the cards whose title or file text contains every word of the query (case-insensitive).
    /// An empty query matches everything.
    func matches(_ items: [ShelfItem], query: String) -> Set<UUID> {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return Set(items.map(\.id)) }
        var out: Set<UUID> = []
        for it in items where words.allSatisfy({ text(for: it).contains($0) }) { out.insert(it.id) }
        return out
    }
}

/// Day groups for the shelf, newest first. Anything 7 days or older folds into "Older".
enum ShelfDay: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "This week"
    case older = "Older"

    /// Where today, yesterday and this week start, worked out once: a card's day is then two date comparisons (the
    /// same answer as `of`, which asks the calendar for every card).
    struct Bounds {
        let tomorrow: Date
        let today: Date
        let yesterday: Date
        let week: Date
        init(_ now: Date, calendar c: Calendar = .current) {
            today = c.startOfDay(for: now)
            tomorrow = c.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
            yesterday = c.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86400)
            week = c.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86400)
        }
        func day(_ made: Date) -> ShelfDay {
            if made >= today && made < tomorrow { return .today }
            if made >= yesterday && made < today { return .yesterday }
            return made >= week ? .week : .older  // later than tomorrow counts as this week, as before
        }
    }

    /// Which day `made` falls in, with `today` = the start of today in `c` (worked out once for a whole shelf).
    static func of(_ made: Date, calendar c: Calendar, today: Date) -> ShelfDay {
        let start = c.startOfDay(for: made)
        if start == today { return .today }
        let days = c.dateComponents([.day], from: start, to: today).day ?? 0
        if days == 1 { return .yesterday }
        return days < 7 ? .week : .older
    }
}

extension ShelfItem {
    var day: ShelfDay { ShelfDay.of(made, calendar: Calendar.current, today: Calendar.current.startOfDay(for: Date())) }
}

enum ShelfGroups {
    /// Everything a card shows, plus the minute (its "just now") and whether Older is open (`ShelfDays`).
    static func key(_ items: [ShelfItem], olderOpen: Bool, now: Date = Date()) -> [String] {
        ["\(Int(now.timeIntervalSince1970 / 60)) \(olderOpen)"] + items.map { "\($0.id) \($0.fresh) \($0.title) \($0.detail) \($0.from) \($0.path)" }
    }
    /// Cards grouped by day, newest group and newest card first; empty groups are dropped.
    /// Each card's day is worked out once (Omar's shelf holds over a thousand cards and this runs on every redraw).
    static func grouped(_ items: [ShelfItem]) -> [(ShelfDay, [ShelfItem])] {
        let sorted = items.sorted { $0.made > $1.made }
        let b = ShelfDay.Bounds(Date())
        var by: [ShelfDay: [ShelfItem]] = [:]
        for it in sorted { by[b.day(it.made), default: []].append(it) }
        return ShelfDay.allCases.compactMap { day in by[day].map { (day, $0) } }
    }
}

/// Plain search box at the top of Ready for you. No X button: clearing the text clears the search.
struct ShelfSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.4))
            TextField("Search", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WorldLook.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.1)))
    }
}

/// A plain day label above its group of cards.
struct ShelfDayLabel: View {
    let day: ShelfDay
    var body: some View {
        Text(day.rawValue).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.4))
            .padding(.horizontal, 4).padding(.top, 2)
    }
}

/// "Older" starts folded; one tap opens it. Always included in a search regardless of this state.
struct ShelfOlderRow: View {
    let count: Int
    @Binding var open: Bool
    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Text("Older · \(count)").font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(WorldLook.cream.opacity(0.55))
            .padding(.horizontal, 4).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Render-only: the real Ready for you column with the search box and day groups, on Omar's own files
/// (read-only; ImageRenderer draws a ScrollView blank, so this lays the cards out without one, and a
/// TextField draws a stray cursor glyph offscreen, so this draws a plain look-alike box instead).
enum ShelfSearchRender {
    static func panel(query: String = "", olderOpen: Bool = false) -> AnyView {
        let all = Shelf.adopt([])
        let fresh = all.filter(\.fresh).count
        let full = ShelfGroups.grouped(all)
        // Real counts per group, but only a few cards drawn per group so the mock fits without a scroll view.
        let shown = full.map { day, v in (day, count: v.count, cards: day == .older ? [] : Array(v.prefix(1))) }
        let q = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let matched = q.isEmpty ? nil : Array(all.filter { it in q.allSatisfy { it.title.lowercased().contains($0) } }.prefix(5))
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(fresh: fresh)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.4))
                    Text(query.isEmpty ? "Search" : query).font(.system(size: 12.5)).foregroundStyle(
                        WorldLook.cream.opacity(query.isEmpty ? 0.4 : 1))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WorldLook.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.1)))
                VStack(alignment: .leading, spacing: 8) {
                    if let matched {
                        ForEach(matched) { ShelfCardView(item: $0) }
                    } else {
                        ForEach(shown, id: \.0) { day, count, cards in
                            if day == .older {
                                ShelfOlderRow(count: count, open: .constant(olderOpen))
                                if olderOpen { ForEach(cards) { ShelfCardView(item: $0) } }
                            } else {
                                ShelfDayLabel(day: day)
                                ForEach(cards) { ShelfCardView(item: $0) }
                            }
                        }
                    }
                }
            }
            .padding(14).frame(width: 260, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.07)))
            .padding(20).background(WorldLook.bg).foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark))
    }
}

/// Ready for you's cards by day (the Older ones folded until opened). Equatable on what the cards show.
struct ShelfDays<Card: View>: View, Equatable {
    let key: [String]
    let groups: [(ShelfDay, [ShelfItem])]
    @Binding var olderOpen: Bool
    @ViewBuilder let card: (ShelfItem) -> Card
    nonisolated static func == (a: ShelfDays, b: ShelfDays) -> Bool { a.key == b.key }
    var body: some View {
        ForEach(groups, id: \.0) { day, items in
            if day == .older {
                ShelfOlderRow(count: items.count, open: $olderOpen).padding(.horizontal, 4)
                if olderOpen { ForEach(items) { card($0) } }
            } else {
                ShelfDayLabel(day: day)
                ForEach(items) { card($0) }
            }
        }
    }
}
