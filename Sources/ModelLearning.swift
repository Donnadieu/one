import Foundation
import SwiftUI

/// Counting one job while it runs: when it started, how many steps, and whether it used a skill it already had.
struct LearnTurn {
    var started = Date()
    var steps = 0
    var usedSkill = false
    var active = false
}

/// Something to say about learning, waiting for a quiet moment (never in the middle of a reply).
struct LearnShow {
    var job: UUID
    var kind: String  // "learned", "ask", "helperLearned"
    var skills: [String] = []
}

// MARK: - Tell me when I learn (see Learning.swift): counting jobs, reading the skill log, the lines and taps.

@MainActor
extension Model {
    // While a job runs

    /// A main-chat turn starts. Hidden turns (One's own notes) aren't jobs.
    func learnStart(hidden: Bool) {
        guard !hidden else { return }
        learnTurn = LearnTurn(started: Date(), active: true)
        clearOffers(helper: nil)  // Undo stays only until the next job starts
    }
    func learnStep(_ title: String) {
        guard learnTurn.active else { return }
        learnTurn.steps += 1
        if title.hasPrefix("skill_view") { learnTurn.usedSkill = true }
    }
    func learnHelperStart(_ id: UUID) {
        learnHelperTurns[id] = LearnTurn(started: Date(), active: true)
        clearOffers(helper: id)
    }
    func learnHelperStep(_ id: UUID, _ title: String) {
        guard learnHelperTurns[id]?.active == true else { return }
        learnHelperTurns[id]?.steps += 1
        if title.hasPrefix("skill_view") { learnHelperTurns[id]?.usedSkill = true }
    }

    /// The main turn's reply is in: tags read and taken out, the job recorded. Returns the text to show.
    func learnFinish(_ text: String, stop: String, idx: Int) -> String {
        let t = Learning.tags(text)
        var full = t.clean
        if let l = t.learned {
            full += learnSaved(name: l.name, room: l.room, job: learnSaving, reply: full, helper: nil)
            learnSaving = nil
        } else if learnSaving != nil, text.lowercased().contains("[learned:") {
            learnSaving = nil  // "[learned: none | none]": the reply already says it couldn't
        }
        guard learnTurn.active, let sid = Engine.shared.mainSession else { return full }
        learnTurn.active = false
        let asked = bubbles.last { $0.fromMe }?.text ?? ""
        let kind = t.kind ?? asked.split(separator: " ").prefix(5).joined(separator: " ")
        let job = LearnJob(
            session: sid, helper: nil, kind: kind, started: learnTurn.started, ended: Date(), steps: learnTurn.steps,
            usedSkill: learnTurn.usedSkill, failed: stop.hasPrefix("error") || paused)
        learning.jobs.append(job)
        if idx < bubbles.count { learnBubbles[job.id] = bubbles[idx].id }
        Learning.save(learning)
        return full
    }

    /// A helper's turn is over (done or needs a yes; stopped helpers never get here).
    func learnHelperFinished(_ id: UUID, stop: String) {
        guard let t = learnHelperTurns[id], t.active, let h = helpers.first(where: { $0.id == id }), let sid = h.sid else { return }
        learnHelperTurns[id]?.active = false
        let job = LearnJob(
            session: sid, helper: id, kind: h.title, started: t.started, ended: Date(), steps: t.steps, usedSkill: t.usedSkill,
            failed: stop.hasPrefix("error"))
        learning.jobs.append(job)
        Learning.save(learning)
    }

    // Every few seconds

    /// Which of One's chats a log line belongs to: the main chat, a helper, or a subagent one of them sent.
    func knownChat(_ sid: String) -> String? {
        var mine = Set(helpers.compactMap(\.sid))
        if let m = Engine.shared.mainSession ?? UserDefaults.standard.string(forKey: "sessionID") { mine.insert(m) }
        if mine.contains(sid) { return sid }
        if let p = Learning.parent(of: sid), mine.contains(p) { return p }
        return nil
    }

