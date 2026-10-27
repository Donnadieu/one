import AppKit
import SwiftUI

// MARK: - A note's text as one selectable piece (drag across paragraphs, then ⌘C)

/// The rooms note reader's body: the whole note in one text view, so a selection can run across
/// headings, paragraphs and lists. Same look as `MarkdownText` (sizes, spacing), drawn by AppKit.
struct NoteText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 14
    /// Where links go; by default only web links open (in the browser).
    var open: ((URL) -> Void)? = nil
    /// The system's text colours (chat readers) instead of the rooms' cream.
    var system = false

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoteText.textView(width: 320)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        context.coordinator.open = open
        tv.markdown = text
        tv.plainCopy = ChatText.plain(text)
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.documentView = tv
        tv.textStorage?.setAttributedString(look(text))
        context.coordinator.shown = text
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.open = open
        guard context.coordinator.shown != text, let tv = sv.documentView as? ChatTextView else { return }
        context.coordinator.shown = text
        tv.markdown = text
        tv.plainCopy = ChatText.plain(text)
        tv.textStorage?.setAttributedString(look(text))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scroll(.zero)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func look(_ s: String) -> NSAttributedString {
        system ? NoteText.attributed(s, size: size, body: .labelColor, dim: .secondaryLabelColor) : NoteText.attributed(s, size: size)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown = ""
        var open: ((URL) -> Void)?
        /// Web links open in the browser; links to other notes do nothing here (the linked notes sit below).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let open, let u = link as? URL ?? (link as? String).flatMap(URL.init(string:)) {
                open(u)
            } else if let u = link as? URL ?? (link as? String).flatMap(URL.init(string:)), ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
            return true
        }
    }

    static let cream = NSColor(srgbRed: 0xF4 / 255, green: 0xEF / 255, blue: 0xE8 / 255, alpha: 1)

    /// A read-only, selectable text view with One's colours (and the Copy / Copy as Markdown menu).
    static func textView(width: CGFloat) -> ChatTextView {
        let tv = ChatTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.selectedTextAttributes = [.backgroundColor: cream.withAlphaComponent(0.24)]
        tv.linkTextAttributes = [
            .foregroundColor: NSColor(srgbRed: 0x9F / 255, green: 0xC9 / 255, blue: 0xD8 / 255, alpha: 1), .cursor: NSCursor.pointingHand,
        ]
        return tv
    }

    /// Plain words of the whole note (for the copy button): title, then the body as it reads on screen.
    static func plain(title: String, _ text: String) -> String {
        title + "\n\n" + attributed(text, size: 14).string
    }

    /// The note's Markdown as one attributed string: the same blocks `MarkdownText` draws.
    static func attributed(
        _ src: String, size: CGFloat, body: NSColor = cream.withAlphaComponent(0.9), dim: NSColor = cream.withAlphaComponent(0.5)
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MarkdownText.blocks(src)
        for (i, b) in blocks.enumerated() {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 8
            p.lineSpacing = 1.5
            var piece = NSMutableAttributedString()
            switch b {
            case .heading(let l, let t):
                p.paragraphSpacingBefore = i == 0 ? 0 : 4
                piece = inline(t, size: size + CGFloat(max(0, 4 - l)) * 2, color: body, weight: .semibold)
            case .bullet(let ind, let t), .numbered(let ind, _, let t):
                let lead = CGFloat(ind) * 16
                var mark = "•"
                if case .numbered(_, let n, _) = b { mark = n + "." }
                let stop = lead + (mark == "•" ? 14 : 22)
                p.firstLineHeadIndent = lead
                p.headIndent = stop
                p.tabStops = [NSTextTab(textAlignment: .left, location: stop)]
                p.paragraphSpacing = 5
                piece = NSMutableAttributedString(string: mark + "\t", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: dim])
                piece.append(inline(t, size: size, color: body))
            case .quote(let t):
                // Indents, not NSTextBlock: the text view lays blocks out as plain paragraphs.
                p.headIndent = 12
                piece = NSMutableAttributedString(
                    string: "▎  ", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: dim.withAlphaComponent(0.4)])
                piece.append(inline(t, size: size, color: dim))
            case .code(let c):
                p.firstLineHeadIndent = 10
                p.headIndent = 10
                piece = NSMutableAttributedString(
                    string: c, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular), .foregroundColor: body])
            case .table(let rows):
                piece = table(rows, size: size, color: body, p: p)
            case .rule:
                p.tabStops = [NSTextTab(textAlignment: .left, location: 2000)]
                piece = NSMutableAttributedString(
                    string: "\t",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 6), .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: cream.withAlphaComponent(0.14),
                    ])
            case .para(let t):
                piece = inline(t, size: size, color: body)
            }
            if i < blocks.count - 1 { piece.append(NSAttributedString(string: "\n")) }
            piece.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        }
        return out
    }

    /// Rows as tab-separated lines with one tab stop per column; the first row is the header.
    static func table(_ rows: [[String]], size: CGFloat, color: NSColor, p: NSMutableParagraphStyle) -> NSMutableAttributedString {
        let font = NSFont.systemFont(ofSize: size)
        let cols = rows.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: cols)
        for r in rows {
            for (j, c) in r.enumerated() {
                widths[j] = max(widths[j], (c as NSString).size(withAttributes: [.font: font]).width)
            }
        }
        var x: CGFloat = 0
        p.tabStops = widths.dropLast().map { w in
            x += w + 14
            return NSTextTab(textAlignment: .left, location: x)
        }
        p.paragraphSpacing = 4
        let s = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            for (j, c) in r.enumerated() {
                if j > 0 { s.append(NSAttributedString(string: "\t")) }
                s.append(inline(c, size: size, color: color, weight: i == 0 ? .semibold : .regular))
            }
            if i < rows.count - 1 { s.append(NSAttributedString(string: "\n")) }
        }
        return s
    }

    /// Inline Markdown (bold, italic, code, links) in AppKit fonts.
    static func inline(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSMutableAttributedString {
        let a = MarkdownText.inline(s)
        let out = NSMutableAttributedString()
        for run in a.runs {
            let part = String(a[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font =
                intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let l = run.link { attrs[.link] = l }
            out.append(NSAttributedString(string: part, attributes: attrs))
        }
        return out
    }

    /// Renders only (ImageRenderer can't draw AppKit views): the same text view drawn into a picture,
    /// optionally with a selection showing, cut at `height`.
    static func snapshot(_ text: String, size: CGFloat = 14, width: CGFloat, height: CGFloat, select: NSRange? = nil) -> NSImage {
        let tv = textView(width: width)
        tv.textStorage?.setAttributedString(attributed(text, size: size))
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tv.appearance = NSAppearance(named: .darkAqua)
        if let r = select {
            tv.setSelectedRange(r)
            // A view outside a window draws no selection, so paint the same colour the live view uses.
            tv.layoutManager?.addTemporaryAttributes([.backgroundColor: cream.withAlphaComponent(0.24)], forCharacterRange: r)
        }
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage(size: tv.bounds.size) }
        rep.size = tv.bounds.size
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let img = NSImage(size: tv.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}
