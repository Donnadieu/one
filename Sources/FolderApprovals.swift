import SwiftUI

// MARK: - Folder access: every NEW grant needs a yes IN THE CONVERSATION, never a silent `defaults write`
//
// The gap (Oct 31, 2026, Omar caught it live): `Access.folders` trusted the raw UserDefaults "folders"
// string with no check on how it got there. Any code running as the person - including the assistant
// itself, from a plain shell command - could silently add a folder with
// `defaults write ai.forjado.one folders -string "$CUR\n<path>"` and nothing ever asked. That's exactly
// how `.gnupg`, two of the engine's own browser-profile folders, `Library/Preferences` and `.fly` ended
// up on Omar's list: real features need them, but none went through a chat ask.
//
// Fix, scoped to what Omar actually asked for after two rounds of steering:
// 1. `Access.folders` itself is UNCHANGED. It is NEVER filtered against the ledger below: nothing
//    already granted - the four paths above or anything else - is ever at risk of being silently
//    dropped. (An earlier draft of this fix cross-checked `Access.folders` against the ledger and
//    excluded anything missing an entry; Omar explicitly ruled that out because it could break an
//    existing grant if the ledger ever fell out of sync. That design is gone.)
// 2. The ask is a plain chat exchange, not a UI card the person might never see: "I don't have access
//    to <folder>. Want me to add it?" / their "Yes", in the SAME conversation, right then - this works
//    identically whether they're at the Mac or on their phone, which is the common case (Omar is
//    usually away from the Mac). `FolderApprovals.grant` is the ONE place in the codebase allowed to
//    add a folder, and it always logs who said yes and how.
// 3. Channel-aware UI: the Mac app (an ACP session, driven through Model's own bubbles) ALSO gets a
//    native approval card with Approve/Deny buttons, reusing the HumanStepCard visual language,
//    because the person can see and tap it there. A phone chat (the background gateway helper, see
//    Messenger.swift) never flows through Model at all - that's the same split that already made
//    `[helper: …]` lines Mac-app-only (one-assistant-dev skill, "Helpers" section: the gateway hands
//    phone messages to a separate background process with its own session, never to this app's Model/
//    bubbles). Nothing in this codebase watches a phone conversation, so by construction only an ACP
//    turn can ever produce the card, and a phone chat always falls back to the plain chat ask/yes - no
//    new "which channel is this" branch needed; that split already existed.
// 4. Both paths call the exact same `FolderApprovals.grant`, so the ledger (`folder-approvals.json`) is
//    one consistent audit trail no matter which one delivered the yes: path, reason, when, and the
//    channel ("mac-app-card", "mac-app-chat", "phone-chat", or "migrated-existing" for the one-time
//    backfill below).
// 5. Defense in depth is honest about its limits: the sandbox can't block a shell `defaults write`
//    (cfprefsd IPC isn't filesystem access, so it isn't something `Access.profile()`'s deny rules can
//    reach - see Env.swift). What IS code-enforced is that `grant` is the only function that writes a
//    ledger entry, and `FolderApprovals.unlogged()` (`Model.tendFolderLedger`, run from the main loop)
//    flags - but never removes - any folder that shows up on the list with no matching entry, so a
//    bypass is visible in a chat bubble and in `hermes/logs/one-folder-ledger.log` rather than invisible.
enum FolderApprovals {
    struct Entry: Codable {
        let path: String
        let reason: String
        let approvedAt: String
        let channel: String  // "mac-app-card" | "mac-app-chat" | "phone-chat" | "migrated-existing"
    }
    struct Ledger: Codable { var approved: [Entry] }

