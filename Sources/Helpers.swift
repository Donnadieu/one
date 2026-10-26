import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

// MARK: - Helpers: Nova sends out a helper for each separate job; each is its own engine session.

struct Helper: Identifiable, Codable {
    var id = UUID()
    var title: String
    var task: String
    var sid: String?
    var state: String  // working, needsYes, done, stopped
    var line: String
    var reply: String = ""
    var asked: String?
    var finishedAway = false
    var toldNova: Bool?  // has Nova been given this result yet?
    var log: [String]?  // everything this helper reported, oldest first (kept for its file)
    var shelfID: UUID?  // its card on the Ready for you shelf
    var started: Date?  // when it was sent out
    var trail: [String]?  // plain-words steps it took, saved in Support/One/helpers/<id>.md
    var resumes: Int?  // times One picked it back up after a restart
    var resumeQueued: Bool?  // cut off by a restart, waiting to be picked back up
    var restartNews: String?  // the assistant hasn't been told it was picked back up yet
    var stoppedByYou: Bool?  // stopped on purpose (the Stop button): never picked back up after a restart
    var viewState: HelperState {
        switch state {
        case "working": .working
        case "needsYes": .needsYes
        case "stopped": .stopped
        default: .done
        }
    }
}

enum Helpers {
    /// Older conversations started before helpers existed, so the app reminds the assistant every turn (not shown to the user).
    static var note: String {
        "\n\n(One app note, not from the user: if this needs any work at all (looking something up, browsing, research, comparing, making a file, checking, watching), don't do it here: send helpers. Say in one short line what you're sending, then one line per job: [helper: Short title | the whole job with every detail]. If it has separate parts (e.g. movie times at two theaters, flights and hotels), send one helper per part so they run at the same time. Only answer here yourself when you already know the answer or it's just conversation. Any file you make for them (PDF, document, spreadsheet, picture) goes in \(Shelf.folder.path); the app puts it in front of them under Ready for you, so just say it's there, without the folder path.)"
    }
    /// Pull "[helper: Title | job]" lines out of Nova's reply.
    static func extract(_ text: String) -> (String, [(String, String)]) {
        var jobs: [(String, String)] = []
        var keep: [String] = []
        for l in text.components(separatedBy: "\n") {
            let tl = l.trimmingCharacters(in: .whitespaces)
            if tl.lowercased().hasPrefix("[helper:"), tl.hasSuffix("]") {
                let parts = tl.dropFirst(8).dropLast().split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { jobs.append((parts[0], parts[1])) }
            } else {
                keep.append(l)
            }
        }
        while let last = keep.last, last.trimmingCharacters(in: .whitespaces).isEmpty { keep.removeLast() }
        return (keep.joined(separator: "\n"), jobs)
    }
    /// Hide helper lines while a reply is still streaming in.
    static func strip(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[helper") }.joined(
            separator: "\n")
    }
    static func short(_ s: String, _ n: Int = 34) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
    static func summary(_ body: String, _ n: Int = 40) -> String {
        var t = body
        for mark in ["**", "__", "`", "#", "> "] { t = t.replacingOccurrences(of: mark, with: "") }
        let first = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Done"
        return short(first, n)
    }
    static func brief(assistant: String, user: String, task: String) -> String {
        """
        You're one of \(assistant.isEmpty ? "the assistant" : assistant)'s helpers, sent to do one job in the background while \(user.isEmpty ? "they" : user) keep talking to \(assistant.isEmpty ? "the assistant" : assistant). Don't send helpers yourself; do the job.

        The job: \(task)

        Do it now. Finish with a short message (2 to 4 lines): what you found or did, in plain words. If you need their yes before going further (money, sending, posting, deleting), stop and ask, ending with a [choices: ...] line. If the job is to keep watching something, do the first check now, say what you found, then set up a routine for the repeat checks (your scheduling tool, e.g. every 6 hours) and say how often it runs. A routine runs with nobody there to ask: its instructions must only check and report, never buy, send or delete; buying waits for their yes.
        """ + Bridge.note
    }
}

