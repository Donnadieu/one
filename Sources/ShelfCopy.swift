import AppKit
import PDFKit
import SwiftUI

/// Copying from the Ready for you shelf.
/// ⌘C on the card you just clicked puts the FILE on the clipboard (pastes into Finder, Mail, Messages, Slack as an attachment)
/// and, for text files, its text too (pastes into a text box as text). The right-click menu and the reader's "Copy all" use the same pieces.
@MainActor
final class ShelfCopy: ObservableObject {
    static let shared = ShelfCopy()
    /// The card last clicked: ⌘C copies it. Any other click clears it, so ⌘C on selected text elsewhere still copies that text.
    @Published var picked: UUID?
    /// A short "Copied" note under the shelf.
    @Published var note: String?
    private var pickedURL: URL?
    private var monitor: Any?
    private var noteTask: Task<Void, Never>?

    /// Files whose text is the file itself.
    nonisolated static let textKinds: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml", "log"]
    /// Documents macOS can read the text out of.
    nonisolated static let richKinds: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt", "html", "htm"]

    nonisolated static func hasText(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return textKinds.contains(e) || richKinds.contains(e) || e == "pdf"
    }

    /// The whole text of a document: the file itself, a PDF's text (PDFKit), or a Word/RTF document's text.
    nonisolated static func text(of url: URL) -> String? {
        let e = url.pathExtension.lowercased()
        var t: String?
        if textKinds.contains(e) {
            t = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        } else if e == "pdf" {
            t = PDFDocument(url: url)?.string
        } else if richKinds.contains(e) {
            t = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let t, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    /// The file as an attachment; with `withText`, a text file's text rides along on the same clipboard item.
    @discardableResult
    nonisolated static func copyFile(_ url: URL, withText: Bool, to pb: NSPasteboard = .general) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if withText, textKinds.contains(url.pathExtension.lowercased()), let t = text(of: url) { item.setString(t, forType: .string) }
        pb.clearContents()
        return pb.writeObjects([item])
    }

    /// Just the words.
    @discardableResult
    nonisolated static func copyText(_ url: URL, to pb: NSPasteboard = .general) -> Bool {
        guard let t = text(of: url) else { return false }
        pb.clearContents()
        return pb.setString(t, forType: .string)
    }

    func pick(_ it: ShelfItem) {
        picked = it.id
        pickedURL = it.url
        start()
    }

    func say(_ s: String) {
        note = s
        noteTask?.cancel()
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { self.note = nil }
        }
    }

    func copyFile(_ it: ShelfItem, withText: Bool) {
        say(Self.copyFile(it.url, withText: withText) ? "File copied. Paste it into Mail, Messages or a folder." : "That file was moved or deleted.")
    }

    func copyText(_ it: ShelfItem) {
        say(Self.copyText(it.url) ? "Text copied." : "There's no text in this one to copy.")
    }

    static func share(_ url: URL) {
        DispatchQueue.main.async {  // after the right-click menu has closed
            guard let w = NSApp.keyWindow ?? NSApp.mainWindow, let v = w.contentView else { return }
            let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
            NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
    }

    /// Watches ⌘C and clicks inside One's own windows (a local monitor: never other apps' keys).
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
            MainActor.assumeIsolated { ShelfCopy.shared.handle(e) }
        }
    }

    /// Returns nil when the event was used (the card was copied).
    func handle(_ e: NSEvent) -> NSEvent? {
        if e.type != .keyDown {
            picked = nil  // a card's own click picks it again right after this
            return e
        }
        guard Self.isCopyKey(e), picked != nil, let u = pickedURL, !Self.hasSelection(NSApp?.keyWindow?.firstResponder) else { return e }
        say(Self.copyFile(u, withText: true) ? "File copied. Paste it into Mail, Messages or a folder." : "That file was moved or deleted.")
        return nil
    }

    nonisolated static func isCopyKey(_ e: NSEvent) -> Bool {
        e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
            && e.charactersIgnoringModifiers?.lowercased() == "c"
    }

    /// Text is selected where the keyboard is: ⌘C belongs to that text, not to the card.
    static func hasSelection(_ r: NSResponder?) -> Bool {
        if let t = r as? NSTextView { return t.selectedRanges.contains { $0.rangeValue.length > 0 } }
        if let p = r as? PDFView { return !(p.currentSelection?.string ?? "").isEmpty }
        return false
    }

    /// `One --test-shelf-copy <file> [cmd-c|copy-text]`: runs the real copy paths on the clipboard and prints what's on it after each.
    /// With a step name it stops after that step, so the clipboard can be checked from outside.
    static func check(_ path: String, stop: String? = nil) -> Bool {
        let url = URL(fileURLWithPath: path)
        let pb = NSPasteboard.general
        var ok = true
        func show(_ step: String, _ want: [NSPasteboard.PasteboardType]) {
            let types = pb.types ?? []
            let has = want.allSatisfy { types.contains($0) }
            ok = ok && has
            let file = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let text = pb.string(forType: .string) ?? ""
            print("\(has ? "ok  " : "FAIL") \(step): file=\(file.first?.path ?? "-") text=\(text.count) chars types=\(types.map(\.rawValue))")
        }
        // ⌘C, through the same key handler the window uses
        let s = ShelfCopy.shared
        s.picked = UUID()
        s.pickedURL = url
        if let k = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)
        {
            let used = s.handle(k) == nil
            print("\(used ? "ok  " : "FAIL") cmd-c taken by the shelf")
            ok = ok && used
        }
        show("cmd-c", textKinds.contains(url.pathExtension.lowercased()) ? [.fileURL, .string] : [.fileURL])
        if stop == "cmd-c" { return ok }
        // a click elsewhere, then ⌘C: left alone
        if let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1),
            let k = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)
        {
            _ = s.handle(click)
            let left = s.handle(k) != nil
            print("\(left ? "ok  " : "FAIL") cmd-c after a click elsewhere is left alone")
            ok = ok && left
        }
        if stop != "copy-text" {
            copyFile(url, withText: false)
            show("copy file", [.fileURL])
        }
        if hasText(url) {
            copyText(url)
            show("copy text", [.string])
        }
        return ok
    }
}

