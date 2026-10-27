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

// MARK: - App state

/// Tap-to-answer choices the assistant puts on the last line: [choices: A | B | C]
enum Choices {
    static func split(_ text: String) -> (body: String, choices: [String]) {
        var lines = text.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), last.lowercased().hasPrefix("[choice") else { return (text, []) }
        lines.removeLast()
        var inner = last.drop { $0 != ":" }.dropFirst()
        guard inner.hasSuffix("]") else { return (lines.joined(separator: "\n"), []) }  // still streaming in
        inner = inner.dropLast()
        let opts = inner.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (lines.joined(separator: "\n"), Array(opts.prefix(4)))
    }
}

struct Bubble: Identifiable {
    let id = UUID()
    let fromMe: Bool
    var text: String
    /// On a reply: what the person sent while it was being worked on (went into that same turn).
    var followUps: [String] = []
}

struct Ask: Identifiable {
    let id = UUID()
    let question: String
    let options: [(String, String)]
    let answer: @Sendable (String?) -> Void
}

enum Step: Equatable {
    case installing, pickAI, signingIn, nameAssistant, nameUser, rooms, world, connect, whichEmail, passwords, passwordsOK, backup, wrapUp, done
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @AppStorage("onboarded") var onboarded = false
    @AppStorage("assistantName") var assistantName = ""
    @AppStorage("userName") var userName = ""
    @AppStorage("interviewOffered") var interviewOffered = false
    @Published var roomInvites: [URL] = []
    var clashes: [String] = []
    /// Routines (scheduled jobs) finish into hermes/cron/output/<job>/<time>.md. Read each new result
    /// out loud, wherever the person is, unless the voice is muted. Silent runs say nothing.
    private var routineSeen: Set<String> = []
    private var routineStarted = false
    func tendRoutines() {
        let root = Env.hermesHome.appendingPathComponent("cron/output")
        let fm = FileManager.default
        var found: [URL] = []
        for job in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: job, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "md" { found.append(f) }
        }
        let fresh = found.filter { !routineSeen.contains($0.path) }
        fresh.forEach { routineSeen.insert($0.path) }
        guard routineStarted else {
            routineStarted = true
            return
        }  // don't replay old results at launch
        for f in fresh.sorted(by: { $0.path < $1.path }) {
            guard let t = try? String(contentsOf: f, encoding: .utf8), let r = t.range(of: "## Response") else { continue }
            var body = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let cut = body.range(of: "\n⚠️") { body = String(body[..<cut.lowerBound]) }
            if body.isEmpty || body.hasPrefix("[SILENT]") { continue }
            let title = t.split(separator: "\n").first.map { $0.replacingOccurrences(of: "# Cron Job: ", with: "") } ?? "A routine"
            bubbles.append(Bubble(fromMe: false, text: "**\(title)**\n\n\(body)"))
            Floater.shared.note("\(title) is done.")
            if !thinking { Task { _ = await Speaker.shared.read(body) } }
        }
    }

    /// The folder list changed since the engine started (a new folder was allowed, maybe by the
    /// assistant itself): once nothing is mid-reply, restart the engine under the new lock and carry on.
    func tendFolders() {
        guard onboarded, !Env.commandLine else { return }
        let busy = thinking || helpers.contains { $0.state == "working" }
        FolderWatch.tend(busy: busy, running: Engine.shared.running) { resume in await self.restartForFolders(resume: resume) }
    }

    func restartForFolders(resume: Bool) async {
        await Engine.shared.stopForNewAccess()
        await ensureEngine()  // same conversation: the saved session is reopened (with retries)
        bubbles.removeAll { $0.text == FolderWatch.restartedLine }
        bubbles.append(Bubble(fromMe: false, text: FolderWatch.restartedLine))
        if resume { await send(FolderWatch.carryOn, toNova: true, hidden: true) }
    }

    /// A new version was found for the first time: an orb note and a spoken line (unless muted). Waits until no reply is playing.
    func updateReady() {
        let line = "A new version of One is ready. Want me to update?"
        Floater.shared.note(line)
        Task {
            for _ in 0..<60 where thinking || !Speaker.shared.ready { try? await Task.sleep(for: .seconds(5)) }
            guard !thinking else { return }
            _ = await Speaker.shared.sayNow(line)
        }
    }
    /// The notification was clicked: open One on Home, where the update card is.
    func showUpdate() {
        openHelper = nil
        Floater.shared.openMain()
        if Updater.shared.available == nil {
            UserDefaults.standard.removeObject(forKey: "updateSkipped")
            Task { await Updater.shared.check() }
        }
    }

    func tendShared() {
        clashes += Shared.tend()
        for n in SharedGuard.tend() { bubbles.append(Bubble(fromMe: false, text: n)) }
        let inv = Shared.invites()
        if inv.map(\.path) != roomInvites.map(\.path) { roomInvites = inv }
    }
    func joinRoom(_ u: URL) {
        Shared.join(u)
        roomInvites.removeAll { $0 == u }
        Task { _ = await Engine.shared.start() }
        if let i = Shared.info(u) {
            bubbles.append(
                Bubble(
                    fromMe: false,
                    text:
                        "You're in \(i.title) now. Anything \(Shared.others(i).joined(separator: " and ")) adds shows up for both of you. Ask me \"what's new in \(i.title)?\" any time."
                ))
        }
    }
    @AppStorage("provider") var providerRaw = ""
    @AppStorage("connections") var connectionsRaw = ""
    @AppStorage("passwords") var passwords = ""
    @AppStorage("backup") var backup = ""
    @Published var pickedRooms: Set<RoomKind> = []

    @Published var bubbles: [Bubble] = Model.savedBubbles() { didSet { saveBubbles() } }
    static func savedBubbles() -> [Bubble] {
        guard let raw = UserDefaults.standard.array(forKey: "bubbles") as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            (d["t"] as? String).map { Bubble(fromMe: d["me"] as? Bool ?? false, text: $0, followUps: d["f"] as? [String] ?? []) }
        }
    }
    func saveBubbles() {
        guard !thinking else { return }
        UserDefaults.standard.set(
            bubbles.suffix(40).filter { !$0.text.isEmpty }.map { ["me": $0.fromMe, "t": $0.text, "f": $0.followUps] as [String: Any] },
            forKey: "bubbles")
    }
    @Published var step: Step = .pickAI
    @Published var signedIn: [Provider: Bool] = [:]
    @Published var signInCode: String?
    @Published var signInNeedsPaste = false
    @Published var signInProblem: String?
    @Published var busy = false
    /// Busy with a turn (including the moment before its voice starts). When it ends, waiting messages go next.
    @Published var thinking = false {
        didSet { if oldValue && !thinking { Task { @MainActor in self.nextUpReady() } } }
    }
    /// Messages sent while busy: "Sent to <name>" (went into the running turn) or "Next up" (waiting).
    @Published var followUps: [FollowUp] = []
    @Published var editingFollowUp: UUID?
    /// The main conversation's turn is with the engine right now, and has started answering.
    var turnLive = false
    var turnStarted = false
    var steeringNow = false
    var steerRetryAt = Date.distantPast
    /// Helpers whose current turn has started answering (they can take a message mid-turn).
    var helperLive: Set<UUID> = []
    /// Finished helpers waiting for the end of the current reply, to get one "by the way" line.
    var doneQueue: [UUID] = []
    var doneNoteWaiting = false
    /// Good morning / status report batches already reported.
    var routinesTold: Set<UUID> = []
    @Published var working: String?
    @Published var asks: [Ask] = []
    /// Steps only the person can do (a code, a passkey…), shown with Done / I'm not at the Mac (HumanStep.swift).
    @Published var humanSteps: [HumanStepAsk] = []
    @Published var paused = false
    @Published var pickedEmails: Set<String> = []
    @Published var pickedConnections: [String] = ["Email", "Calendar", "News", "Files", "Browser"].map { _ in "" }.filter { !$0.isEmpty }
    @Published var connectOptions: [String] = ["Email", "Calendar", "News", "Files", "Browser"]

    @Published var switchingAI = false
    @Published var speaking = false
    @Published var installDone = 0
    @Published var installLine = ""
    @Published var installError: String?
    @Published var needDevTools = false
    @Published var worldCaption = ""
    @Published var tourNode: String?
    @Published var touring = false
    @Published var skipTour = false
    @Published var speakUntil = Date.distantPast

    var signIn: SignIn?

    /// Pictures waiting to go with the next message (dragged, pasted, picked or dropped on the orb).
    @Published var pictures: [Picture] = []
    @Published var files: [SharedFile] = []
    /// Talking inside One's window (mic button, or the talk key while One is in front).
    @Published var talkingInApp = false
    @Published var talkNote: String?

    // Helpers
    @Published var helpers: [Helper] = Model.savedHelpers() { didSet { saveHelpers() } }
    @Published var openHelper: UUID?
    var helperTurnEnded: [UUID: Date] = [:]  // when each helper's last engine turn ended (checks read it)
    @Published var shelf: [ShelfItem] = Shelf.load() { didSet { Shelf.save(shelf) } }
    var shelfScanning = false
    @Published var openedShelf: UUID?
    @Published var draftSeed: String?
    @Published var about: (title: String, url: URL)?
    @Published var viewing: URL?

    // Tell me when I learn (ModelLearning.swift)
    var learning = Learning.load()
    var learnTurn = LearnTurn()
    var learnHelperTurns: [UUID: LearnTurn] = [:]
    var learnBubbles: [UUID: UUID] = [:]  // job → the reply bubble it ended with
    var learnQueue: [LearnShow] = []
    var learnSaving: UUID?  // "Yes, remember it" in the main chat: the job being saved

    var heldText = ""
    var pendingReveal: (idx: Int, text: String, token: Int)?
    var revealCount = 0
}