    func tendLearning() {
        guard onboarded || Env.selfTest else { return }
        var changed = false
        if !learning.started, !FileManager.default.fileExists(atPath: Learning.ledger.path) {
            learning.started = true  // no log yet: nothing old to skip, so the very first line counts
            changed = true
        }
        if let lines = Learning.readLedger() {
            Learning.take(lines, into: &learning, known: knownChat)
            changed = true
            refreshLearnedCards()
        }
        let events = Learning.evaluate(&learning)
        for e in events {
            changed = true
            switch e {
            case .learned(let j, let skills): learned(j, skills)
            case .ask(let j): learnQueue.append(LearnShow(job: j.id, kind: "ask"))
            case .undoQuietly(let j, let skills):
                // They said no to recipes for this kind of job: the engine saved one anyway, so it goes, quietly.
                Task {
                    for s in skills {
                        let ok = await Learning.rollback(j.lines, skill: s)
                        Learning.log("declined kind \"\(j.kind)\": skill \(s) rolled back by itself (\(ok))")
                    }
                }
            }
        }
        if showQueued() { changed = true }
        if changed { Learning.save(learning) }
    }

    /// A new skill: remembered, a Learned card, and the line (in the main chat, or in the helper's own conversation).
    private func learned(_ j: LearnJob, _ skills: [String]) {
        for s in skills {
            guard let file = Learning.skillFile(j.lines, s) else { continue }
            var l = LearnedSkill(name: s, room: nil, path: file, session: j.session)
            l.ledgerIDs = j.lines.filter { $0.skill == s }.map(\.id)
            l.card = learnCard(s, path: file)
            learning.learned.removeAll { $0.name == s && $0.room == nil }
            learning.learned.append(l)
        }
        learnQueue.append(LearnShow(job: j.id, kind: "learned", skills: skills))
        if j.helper != nil { learnQueue.append(LearnShow(job: j.id, kind: "helperLearned", skills: skills)) }
        Learning.log("learned \(skills.joined(separator: ", ")) in \(j.helper == nil ? "the main chat" : "a helper") (\(j.kind))")
    }