/// Selected look + the right-click menu for a shelf card.
struct ShelfCopyable: ViewModifier {
    @ObservedObject var c = ShelfCopy.shared
    let item: ShelfItem
    let remove: () -> Void
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                    Color(hex: 0xFFE2C2, c.picked == item.id ? 0.6 : 0), lineWidth: 1.2)
            )
            .contextMenu { ShelfCopyMenu(item: item, remove: remove) }
    }
}

struct ShelfCopyMenu: View {
    let item: ShelfItem
    let remove: () -> Void
    /// The menu's lines in order (nil = a divider). The render draws the same list.
    static func entries(_ item: ShelfItem, remove: @escaping () -> Void) -> [(String, () -> Void)?] {
        var v: [(String, () -> Void)?] = [("Copy file", { ShelfCopy.shared.copyFile(item, withText: false) })]
        if ShelfCopy.hasText(item.url) { v.append(("Copy text", { ShelfCopy.shared.copyText(item) })) }
        v += [
            nil, ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }), ("Share…", { ShelfCopy.share(item.url) }), nil,
            ("Take off the shelf (the file stays)", remove),
        ]
        return v
    }
    var body: some View {
        ForEach(Array(Self.entries(item, remove: remove).enumerated()), id: \.offset) { _, e in
            if let e { Button(e.0) { e.1() } } else { Divider() }
        }
    }
}

/// "File copied" under the shelf, for a moment.
struct ShelfCopyNote: View {
    @ObservedObject var c = ShelfCopy.shared
    var body: some View {
        ZStack { line }.animation(.easeOut(duration: 0.2), value: c.note)
    }
    @ViewBuilder var line: some View {
        if let n = c.note {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: 0xFFE2C2))
                Text(n).font(.system(size: 11)).foregroundStyle(Color(hex: 0xF4EFE8, 0.9)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x2A2A2F, 0.98)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.14)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The reader's "Copy all": the whole document's text.
struct ShelfCopyAllButton: View {
    let url: URL
    @State private var done = false
    var body: some View {
        if ShelfCopy.hasText(url) {
            Button {
                done = ShelfCopy.copyText(url)
                if done { DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { done = false } }
            } label: {
                Label(done ? "Copied" : "Copy all", systemImage: done ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy the whole text, to paste anywhere")
        }
    }
}

/// `One --render-world`: the shelf with a picked card and its right-click menu, and the reader's toolbar with "Copy all".
@MainActor
enum ShelfCopyRender {
    static func sample(_ name: String, _ text: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    static var plan: ShelfItem {
        ShelfItem(
            title: "Quebec trip plan", detail: "Flights Dec 20 to 24, two hotels near the old town", from: "Flight to Quebec",
            path: sample("Quebec trip plan.md", "# Quebec trip plan\n\nCheapest: **$312** from PHL, Dec 20 to 24.\n").path, fresh: true)
    }
    static var pdf: ShelfItem {
        ShelfItem(title: "Receipts 2026", detail: "PDF · ready to share", from: "Receipts", path: sample("Receipts 2026.pdf", "").path, fresh: false)
    }
    static func menu() -> AnyView {
        let it = plan
        ShelfCopy.shared.picked = it.id
        ShelfCopy.shared.note = "File copied. Paste it into Mail, Messages or a folder."
        let lines = ShelfCopyMenu.entries(it) {}
        return AnyView(
            ZStack(alignment: .topLeading) {
                WorldLook.bg
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready for you").font(.system(size: 13, weight: .semibold))
                    ShelfCardView(item: it).modifier(ShelfCopyable(item: it) {})
                    ShelfCardView(item: pdf)
                    Spacer()
                }
                .padding(14).frame(width: 250, height: 400, alignment: .topLeading)
                .overlay(alignment: .bottom) { ShelfCopyNote().padding(.horizontal, 10).padding(.bottom, 34) }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.07)))
                .offset(x: 540, y: 20)
                // the right-click menu macOS draws (same lines, same order)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, e in
                        if let e {
                            Text(e.0).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == 0 ? Color.accentColor : .clear))
                        } else {
                            Divider().padding(.vertical, 5).padding(.horizontal, 10)
                        }
                    }
                }
                .padding(5).frame(width: 250)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x2C2C30, 0.97)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .offset(x: 330, y: 92)
            }
            .environment(\.colorScheme, .dark))
    }
    static func reader() -> AnyView {
        return AnyView(ShelfOpened(m: Model.shared, item: plan).background(WorldLook.bg).environment(\.colorScheme, .dark))
    }
}
