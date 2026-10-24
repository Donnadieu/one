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

    func toggleConnection(_ c: String) {
        if let i = pickedConnections.firstIndex(of: c) { pickedConnections.remove(at: i) } else { pickedConnections.append(c) }
    }
    func addOwnConnection(_ c: String) {
        let c = c.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        if !connectOptions.contains(c) { connectOptions.append(c) }
        if !pickedConnections.contains(c) { pickedConnections.append(c) }
    }
    func connectionsChosen() async {
        let list = pickedConnections
        if list.isEmpty {
            me("Not now")
            await wrapUp()
            return
        }
        me(list.joined(separator: ", "))
        list.filter { $0 != "Email" }.forEach(addConnection)
        if list.contains("Email") {
            step = .whichEmail
            await say("Which email do you use? Pick all that apply. You can add as many accounts as you like.", voice: "whichEmail")
        } else {
            await say("Got it. I'll set each one up with you the first time we need it.")
            await askPasswords()
        }
    }
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

    func runTour() async {
        guard !touring, worldCaption.isEmpty else { return }
        touring = true
        skipTour = false
        func hold(_ d: Double, min: Double) async {
            let end = Date().addingTimeInterval(max(d, min) + 0.35)
            while Date() < end && !skipTour { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func speak(_ key: String) -> Double {
            let d = Voice.shared.play(key)
            speakUntil = Date().addingTimeInterval(d > 0 ? d : 2.6)
            return d
        }
        let intro = "Nice to meet you, \(userName). This is everything I can reach from your Mac."
        let live = await Speaker.shared.sayNow(intro)
        if live > 0 { try? await Task.sleep(for: .milliseconds(500)) }
        worldCaption = intro
        if live > 0 { speakUntil = Date().addingTimeInterval(live) }
        await hold(live > 0 ? live : speak("worldIntro"), min: 3.6)
        for n in worldNodes where !skipTour {
            tourNode = n.id
            worldCaption = n.line
            await hold(n.voice.map(speak) ?? 0, min: 3.4)
        }
        if skipTour { Voice.shared.stop() }
        tourNode = nil
        touring = false
        worldCaption = "What would you like me to look after?"
        _ = speak("worldPick")
    }

    func setFolders(_ f: [String]) {
        Access.set(f)
        if f.isEmpty {
            pickedConnections.removeAll { $0 == "Files" }
        } else if !pickedConnections.contains("Files") {
            pickedConnections.append("Files")
        }
        if onboarded {
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
            Task { _ = await Engine.shared.start() }
        }
    }

    private var signIn: SignIn?
    var provider: Provider? { Provider(rawValue: providerRaw) }
    var connections: [String] { connectionsRaw.split(separator: ",").map(String.init) }
    var name: String { assistantName.isEmpty ? "Your assistant" : assistantName }
    /// The assistant's name lives in the brain's owner.yaml (`assistant: "…"`), so "call yourself Elias" works from a chat:
    /// the assistant edits that line, and the app picks it up everywhere (title, orb, voice lines, its own soul).
    static var ownerFile: URL { Brain.root.appendingPathComponent("owner.yaml") }
    static func nameInOwner() -> String? {
        guard let y = try? String(contentsOf: ownerFile, encoding: .utf8) else { return nil }
        for l in y.split(separator: "\n") where l.hasPrefix("assistant:") {
            let v = l.dropFirst("assistant:".count).split(separator: "#")[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
    static func writeNameToOwner(_ n: String) {
        guard var y = try? String(contentsOf: ownerFile, encoding: .utf8) else { return }
        var lines = y.components(separatedBy: "\n")
        let row = "assistant: \"\(n)\"         # what your assistant is called. Change it here or just ask it to."
        if let i = lines.firstIndex(where: { $0.hasPrefix("assistant:") }) {
            lines[i] = row
        } else if let i = lines.firstIndex(where: { $0.hasPrefix("name:") }) {
            lines.insert(row, at: i + 1)
        } else {
            lines.append(row)
        }
        y = lines.joined(separator: "\n")
        try? y.write(to: ownerFile, atomically: true, encoding: .utf8)
    }
    func rename(_ n: String) {
        let n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != assistantName else { return }
        let old = assistantName
        assistantName = n
        Model.writeNameToOwner(n)
        Persona.write(assistant: n, user: userName, connections: connections, passwords: passwords)
        // its own memory of what it's called
        let mem = Env.support.appendingPathComponent("hermes/memories/USER.md")
        if !old.isEmpty, let t = try? String(contentsOf: mem, encoding: .utf8) {
            try? t.replacingOccurrences(of: "call their assistant \(old)", with: "call their assistant \(n)").write(
                to: mem, atomically: true, encoding: .utf8)
        }
    }
    func syncName() {
        if let n = Model.nameInOwner() {
            if n != assistantName { rename(n) }
        } else if !assistantName.isEmpty, onboarded {
            Model.writeNameToOwner(assistantName)
        }
    }

    /// The assistant speaks: the line emerges on screen and, if a voice line exists, is spoken.
    func say(_ text: String, voice: String? = nil) async {
        speaking = true
        defer { speaking = false }
        try? await Task.sleep(for: .milliseconds(350))
        // Voice first: live voice says the exact line (with names); the recorded line is the fallback.
        var d = Speaker.shared.ready ? await Speaker.shared.sayNow(text) : 0
        if d == 0 { d = voice.map { Voice.shared.play($0) } ?? 0 }
        let lag = d > 0 ? 0.6 : 0
        if lag > 0 { try? await Task.sleep(for: .milliseconds(Int(lag * 1000))) }
        // ...then the words follow.
        bubbles.append(Bubble(fromMe: false, text: text))
        try? await Task.sleep(for: .milliseconds(Int(max(d - lag, 1.1) * 1000) + 200))
    }
    func me(_ text: String) {
        Voice.shared.stop()
        Speaker.shared.stop()
        bubbles.append(Bubble(fromMe: true, text: text))
    }

    // Onboarding

    func beginOnboarding() async {
        guard bubbles.isEmpty else { return }
        await say("Let's get you set up.", voice: "setup")
        if Env.hermesPath == nil {
            step = .installing
            await say("First, I'm setting myself up on this Mac. This only happens once. Please hang on while I get ready.", voice: "installing")
            await install()
            return
        }
        await askAI()
    }

    func install() async {
        installError = nil
        needDevTools = false
        installDone = 0
        installLine = ""
        if Installer.devToolsMissing {
            needDevTools = true
            Installer.askForDevTools()
            await say(
                "Your Mac needs one small Apple add-on first. Click Install on the box that just opened, then press Continue here when it's done.",
                voice: "devTools")
            return
        }
        let err = await Installer.run { n, line in
            Task { @MainActor in
                self.installDone = n
                self.installLine = line
            }
        }
        if let err {
            installError = err
            await say("Something stopped the setup. Check your internet connection and try again.", voice: "installFailed")
        } else {
            Task.detached { if await Speaker.shared.install() { Speaker.shared.start() } }
            await say("Done. I'm ready.", voice: "installDone")
            await askAI()
        }
    }

    func askAI() async {
        step = .pickAI
        await say("Which AI do you already pay for? I'll use it as my brain. You can switch any time.", voice: "pickAI")
        for p in Provider.allCases { signedIn[p] = await SignIn.isSignedIn(p) }
    }

    func choose(_ p: Provider) async {
        me(p.title)
        providerRaw = p.rawValue
        if signedIn[p] == true {
            await verify(p)
            return
        }
        step = .signingIn
        signInCode = nil
        signInNeedsPaste = false
        signInProblem = nil
        await say("I'm opening \(p.title)'s sign-in page in your browser. Sign in there, then come back here.", voice: "signin")
        let s = SignIn()
        signIn = s
        let result: (Bool, String) = await withCheckedContinuation { cont in
            let once = Box(false)
            s.start(p) { ev in
                Task { @MainActor in
                    switch ev {
                    case .openPage(let u): NSWorkspace.shared.open(u)
                    case .code(let c): self.signInCode = c
                    case .needPaste: self.signInNeedsPaste = true
                    case .done(let ok, let msg):
                        if !once.v {
                            once.v = true
                            cont.resume(returning: (ok, msg))
                        }
                    }
                }
            }
        }
        signIn = nil
        signInCode = nil
        signInNeedsPaste = false
        if result.0 {
            signedIn[p] = true
            await verify(p)
        } else {
            step = .pickAI
            await say("That sign-in didn't finish. Want to try again, or pick another one?", voice: "signinFailed")
            if !result.1.isEmpty { signInProblem = result.1 }
        }
    }

    func pasteCode(_ c: String) {
        signIn?.paste(c)
        signInNeedsPaste = false
    }
    func cancelSignIn() { signIn?.cancel() }

    private func verify(_ p: Provider) async {
        busy = true
        defer { busy = false }
        await say("You're connected to \(p.title). Let me check I can think with it…", voice: "checking")
        var stop = "error: no model answered"
        let got = Box("")
        for model in p.models {
            await SignIn.makeDefault(p, model: model)
            if let err = await Engine.shared.start() {
                step = .pickAI
                await say("Something went wrong: \(err)")
                return
            }
            got.v = ""
            Engine.shared.onText = { t in got.v += t }
            stop = await Engine.shared.prompt("Reply with exactly one word: ready")
            Engine.shared.onText = nil
            if !stop.hasPrefix("error") && !got.v.isEmpty && !got.v.lowercased().contains("rejected") { break }
            got.v = ""
        }
        if stop.hasPrefix("error") || got.v.isEmpty {
            step = .pickAI
            await say("I signed in, but \(p.title) didn't answer (\(stop)). Try again, or pick another one.")
            return
        }
        if onboarded {
            switchingAI = false
            step = .done
            bubbles.removeAll()
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
            _ = await Engine.shared.start()
            bubbles.append(Bubble(fromMe: false, text: "All set. I'm using \(p.title) now."))
            return
        }
        step = .nameAssistant
        await say("It works. Now, what would you like to call me? You can rename me any time.", voice: "nameAssistant")
    }

    func nameAssistant(_ n: String) async {
        let n = n.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        me(n)
        assistantName = n
        step = .nameUser
        await say("\(n). I like it. And what should I call you?", voice: "nameUser")
    }

    func nameUser(_ n: String) async {
        let n = n.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        me(n)
        userName = n
        step = .rooms
        await say("Nice to meet you, \(n).", voice: "niceToMeet")
        await say(
            "I also have a memory, and it's yours. It lives on this Mac as plain files, so even if you switch AIs, I still remember.", voice: "memory"
        )
        await say("Everything starts in your personal room: family, home, health, plans.", voice: "personalRoom")
        await say(
            "Want to keep part of your life separate, like a job or a business? I'll give it its own room, where I act differently and keep its notes apart.",
            voice: "roomsQuestion")
    }

    func roomsChosen(_ simple: Bool) async {
        let extra = simple ? [] : RoomKind.allCases.filter { pickedRooms.contains($0) && $0 != .personal }
        me(extra.isEmpty ? "Start simple" : extra.map(\.chip).joined(separator: ", "))
        busy = true
        let err = Brain.build(owner: userName, ai: assistantName, rooms: extra)
        busy = false
        if let err {
            await say("I couldn't set up your memory: \(err)")
        } else if extra.isEmpty {
            await say("Your personal room is ready. If you ever want another one, just ask.", voice: "roomsSimple")
        } else {
            await say("Done. Each room keeps its own notes, and I act the way you want in each one.", voice: "roomsDone")
        }
        step = .world
    }

    func connect(_ what: String) async {
        let what = what.trimmingCharacters(in: .whitespaces)
        guard !what.isEmpty else { return }
        me(what)
        let w = what.lowercased()
        if w.contains("email") || w.contains("mail") {
            step = .whichEmail
            await say("Which email do you use? Pick all that apply. You can add as many accounts as you like.", voice: "whichEmail")
        } else if w == "not now" {
            await wrapUp()
        } else {
            addConnection(what)
            await say("Got it: \(what). I'll set that up with you the first time we need it.")
            await askPasswords()
        }
    }

    func emailsChosen() async {
        let list = pickedEmails.sorted()
        guard !list.isEmpty else { return }
        me(list.joined(separator: ", "))
        list.forEach(addConnection)
        await say("To read \(list.joined(separator: " and ")) I'll need to sign in for you.")
        await askPasswords()
    }

    private func askPasswords() async {
        step = .passwords
        await say("When I need to log in somewhere, where should I find your passwords?", voice: "passwords")
    }

    func passwordsChosen(_ choice: String) async {
        me(choice)
        if choice == "Ask me each time" {
            passwords = "ask the user for each login; never store passwords"
            await say("Okay. I'll ask you each time, and I won't keep anything.", voice: "askEach")
            await wrapUp()
            return
        }
        step = .passwordsOK
        passwords = choice
        await say(
            "To use \(choice) I need your OK first. I'll only look up a login when a task needs it, and I'll tell you which one.",
            voice: "passwordsOK")
    }

    func passwordsOK(_ yes: Bool) async {
        me(yes ? "Yes" : "Not now")
        if yes {
            passwords = "use \(passwords) (permission given \(Date().formatted(date: .abbreviated, time: .omitted)))"
        } else {
            passwords = "not set up yet; ask before using any password source"
        }
        await say(yes ? "Thanks. Noted." : "No problem. I'll ask again when it's needed.", voice: yes ? "thanks" : "notNow")
        await wrapUp()
    }

    func backupChosen(_ yes: Bool) async {
        me(yes ? "Yes, back it up" : "Not now")
        if yes {
            busy = true
            let err = await Task.detached { Brain.backupToICloud() }.value
            busy = false
            if let err {
                backup = "off"
                await say("I couldn't turn it on: \(err) We can try again later.")
            } else {
                backup = "icloud"
                await say("Backup is on. I'll keep a copy in your iCloud Drive.", voice: "backupOn")
            }
        } else {
            backup = "off"
            await say("Okay. Your memory stays only on this Mac. Ask me any time to turn backup on.", voice: "backupOff")
        }
        await wrapUp()
    }

    private func addConnection(_ c: String) {
        var l = connections
        if !l.contains(c) { l.append(c) }
        connectionsRaw = l.joined(separator: ",")
    }

    private func wrapUp() async {
        if backup.isEmpty {
            step = .backup
            await say(
                "One last thing. Want me to back up your memory to iCloud, so it's safe if something happens to this Mac?", voice: "backupQuestion")
            return
        }
        step = .wrapUp
        busy = true
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        _ = await Engine.shared.start()  // restart so the new name and memory load
        busy = false
        await say("You're all set, \(userName). Here are a few things I can do right now. Tap one, or just ask.", voice: "allSet")
    }

    func finish() {
        onboarded = true
        step = .done
        bubbles.removeAll()
    }

    var suggestions: [String] { [tryItems[0].text, tryItems[4].text, tryItems[3].text] }

    var suggestionsOld: [String] {
        var s: [String] = []
        if connections.contains(where: { ["Gmail", "Outlook", "iCloud Mail", "Yahoo"].contains($0) }) {
            s.append("Every morning, tell me what matters in my email")
        }
        if connections.contains("Calendar") { s.append("What does my week look like?") }
        if connections.contains("News") { s.append("Give me 5 headlines I'd care about") }
        s += ["Plan a Saturday for me nearby", "Help me plan a trip", "Remind me to call someone tomorrow"]
        return Array(s.prefix(3))
    }

    // Talking after setup

    func ensureEngine() async {
        guard onboarded, !Engine.shared.running else { return }
        if backup == "icloud" { Task.detached { _ = Brain.backupToICloud() } }
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        if !Installer.applyOverlay() && UserDefaults.standard.string(forKey: "passwordsWith") == "KeePass" {
            bubbles.append(
                Bubble(
                    fromMe: false,
                    text: "Heads up: after an update I can't use your KeePass logins right now. Everything else works. Tell me and I'll look into it."
                ))
        }
        Task.detached { _ = GoogleSignIn.ensureVenv() }
        if let e = await Engine.shared.ensureStarted() { bubbles.append(Bubble(fromMe: false, text: "I couldn't start: \(e)")) }
    }

    /// Pictures waiting to go with the next message (dragged, pasted, picked or dropped on the orb).
    @Published var pictures: [Picture] = []
    @Published var files: [SharedFile] = []
    /// Talking inside One's window (mic button, or the talk key while One is in front).
    @Published var talkingInApp = false
    @Published var talkNote: String?
    func talkBegin() {
        guard !talkingInApp else { return }
        talkNote = nil
        if busyHere {
            talkNote = "I'm still on the last thing. Give me a moment."
            return
        }
        talkingInApp = true
        Voice.shared.stop()
        Speaker.shared.stop()
        Listener.shared.begin()
    }
    func talkEnd() {
        guard talkingInApp else { return }
        Listener.shared.finish { heard in
            Task { @MainActor in
                self.talkingInApp = false
                if heard.isEmpty {
                    if Listener.shared.problem == nil { self.talkNote = "I didn't catch that. Hold the mic and talk, then let go." }
                    return
                }
                await self.send(heard)
            }
        }
    }

    // Helpers
    @Published var helpers: [Helper] = Model.savedHelpers() { didSet { saveHelpers() } }
    @Published var openHelper: UUID?
    @Published var shelf: [ShelfItem] = Shelf.load() { didSet { Shelf.save(shelf) } }
    @Published var openedShelf: UUID?
    @Published var draftSeed: String?
    @Published var about: (title: String, url: URL)?
    @Published var viewing: URL?
    func openShelf(_ id: UUID) {
        openedShelf = id
        if let k = shelf.firstIndex(where: { $0.id == id }) { shelf[k].fresh = false }
    }
    func removeShelf(_ id: UUID) {
        if openedShelf == id { openedShelf = nil }
        if let it = shelf.first(where: { $0.id == id }) {
            var h = UserDefaults.standard.stringArray(forKey: "shelfHidden") ?? []
            h.append(it.url.standardizedFileURL.path)
            UserDefaults.standard.set(h, forKey: "shelfHidden")
        }
        shelf.removeAll { $0.id == id }
    }
    /// Puts any new file in the results folder on the shelf. Runs every few seconds and after each reply.
    func scanShelf() {
        let new = Shelf.adopt(shelf)
        guard !new.isEmpty else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(contentsOf: new, at: 0) }
    }
    func putOnShelf(title: String, body: String, from: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let it = Shelf.keep(title: title, body: body, from: from) else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(it, at: 0) }
    }
    var openedHelper: Helper? { openHelper.flatMap { id in helpers.first { $0.id == id } } }
    /// Is whatever you're talking to right now busy?
    var busyHere: Bool {
        if let h = openedHelper { return h.state == "working" }
        return thinking
    }
    static func savedHelpers() -> [Helper] {
        guard let d = UserDefaults.standard.data(forKey: "helpers"), var hs = try? JSONDecoder().decode([Helper].self, from: d) else { return [] }
        for k in hs.indices where hs[k].state == "working" {
            hs[k].state = "stopped"
            hs[k].line = "Paused when One closed · tap to pick up"
        }
        return hs
    }
    func saveHelpers() { UserDefaults.standard.set(try? JSONEncoder().encode(helpers), forKey: "helpers") }
    func update(_ id: UUID, _ f: (inout Helper) -> Void) { if let k = helpers.firstIndex(where: { $0.id == id }) { f(&helpers[k]) } }
    func focusHelper(_ id: UUID) {
        openHelper = openHelper == id ? nil : id
        update(id) { $0.finishedAway = false }
    }
    func dismissHelper(_ id: UUID) {
        if openHelper == id { openHelper = nil }
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { $0.id == id } }
    }
    func clearAway() {
        let gone = helpers.filter { $0.finishedAway && $0.state == "done" }.map(\.id)
        for k in helpers.indices { helpers[k].finishedAway = false }
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { gone.contains($0.id) } }
    }

    func spawnHelper(title: String, task: String) {
        helpers.removeAll { ($0.state == "done" || $0.state == "stopped") && !$0.finishedAway && $0.id != openHelper }
        if helpers.filter({ $0.state == "working" }).count >= 3 {
            bubbles.append(
                Bubble(fromMe: false, text: "I already have 3 helpers busy. I'll take \"\(title)\" as soon as one is free; ask me again in a bit."))
            return
        }
        while helpers.count >= 4, let k = helpers.firstIndex(where: { $0.state != "working" }) { helpers.remove(at: k) }
        let h = Helper(title: title, task: task, sid: nil, state: "working", line: "Getting started…")
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { helpers.append(h) }
        let id = h.id
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                self.update(id) {
                    $0.state = "done"
                    $0.line = "Couldn't start"
                    $0.reply = "I couldn't start this job. Ask \(self.name) again in a minute."
                }
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Helpers.brief(assistant: self.assistantName, user: self.userName, task: task), images: [])
        }
    }

    func runHelper(_ id: UUID, _ text: String, images: [String]) async {
        guard let sid = helpers.first(where: { $0.id == id })?.sid else { return }
        update(id) {
            $0.state = "working"
            $0.reply = ""
            $0.line = "Working on it…"
            $0.finishedAway = false
            $0.toldNova = false
        }
        let stop = await Engine.shared.promptSession(
            sid, text, images: images,
            onText: { s in Task { @MainActor in self.update(id) { $0.reply += s } } },
            onTool: { s in Task { @MainActor in self.update(id) { $0.line = Plain.step(s) } } })
        try? await Task.sleep(for: .milliseconds(150))
        let away = !NSApp.isActive
        update(id) { h in
            if stop.hasPrefix("error") && h.reply.isEmpty { h.reply = "I couldn't finish this (\(stop.dropFirst(7)))." }
            let parts = Choices.split(h.reply)
            if !parts.choices.isEmpty {
                h.state = "needsYes"
                h.line = "Needs your yes"
            } else {
                h.state = "done"
                h.line = "Done · " + Helpers.summary(parts.body, 30)
            }
            h.finishedAway = away || (self.openHelper != id && h.state == "needsYes")
        }
        if let h = helpers.first(where: { $0.id == id }), !stop.hasPrefix("error") {
            let said = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty {
                var entry = said
                if let a = h.asked, !a.isEmpty, !(h.log ?? []).isEmpty { entry = "**You:** \(a)\n\n" + said }
                update(id) { $0.log = ($0.log ?? []) + [entry] }
            }
            if let h2 = helpers.first(where: { $0.id == id }), h2.state == "done", let log = h2.log, !log.isEmpty {
                // The file keeps the whole report: the first full answer plus every follow-up, never just the last line.
                let body = log.joined(separator: "\n\n---\n\n")
                if let sid = h2.shelfID, let k = shelf.firstIndex(where: { $0.id == sid }) {
                    let text =
                        "# \(h2.title)\n\n\(body)\n\n— \(h2.title) helper, \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
                    try? text.write(to: shelf[k].url, atomically: true, encoding: .utf8)
                    shelf[k].detail = Helpers.summary(log[0], 60)
                    shelf[k].fresh = true
                    shelf[k].made = Date()
                } else if let it = Shelf.keep(title: h2.title, body: body, from: "\(h2.title) helper") {
                    var it = it
                    it.detail = Helpers.summary(log[0], 60)
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(it, at: 0) }
                    update(id) { $0.shelfID = it.id }
                }
            }
        }
        if away, let h = helpers.first(where: { $0.id == id }) {
            let line = h.state == "needsYes" ? "\(h.title) needs your yes." : "\(h.title) is done."
            Floater.shared.note(line)
            if !thinking { Task { _ = await Speaker.shared.sayNow(line) } }  // heard even with One in the background
        }
    }

    func markConnected(_ id: String) {
        var c = connections.filter { !$0.isEmpty }
        if !c.contains(id) { c.append(id) }
        connectionsRaw = c.joined(separator: ",")
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
    }

    func sharedNote() -> String {
        let n = Shared.note(clashes: clashes)
        clashes = []
        return n + Model.githubNote
    }
    /// If they're signed in to GitHub on this Mac, say so every turn so the assistant never claims it can't.
    static var githubNote: String {
        let h = NSHomeDirectory()
        guard let hosts = try? String(contentsOfFile: "\(h)/.config/gh/hosts.yml", encoding: .utf8), hosts.contains("github.com"),
            let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return "" }
        return
            "\n\n(One app note, not from the user: GITHUB IS CONNECTED. They're signed in on this Mac; use \(gh) (gh repo list, gh repo clone, gh api) and git directly, including private repos. Clone into \(Env.support.path)/work or the brain. Repos with rooms often link each room as a separate repo (git submodules): clone with --recurse-submodules or clone the room's own repo. Never tell them GitHub can't be connected or ask them to download zips.)"
    }

    /// Extra guidance when they talk about rooms or start the welcome interview (not shown to them).
    func roomNotes(_ text: String) -> String {
        let t = text.lowercased()
        var out = ""
        if t.contains("room") {
            out +=
                "\n\n(One app note, not from the user: ROOMS. A room is one part of their life where you act differently and keep its notes apart. A new room is only for different rules, not a new topic. To add one, follow the brain's skills/add-room/SKILL.md, but local only: no GitHub, git or keys; the One app handles backup. First say in one plain line what a room is. Then ask these one per message, each ending with a [choices: ...] line: 1) what you should be for them in this room, 2) who might ever see it, 3) how private it is, 4) what you should push them toward. Then show the room in a short summary: its name, your job there, who might see it, how private it is, what you push toward, and the rules (on your own: read and draft; needs their yes: send, spend, delete; only them: change these rules), ending with [choices: Make the room | Change something]. Build nothing before 'Make the room'. If it's only a topic, say which room and folder it fits in instead. After making it, offer a short get-to-know-you for that room, run from its skills/setup/SKILL.md, with Skip and That's enough for now on every question.)"
        }
        if t.contains("welcome interview") || t.contains("get to know me") {
            out +=
                "\n\n(One app note, not from the user: WELCOME INTERVIEW. Run the personal room's setup (\(Brain.root.path)/personal-room/skills/setup/SKILL.md) as a friendly get-to-know-you interview. Start with what makes the room's purpose clear: what you should be for them in this room, and what you should push them toward. Then its setup questions. One question per message. End every question with a [choices: ...] line whose last two answers are exactly Skip | That's enough for now. Write each answer into the room as it comes. On 'That's enough for now', thank them, say in one line what you saved, and that they can say 'get to know me' any time to continue.)"
        }
        return out
    }

    /// What Nova should know about her helpers: who's still working, and full results she hasn't seen yet.
    func helperNews() -> String {
        guard !helpers.isEmpty else { return "" }
        var lines: [String] = []
        for k in helpers.indices {
            let h = helpers[k]
            switch h.state {
            case "working": lines.append("- \(h.title): still working (\(h.line)).")
            case "stopped": lines.append("- \(h.title): paused, not finished.")
            default:
                let what = h.state == "needsYes" ? "is waiting for the user's yes" : "is DONE"
                if h.toldNova == true {
                    lines.append("- \(h.title): \(what) (you were already given its result).")
                } else {
                    var r = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.count > 2500 { r = String(r.prefix(2500)) + "…" }
                    lines.append("- \(h.title): \(what). Its result:\n\(r.isEmpty ? "(no text)" : r)")
                    helpers[k].toldNova = true
                }
            }
        }
        return "\n\n(One app note, not from the user: status of your helpers right now. Trust this over anything said earlier.\n"
            + lines.joined(separator: "\n") + ")"
    }

    /// Turn what you typed/said plus any pictures and files into (what you see, what the engine gets, images).
    private func compose(_ text: String) -> (display: String, engine: String, images: [String])? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = about
        guard !(t.isEmpty && pictures.isEmpty && files.isEmpty && ref == nil) else { return nil }
        about = nil
        if t.isEmpty, let ref { t = "Tell me what's in \"\(ref.title)\" in a few lines, then ask what I'd like to do with it." }
        let pics = pictures
        pictures = []
        let docs = files
        files = []
        if t.isEmpty {
            t =
                docs.isEmpty
                ? (pics.count == 1 ? "What's in this picture?" : "What's in these pictures?")
                : (pics.count + docs.count == 1 ? "Have a look at this and tell me what it is." : "Have a look at these and tell me what they are.")
        }
        var tags: [String] = []
        if let ref { tags.append("📄 " + ref.title) }
        if !pics.isEmpty { tags.append("🖼 " + (pics.count == 1 ? "1 picture" : "\(pics.count) pictures")) }
        tags += docs.map { "📄 " + $0.name }
        var forEngine = t
        if let ref { forEngine += "\n\n(This is about \"\(ref.title)\". Read it first: \(ref.url.path))" }
        if !docs.isEmpty {
            forEngine += "\n\n(I'm sharing these files. Copies are saved here and you can open them:"
            for d in docs {
                forEngine += "\n- \(d.copy.path)"
                if let tx = d.textCopy { forEngine += " (plain-text version: \(tx.path))" }
            }
            forEngine += ")"
        }
        return (tags.isEmpty ? t : tags.joined(separator: "  ") + "\n" + t, forEngine, pics.map { $0.data.base64EncodedString() })
    }

    /// toNova: the floating orb always talks to Nova, never to an open helper.
    func send(_ text: String, toNova: Bool = false) async {
        if !toNova, let hid = openHelper, let h = openedHelper {
            guard !paused, h.state != "working", let c = compose(text) else { return }
            await ensureEngine()
            update(hid) { $0.asked = c.display }
            await runHelper(hid, c.engine, images: c.images)
            return
        }
        guard !paused, !thinking, let c = compose(text) else { return }
        await ensureEngine()
        me(c.display)
        bubbles.append(Bubble(fromMe: false, text: ""))
        let idx = bubbles.count - 1
        thinking = true
        working = nil
        let voiceFirst = Speaker.shared.ready && !UserDefaults.standard.bool(forKey: "voiceMuted")
        heldText = ""
        Engine.shared.onText = { s in
            Task { @MainActor in
                if voiceFirst { self.heldText += s } else if idx < self.bubbles.count { self.bubbles[idx].text += s }
            }
        }
        Engine.shared.onTool = { s in Task { @MainActor in self.working = Plain.step(s) } }
        Engine.shared.onPermission = { q, opts, answer in
            Task { @MainActor in self.asks.append(Ask(question: q, options: opts, answer: answer)) }
        }
        // Older conversations started before helpers existed, so remind Nova every turn (not shown to the user).
        let note =
            "\n\n(One app note, not from the user: if this needs any work at all (looking something up, browsing, research, comparing, making a file, checking, watching), don't do it here: send helpers. Say in one short line what you're sending, then one line per job: [helper: Short title | the whole job with every detail]. If it has separate parts (e.g. movie times at two theaters, flights and hotels), send one helper per part so they run at the same time. Only answer here yourself when you already know the answer or it's just conversation. Any file you make for them (PDF, document, spreadsheet, picture) goes in \(Shelf.folder.path); the app puts it in front of them under Ready for you, so just say it's there, without the folder path.)"
        let stop = await Engine.shared.prompt(c.engine + note + roomNotes(c.engine) + sharedNote() + Bridge.note + helperNews(), images: c.images)
        try? await Task.sleep(for: .milliseconds(150))
        var full = voiceFirst ? heldText : (idx < bubbles.count ? bubbles[idx].text : "")
        heldText = ""
        let (clean, jobs) = Helpers.extract(full)
        if !jobs.isEmpty {
            full = clean
            for j in jobs { spawnHelper(title: j.0, task: j.1) }
        }
        if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            full = stop.hasPrefix("error") ? "I couldn't do that (\(stop.dropFirst(7))). Try again?" : "Done."
        }
        if voiceFirst && !stop.hasPrefix("error") && !paused {
            // Voice first: the words appear just after she starts talking (or after 6s if the voice stalls).
            revealCount += 1
            let tk = revealCount
            pendingReveal = (idx, full, tk)
            Speaker.shared.read(full) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Task { @MainActor in self?.reveal(tk) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(6))
                reveal(tk)
            }
        } else {
            if idx < bubbles.count { bubbles[idx].text = full }
            thinking = false
            working = nil
            syncName()
            saveBubbles()
            if !voiceFirst, !stop.hasPrefix("error"), !paused { Speaker.shared.read(full) }
        }
    }

    var heldText = ""
    private var pendingReveal: (idx: Int, text: String, token: Int)?
    private var revealCount = 0
    func reveal(_ token: Int? = nil) {
        guard let p = pendingReveal, token == nil || p.token == token else { return }
        pendingReveal = nil
        if p.idx < bubbles.count { bubbles[p.idx].text = p.text }
        thinking = false
        working = nil
        syncName()
        saveBubbles()
    }

    func answer(_ a: Ask, _ choice: String?) {
        a.answer(choice)
        asks.removeAll { $0.id == a.id }
    }

    func toggleStop() {
        paused.toggle()
        if paused { helpers.filter { $0.state == "working" }.compactMap(\.sid).forEach { Engine.shared.cancel(session: $0) } }
        if paused {
            Speaker.shared.stop()
            reveal()
        }
        if paused {
            Engine.shared.cancel()
            asks.forEach { $0.answer(nil) }
            asks.removeAll()
            thinking = false
        }
    }
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
