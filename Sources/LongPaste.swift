import AppKit
import SwiftUI

// MARK: - Paste as a file or as text? (Claude Design "Long Paste", option 1 · Fold, approved by Omar 2026-11-04)
// ⌘V of long text (over 30 lines or 2,000 characters) into the ask box asks first, in a small pop-up between the
// orb and the ask box. "As a file" keeps the text as a file the assistant reads (a "Pasted text, 214 lines" chip
// above the ask box, like any attached file); "As text" pastes it into the box as before. The X, a click outside
// and Esc close it without pasting. Short pastes, pictures and files paste exactly as before.

struct PasteOffer: Identifiable {
    let id = UUID()
    let text: String
    let lines: Int
    /// The ask box it was pasted into, to put the text back in for "As text".
    weak var into: NSTextView?
}

@MainActor enum LongPaste {
    static let overLines = 30
    static let overChars = 2000

    static func lines(_ t: String) -> Int { t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).count }
    static func isLong(_ t: String) -> Bool { t.count > overChars || lines(t) > overLines }

    /// Every ⌘V rule: pictures and files attach first (`PictureIn.installPaste`), then long text into an ask box asks
    /// first; Esc and Return answer the pop-up while it's up.
    static func install() {
        PictureIn.installPaste()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let m = Model.shared
            if m.pasteOffer != nil {
                if e.keyCode == 53 {  // Esc: close, nothing pasted
                    m.pasteOffer = nil
                    return nil
                }
                if e.keyCode == 36 || e.keyCode == 76 {  // Return: the main button
                    asFile()
                    return nil
                }
                // ⌘V again while it asks: the question still stands (never pasted into the box behind it).
                let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                return cmd && e.charactersIgnoringModifiers == "v" ? nil : e
            }
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v" else { return e }
            return offer(NSPasteboard.general, in: e.window ?? NSApp.keyWindow) ? nil : e
        }
    }

    /// True when the paste was long text going into an ask box: the question is up and the paste waits on it.
    static func offer(_ pb: NSPasteboard, in window: NSWindow?) -> Bool {
        guard let tv = window?.firstResponder as? AskTextView, tv.isEditable,
            pb.availableType(from: [.png, .tiff, .fileURL]) == nil,
            let text = pb.string(forType: .string), isLong(text)
        else { return false }
        Model.shared.pasteOffer = PasteOffer(text: text, lines: lines(text), into: tv)
        return true
    }

    /// "As a file": the text becomes a file chip above the ask box; the assistant gets its path when it's sent.
    static func asFile() {
        let m = Model.shared
        guard let o = m.pasteOffer else { return }
        m.pasteOffer = nil
        if let f = SharedFile.fromText(o.text, lines: o.lines) { PictureIn.addFiles([f]) }
        focus(o.into)
    }

    /// "As text": pasted into the box, exactly as without the question.
    static func asText() {
        let m = Model.shared
        guard let o = m.pasteOffer else { return }
        m.pasteOffer = nil
        guard let tv = o.into else { return }
        focus(tv)
        tv.insertText(o.text, replacementRange: tv.selectedRange())
    }

    static func close() {
        let m = Model.shared
        let tv = m.pasteOffer?.into
        m.pasteOffer = nil
        focus(tv)
    }

    static func focus(_ tv: NSTextView?) {
        guard let tv, let w = tv.window else { return }
        w.makeFirstResponder(tv)
    }
}

/// The pop-up itself (on One's shared pop-up glass, with its X and "Esc to close").
struct PasteAsk: View {
    let offer: PasteOffer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Paste as a file or as text?").font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 120)  // the X and "Esc to close"
            }.frame(minHeight: 28)
            Text("It's long: \(offer.lines) lines. As a file keeps your chat tidy, and I still read all of it.")
                .font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("As text") { LongPaste.asText() }.buttonStyle(.bordered)
                Button {
                    LongPaste.asFile()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 12, weight: .semibold))
                        Text("As a file").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(WorldLook.bg).padding(.horizontal, 16).frame(height: 30).background(Capsule().fill(WorldLook.cream))
                }
                .buttonStyle(.plain)
            }.padding(.top, 6)
        }
        .foregroundStyle(WorldLook.cream)
        .padding(20).frame(width: 400, alignment: .leading)
    }
}

extension View {
    /// Home's "Paste as a file or as text?" pop-up, just above the ask box (below the orb, never over it).
    func pasteAsk(_ m: Model) -> some View {
        let close: () -> Void = { LongPaste.close() }
        return onePopup(m.pasteOffer != nil, close: close, align: .bottom, inset: EdgeInsets(top: 0, leading: 0, bottom: 118, trailing: 0)) { _ in
            if let o = m.pasteOffer { PasteAsk(offer: o) }
        }
    }
}
