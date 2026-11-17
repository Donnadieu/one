import SwiftUI

// MARK: - The Routines dial by bot (Claude Design "One bots design", B · Moons, f6). A bot is who, a routine is
// when: a routine set up in a bot's own conversation belongs to that bot (the engine keeps that conversation as the
// routine's origin, `Routine.owner`). Its marks and words wear the bot's colour; the assistant's own stay cream.
// Under the title: All · the assistant · each bot (selected = outline + check), only when there are bots.

extension RoutinesPanel {
    /// The bot a routine belongs to, if any.
    func owner(_ r: Routine) -> Helper? { r.owner.flatMap { o in m.bots.first { $0.sid == o } } }

    /// Routine id → its bot's colour.
    func tints(_ s: RoutinesSnapshot) -> [String: UInt32] {
        var out: [String: UInt32] = [:]
        for r in s.routines { if let b = owner(r)?.bot { out[r.id] = Bots.hex(b.color) } }
        return out
    }

    /// Only the routines of the bot picked under the title ("main" = the assistant's own).
    func only(_ s: RoutinesSnapshot) -> RoutinesSnapshot {
        guard let k = onlyBot else { return s }
        var t = s
        t.routines = s.routines.filter { r in k == "main" ? owner(r) == nil : owner(r)?.id.uuidString == k }
        return t
    }

    @ViewBuilder var botFilter: some View {
        if !m.bots.isEmpty {
            HStack(spacing: 6) {
                filterChip(nil, label: "All") { EmptyView() }
                filterChip("main", label: m.name) { MiniOrb(size: 11) }
                ForEach(m.bots) { h in
                    if let b = h.bot { filterChip(h.id.uuidString, label: b.name) { BotMoon(hex: Bots.hex(b.color), size: 15, t: 21.7) } }
                }
            }
            .fixedSize().starCalm(floor: 0.12)
        }
    }

    func filterChip<I: View>(_ key: String?, label: String, @ViewBuilder icon: () -> I) -> some View {
        let on = onlyBot == key
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                onlyBot = key
                sel = nil
                picked = true
            }
        } label: {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                icon()
                Text(label).font(.system(size: 11.5, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(WorldLook.cream.opacity(on ? 1 : 0.6))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(on ? 0.7 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