    private func learnCard(_ name: String, path: String) -> UUID? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let it = ShelfItem(title: "Learned: \(Learning.plain(name))", detail: "A recipe I keep for this. Tap to read it.", from: name, path: path)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shelf.insert(it, at: 0) }
        return it.id
    }

    /// Fixes to a learned skill only change its card's small text.
    private func refreshLearnedCards() {
        for l in learning.learned where l.fixes > 0 {
            guard let c = l.card, let k = shelf.firstIndex(where: { $0.id == c }) else { continue }
            let when = l.lastFix.map {
                Calendar.current.isDateInToday($0) ? "today" : DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
            }
            let d = "Got better \(l.fixes) time\(l.fixes == 1 ? "" : "s")" + (when.map { ", last \($0)" } ?? "")
            if shelf[k].detail != d { shelf[k].detail = d }
        }
    }

    /// Shows what's waiting, once the chat it goes into is quiet. Returns true if anything changed.
    private func showQueued() -> Bool {
        var changed = false
        var keep: [LearnShow] = []
        for q in learnQueue {
            guard let j = learning.jobs.first(where: { $0.id == q.job }) else {
                changed = true
                continue
            }
            let mainQuiet = !thinking && !paused && !voicePlaying && !followUps.contains { $0.helper == nil }
            switch q.kind {
            case "learned" where j.helper == nil, "helperLearned":
                guard mainQuiet else {
                    keep.append(q)
                    continue
                }
                if q.kind == "helperLearned" {
                    let title = helpers.first { $0.id == j.helper }?.title ?? j.kind
                    bubbles.append(Bubble(fromMe: false, text: "By the way, \(title) learned how to do this, so next time it'll be faster."))
                } else {
                    var line = Learning.learnedLine
                    if !learning.explainedSkill {
                        line += " " + Learning.explain
                        learning.explainedSkill = true
                    }
                    say(line, choices: [Learning.undo], offer: LearnOffer(kind: "undo", job: j.id, skills: q.skills, line: line), in: j)
                }
            case "learned":
                guard let h = helpers.first(where: { $0.id == j.helper }), h.state != "working" else {
                    if helpers.contains(where: { $0.id == j.helper }) { keep.append(q) }
                    continue
                }
                var line = Learning.learnedLine
                if !learning.explainedSkill {
                    line += " " + Learning.explain
                    learning.explainedSkill = true
                }
                say(line, choices: [Learning.undo], offer: LearnOffer(kind: "undo", job: j.id, helper: h.id, skills: q.skills, line: line), in: j)
            default:  // "ask"
                // The moment passed: another job started in that chat, or 30 minutes went by.
                let later = j.helper == nil ? learnTurn.started > j.ended : (learnHelperTurns[j.helper!]?.started ?? .distantPast) > j.ended
                if later || Date().timeIntervalSince(j.ended) > 1800 {
                    changed = true
                    continue
                }
                let quiet = j.helper == nil ? mainQuiet : helpers.first { $0.id == j.helper }.map { $0.state == "done" } ?? false
                guard quiet else {
                    if j.helper == nil || helpers.contains(where: { $0.id == j.helper }) { keep.append(q) }
                    continue
                }
                say(
                    Learning.askLine, choices: [Learning.yes, Learning.no],
                    offer: LearnOffer(kind: "ask", job: j.id, helper: j.helper, line: Learning.askLine), in: j)
            }
            changed = true
        }
        learnQueue = keep
        return changed
    }

    /// Puts a line (with its tap answers) under the job's own reply when it's still the last thing said, else on its own.
    private func say(_ line: String, choices: [String], offer: LearnOffer, in j: LearnJob) {
        let tail = "\n\n" + line + "\n[choices: " + choices.joined(separator: " | ") + "]"
        if let hid = j.helper {
            update(hid) { h in
                guard Choices.split(h.reply).choices.isEmpty else {
                    h.reply += "\n\n" + line  // it's already asking something: the line goes in, without taps
                    return
                }
                h.reply += tail
                if offer.kind == "ask" {
                    h.state = "needsYes"
                    h.line = "Needs your yes"
                    h.seen = openHelper == hid
                }
            }
            learning.offers.append(offer)
            return
        }
        if let bid = learnBubbles[j.id], let k = bubbles.lastIndex(where: { $0.id == bid }), k == bubbles.count - 1,
            Choices.split(bubbles[k].text).choices.isEmpty
        {
            bubbles[k].text += tail
        } else {
            bubbles.append(Bubble(fromMe: false, text: String(tail.dropFirst(2))))
        }
        saveBubbles()
        learning.offers.append(offer)
    }

    // Taps

    /// A tap on a choice: Undo / Yes, remember it / No thanks are One's own; anything else goes to the assistant.
    func choose(_ c: String) async {
        if await learnPick(c) { return }
        await send(c)
    }

    func learnPick(_ c: String) async -> Bool {
        let hid = openHelper
        guard
            let k = learning.offers.lastIndex(where: { o in
                o.helper == hid && ((o.kind == "undo" && c == Learning.undo) || (o.kind == "ask" && (c == Learning.yes || c == Learning.no)))
            })
        else { return false }
        let o = learning.offers.remove(at: k)
        let job = learning.jobs.first { $0.id == o.job }
        switch c {
        case Learning.undo:
            resolve(o, with: "Forgetting it…")
            var ok = true
            for s in o.skills {
                guard let l = learning.learned.last(where: { $0.name == s }) else { continue }
                let gone = l.room == nil ? await Learning.rollback(job?.lines ?? [], skill: s) : Learning.trash(l.path)
                if gone {
                    if let card = l.card { shelf.removeAll { $0.id == card } }
                    learning.learned.removeAll { $0.name == s && $0.room == l.room }
                } else {
                    ok = false
                }
            }
            resolve(o, with: ok ? Learning.forgot : "I couldn't undo that one. Ask me and I'll sort it out.", replacing: "Forgetting it…")
        case Learning.no:
            if let kind = job?.kind, !kind.isEmpty, !Learning.declined(kind, learning) {
                learning.declinedKinds.append(.init(kind: kind, date: Date()))
            }
            resolve(o, with: "Okay, I won't ask about this kind of job again.")
            Learning.save(learning)  // the memory note below reads it
            Persona.write(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
        default:  // yes
            resolve(o, with: "Okay, saving how I did it…")
            if let hid, let sid = helpers.first(where: { $0.id == hid })?.sid {
                Task { await saveFromHelper(hid, sid: sid, job: o.job) }
            } else {
                learnSaving = o.job
                Task { await send(Learning.savePrompt(brain: Brain.root.path), toNova: true, hidden: true) }
            }
        }
        Learning.save(learning)
        return true
    }

    /// Takes the offer's taps away and puts the answer in place of its line.
    private func resolve(_ o: LearnOffer, with reply: String, replacing old: String? = nil) {
        func fix(_ text: String) -> String {
            var body = Choices.split(text).body
            if let old, body.contains(old) { return body.replacingOccurrences(of: old, with: reply) }
            if let r = body.range(of: o.line, options: .backwards) {
                body.replaceSubrange(r, with: reply)
            } else {
                body += "\n\n" + reply
            }
            return body
        }
        if let hid = o.helper {
            update(hid) { h in
                h.reply = fix(h.reply)
                if h.state == "needsYes", Choices.split(h.reply).choices.isEmpty {
                    h.state = "done"
                    h.line = "Done · " + Helpers.summary(h.reply, 30)
                }
            }
            return
        }
        let target = old ?? o.line
        if let k = bubbles.lastIndex(where: { $0.text.contains(target) }) { bubbles[k].text = fix(bubbles[k].text) }
        saveBubbles()
    }

    /// Undo and the remember question last until the next job in that chat starts.
    func clearOffers(helper: UUID?) {
        let old = learning.offers.filter { $0.helper == helper }
        guard !old.isEmpty else { return }
        learning.offers.removeAll { $0.helper == helper }
        learnQueue.removeAll { q in q.kind != "helperLearned" && learning.jobs.first { $0.id == q.job }?.helper == helper }
        for o in old {
            if let hid = o.helper {
                update(hid) { h in if h.reply.contains(o.line) { h.reply = Choices.split(h.reply).body } }
            } else if let k = bubbles.lastIndex(where: { $0.text.contains(o.line) }) {
                bubbles[k].text = Choices.split(bubbles[k].text).body
            }
        }
        Learning.save(learning)
    }

    /// "Yes, remember it" in a helper: asked in its own conversation, quietly, without touching what it already reported.
    private func saveFromHelper(_ hid: UUID, sid: String, job: UUID) async {
        let box = TextBox()
        let stop = await Engine.shared.promptSession(
            sid, Learning.savePrompt(brain: Brain.root.path), onText: { s in box.add(s) }, onTool: { _ in })
        let t = Learning.tags(box.text)
        var line = t.clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if let l = t.learned, !stop.hasPrefix("error") {
            line += learnSaved(name: l.name, room: l.room, job: job, reply: line, helper: hid)
        } else {
            line = "I couldn't save that one. Want me to try again?"
        }
        update(hid) { $0.reply = $0.reply.replacingOccurrences(of: "Okay, saving how I did it…", with: line) }
    }

    /// The assistant says it saved the skill into a room. Checked on disk before anything shows.
    /// Returns what goes after its reply: the Undo taps, or nothing.
    func learnSaved(name: String, room: String, job: UUID?, reply: String, helper: UUID?) -> String {
        let shared = Shared.paths.first { URL(fileURLWithPath: $0).lastPathComponent == room }
        let base = shared.map { URL(fileURLWithPath: $0) } ?? Brain.root.appendingPathComponent(room)
        let file = base.appendingPathComponent("skills/learned/\(name)/SKILL.md")
        guard let t = try? String(contentsOf: file, encoding: .utf8), t.hasPrefix("---") else {
            Learning.log("save said \(name) in \(room), but \(file.path) isn't a skill")
            return "\n\nI couldn't save that one. Want me to try again?"
        }
        if shared != nil {
            // A shared room's skills stay out of the engine's reach (LearnedDirs): it gets its own private copy instead.
            let mine = Env.hermesHome.appendingPathComponent("skills/learned/\(name)")
            try? FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: mine.appendingPathComponent("SKILL.md"))
            try? FileManager.default.copyItem(at: file, to: mine.appendingPathComponent("SKILL.md"))
        }
        var l = LearnedSkill(name: name, room: room, path: file.path)
        if room != "nyx-room" { l.card = learnCard(name, path: file.path) }  // Nyx stays private: no card
        learning.learned.removeAll { $0.name == name && $0.room == room }
        learning.learned.append(l)
        if let kind = learning.jobs.first(where: { $0.id == job })?.kind { learning.declinedKinds.removeAll { Learning.sameKind($0.kind, kind) } }
        Task { await LearnedDirs.sync() }
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? reply
        learning.offers.append(LearnOffer(kind: "undo", job: job ?? UUID(), helper: helper, skills: [name], line: line))
        Learning.save(learning)
        Learning.log("saved \(name) into \(room)")
        return "\n[choices: \(Learning.undo)]"
    }
}

/// Collects a reply's words from the engine's thread.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t = ""
    func add(_ s: String) {
        lock.lock()
        t += s
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return t
    }
}
