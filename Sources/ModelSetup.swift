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

@MainActor
extension Model {
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
            // No restart here: Done with an unchanged list used to restart the engine at once and cut off every
            // helper at work. `FolderWatch` restarts by itself when the list really changed, once nothing is busy.
        }
    }

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
        if onboarded { Persona.refreshSoul(assistant: assistantName, user: userName) }
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
        if await SignIn.isSignedIn(p) {
            signedIn[p] = true
            await verify(p)
            return
        }
        step = .signingIn
        signInChoice = p
        signInCode = nil
        signInNeedsPaste = false
        signInProblem = nil
        await say("I need to open your browser to sign in to \(p.title). Can I?", voice: "signin")
    }

    func confirmSignIn(_ p: Provider) async {
        guard step == .signingIn, signInChoice == p else { return }
        signInChoice = nil
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
        let config = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        let old = SwitchAI.currentProvider(config) ?? provider ?? .claude
        let oldModel = MeCard.currentModel()
        // Hermes has one process for all conversations. Let every existing turn finish on its old AI.
        if !SwitchAI.ready(helpers, thinking: thinking) {
            await say("I'll switch to \(p.title) once the helpers at work finish. They're staying on their current AI.")
        }
        while (!onboarded || switchingAI) && !SwitchAI.ready(helpers, thinking: thinking) {
            try? await Task.sleep(for: .seconds(2))
        }
        guard !onboarded || switchingAI else { return }
        await say("Let me check \(p.title) answers before I switch.", voice: "checking")
        var stop = "error: no model answered"
        let got = Box("")
        var failure = "It didn't answer."
        for model in p.models {
            let changed = await SignIn.makeDefault(p, model: model)
            guard changed else {
                failure = "I couldn't save that AI choice."
                break
            }
            if let err = await Engine.shared.start() {
                failure = SignIn.plainReason(err, provider: p.title)
                break
            }
            got.v = ""
            Engine.shared.onText = { t in got.v += t }
            stop = await Engine.shared.prompt("Reply with exactly one word: ready")
            Engine.shared.onText = nil
            if SwitchAI.answered(stop: stop, reply: got.v) { break }
            failure = stop.hasPrefix("error") ? SignIn.plainReason(String(stop.dropFirst(7)), provider: p.title) : "It didn't give a usable answer."
            got.v = ""
        }
        if !SwitchAI.answered(stop: stop, reply: got.v) {
            _ = await SignIn.makeDefault(old, model: oldModel.isEmpty ? old.defaultModel : oldModel)
            _ = await Engine.shared.start()
            step = .pickAI
            await say("I kept your old AI. \(failure) Try again when you're ready.")
            return
        }
        providerRaw = p.rawValue
        if onboarded {
            switchingAI = false
            step = .done
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
            await say("All set. I'm using \(p.title) now.")
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

    var suggestions: [String] {
        [
            "Tidy my Downloads into folders that make sense", "Every morning at 7, send me my day on my phone",
            "Watch a flight price and tell me when it drops",
        ]
    }

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
}