    static var file: URL { Env.support.appendingPathComponent("folder-approvals.json") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-folder-ledger.log") }

    static func load() -> Ledger {
        guard let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(Ledger.self, from: d) else { return Ledger(approved: []) }
        return l
    }
    static func save(_ l: Ledger) { try? JSONEncoder().encode(l).write(to: file, options: .atomic) }

    static func approvedPaths() -> Set<String> { Set(load().approved.map(\.path)) }

    /// A folder on the real list with no ledger entry: either a pre-fix grant not yet migrated, or a
    /// bare `defaults write` that skipped the ask. `migrateExisting()` clears the former on first run.
    static func unlogged() -> [String] {
        let known = approvedPaths()
        return Access.freshFolders.filter { !known.contains($0) }
    }

    /// One-time, the first time a build with this fix runs: every folder already on the list (the four
    /// Omar named, and anything else already there) is logged as "migrated-existing" so it's never
    /// mistaken for a bypass later, and is NEVER asked about again or removed.
    static func migrateExisting() {
        guard !UserDefaults.standard.bool(forKey: "folderApprovalsMigrated") else { return }
        var l = load()
        let known = Set(l.approved.map(\.path))
        let now = ISO8601DateFormatter().string(from: Date())
        for p in Access.folders where !known.contains(p) {
            l.approved.append(
                Entry(
                    path: p, reason: "already allowed before this fix shipped; grandfathered in once, not re-asked (Omar's explicit instruction)",
                    approvedAt: now, channel: "migrated-existing"))
        }
        save(l)
        UserDefaults.standard.set(true, forKey: "folderApprovalsMigrated")
    }

    /// The ONLY function in the codebase allowed to add a new folder. Appends to the ledger AND to the
    /// UserDefaults `folders` list (`Access.set`), so every existing reader of `Access.folders` keeps
    /// working unchanged. Called either from a tapped Approve card (`channel: "mac-app-card"`), a typed
    /// yes in the Mac app's own chat (`"mac-app-chat"`), or `One --grant-folder` (the engine's own path
    /// for a phone chat's yes, `"phone-chat"`/`"chat"`).
    static func grant(path rawPath: String, reason: String, channel: String) {
        let path = (rawPath as NSString).expandingTildeInPath
        var l = load()
        if !l.approved.contains(where: { $0.path == path }) {
            l.approved.append(Entry(path: path, reason: reason, approvedAt: ISO8601DateFormatter().string(from: Date()), channel: channel))
            save(l)
        }
        var f = Access.freshFolders
        if !f.contains(path) {
            f.append(path)
            Access.set(f)
        }
        log("granted \(path) (\(channel)): \(reason.prefix(140))")
    }

    static func log(_ s: String) {
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    /// `One --grant-folder <path> <reason> [channel]`: the one shell command the assistant is told to
    /// run once Omar says yes in chat. It never writes `defaults` itself - it calls `grant` above, the
    /// single code path that updates both the UserDefaults list and the ledger together, so the write
    /// and the audit trail can never land separately. Returns an exit code, or nil if this isn't it.
    static func bridge(_ a: [String]) -> Int32? {
        guard let k = a.firstIndex(of: "--grant-folder") else { return nil }
        guard a.count > k + 2 else {
            print("usage: One --grant-folder <full path> <reason> [channel]")
            return 2
        }
        grant(path: a[k + 1], reason: a[k + 2], channel: a.count > k + 3 ? a[k + 3] : "chat")
        print("granted: \((a[k + 1] as NSString).expandingTildeInPath)")
        return 0
    }

    // MARK: Spotting the assistant's plain ask and their yes (mirrors BrowserGuard.isAsk/isYes/heard)

    static let askPhrase = "want me to add it?"
    static let askLead = "i don't have access to"

    /// True when this reply is the assistant's plain folder ask, word for word (also in `soul` below).
    static func isAsk(_ reply: String) -> Bool {
        let l = reply.lowercased()
        return l.contains(askLead) && l.contains(askPhrase)
    }

    /// The path named in "I don't have access to <path>. Want me to add it?", `~` expanded.
    static func pathIn(_ reply: String) -> String? {
        guard let r = reply.range(of: askLead, options: .caseInsensitive) else { return nil }
        let after = reply[r.upperBound...]
        let end = after.range(of: ".", options: .caseInsensitive)?.lowerBound ?? after.endIndex
        let raw = String(after[after.startIndex..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " .\""))
        return raw.isEmpty ? nil : (raw as NSString).expandingTildeInPath
    }

    static func isYes(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("yes") || t == "ok" || t == "go ahead" || t == "sure" || t == "add it" || t == "yes, add it"
    }

    /// SOUL paragraph: the assistant must ask in chat and wait, on EVERY channel, never shell out itself.
    static let soul = """
        Folders: you can only open One's own data, the brain and the folders already allowed. If a job truly needs one you don't have, ask in plain words, word for word: "I don't have access to <full path>. Want me to add it?", ending with [choices: Yes, add it | No]. Wait for their answer in THIS conversation - never assume a yes. Never add a folder yourself with `defaults write` or any other shell command; that is the one thing you must never do here, on the Mac or away from it. Once they say yes, run `One --grant-folder "<full path>" "<the reason you gave them>"` (One's own binary, already on PATH) and it does the rest and tells you it's done. If they say no, drop it and say so. A routine can't ask anyone: it skips that step and says so in its report.
        """
    static var note: String { "\n\n(One app note, not from the user: FOLDER ACCESS. " + soul + ")" }
}

/// One pending ask shown as a card in the Mac app's own chat (ACP sessions only - see the note at the
/// top of this file for why a phone chat never reaches this).
struct FolderAsk: Identifiable, Equatable {
    let id: String
    let path: String
    let reason: String
}

/// The card: the exact path, the assistant's stated reason, Approve / Deny. Visual language copied
/// from `HumanStepCard` on purpose (Omar: reuse the existing approval-card pattern, don't invent a new one).
struct FolderAskCard: View {
    let a: FolderAsk
    let answer: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Can I add this folder?").font(.headline)
            Text((a.path as NSString).abbreviatingWithTildeInPath).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Text(a.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Yes, add it") { answer(true) }.buttonStyle(.borderedProminent)
                Button("No") { answer(false) }.buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
}

@MainActor
extension Model {
    /// Called once per finished reply (ACP only - a phone-chat turn never runs this code at all):
    /// spots the assistant's plain folder ask and shows the card.
    func detectFolderAsk(_ reply: String) {
        guard FolderApprovals.isAsk(reply), let path = FolderApprovals.pathIn(reply) else { return }
        guard !folderAsks.contains(where: { $0.path == path }) else { return }
        folderAsks.append(FolderAsk(id: UUID().uuidString, path: path, reason: reply))
    }

    /// The card's Approve/Deny, or a typed yes caught by `folderHeard` below.
    func answerFolderAsk(_ id: String, approved: Bool) {
        guard let a = folderAsks.first(where: { $0.id == id }) else { return }
        folderAsks.removeAll { $0.id == id }
        if approved {
            FolderApprovals.grant(path: a.path, reason: a.reason, channel: "mac-app-card")
            Task {
                await send(
                    "(One app note, not from the user: they approved adding \(a.path) with the card. It's added now. Carry on.)", toNova: true,
                    hidden: true)
            }
        } else {
            Task {
                await send(
                    "(One app note, not from the user: they said no to adding \(a.path). Don't add it; say so plainly.)", toNova: true, hidden: true)
            }
        }
    }

    /// A plain typed "yes" in the main chat (no card tap needed) also counts, same as `BrowserGuard.heard`.
    func folderHeard(_ text: String) -> String {
        guard FolderApprovals.isYes(text), let a = folderAsks.first else { return "" }
        FolderApprovals.grant(path: a.path, reason: a.reason, channel: "mac-app-chat")
        folderAsks.removeAll { $0.id == a.id }
        return "\n\n(One app note, not from the user: they said yes in chat; \(a.path) is added now. Carry on.)"
    }

    /// Run every so often from the main loop: a folder on the real list with no matching ledger entry
    /// (a bypass of the ask, after the one-time migration) gets flagged once, never removed.
    func tendFolderLedger() {
        for p in FolderApprovals.unlogged() where !folderLedgerFlagged.contains(p) {
            folderLedgerFlagged.insert(p)
            FolderApprovals.log("flagged (no ledger entry, not the migration): \(p)")
            bubbles.append(
                Bubble(
                    fromMe: false,
                    text:
                        "Heads up: \"\((p as NSString).abbreviatingWithTildeInPath)\" was added to my allowed folders without the usual ask-in-chat step. I didn't ask you for it - flagging it so you know."
                ))
        }
    }
}
