import AppKit
import SwiftUI

// MARK: - Paste as a file or as text? (Claude Design "Long Paste", option 1 · Fold, approved by Omar 2026-11-04)
// Long text (over 30 lines or 2,000 characters) going into the ask box asks first, in a small pop-up between the
// orb and the ask box. "As a file" keeps the text as a file the assistant reads (a "Pasted text, 214 lines" chip
// above the ask box, like any attached file); "As text" puts it in the box as before. The X, a click outside
// and Esc close it without pasting. Short pastes, pictures and files paste exactly as before.
// Since 0.9.96 the question lives in the box itself (`AskTextView.shouldChangeText`), so every road in asks the
// same once: ⌘V with any flags (Caps Lock), Edit › Paste, right-click Paste, Paste and Match Style, a drop,
// Services, dictation and apps that type for you. Until then only a plain ⌘V key press asked.

struct PasteOffer: Identifiable {
    let id = UUID()
    let text: String
    let lines: Int
    /// The ask box it was going into, to put the text back in for "As text".
    weak var into: NSTextView?
    /// Where in the box it was going (the cursor, the selection it replaces, or the drop point).
    var range: NSRange? = nil
}

@MainActor enum LongPaste {
    static let overLines = 30
    static let overChars = 2000

    /// Lines as a person counts them: a Windows line end (\r\n) is one line end, not two.
    static func lines(_ t: String) -> Int {
        t.trimmingCharacters(in: .whitespacesAndNewlines).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }
    static func isLong(_ t: String) -> Bool { t.count > overChars || lines(t) > overLines }

    /// Every ⌘V rule: pictures and files attach first (`PictureIn.installPaste`); a ⌘V with the typing focus outside
    /// any box goes into the ask box; Esc and Return answer the pop-up while it's up. Long text asks in the box itself.
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
                return PictureIn.isPasteKey(e) ? nil : e
            }
            guard PictureIn.isPasteKey(e), let w = e.window ?? NSApp.keyWindow else { return e }
            return intoBox(w) ? nil : e
        }
    }

    /// ⌘V while the typing focus is on a chat message (or nowhere): the paste goes into the ask box, through the
    /// same question. Never when another text field has the focus (Find, a waiting message being changed).
    static func intoBox(_ w: NSWindow) -> Bool {
        if let tv = w.firstResponder as? NSTextView, tv.isEditable { return false }
        let m = Model.shared  // a reader or panel in front: the box behind it isn't where they're looking
        guard m.viewing == nil, m.openedShelf == nil, PopupLook.open == 0 || m.writingPanel else { return false }
        guard NSPasteboard.general.string(forType: .string) != nil || NSPasteboard.general.availableType(from: [.png, .tiff, .fileURL]) != nil,
            let box = box(in: w)
        else { return false }
        w.makeFirstResponder(box)
        box.paste(nil)
        return true
    }

    /// The ask box in this window that's on screen: the newest one (the writing panel's while it's open).
    static func box(in w: NSWindow) -> AskTextView? {
        if let l = AskTextView.latest, l.window === w, l.isEditable, !l.isHiddenOrHasHiddenAncestor { return l }
        func find(_ v: NSView) -> AskTextView? {
            if let a = v as? AskTextView, a.isEditable, !a.isHiddenOrHasHiddenAncestor { return a }
            for s in v.subviews.reversed() { if let a = find(s) { return a } }
            return nil
        }
        return w.contentView.flatMap(find)
    }

    /// Text on its way into an ask box: true when it's long, so it waits on the question instead of going in.
    /// While the question is up, any other long text waits too (the first one is what it asks about).
    static func ask(_ text: String, into tv: NSTextView, at range: NSRange?) -> Bool {
        guard isLong(text) else { return false }
        if Model.shared.pasteOffer == nil {
            Model.shared.pasteOffer = PasteOffer(text: text, lines: lines(text), into: tv, range: range)
        }
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

    /// "As text": into the box where it was going, exactly as without the question.
    static func asText() {
        let m = Model.shared
        guard let o = m.pasteOffer else { return }
        m.pasteOffer = nil
        guard let tv = o.into else { return }
        focus(tv)
        let n = (tv.string as NSString).length
        let r = o.range.flatMap { NSMaxRange($0) <= n ? $0 : nil } ?? tv.selectedRange()
        (tv as? AskTextView)?.letThrough = true
        tv.insertText(o.text, replacementRange: r)
        (tv as? AskTextView)?.letThrough = false
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
    /// Applied after the writing panel, so a paste into the writing panel asks on top of it, not hidden under it.
    func pasteAsk(_ m: Model) -> some View {
        let close: () -> Void = { LongPaste.close() }
        return onePopup(m.pasteOffer != nil, close: close, align: .bottom, inset: EdgeInsets(top: 0, leading: 0, bottom: 118, trailing: 0)) { _ in
            if let o = m.pasteOffer { PasteAsk(offer: o) }
        }
    }
}
