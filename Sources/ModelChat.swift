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
        Installer.applyHumanStep()  // codes, passkeys, human checks: shown to the person, never typed in chat
        await BrowserGuard.sync()  // no visible browser window without their yes (engine plugin + hidden browser tools)
        BundledSkills.sync()  // skills that ship with One; never overwrites one changed here
        Task.detached { _ = GoogleSignIn.ensureVenv() }
        await ExperimentalGuard.sync()
        await LearnedDirs.sync()  // skills saved into private rooms count as skills; shared rooms never
        Task { await LearnedDirs.checkLedgerOn() }
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
        guard isReady else {
            talkNote = GateWords.talk
            return
        }
        talkNote = nil
        // Talking always works, busy or not: what's said goes into the running turn or waits next up.
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
        if let h = helpers.first(where: { $0.shelfID == id }) { markSeen(h.id) }  // its card opened: the helper's been seen
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
        guard let d = UserDefaults.standard.data(forKey: "helpers") else { return [] }
        // One unreadable entry never costs the rest.
        return HelperTrail.restore(HelperClose.decode(d))  // the ones a restart cut off get picked back up once the engine is ready
    }

    func saveHelpers() { UserDefaults.standard.set(try? JSONEncoder().encode(helpers), forKey: "helpers") }
    func update(_ id: UUID, _ f: (inout Helper) -> Void) { if let k = helpers.firstIndex(where: { $0.id == id }) { f(&helpers[k]) } }
    func focusHelper(_ id: UUID) {
        if let h = helpers.first(where: { $0.id == id }), asleep(h) || !isReady { return }  // not back yet: can't be opened
        openHelper = openHelper == id ? nil : id
        update(id) { $0.finishedAway = false }
        if openHelper == id { markSeen(id) }
    }
    /// They opened a finished helper: its orb stops glowing orange and shows the check mark, and no "by the way" goes out for it.
    func markSeen(_ id: UUID) {
        if helpers.first(where: { $0.id == id })?.seen == false { update(id) { $0.seen = true } }
        doneQueue.removeAll { $0 == id }
    }
    /// "Got it" on the While you were gone card: the card goes, every orb stays (only closing one removes it).
    func clearAway() {
        for k in helpers.indices where helpers[k].finishedAway { helpers[k].finishedAway = false }
    }

    func spawnHelper(title: String, task: String, routine: UUID? = nil) {
        // No limit, and nothing makes room: every helper starts right away (the engine runs all its conversations
        // at once) and every finished one stays until they dismiss it (orbs used to vanish before they were opened).
        var h = Helper(title: title, task: task, sid: nil, state: "working", line: "Getting started…")
        h.started = Date()
        h.routine = routine
        HelperTrail.flush(h)
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { helpers.append(h) }
        let id = h.id
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                // Never "done" and never left for them to ask again: it waits for the engine and starts when it's back.
                self.update(id) { HelperTrail.notFinished(&$0, .cutOff) }
                self.saveTrail(id)
                self.resumeWhenReady(after: 1)
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Helpers.brief(assistant: self.assistantName, user: self.userName, task: task), images: [])
        }
    }

    func runHelper(_ id: UUID, _ text: String, images: [String]) async {
        guard let sid = helpers.first(where: { $0.id == id })?.sid else { return }
        helperLive.remove(id)
        learnHelperStart(id)
        update(id) {
            $0.state = "working"
            $0.reply = ""
            $0.line = "Working on it…"
            $0.finishedAway = false
            $0.toldNova = false
            $0.resumeQueued = false
            $0.stoppedByYou = nil  // asked again: it's working again
            $0.seen = nil
        }
        let stop = await Engine.shared.promptSession(
            sid, Helpers.forHelper(text) + SessionNotes.helper, images: images,  // the same notes as the main chat, every turn
            onText: { s in
                Task { @MainActor in
                    self.helperUnderway(id)
                    self.update(id) { $0.reply += s }
                    self.saveTrail(id, force: false)
                }
            },
            onTool: { s in
                Task { @MainActor in
                    guard self.helpers.first(where: { $0.id == id })?.state == "working" else { return }  // stopped or paused: keep its line
                    self.helperUnderway(id)
                    BlockedAsk.saw(s, by: id.uuidString)
                    self.learnHelperStep(id, s)
                    self.update(id) {
                        $0.line = Plain.step(s)
                        HelperTrail.add($0.line, to: &$0)
                    }
                    self.saveTrail(id)
                }
            })
        helperTurnEnded[id] = Date()
        if helpers.first(where: { $0.id == id })?.updatePaused == true {
            // Paused for an update: the engine is going away. It picks back up after the restart; nothing else happens now.
            saveTrail(id)
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        await helperTurnOver(id)
        defer { Task { @MainActor in self.nextUpForHelper(id) } }  // what they sent meanwhile goes next
        let away = !NSApp.isActive
        if helpers.first(where: { $0.id == id })?.stoppedByYou == true {
            // Stopped on purpose: it stays stopped, isn't reported as done, and frees its slot.
            saveTrail(id)
            resumeInterrupted()
            if let b = helpers.first(where: { $0.id == id })?.routine { Task { await deliverRoutine(b) } }
            return
        }
        // Cut off (a restart, a dropped connection), cancelled or failed: stopped and picked back up, never "done".
        if helperDidNotFinish(id, stop: stop) { return }
        update(id) { h in
            // Only the main assistant sends helpers: a helper's own [helper: …] line is dropped, logged, never started.
            let had = !h.reply.isEmpty
            h.reply = Helpers.dropStrayLines(h.reply, helper: h.title)
            if had && h.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                h.reply = "I tried to hand this to another helper instead of doing it. Ask me again and I'll do it myself."
            }
            if stop.hasPrefix("error") && h.reply.isEmpty { h.reply = "I couldn't finish this (\(stop.dropFirst(7)))." }
            // One stopped it at a robot check and its ask is still open: it ends on that ask, orange, never done.
            if let b = self.blockedAsk(for: id) { h.reply = BlockedAsk.enforce(h.reply, line: b.line) }
            let parts = Choices.split(h.reply)
            if !parts.choices.isEmpty {
                h.state = "needsYes"
                h.line = "Needs your yes"
            } else {
                h.state = "done"
                h.line = "Done · " + Helpers.summary(parts.body, 30)
            }
            h.finishedAway = away || (self.openHelper != id && h.state == "needsYes")
            // Orange until they open it, unless they're looking at it right now or it's part of a routine (reported in the chat).
            h.seen = self.openHelper == id || h.routine != nil
        }
        learnHelperFinished(id, stop: stop)
        if let h = helpers.first(where: { $0.id == id }), h.waiting { HelperSound.ring(needsYes: h.state == "needsYes") }  // with the orange pulse
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
        resumeInterrupted()  // pick up any helper a restart cut off that's still waiting
        let routine = helpers.first(where: { $0.id == id })?.routine
        if let b = routine {
            Task { await deliverRoutine(b) }
        } else if openHelper != id, !stop.hasPrefix("error") {
            queueDoneNote(id)
        }
        if away, let h = helpers.first(where: { $0.id == id }) {
            let line = h.state == "needsYes" ? "\(h.title) needs your yes." : "\(h.title) is done."
            Floater.shared.note(line)
            // Heard even with One in the background. Regular helpers get the assistant's own "by the way" line instead.
            if !thinking, routine != nil || stop.hasPrefix("error") { Task { _ = await Speaker.shared.sayNow(line) } }
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
        return n + SharedGuard.note
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

    /// Turn what you typed/said plus any pictures and files into (what you see, what the engine gets, images).
    func compose(_ text: String) -> Composed? {
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
        return Composed(
            display: tags.isEmpty ? t : tags.joined(separator: "  ") + "\n" + t, engine: forEngine,
            images: pics.map { $0.data.base64EncodedString() }, typed: t)
    }

    /// toNova: the floating orb always talks to Nova, never to an open helper.
    func send(_ text: String, toNova: Bool = false, hidden: Bool = false) async {
        if !isReady { gateCheck() }  // the engine may be up a moment before its news arrives
        if !toNova, let hid = openHelper, let h = openedHelper {
            guard var c = compose(text) else { return }
            BrowserGuard.heard(text, after: h.reply)  // "Yes, open it" to a helper's ask unlocks one window
            c.engine += blockedYes(text, helper: hid)  // "Yes, show it" to a robot-check ask shows that one window
            // Busy or stopped: never refused. It goes into the helper's running turn, or next.
            // Being picked back up, or One is getting ready: it waits next up and goes once the helper is back.
            if paused || h.state == "working" || asleep(h) || !isReady { return followUp(c, helper: hid, hidden: false) }
            await ensureEngine()
            update(hid) { $0.asked = c.display }
            await runHelper(hid, c.engine, images: c.images)
            return
        }
        guard var c = compose(text) else { return }
        if !hidden { c.engine += blockedYes(text, helper: nil) }
        if FrictionLog.matches(text) { FrictionLog.add(text, context: bubbles.last { !$0.fromMe }?.text ?? "") }
        if !hidden { BrowserGuard.heard(text, after: bubbles.last { !$0.fromMe }?.text ?? "") }
        // Busy (or stopped): the message goes into the running turn as it runs, or waits next up. Never a second turn, never a stop.
        // Getting ready: it waits next up and goes the moment One opens (StartupGate.swift). Never lost.
        if paused || thinking || !isReady { return followUp(c, helper: nil, hidden: hidden) }
        thinking = true  // taken now, before any wait, so two sends can never both start a turn
        await runTurn(c, hidden: hidden)
    }

    /// One turn of the main conversation. `thinking` is already set.
    func runTurn(_ c: Composed, hidden: Bool) async {
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
        Engine.shared.onTool = { s in
            Task { @MainActor in
                self.working = Plain.step(s)
                BlockedAsk.saw(s, by: "main")
                self.learnStep(s)
            }
        }
        Engine.shared.onPermission = { q, opts, answer in
            Task { @MainActor in self.asks.append(Ask(question: q, options: opts, answer: answer)) }
        }
        Engine.shared.onActivity = { Task { @MainActor in self.turnUnderway() } }
        let message =
            c.engine + recap + Helpers.note + roomNotes(c.engine) + sharedNote() + helperNews()
            + SessionNotes.main  // their screen, what is connected and built, which One: told every turn
            + (hidden ? "" : Learning.kindNote)
        learnStart(hidden: hidden)
        let gateway = GatewayGuard.recordedPID()
        turnLive = true
        turnStarted = false
        var stop = await Engine.shared.prompt(message, images: c.images)
        try? await Task.sleep(for: .milliseconds(150))
        let soFar = voiceFirst ? heldText : (idx < bubbles.count ? bubbles[idx].text : "")
        if Engine.dropped(stop, text: soFar, gatewayBefore: gateway) {
            // The engine's helper restarted under this message: send it again once, quietly,
            // with anything they'd already sent into it, so none of it is lost.
            heldText = ""
            if idx < bubbles.count { bubbles[idx].text = "" }
            working = "Picking that back up…"
            turnStarted = false
            let sentSoFar = followUps.filter { $0.helper == nil && $0.state == .sent }.map(\.engine)
            stop = await Engine.shared.promptAgain(([message] + sentSoFar).joined(separator: "\n\n"), images: c.images)
            try? await Task.sleep(for: .milliseconds(150))
        }
        await turnOver(idx, failed: stop.hasPrefix("error"))
        var full = voiceFirst ? heldText : (idx < bubbles.count ? bubbles[idx].text : "")
        heldText = ""
        let (unstopped, stops) = HelperStop.extract(full)
        if !stops.isEmpty {
            // "[stop-helper: …]": stopped first, so a helper sent in the same reply is never caught by "all".
            full = unstopped
            for s in stops { if let miss = stopHelpers(named: s) { full += (full.isEmpty ? "" : "\n\n") + miss } }
        }
        let (unclosed, closes) = HelperStop.extract(full, tag: "close-helper")
        if !closes.isEmpty {
            // "[close-helper: …]": asked to take an orb off the screen. The only way besides its X.
            full = unclosed
            for s in closes { if let miss = closeHelpers(named: s) { full += (full.isEmpty ? "" : "\n\n") + miss } }
        }
        full = Helpers.undouble(full)  // one reply delivered twice shows (and sends its helpers) once
        let (clean, all) = Helpers.extract(full)
        let (jobs, skipped) = Helpers.unique(all, among: helpers)  // the same job twice starts one helper
        Helpers.logSkipped(skipped)
        if !all.isEmpty {
            full = clean
            let routine = Helpers.isRoutine(c.typed) ? UUID() : nil  // a good morning or status report: one combined report later
            for j in jobs { spawnHelper(title: j.0, task: j.1, routine: routine) }
        }
        full = learnFinish(full, stop: stop, idx: idx)  // [job-kind:] / [learned:] read and hidden; the job recorded
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
        let lines = last.map { b in
            b.followUps.map { userName + ": " + $0 } + [(b.fromMe ? userName : assistantName) + ": " + String(b.text.prefix(1200))]
        }.flatMap { $0 }
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
        } else {
            sendWaiting()  // back on: what they sent while stopped goes now, in order
        }
    }
}
