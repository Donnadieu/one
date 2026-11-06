import AppKit
import SwiftUI

// MARK: - Going back in the chat: the day pill, Find, "Back to now" (A+ · Quiet scroll + find, Omar Nov 5 2026)
// While earlier messages show, the greeting row becomes one small pill: the day you're looking at and a
// magnifier. Either opens one panel: "Find in our chat" on top (matches as short lines, the match in bold),
// "Jump to a day" underneath. Picking one moves the chat there (ChatPager.jump). It's One's pop-up
// (`onePopup`: the same glass, closes with its X, a click outside, Esc). "Back to now" sits above the ask box and brings the orb back.

struct DayPill: View {
    let day: String
    @Binding var finding: Bool
    var body: some View {
        Button {
            finding.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(day).font(.system(size: 13, weight: .medium))
                Image(systemName: finding ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
                Rectangle().fill(WorldLook.cream.opacity(0.18)).frame(width: 1, height: 14)
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(WorldLook.cream.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color(hex: 0x1C1C20, 0.9)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("Find in our chat or jump to a day (⌘F)")
        .keyboardShortcut("f", modifiers: .command)
    }
}

struct FindPanel: View {
    @ObservedObject var pager: ChatPager
    let close: () -> Void
    @State var q = FindPanel.stillQuery
    @FocusState var focused: Bool
    /// Renders only: what's typed in the field.
    nonisolated(unsafe) static var stillQuery = ""

    var body: some View {
        let (total, hits) = pager.find(q)
        VStack(alignment: .leading, spacing: 0) {
            Text("Go back in our chat").font(.system(size: 14, weight: .semibold)).foregroundStyle(WorldLook.cream)
                .frame(height: 28).padding(.top, 16).padding(.horizontal, 18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.6))
                if HomeView.still {
                    Text(q.isEmpty ? "Find in our chat" : q).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(q.isEmpty ? 0.4 : 0.95))
                    Spacer(minLength: 0)
                } else {
                    TextField("Find in our chat", text: $q).textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                        .onSubmit { if let h = hits.first { go(h.id) } }
                }
                if q.count >= 2 {
                    Text(total == 1 ? "1 match" : "\(total) matches").font(.caption).foregroundStyle(WorldLook.cream.opacity(0.45))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WorldLook.cream.opacity(0.06)))
            .padding(10)
            if pager.loadingArchive {
                Text("Reading the rest of our chat…").font(.caption).foregroundStyle(WorldLook.cream.opacity(0.45)).padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            if q.count >= 2 && hits.isEmpty && !pager.loadingArchive {
                Text("Nothing found for \u{201C}\(q)\u{201D}.").font(.callout).foregroundStyle(WorldLook.cream.opacity(0.55)).padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            ForEach(hits) { h in
                Button {
                    go(h.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(h.day).font(.caption).foregroundStyle(WorldLook.cream.opacity(0.45)).frame(width: 74, alignment: .leading)
                        (Text(h.before) + Text(h.hit).bold().foregroundColor(WorldLook.cream) + Text(h.after))
                            .font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !hits.isEmpty { Divider().overlay(WorldLook.cream.opacity(0.08)).padding(.vertical, 6) }
            Text("JUMP TO A DAY").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.4))
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 4)
            ForEach(pager.dayList(), id: \.day) { d in
                Button {
                    pager.jump(toDay: d.day)
                    close()
                } label: {
                    HStack {
                        Text(d.label).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.85))
                        Spacer()
                        Text("\(d.count)").font(.caption).foregroundStyle(WorldLook.cream.opacity(0.4))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Color.clear.frame(height: 8)
        }
        .frame(width: 440)
        .onAppear {
            focused = true
            if !HomeView.still { pager.readArchive() }
        }
    }

    func go(_ id: UUID) {
        pager.jump(to: id)
        close()
    }
}

/// "Back to now ↓": above the ask box while earlier messages show.
struct BackToNow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Back to now").font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(WorldLook.cream.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color(hex: 0x1C1C20, 0.92)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("Back to the latest messages")
    }
}

/// The line at the top of earlier messages: loading more, or the very start of the chat.
struct EarlierEdge: View {
    let more: Bool
    var body: some View {
        HStack(spacing: 6) {
            if more { ProgressView().controlSize(.mini) }
            Text(more ? "Loading earlier…" : "The start of our chat").font(.caption)
        }
        .foregroundStyle(WorldLook.cream.opacity(0.5)).frame(maxWidth: .infinity).frame(height: 30)
    }
}

/// Scrolling up at the top of home opens earlier messages by itself (no button to find). One watcher for the app.
@MainActor enum ScrollUpOpener {
    nonisolated(unsafe) static var installed = false
    nonisolated(unsafe) static var pull: CGFloat = 0
    nonisolated(unsafe) static var lastAt = Date.distantPast
    /// `ready()`: home is showing, earlier messages are closed and the page is at its top.
    static func install(ready: @escaping @MainActor () -> Bool, open: @escaping @MainActor () -> Void) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated {
                guard e.scrollingDeltaY > 0, e.window?.isMainWindow == true, ready() else {
                    pull = 0
                    return
                }
                if Date().timeIntervalSince(lastAt) > 0.5 { pull = 0 }
                lastAt = Date()
                pull += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
                if pull > 40 {
                    pull = 0
                    open()
                }
            }
            return e
        }
    }
}