/// Turns the engine's technical step titles ("browser_exec: import time…") into plain words.
enum Plain {
    static func step(_ title: String) -> String {
        let parts = title.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let tool = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        func file() -> String {
            let a = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            let n = (a.components(separatedBy: " ").first ?? a).split(separator: "/").last.map(String.init) ?? ""
            return n.isEmpty ? "a file" : n
        }
        func cut(_ x: String, _ n: Int = 60) -> String { x.count > n ? String(x.prefix(n - 1)) + "…" : x }
        // Browser steps start with a one-line comment that says what they do.
        if let c = arg.range(of: "# ") {
            let line = arg[c.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            let clean = line.components(separatedBy: CharacterSet(charactersIn: "#;")).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if clean.count > 3, tool.hasPrefix("browser") { return cut(clean) + "…" }
        }
        switch tool {
        case let t where t.hasPrefix("browser"): return "Using the browser…"
        case "web_search":
            return arg.isEmpty
                ? "Searching the web…" : "Searching the web for “\(cut(arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), 40))”…"
        case "web_extract": return "Reading a web page…"
        case "read_file": return "Reading \(cut(file(), 40))…"
        case "write_file", "patch": return "Saving \(cut(file(), 40))…"
        case "search_files": return "Looking through your files…"
        case "vision_analyze": return "Looking at the picture…"
        case "session_search": return "Remembering what we talked about…"
        case "terminal": return shell(arg)
        case "execute_code": return code(arg)
        case "manage_connections": return "Checking your connections…"
        case "text_to_speech": return "Getting my voice ready…"
        case "todo", "todo_list": return "Planning the steps…"
        default: return "Working on it…"
        }
    }
}

/// Plain words for a command the assistant runs on the Mac. Never shows the command itself.
extension Plain {
    static let shellWords: [(heads: [String], say: String)] = [
        (["ls", "find", "tree", "du", "mdfind", "stat", "wc", "fd"], "Looking through your files…"),
        (["cat", "head", "tail", "less", "grep", "rg", "sed", "awk", "jq", "pdftotext"], "Reading your files…"),
        (["cp", "mv", "mkdir", "rsync", "ditto", "ln", "touch"], "Moving your files around…"),
        (["zip", "unzip", "tar"], "Packing up your files…"),
        (["curl", "wget", "http", "ping"], "Checking a website…"),
        (["git", "gh"], "Saving to GitHub…"),
        (["brew", "pip", "pip3", "uv", "npm", "npx", "pnpm"], "Getting a tool ready…"),
        (["open"], "Opening it for you…"),
        (["osascript", "shortcuts"], "Asking your Mac's apps…"),
        (["say", "afplay", "ffmpeg", "sips", "convert", "magick"], "Working on the picture or sound…"),
        (["date", "cal"], "Checking the date…"),
        (["sqlite3"], "Looking something up…"),
    ]
    /// `terminal: <command preview>` → what it does, in plain words.
    static func shell(_ cmd: String) -> String {
        let words = cmd.replacingOccurrences(of: "\n", with: " ").split(whereSeparator: { " \t;|&()".contains($0) }).map(String.init)
        var i = 0
        while i < words.count, ["cd", "sudo", "env", "time", "export", "source", "."].contains(words[i]) || words[i].contains("=") {
            // `cd somewhere && …`, `FOO=1 …`: skip to the command that does the work.
            i += words[i] == "cd" ? 2 : 1
        }
        guard i < words.count else { return "Working on your Mac…" }
        let head = (words[i].split(separator: "/").last.map(String.init) ?? words[i]).lowercased()
        if head.hasPrefix("python") || ["node", "bash", "sh", "zsh", "ruby", "swift", "perl"].contains(head) {
            return script(words.dropFirst(i + 1).first { !$0.hasPrefix("-") })
        }
        if head.hasSuffix(".py") || head.hasSuffix(".sh") { return script(head) }
        if head == "git" && i + 1 < words.count && ["status", "log", "diff", "show"].contains(words[i + 1]) {
            return "Checking your saved changes…"
        }
        if head == "git" && i + 1 < words.count && ["clone", "pull", "fetch"].contains(words[i + 1]) { return "Getting it from GitHub…" }
        if ["hermes", "one"].contains(head) { return "Checking my own setup…" }
        return shellWords.first { $0.heads.contains(head) }?.say ?? "Working on your Mac…"
    }
    /// A script's name made readable: `make_flight_report.py` → "Running make flight report…".
    static func script(_ path: String?) -> String {
        guard let path, !path.hasPrefix("-c"), !path.isEmpty else { return "Running a small program…" }
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let stem = file.split(separator: ".").first.map(String.init) ?? file
        let name = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard name.count >= 3, name.count <= 32, name.allSatisfy({ $0.isLetter || $0 == " " || $0.isNumber }) else {
            return "Running a small program…"
        }
        return "Running \(name.lowercased())…"
    }
    /// `execute_code: <code preview>`: use its first comment when there is one.
    static func code(_ src: String) -> String {
        if let r = src.range(of: "# ") {
            let line = src[r.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.count > 3, clean.count <= 60, !clean.contains("(") { return clean + "…" }
        }
        return "Working it out on your Mac…"
    }
}