struct NovaWithHelpers: View {
    @ObservedObject var m: Model
    static func orbTime(_ t: Double, _ i: Int) -> Double { t + Double(i) * 3.1 }
    static let slots: [CGPoint] = [CGPoint(x: -168, y: -34), CGPoint(x: 168, y: -34), CGPoint(x: -150, y: 76), CGPoint(x: 150, y: 76)]
    var body: some View {
        let shown = Array(m.helpers.prefix(4).enumerated())
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: m.helpers.isEmpty)) { tl in
            let t = tl.date.timeIntervalSince(WorldLook.start)
            ZStack {
                Orb(size: 92, active: m.thinking).opacity(m.openHelper == nil ? 1 : 0.5)
                    .contentShape(Circle())
                    .onTapGesture { if m.openHelper != nil { withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil } } }
                    .help(m.openHelper == nil ? "" : "Back to \(m.name)")
                    .onHover { inside in if m.openHelper != nil { inside ? NSCursor.pointingHand.push() : NSCursor.pop() } }
                ForEach(shown, id: \.element.id) { i, h in
                    let p = Self.slots[i]
                    Button {
                        m.focusHelper(h.id)
                    } label: {
                        VStack(spacing: -10) {
                            HelperOrb(state: h.viewState, t: Self.orbTime(t, i), size: 42)
                            HelperLabel(title: Helpers.short(h.title, 24), line: Helpers.short(h.line, 32), warm: h.state == "needsYes")
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(h.state == "working" ? h.line : "Tap to see this job")
                    .offset(x: p.x + sin(t * 0.4 + Double(i) * 1.7) * 4, y: p.y + sin(t * 0.55 + Double(i) * 2.3) * 5)
                    .opacity(m.openHelper == nil || m.openHelper == h.id ? 1 : 0.5)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.2).combined(with: .opacity),
                            removal: .offset(x: -p.x, y: -p.y).combined(with: .scale(scale: 0.1)).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity).frame(height: m.helpers.isEmpty ? 150 : 250)
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: m.helpers.map(\.id))
    }
}

struct HelperCard: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        let parts = Choices.split(h.reply)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(h.title).font(.headline)
                Text("· " + (h.state == "working" ? "working" : h.state == "needsYes" ? "needs your yes" : h.state == "stopped" ? "stopped" : "done"))
                    .foregroundStyle(h.state == "needsYes" ? Color.orange : Color.secondary)
                Spacer()
                Button {
                    m.openHelper = nil
                } label: {
                    Label(m.name, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Back to \(m.name)")
            }
            if let a = h.asked, !a.isEmpty { Text(a).font(.callout).foregroundStyle(Color.accentColor) }
            if h.reply.isEmpty {
                Text(h.state == "working" ? h.line : "Nothing yet.").foregroundStyle(.secondary)
            } else {
                MarkdownText(text: parts.body, size: 15).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !parts.choices.isEmpty && h.state != "working" {
                ChoiceRow(choices: parts.choices, disabled: m.paused) { c in
                    Task { await m.send(c) }
                } onOther: {
                }
            }
            if h.state == "done" || h.state == "stopped" {
                HStack {
                    Spacer()
                    Button("Got it") { m.dismissHelper(h.id) }.buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(
                        Color(hex: 0x141416))
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xF0A04B, h.state == "needsYes" ? 0.55 : 0), lineWidth: 1.2))
    }
}

