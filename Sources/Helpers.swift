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
    var toldState: String?  // the state its last "by the way" notice gave (one notice per change of state)
    var restartNews: String?  // the assistant hasn't been told it was picked back up yet
    var stoppedByYou: Bool?  // stopped on purpose (the Stop button): never picked back up after a restart
    var updatePaused: Bool?  // paused so an update could install: picks back up after the restart, never counted as a cut-off
    var pausedFor: String?  // what the pause was for, in plain words ("a new folder"); nil = the update
    var busyTries: Int?  // its old turn was still finishing when it was picked back up: retries so far (HelperFinish)
    var seen: Bool?  // false: finished and not opened yet (orange until they tap it). nil = from before this existed: seen.
    var routine: UUID?  // sent for a good morning / status report: the assistant gives one combined report when the batch is done
    /// Finished, but they haven't opened it yet.
    var waiting: Bool { (state == "done" || state == "needsYes") && seen == false }
    var viewState: HelperState {
        switch state {
        case "working": .working
        case "needsYes": .needsYes
        case "stopped": .stopped
        default: seen == false ? .needsYes : .done  // same orange pulse as "needs your yes" until it's opened
        }
    }
}

enum Helpers {
    /// Older conversations started before helpers existed, so the app reminds the assistant every turn (not shown to the user).
    static var note: String {
        "\n\n(One app note, not from the user: if this needs any work at all (looking something up, browsing, research, comparing, making a file, checking, watching), don't do it here: send helpers. Say in one short line what you're sending, then one line per job: [helper: Short title | the whole job with every detail]. If it has separate parts (e.g. movie times at two theaters, flights and hotels), send one helper per part so they run at the same time. Only answer here yourself when you already know the answer or it's just conversation. Any file you make for them (PDF, document, spreadsheet, picture) goes in \(Shelf.folder.path); the app puts it in front of them under Ready for you, so just say it's there, without the folder path. When a helper finishes, its orb turns orange and holds the result, and they open it there. Never repeat a helper's result or ask its question here; One tells you when to add one \"By the way, <title> is done. Tap it to take a look.\" line, after you finish what you're saying. Only for a good morning, good afternoon, good evening or a status report do you give the helpers' results yourself, all in one report once they're all back.)"
            + HelperStop.note + BlockedAsk.note + KeepAwake.note
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
        Learning.hideTags(HelperStop.hide(text)).components(separatedBy: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !l.hasPrefix("[helper") && !l.hasPrefix("[stop-helper") && !l.hasPrefix("[close-helper")
        }.joined(
            separator: "\n")
    }
    /// A good morning / afternoon / evening or a status report: its helpers report back together, in one reply.
    static func isRoutine(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["good morning", "good afternoon", "good evening", "status report", "status update", "morning brief"].contains { t.contains($0) }
    }
    /// The hidden note after a reply ends: one plain "by the way" line for the helpers that just finished, never their result.
    static func doneNote(_ hs: [Helper], user: String) -> String {
        let done = hs.filter { $0.state == "done" }.map { "\"\($0.title)\"" }
        let yes = hs.filter { $0.state == "needsYes" }.map { "\"\($0.title)\"" }
        var what: [String] = []
        if !done.isEmpty { what.append(list(done) + (done.count == 1 ? " is done" : " are done")) }
        if !yes.isEmpty { what.append(list(yes) + (yes.count == 1 ? " needs \(user)'s yes" : " need \(user)'s yes")) }
        return "(One app note, not from the user: \(what.joined(separator: ", and ")). Its orb is orange and holds the whole result; "
            + "\(user) opens it there and can talk to it there. Reply with exactly ONE short plain line, like: "
            + "\"By the way, \(list(hs.map(\.title))) \(hs.count == 1 ? "is" : "are") done. Tap \(hs.count == 1 ? "it" : "them") to take a look.\" "
            + "Don't repeat, summarise or hint at the result, don't ask its question, no choices line, nothing else.)"
    }
    static func list(_ v: [String]) -> String {
        v.count < 2 ? (v.first ?? "") : v.dropLast().joined(separator: ", ") + " and " + v.last!
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
        """ + helperNote  // runHelper adds SessionNotes.helper on every turn
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
                            Text(
                                h.state == "needsYes"
                                    ? "Needs your yes. Tap to answer." : Helpers.summary(Choices.split(Helpers.strip(h.reply)).body, 140)
                            )
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
        let fm = FileManager.default
        // The assistant was renamed: move results from the old "Made by …" folder in Documents into the new one.
        // Only the person's own One ever moves their files (never a test, check or render: TestWorld.swift).
        if Env.production {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
            for k in v.indices where !v[k].path.hasPrefix(folder.path + "/") {
                let old = URL(fileURLWithPath: v[k].path)
                let dir = old.deletingLastPathComponent()
                guard fm.fileExists(atPath: old.path), dir.lastPathComponent.hasPrefix("Made by "),
                    dir.deletingLastPathComponent().standardizedFileURL.path == docs,
                    folder.deletingLastPathComponent().standardizedFileURL.path == docs
                else { continue }
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(old.lastPathComponent)
                if (try? fm.moveItem(at: old, to: dest)) != nil {
                    v[k].path = dest.path
                    if (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0 != ".DS_Store" }.isEmpty) == true { try? fm.removeItem(at: dir) }
                }
            }
        }
        // A card whose file is gone is kept aside (`shelfMissing`), never forgotten, and comes back when the file does.
        let saved = (UserDefaults.standard.data(forKey: "shelfMissing")).flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
        let (kept, missing) = reconcile(v, missing: saved) { fm.fileExists(atPath: $0) }
        if Env.production {
            UserDefaults.standard.set(try? JSONEncoder().encode(missing), forKey: "shelfMissing")
            save(kept)
        }
        return kept
    }
    /// Cards with a file are shown; cards without one are kept aside, and come back when their file does.
    static func reconcile(_ shelf: [ShelfItem], missing: [ShelfItem], exists: (String) -> Bool) -> (kept: [ShelfItem], missing: [ShelfItem]) {
        var v = shelf
        var m = missing
        let back = m.filter { x in exists(x.path) && !v.contains { $0.path == x.path } }
        v += back
        m.removeAll { x in back.contains { $0.path == x.path } }
        for x in v where !exists(x.path) && !m.contains(where: { $0.path == x.path }) { m.append(x) }
        return (v.filter { exists($0.path) }, m)
    }
    static func save(_ v: [ShelfItem]) {
        guard Env.production else { return }  // a test, check or render keeps its shelf in memory only
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: "shelf")
    }
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
        let f = item.fresh
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(WorldLook.cream.opacity(f ? 0.08 : 0.06))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: item.icon).font(.system(size: 15)).foregroundStyle(f ? Color(hex: 0xF5D3AE) : WorldLook.cream.opacity(0.55)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(f ? Color.white : WorldLook.cream.opacity(0.78))
                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(f ? 0.62 : 0.48))
                Text("\(item.from) · \(item.when)").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.36))
            }
            .lineLimit(1).truncationMode(.tail).padding(.trailing, f ? 10 : 0)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.leading, 10).padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if f {
                Circle().fill(Color(hex: 0xF7DFA6)).frame(width: 7, height: 7).shadow(color: Color(hex: 0xF7DFA6, 0.55), radius: 3)
                    .padding(.top, 13).padding(.trailing, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(f ? 0.055 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(f ? 0.22 : 0.06)))
        .contentShape(Rectangle())
    }
}

struct ShelfPanel: View {
    @ObservedObject var m: Model
    @AppStorage(Glass.key) var solid = Glass.standard
    var collapse: () -> Void = {}
    var body: some View {
        let fresh = m.shelf.filter(\.fresh).count
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(fresh: fresh, markAll: { m.markShelfRead() }, collapse: collapse).padding(.horizontal, 4)
            StillScroll {
                VStack(spacing: 8) {
                    ForEach(m.shelf) { it in
                        ShelfCardView(item: it)
                            .onTapGesture {
                                ShelfCopy.shared.pick(it)
                                m.openShelf(it.id)
                            }
                            .onDrag { NSItemProvider(contentsOf: it.url) ?? NSItemProvider() }
                            .help("Click to open. ⌘C copies it. Drag into Mail or Messages to share.")
                            .modifier(ShelfCopyable(item: it) { m.removeShelf(it.id) })
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            ShelfFooter()
        }
        .padding(.top, 14).padding(.horizontal, 12).frame(width: 260)
        .overlay(alignment: .bottom) { ShelfCopyNote().padding(.horizontal, 10).padding(.bottom, 50) }
        .onAppear { ShelfCopy.shared.start() }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WorldLook.cream.opacity(0.04)))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1C1C20, Glass.thin(solid) ? 0.6 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.06)))
        .padding(.top, 8).padding(.bottom, 16).padding(.trailing, 16)
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
        return PopupStage(close: close) { g in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xFFE2C2))
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 150)  // the X and "Esc to close"
                }.padding(.horizontal, 22).padding(.vertical, 16)
                Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                ReaderText(text: text.isEmpty ? "Nothing written here yet." : text)
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
            .frame(width: min(720, g.width - 60), height: max(320, g.height - 70))
        }
    }
    func close() { m.viewing = nil }
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
    func close() { m.openedShelf = nil }
    var body: some View {
        let body = (try? String(contentsOf: item.url, encoding: .utf8)) ?? "This file was moved or deleted."
        let shown = body.components(separatedBy: "\n").drop { $0.hasPrefix("# ") || $0.isEmpty }.joined(separator: "\n")
        PopupStage(close: close) { g in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: item.icon).foregroundStyle(Color(hex: 0xFFE2C2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 17, weight: .semibold))
                        Text("\(item.from) · \(item.when)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 150)  // the X and "Esc to close"
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                if !FileViewer.readable.contains(item.url.pathExtension.lowercased()) {
                    Group {
                        if item.url.pathExtension.lowercased() == "pdf" { PDFReader(url: item.url) } else { QuickLookView(url: item.url) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReaderText(text: shown)
                }
                Divider().overlay(Color(hex: 0xF4EFE8, 0.08))
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    ShelfCopyAllButton(url: item.url)
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
                    Text("Drag the card or press ⌘C to share it.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            .frame(width: min(720, g.width - 60), height: max(320, g.height - 70))
        }
    }
}
