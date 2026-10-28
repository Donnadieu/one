import SwiftUI

// MARK: - Ready for you: "Mark all read" clears every new dot on the shelf in one tap.

extension Model {
    /// Every card on the shelf is read, and every finished helper behind one counts as seen.
    func markShelfRead() {
        guard shelf.contains(where: \.fresh) else { return }
        var v = shelf
        for k in v.indices { v[k].fresh = false }
        withAnimation(.easeOut(duration: 0.3)) { shelf = v }  // one save, not one per card
        for h in helpers where h.shelfID != nil { markSeen(h.id) }
    }
}

/// The shelf's title row: "Ready for you", the new count, and "Mark all read" below it while anything is new.
struct ShelfHeader: View {
    let fresh: Int
    var markAll: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Ready for you").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                if fresh > 0 {
                    Text("\(fresh) new").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color(hex: 0x141416))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFFE2C2))).fixedSize()
                }
                Spacer(minLength: 0)
            }
            if fresh > 0 {
                Button(action: markAll) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                        Text("Mark all read").font(.system(size: 10.5))
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color(hex: 0xF4EFE8, 0.6))
                .help("Clears every new dot. Nothing is moved or deleted.")
            }
        }
    }
}

/// Render-only: the shelf with new cards (button showing) and after the tap (all read, button gone).
enum ShelfReadRender {
    static func panel(read: Bool) -> AnyView {
        let items: [ShelfItem] = [
            ShelfItem(title: "Receipts 2026", detail: "23 receipts · $1,284 total", from: "Receipts helper", path: "/tmp/a.md", fresh: !read),
            ShelfItem(
                title: "Quebec flight prices", detail: "Newark $3,104 · Philadelphia $3,416", from: "Flight helper", path: "/tmp/b.md", fresh: !read),
            ShelfItem(title: "Reply to the school", detail: "Draft, not sent", from: "Elias", path: "/tmp/c.md", fresh: false),
        ]
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(fresh: read ? 0 : 114)  // worst case: Omar had 114 new
                ForEach(items) { ShelfCardView(item: $0) }
            }
            .padding(14).frame(width: 250, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.07)))
            .padding(20).background(WorldLook.bg).foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark))
    }
}