struct AwayCard: View {
    @ObservedObject var m: Model
    let hs: [Helper]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHILE YOU WERE GONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(hs) { h in
                Button {
                    m.focusHelper(h.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: h.state == "needsYes" ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(h.state == "needsYes" ? Color.orange : Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title).font(.callout.weight(.semibold))
                            Text(h.state == "needsYes" ? "Needs your yes. Tap to answer." : Helpers.summary(Choices.split(h.reply).body, 140))
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Got it") { m.clearAway() }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
    }
}

// MARK: - Ready for you: what Nova and her helpers made, kept on a shelf and saved as real files.

struct ShelfItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var from: String
    var path: String
    var made = Date()
    var fresh = true
    var url: URL { URL(fileURLWithPath: path) }
    var icon: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "csv", "xlsx", "numbers": return "tablecells"
        case "docx", "doc", "pages", "rtf": return "doc.text"
        default: break
        }
        let t = (title + " " + detail).lowercased()
        if t.contains("flight") || t.contains("trip") || t.contains("hotel") { return "airplane" }
        if t.contains("receipt") || t.contains("$") || t.contains("budget") { return "receipt" }
        if t.contains("email") || t.contains("reply") || t.contains("draft") { return "envelope" }
        if t.contains("folder") || t.contains("download") || t.contains("files") { return "folder" }
        return "doc.text"
    }
    var when: String {
        let c = Calendar.current
        if Date().timeIntervalSince(made) < 120 { return "just now" }
        let f = DateFormatter()
        f.dateFormat = c.isDateInToday(made) ? "h:mm a" : (c.isDateInYesterday(made) ? "'yesterday'" : "EEE")
        return f.string(from: made)
    }
}

enum Shelf {
    static var who: String {
        let n = UserDefaults.standard.string(forKey: "assistantName") ?? ""
        return n.isEmpty ? "your assistant" : n
    }
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Env.selfTest ? Env.support.appendingPathComponent("selftest-made") : docs.appendingPathComponent("Made by \(Shelf.who)")
    }
    static func load() -> [ShelfItem] {
        guard let d = UserDefaults.standard.data(forKey: "shelf"), var v = try? JSONDecoder().decode([ShelfItem].self, from: d) else { return [] }
        // The assistant was renamed: move results from the old "Made by …" folder into the new one.
        let fm = FileManager.default
        for k in v.indices where !v[k].path.hasPrefix(folder.path + "/") {
            let old = URL(fileURLWithPath: v[k].path)
            guard fm.fileExists(atPath: old.path), old.deletingLastPathComponent().lastPathComponent.hasPrefix("Made by ") else { continue }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(old.lastPathComponent)
            if (try? fm.moveItem(at: old, to: dest)) != nil {
                v[k].path = dest.path
                let dir = old.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0 != ".DS_Store" }.isEmpty) == true { try? fm.removeItem(at: dir) }
            }
        }
        let kept = v.filter { FileManager.default.fileExists(atPath: $0.path) }
        save(kept)
        return kept
    }
    static func save(_ v: [ShelfItem]) { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: "shelf") }
    /// Save a finished result as a file in Documents › Made by Nova.
    /// Files the assistant made directly (PDFs, documents…) that aren't on the shelf yet.
    static func adopt(_ have: [ShelfItem]) -> [ShelfItem] {
        let fm = FileManager.default
        let known = Set(have.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "shelfHidden") ?? [])
        let items =
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]))
            ?? []
        var out: [ShelfItem] = []
        for u in items {
            let path = u.standardizedFileURL.path
            guard !known.contains(path), !hidden.contains(path),
                (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                !u.lastPathComponent.hasSuffix(".part"), !u.lastPathComponent.hasPrefix("~")
            else { continue }
            let made = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var title = u.deletingPathExtension().lastPathComponent
            if let r = title.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) { title.removeSubrange(r) }
            let kind = u.pathExtension.uppercased()
            out.append(
                ShelfItem(
                    title: title, detail: kind.isEmpty ? "A file \(who) made" : "\(kind) · ready to share", from: who, path: path, made: made,
                    fresh: true))
        }
        return out.sorted { $0.made > $1.made }
    }
    static func keep(title: String, body: String, from: String) -> ShelfItem? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-").trimmingCharacters(
            in: .whitespaces)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(f.string(from: Date())) \(safe).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(f.string(from: Date())) \(safe) \(n).md")
            n += 1
        }
        let text =
            "# \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n— \(from), \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return ShelfItem(title: title, detail: Helpers.summary(body, 60), from: from, path: url.path)
    }
}

