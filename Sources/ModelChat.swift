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
    // Talking after setup

    func ensureEngine() async {
        guard onboarded, !Engine.shared.running, !Env.commandLine else { return }
        if backup == "icloud" { Task.detached { _ = Brain.backupToICloud() } }
        Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        // Warn only if KeePass really isn't wired in after a retry, and never twice in a row
        // (a one-off failed write used to show this on every open even though KeePass worked).
        let warn = "Heads up: after an update I can't use your KeePass logins right now. Everything else works. Tell me and I'll look into it."
        bubbles.removeAll { $0.text == warn }
        if UserDefaults.standard.string(forKey: "passwordsWith") == "KeePass", !Installer.applyOverlay(), !Installer.applyOverlay(),
            !Installer.keepassWired
        {
            bubbles.append(
                Bubble(
                    fromMe: false,
                    text: warn
                ))
        }
        BundledSkills.sync()  // skills that ship with One; never overwrites one changed here
        Task.detached { _ = GoogleSignIn.ensureVenv() }
        await ExperimentalGuard.sync()
        await SignIn.enableRoutines()
        await PhoneVoice.sync()  // phone chats speak with the same voice as the Mac
        if let e = await Engine.shared.ensureStarted() {
            bubbles.append(Bubble(fromMe: false, text: "I couldn't start: \(e)"))
        } else {
            resumeInterrupted()  // helpers a restart cut off pick up where they left off
        }
    }

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
    /// Reads the "Made by" folder off the main thread. The first read of Documents can wait on a
    /// macOS permission prompt; on the main thread that froze the whole app until someone clicked.
    func scanShelf() {
        guard !shelfScanning else { return }
        shelfScanning = true
        let have = shelf
        Task.detached {
            let new = Shelf.adopt(have)
            await MainActor.run {
                self.shelfScanning = false
                let known = Set(self.shelf.map(\.path))
                let fresh = new.filter { !known.contains($0.path) }
                guard !fresh.isEmpty else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { self.shelf.insert(contentsOf: fresh, at: 0) }
            }
        }
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
        guard let d = UserDefaults.standard.data(forKey: "helpers"), let hs = try? JSONDecoder().decode([Helper].self, from: d) else { return [] }
        return HelperTrail.restore(hs)  // the ones a restart cut off get picked back up once the engine is ready
    }

    /// Picks up helpers a restart cut off, up to 3 working at once. Runs once the engine is ready and
    /// whenever a helper finishes. Tells the person once per helper, in the chat, on the orb and out loud.
    func resumeInterrupted() {
        guard Engine.shared.running, !paused, helpers.contains(where: { $0.resumeQueued == true }) else { return }
        let picked = HelperTrail.pick(&helpers) { Helpers.brief(assistant: self.assistantName, user: self.userName, task: $0) }
        for p in picked {
            guard let h = helpers.first(where: { $0.id == p.id }) else { continue }
            HelperTrail.flush(h)
            let line = HelperTrail.told(h.title)
            bubbles.append(Bubble(fromMe: false, text: line))
            Floater.shared.note(line)
            Task {
                for _ in 0..<24 where self.thinking { try? await Task.sleep(for: .seconds(5)) }
                _ = await Speaker.shared.sayNow(line)  // silent when muted
            }
            Task { @MainActor in
                let sid = await HelperTrail.session(
                    old: h.sid, reopen: { await Engine.shared.reopenSession($0) }, open: { await Engine.shared.openSession() })
                guard let sid else {
                    self.update(p.id) {
                        $0.state = "stopped"
                        $0.line = "Couldn't pick it back up · tap to see what it did"
                    }
                    return
                }
                self.update(p.id) { $0.sid = sid }
                await self.runHelper(p.id, p.prompt, images: [])
            }
        }
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
        helpers.removeAll {
            ($0.state == "done" || $0.state == "stopped") && !$0.finishedAway && $0.id != openHelper && $0.resumeQueued != true
        }
        if helpers.filter({ $0.state == "working" }).count >= 3 {
            bubbles.append(
                Bubble(fromMe: false, text: "I already have 3 helpers busy. I'll take \"\(title)\" as soon as one is free; ask me again in a bit."))
            return
        }
        while helpers.count >= 4, let k = helpers.firstIndex(where: { $0.state != "working" && $0.resumeQueued != true }) { helpers.remove(at: k) }
        var h = Helper(title: title, task: task, sid: nil, state: "working", line: "Getting started…")
        h.started = Date()
        HelperTrail.flush(h)
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
            $0.resumeQueued = false
            $0.stoppedByYou = nil  // asked again: it's working again
        }
        let stop = await Engine.shared.promptSession(
            sid, text, images: images,
            onText: { s in
                Task { @MainActor in
                    self.update(id) { $0.reply += s }
                    self.saveTrail(id, force: false)
                }
            },
            onTool: { s in
                Task { @MainActor in
                    self.update(id) {
                        $0.line = Plain.step(s)
                        HelperTrail.add($0.line, to: &$0)
                    }
                    self.saveTrail(id)
                }
            })
        try? await Task.sleep(for: .milliseconds(150))
        let away = !NSApp.isActive
        if helpers.first(where: { $0.id == id })?.stoppedByYou == true {
            // Stopped on purpose: it stays stopped, isn't reported as done, and frees its slot.
            saveTrail(id)
            resumeInterrupted()
            return
        }
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
        saveTrail(id)
        resumeInterrupted()  // a slot is free: pick up the next helper a restart cut off
        if openHelper != id, !stop.hasPrefix("error") { Task { await deliverHelper(id) } }
        if away, let h = helpers.first(where: { $0.id == id }) {
            let line = h.state == "needsYes" ? "\(h.title) needs your yes." : "\(h.title) is done."
            Floater.shared.note(line)
            if !thinking { Task { _ = await Speaker.shared.sayNow(line) } }  // heard even with One in the background
        }
    }

    func saveTrail(_ id: UUID, force: Bool = true) {
        if let h = helpers.first(where: { $0.id == id }) { HelperTrail.flush(h, force: force) }
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
        return n + SharedGuard.note + Model.githubNote
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
    /// A helper finished: the assistant tells you what it found right away, in the chat and out loud.
    /// Before, it only said "X is done", and asking got "I have the update" instead of the update itself.
    func deliverHelper(_ id: UUID) async {
        while thinking || paused { try? await Task.sleep(for: .milliseconds(500)) }
        guard let h = helpers.first(where: { $0.id == id }), h.toldNova != true else { return }
        let ask = h.state == "needsYes" ? " It needs their yes: say exactly what for and offer the choices." : ""
        await send(
            "(One app note, not from the user: your helper \"\(h.title)\" just finished. Give \(userName) the actual result now, "
                + "in your own words: the real content they asked for (the numbers, names, times, what changed), short and complete. "
                + "Never just say you have the update or that it's ready.\(ask))", toNova: true, hidden: true)
    }

    func helperNews() -> String {
        guard !helpers.isEmpty else { return "" }
        var lines: [String] = []
        for k in helpers.indices {
            let h = helpers[k]
            switch h.state {
            case "working":
                if let n = h.restartNews {
                    lines.append("- \(h.title): still working. A restart cut it off and One picked it back up by itself; they were told: \"\(n)\"")
                    helpers[k].restartNews = nil
                } else {
                    lines.append("- \(h.title): still working (\(h.line)).")
                }
            case "stopped":
                lines.append(
                    h.resumeQueued == true
                        ? "- \(h.title): cut off by a restart; One picks it back up by itself in a moment."
                        : "- \(h.title): stopped, not finished (\(h.line)).")
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
    func send(_ text: String, toNova: Bool = false, hidden: Bool = false) async {
        if !toNova, let hid = openHelper, let h = openedHelper {
            guard !paused, h.state != "working", let c = compose(text) else { return }
            await ensureEngine()
            update(hid) { $0.asked = c.display }
            await runHelper(hid, c.engine, images: c.images)
            return
        }
        guard !paused, !thinking, let c = compose(text) else { return }
        if FrictionLog.matches(text) { FrictionLog.add(text, context: bubbles.last { !$0.fromMe }?.text ?? "") }
        await ensureEngine()
        let recap = Engine.shared.lostConversation ? onScreenRecap() : ""
        Engine.shared.lostConversation = false
        if !hidden { me(c.display) }
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
        let message = c.engine + recap + Helpers.note + roomNotes(c.engine) + sharedNote() + Bridge.note + FolderWatch.note + helperNews()
        let gateway = GatewayGuard.recordedPID()
        var stop = await Engine.shared.prompt(message, images: c.images)
        try? await Task.sleep(for: .milliseconds(150))
        let soFar = voiceFirst ? heldText : (idx < bubbles.count ? bubbles[idx].text : "")
        if Engine.dropped(stop, text: soFar, gatewayBefore: gateway) {
            // The engine's helper restarted under this message: send it again once, quietly.
            heldText = ""
            if idx < bubbles.count { bubbles[idx].text = "" }
            working = "Picking that back up…"
            stop = await Engine.shared.promptAgain(message, images: c.images)
            try? await Task.sleep(for: .milliseconds(150))
        }
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

    /// When the saved conversation couldn't be reopened, hand the new one the end of what's on screen,
    /// so the person never has to repeat themselves.
    func onScreenRecap() -> String {
        let last = bubbles.filter { !$0.text.isEmpty }.suffix(12)
        guard !last.isEmpty else { return "" }
        let lines = last.map { ($0.fromMe ? userName : assistantName) + ": " + String($0.text.prefix(1200)) }
        return "\n\n(One app note, not from the user: the app restarted and the earlier conversation couldn't be reopened. "
            + "This is the end of it, as it was on screen. Carry on from it; don't say you lost it.\n"
            + lines.joined(separator: "\n") + ")"
    }

    /// "Start fresh": a new conversation on purpose. Memory, rooms and helpers stay.
    func startFresh() async {
        guard !thinking else { return }
        Speaker.shared.stop()
        await ensureEngine()
        guard await Engine.shared.startFresh() else {
            bubbles.append(Bubble(fromMe: false, text: "I couldn't start a new conversation just now. Try again in a moment?"))
            return
        }
        bubbles = []
    }

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

    /// The person stopped this helper on purpose: its work is cancelled and it stays stopped, even after a restart.
    func stopHelper(_ id: UUID) {
        var cancel = false
        update(id) { cancel = HelperTrail.stopByYou(&$0) }
        saveTrail(id)
        if cancel, let sid = helpers.first(where: { $0.id == id })?.sid { Engine.shared.cancel(session: sid) }
    }

    /// Something is being said out loud right now (or a reply is waiting on its first words).
    var voicePlaying: Bool { Speaker.shared.talking || pendingReveal != nil }
    /// Stop talking just this once (Esc, or a click on the orb while it talks): the voice stops now and the
    /// held words show at once. Never the mute: the reply, helpers and the next reply's voice carry on.
    func hushVoice() {
        Speaker.shared.hushReply()
        reveal()
    }

    func toggleStop() {
        paused.toggle()
        if paused { helpers.filter { $0.state == "working" || $0.resumeQueued == true }.map(\.id).forEach { stopHelper($0) } }
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
