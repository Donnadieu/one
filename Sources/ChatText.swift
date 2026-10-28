import AppKit
import SwiftUI

// MARK: - Chat messages you can select and copy

/// One chat message (the person's or the assistant's) as one selectable piece of text: drag across
/// lines to select, ⌘A inside it, ⌘C, and a right-click menu with Copy (plain words) and Copy as
/// Markdown. Same look as `MarkdownText`, drawn by AppKit so a selection can run across the whole
/// message. Still renders (ImageRenderer can't draw AppKit views) fall back to the SwiftUI drawing.
struct ChatText: View {
    let text: String
    var size: CGFloat = 15
    /// The person's own words: shown as typed, no Markdown.
    var plain = false
    var center = false
    var accent = false
    @Environment(\.openURL) var openURL

    /// Set while `--render-world` draws stills.
    @MainActor static var still = false

    var body: some View {
        if ChatText.still {
            if plain {
                Text(text).font(.system(size: size)).foregroundStyle(accent ? Color.accentColor : Color.primary)
                    .multilineTextAlignment(center ? .center : .leading)
            } else {
                MarkdownText(text: text, size: size)
            }
        } else {
            ChatTextBox(shown: ChatText.attributed(text, size: size, plain: plain, center: center, accent: accent), markdown: text, plain: plain) {
                openURL($0)
            }
        }
    }

    /// The message in plain words for Copy: Markdown marks gone, a blank line between paragraphs.
    static func plain(_ md: String) -> String {
        var out = ""
        var lastList = false
        for b in MarkdownText.blocks(md) {
            var line: String
            var list = false
            switch b {
            case .heading(_, let t), .para(let t), .quote(let t): line = String(MarkdownText.inline(t).characters)
            case .bullet(let i, let t):
                line = String(repeating: "  ", count: i) + "• " + String(MarkdownText.inline(t).characters)
                list = true
            case .numbered(let i, let n, let t):
                line = String(repeating: "  ", count: i) + n + ". " + String(MarkdownText.inline(t).characters)
                list = true
            case .code(let c): line = c
            case .table(let rows):
                line = rows.map { $0.map { String(MarkdownText.inline($0).characters) }.joined(separator: "\t") }.joined(separator: "\n")
            case .rule: continue
            }
            if !out.isEmpty { out += list && lastList ? "\n" : "\n\n" }
            out += line
            lastList = list
        }
        return out
    }

    static var callout: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize }

    /// What the message looks like: Markdown blocks for replies, the typed words for the person's own.
    static func attributed(_ text: String, size: CGFloat, plain: Bool, center: Bool, accent: Bool) -> NSAttributedString {
        let color = accent ? NSColor.controlAccentColor : NSColor.labelColor
        let s: NSMutableAttributedString
        if plain {
            s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 1.5
            s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        } else {
            s = NSMutableAttributedString(attributedString: NoteText.attributed(text, size: size, body: color, dim: .secondaryLabelColor))
        }
        if center {
            s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, r, _ in
                let p = ((v as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                p.alignment = .center
                s.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }
        return s
    }

    /// Height of `s` laid out at `width` (same text system the view draws with).
    static func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let ts = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        ts.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: ceil(used.width), height: ceil(max(used.height, 1)))
    }

    /// Renders only: the message drawn by the live text view, with a selection showing.
    static func snapshot(_ text: String, size: CGFloat = 16, width: CGFloat, select: NSRange? = nil, plain: Bool = false, center: Bool = false)
        -> NSImage
    {
        let s = attributed(text, size: size, plain: plain, center: center, accent: plain)
        let h = measure(s, width: width).height
        let tv = ChatTextView.make()
        tv.appearance = NSAppearance(named: .darkAqua)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: h)
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(s)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        if let r = select {
            tv.layoutManager?.addTemporaryAttributes([.backgroundColor: NoteText.cream.withAlphaComponent(0.24)], forCharacterRange: r)
        }
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage(size: tv.bounds.size) }
        rep.size = tv.bounds.size
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let img = NSImage(size: tv.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

/// A long document in the readers (Ready for you, files): one scrolling, selectable text with the same
/// right-click menu as chat messages.
struct ReaderText: View {
    let text: String
    @Environment(\.openURL) var openURL
    var body: some View {
        if ChatText.still {
            // Renders draw a ScrollView blank, so the text is drawn as is, from the top.
            MarkdownText(text: text, size: 15).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            NoteText(text: text, size: 15, open: { openURL($0) }, system: true).padding(.horizontal, 22).padding(.vertical, 18)
        }
    }
}

/// The AppKit text view behind `ChatText`, sized by SwiftUI to the message's height.
struct ChatTextBox: NSViewRepresentable {
    let shown: NSAttributedString
    let markdown: String
    var plain = false
    let open: (URL) -> Void

    func makeNSView(context: Context) -> ChatTextView {
        let tv = ChatTextView.make()
        tv.delegate = context.coordinator
        context.coordinator.open = open
        set(tv, context)
        return tv
    }
    func updateNSView(_ tv: ChatTextView, context: Context) {
        context.coordinator.open = open
        // Only replace the text when it really changed, or every redraw would drop the selection.
        if !shown.isEqual(to: context.coordinator.shown) { set(tv, context) }
    }
    func set(_ tv: ChatTextView, _ context: Context) {
        context.coordinator.shown = shown
        context.coordinator.fits = [:]
        tv.markdown = markdown
        tv.plainCopy = plain ? markdown : ChatText.plain(markdown)
        tv.textStorage?.setAttributedString(shown)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: ChatTextView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        if let h = context.coordinator.fits[w] { return h }
        var s = ChatText.measure(shown, width: max(w, 1))
        if proposal.width != nil && w < 100_000 { s.width = w }
        context.coordinator.fits[w] = s
        return s
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown = NSAttributedString()
        var fits: [CGFloat: CGSize] = [:]
        var open: (URL) -> Void = { _ in }
        /// Links go through the app's own link handling (files open in One's reader, web links in the browser).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let u = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { open(u) }
            return true
        }
    }
}

/// A read-only, selectable text view that knows the Markdown it shows, for the right-click menu.
final class ChatTextView: NSTextView {
    var markdown = ""
    /// What Copy puts on the clipboard for the whole message (falls back to the words on screen).
    var plainCopy: String?

    static func make() -> ChatTextView {
        let tv = ChatTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        tv.selectedTextAttributes = [.backgroundColor: NoteText.cream.withAlphaComponent(0.24)]
        tv.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        return tv
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    /// One selection at a time: leaving a message clears its highlight.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return ok
    }

    /// Plain words of the whole message, as it reads on screen.
    var plainText: String { plainCopy ?? textStorage?.string ?? "" }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if selectedRange().length > 0 {
            m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Copy Whole Message", action: #selector(copyPlain(_:)), keyEquivalent: "").target = self
        } else {
            m.addItem(withTitle: "Copy", action: #selector(copyPlain(_:)), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "Copy as Markdown", action: #selector(copyMarkdown(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return m
    }

    /// ⌘C puts plain words on the clipboard (no stray colours when pasted elsewhere).
    override func copy(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0, let s = textStorage?.string as NSString? else { return }
        ChatTextView.put(s.substring(with: r).replacingOccurrences(of: "▎  ", with: ""))
    }
    @objc func copyPlain(_ sender: Any?) { ChatTextView.put(plainText) }
    @objc func copyMarkdown(_ sender: Any?) { ChatTextView.put(markdown.isEmpty ? plainText : markdown) }

    static func put(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