struct ShelfCardView: View {
    let item: ShelfItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(Color(hex: 0xFFE2C2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("\(item.from) · \(item.when)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if item.fresh { Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 6, height: 6).padding(.top, 4) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(item.fresh ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, item.fresh ? 0.22 : 0.07)))
        .shadow(color: Color(hex: 0xFFE2C2, item.fresh ? 0.12 : 0), radius: 10)
        .contentShape(Rectangle())
    }
}

struct ShelfPanel: View {
    @ObservedObject var m: Model
    var body: some View {
        let fresh = m.shelf.filter(\.fresh).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ready for you").font(.system(size: 13, weight: .semibold))
                if fresh > 0 {
                    Text("\(fresh) new").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color(hex: 0x141416))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFFE2C2)))
                }
                Spacer()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(m.shelf) { it in
                        ShelfCardView(item: it)
                            .onTapGesture { m.openShelf(it.id) }
                            .onDrag { NSItemProvider(contentsOf: it.url) ?? NSItemProvider() }
                            .help("Click to open. Drag into Mail or Messages to share.")
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                                Button("Take off the shelf (the file stays)") { m.removeShelf(it.id) }
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            Button {
                NSWorkspace.shared.open(Shelf.folder)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text("All saved in Documents › Made by \(Shelf.who)").font(.system(size: 10.5))
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.07)))
        .padding(.vertical, 14).padding(.trailing, 14)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: m.shelf.map(\.id))
    }
}

/// Any note or file the assistant links to opens here, inside One, instead of in another app.
struct FileViewer: View {
    @ObservedObject var m: Model
    let url: URL
    var body: some View {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "I couldn't open this file. It may have been moved or deleted."
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        var title = url.deletingPathExtension().lastPathComponent
        if let f = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[f].hasPrefix("# ") {
            title = String(lines[f].dropFirst(2))
            lines.remove(at: f)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeometryReader { g in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.viewing = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xFFE2C2))
                        Text(title).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button {
                            m.viewing = nil
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Close")
                    }.padding(.horizontal, 22).padding(.vertical, 16)
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    ScrollView {
                        MarkdownText(text: text.isEmpty ? "Nothing written here yet." : text, size: 15).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 18)
                    }
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }.buttonStyle(.bordered)
                        Button {
                            m.viewing = nil
                            m.openHelper = nil
                            m.about = (title, url)
                            m.draftSeed = ""
                        } label: {
                            Label("Ask \(m.name) about it", systemImage: "bubble.left")
                        }.buttonStyle(.bordered)
                        Spacer()
                    }.padding(.horizontal, 22).padding(.vertical, 14)
                }
                .frame(width: min(720, g.size.width - 60), height: max(320, g.size.height - 70))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x1E1E22, 0.99)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.14)))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            }
        }
    }
    static let readable: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml", "log"]
}

/// PDFs: Apple's own PDF reader, scrolls with the trackpad and mouse wheel.
struct PDFReader: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor(white: 0.12, alpha: 1)
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) { if v.document?.documentURL != url { v.document = PDFDocument(url: url) } }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL } }
}

struct ShelfOpened: View {
    @ObservedObject var m: Model
    let item: ShelfItem
    var body: some View {
        let body = (try? String(contentsOf: item.url, encoding: .utf8)) ?? "This file was moved or deleted."
        let shown = body.components(separatedBy: "\n").drop { $0.hasPrefix("# ") || $0.isEmpty }.joined(separator: "\n")
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.openedShelf = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).foregroundStyle(Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 17, weight: .semibold))
                            Text("\(item.from) · \(item.when)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            m.openedShelf = nil
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Close")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    if !FileViewer.readable.contains(item.url.pathExtension.lowercased()) {
                        Group {
                            if item.url.pathExtension.lowercased() == "pdf" { PDFReader(url: item.url) } else { QuickLookView(url: item.url) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            MarkdownText(text: shown, size: 15)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.vertical, 18)
                        }
                    }
                    Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            m.openedShelf = nil
                            m.openHelper = nil
                            m.about = (item.title, item.url)
                            m.draftSeed = ""
                        } label: {
                            Label("Ask \(m.name) about it", systemImage: "bubble.left")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Text("Drag the card into Mail or Messages to share it.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                }
                .frame(width: min(720, g.size.width - 60), height: max(320, g.size.height - 70))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x1E1E22, 0.99)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.14)))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            }
        }
    }
}
