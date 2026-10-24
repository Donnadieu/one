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
        return raw.compactMap { d in (d["t"] as? String).map { Bubble(fromMe: d["me"] as? Bool ?? false, text: $0) } }
    }
    func saveBubbles() {
        guard !thinking else { return }
        UserDefaults.standard.set(bubbles.suffix(40).filter { !$0.text.isEmpty }.map { ["me": $0.fromMe, "t": $0.text] }, forKey: "bubbles")
    }
    @Published var step: Step = .pickAI
    @Published var signedIn: [Provider: Bool] = [:]
    @Published var signInCode: String?
    @Published var signInNeedsPaste = false
    @Published var signInProblem: String?
    @Published var busy = false
    @Published var thinking = false
    @Published var working: String?
    @Published var asks: [Ask] = []
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
    @Published var shelf: [ShelfItem] = Shelf.load() { didSet { Shelf.save(shelf) } }
    @Published var openedShelf: UUID?
    @Published var draftSeed: String?
    @Published var about: (title: String, url: URL)?
    @Published var viewing: URL?

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
        case "terminal", "execute_code": return "Working on your Mac…"
        case "manage_connections": return "Checking your connections…"
        case "text_to_speech": return "Getting my voice ready…"
        case "todo", "todo_list": return "Planning the steps…"
        default: return "Working on it…"
        }
    }
}
