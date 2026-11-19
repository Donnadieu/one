import AppKit
import SwiftUI

// MARK: - Star path chat: its state, and what the check reads back (views in StarChatView.swift)

/// Which days are open, the search, the summary card and where to scroll, for the chat on screen (one at a time).
@MainActor final class StarState: ObservableObject {
    static let shared = StarState()
    static let end = "star-end"
    @Published var chat = ""
    @Published var open: Set<String> = []  // earlier days opened by hand (the newest is always open)
    @Published var query = "" { didSet { if query != oldValue { hit = nil } } }
    @Published var searching = false
    @Published var summaryOpen = false
    @Published var hit: String?  // the match search stepped to
    @Published var target: String?  // home scrolls here (a day's star, a message, the end)
    /// The chat's days, as last drawn (search steps and the dial use them).
    var days: [StarDay] = []
    var memo: (key: String, days: [StarDay]) = ("", [])

    /// A different chat opened: everything folded again, no search.
    func reset(for chat: String) {
        guard chat != self.chat else { return }
        self.chat = chat
        open = []
        query = ""
        searching = false
        summaryOpen = false
        hit = nil
        target = nil
        memo = ("", [])
    }
    /// Its days, worked out once per change of the chat (home redraws often while helpers stream words).
    func days(_ lines: [StarLine], now: Date = Date()) -> [StarDay] {
        let key = "\(chat)|\(lines.count)|\(lines.last?.id ?? "")|\(lines.last?.text.count ?? 0)|\(StarPath.dayKey.string(from: now))"
        if memo.key != key { memo = (key, StarPath.days(lines, now: now)) }
        days = memo.days
        return memo.days
    }
    var hits: [String] { searching ? StarPath.matches(days.flatMap(\.lines), query) : [] }
    func isOpen(_ d: StarDay) -> Bool { d.id == days.last?.id || open.contains(d.id) }
    func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }
    /// The dial: open that day and fly to its star.
    func jump(_ id: String) {
        if id != days.last?.id { open.insert(id) }
        target = id == days.last?.id ? StarState.end : "day-\(id)"
    }
    /// Next (+1) or previous (-1) match: its day opens and home scrolls to it.
    func step(_ dir: Int) {
        searching = true
        let all = hits
        guard !all.isEmpty else { return }
        let k = hit.flatMap { all.firstIndex(of: $0) }.map { ($0 + dir + all.count) % all.count } ?? (dir > 0 ? 0 : all.count - 1)
        hit = all[k]
        if let d = days.first(where: { $0.lines.contains { $0.id == all[k] } }), d.id != days.last?.id { open.insert(d.id) }
        target = all[k]
    }
    /// Back to the newest message: earlier days fold, the search closes.
    func backToNow() {
        open = []
        query = ""
        searching = false
        hit = nil
        target = StarState.end
    }
    /// Something earlier is showing (Back to now appears).
    var away: Bool { !open.isEmpty || searching }
}

/// What the check reads back from the drawn chat: each row's kind, frame and look. Off unless a check turns it on.
enum StarProbe {
    static let space = "starchat"
    nonisolated(unsafe) static var on = false
    nonisolated(unsafe) static var rows: [Row] = []
    struct Row: Equatable {
        let kind: String  // me, them, day, summary
        let id: String
        let frame: CGRect
        var hex: UInt32 = 0
        var named = false
        var halo = false
        var folded = false
        var matches = 0
    }
}
struct StarProbeKey: PreferenceKey {
    static let defaultValue: [StarProbe.Row] = []
    static func reduce(value: inout [StarProbe.Row], nextValue: () -> [StarProbe.Row]) { value += nextValue() }
}
extension View {
    /// Reports this row to `StarProbe` (checks only; nothing is measured otherwise).
    @ViewBuilder func starProbe(_ row: @escaping (CGRect) -> StarProbe.Row) -> some View {
        if StarProbe.on {
            background(GeometryReader { g in Color.clear.preference(key: StarProbeKey.self, value: [row(g.frame(in: .named(StarProbe.space)))]) })
        } else {
            self
        }
    }
}
