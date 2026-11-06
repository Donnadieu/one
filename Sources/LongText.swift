import AppKit
import SwiftUI

// MARK: - Long messages fold away (Claude Design "Long Paste", option 1 · Fold, approved by Omar 2026-11-04)
// A message over 12 lines (his own or the assistant's, under the orb and in Message history) shows its first
// 4 lines with a soft fade and "Show all (214 lines)". Open, it has Hide at its top and at its end, so he never
// scrolls back up to fold it. Whether a message is open is remembered per message, across restarts.

enum LongFold {
    /// Over this many lines a message folds.
    static let foldOver = 12
    /// Lines shown while folded.
    static let keep = 4
    /// About how many characters fit on one line of the chat column (for messages that are one long paragraph).
    static let perLine = 90
    /// Remembered open messages (UserDefaults), newest last, at most `maxRemembered`.
    static let key = "longOpen"
    static let maxRemembered = 300

    /// Lines as the chat shows them: each written line, a long one counted as the lines it wraps to.
    static func lines(_ t: String) -> Int {
        t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            .reduce(0) { $0 + max(1, Int((Double($1.count) / Double(perLine)).rounded(.up))) }
    }
    static func folds(_ t: String) -> Bool { lines(t) > foldOver }
    /// The number the label shows: the written lines, or the wrapped estimate when it's one long paragraph.
    static func label(_ t: String) -> Int {
        let written = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").count
        return written > foldOver ? written : lines(t)
    }
    /// A message's lasting name: when it was said, who said it and its length (saved bubbles keep all three).
    static func key(_ b: Bubble) -> String { "\(Int(b.date.timeIntervalSince1970 * 1000))-\(b.fromMe ? "me" : "ai")-\(b.text.count)" }

    static func isOpen(_ k: String, in raw: String) -> Bool { raw.split(separator: "\n").contains { $0 == k } }
    static func set(_ k: String, open: Bool, in raw: String) -> String {
        var ks = raw.split(separator: "\n").map(String.init).filter { $0 != k }
        if open { ks.append(k) }
        return ks.suffix(maxRemembered).joined(separator: "\n")
    }
    /// Height of `keep` lines of chat text at this size (same font and spacing `ChatText` draws with).
    /// What a folded message hands to the text view: its first lines only. The fold shows 4 lines; laying out
    /// the whole message and clipping it was most of the wait when earlier messages opened (routine reports
    /// held 88% of the text in Omar's chat).
    static func head(_ t: String) -> String {
        let lines = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").prefix(keep + 4)
        let h = lines.joined(separator: "\n")
        return h.count > 900 ? String(h.prefix(900)) : h
    }
    static func foldedHeight(_ size: CGFloat) -> CGFloat {
        (NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: size)) + 1.5) * CGFloat(keep)
    }
}

/// A chat message that folds when it's long. Short messages are drawn exactly as before.
struct LongFoldText: View {
    let text: String
    /// The message's lasting name (`LongFold.key`); nil = not remembered (stays folded each time).
    let key: String?
    var size: CGFloat = 15
    var plain = false
    var center = false
    var accent = false
    /// The reply being written right now never folds under the reader's eyes.
    var live = false
    /// Hug the words (a pill around your own message) instead of taking the whole width.
    var hug = false
    @AppStorage(LongFold.key) var raw = ""
    @State var openHere = false

    var open: Bool { key.map { LongFold.isOpen($0, in: raw) } ?? openHere }

    var body: some View {
        if live || !LongFold.folds(text) {
            message
        } else {
            VStack(alignment: center ? .center : .leading, spacing: 6) {
                if open { control(hide: true) }
                if open {
                    message
                } else {
                    ChatText(text: LongFold.head(text), size: size, plain: plain, center: center, accent: accent, copy: text)
                        .frame(height: LongFold.foldedHeight(size), alignment: .top).clipped()
                        .mask(
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: size * 2.4)
                            })
                }
                control(hide: open)
            }
        }
    }

    var message: some View { ChatText(text: text, size: size, plain: plain, center: center, accent: accent, hug: hug) }

    func control(hide: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hide ? "chevron.up" : "chevron.down").font(.system(size: 9.5, weight: .semibold))
                Text(hide ? "Hide" : "Show all (\(LongFold.label(text)) lines)").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(WorldLook.cream.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(WorldLook.cream.opacity(0.07)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(hide ? "Fold this message" : "Show the whole message")
        .accessibilityLabel(hide ? "Hide" : "Show all")
    }

    func toggle() {
        if let key { raw = LongFold.set(key, open: !open, in: raw) } else { openHere.toggle() }
    }
}
