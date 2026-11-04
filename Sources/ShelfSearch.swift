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
}

extension ShelfItem {
    var day: ShelfDay {
        let c = Calendar.current
        if c.isDateInToday(made) { return .today }
        if c.isDateInYesterday(made) { return .yesterday }
        let days = c.dateComponents([.day], from: c.startOfDay(for: made), to: c.startOfDay(for: Date())).day ?? 0
        return days < 7 ? .week : .older
    }
}

enum ShelfGroups {
    /// Cards grouped by day, newest group and newest card first; empty groups are dropped.
    static func grouped(_ items: [ShelfItem]) -> [(ShelfDay, [ShelfItem])] {
        let sorted = items.sorted { $0.made > $1.made }
        return ShelfDay.allCases.compactMap { day in
            let v = sorted.filter { $0.day == day }
            return v.isEmpty ? nil : (day, v)
        }
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
