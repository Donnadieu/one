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

// MARK: - The brain (built from the AI Brain Starter, kept as local folders)

enum RoomKind: String, CaseIterable, Identifiable {
    case personal, work, cofounder, privateRoom
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .personal: "personal-room"
        case .work: "work-room"
        case .cofounder: "cofounder-room"
        case .privateRoom: "private-room"
        }
    }
    var title: String {
        switch self {
        case .personal: "personal room"
        case .work: "work room"
        case .cofounder: "co-founder room"
        case .privateRoom: "private room"
        }
    }
    var chip: String {
        switch self {
        case .personal: "No, start simple"
        case .work: "My job"
        case .cofounder: "A business I'm starting"
        case .privateRoom: "Something just for me"
        }
    }
    var hub: String {
        switch self {
        case .personal: "brain/life.md"
        case .work: "brain/jobs.md"
        case .cofounder: "brain/company.md"
        case .privateRoom: "brain/notes.md"
        }
    }
    var holds: String {
        switch self {
        case .personal: "home, family, health, money, relationships, hobbies, creative work, learning, long-term goals, community."
        case .work: "your own notes about your job or jobs: commitments, people, wins, how you work best."
        case .cofounder: "a business you run or are starting: ideas, buyers, the offer, the pipeline."
        case .privateRoom: "whatever you want kept just for you."
        }
    }
    var never: String {
        switch self {
        case .personal: "a job's work, a business."
        case .work: "your employer's code, data, documents or customer information. Personal life. A business of your own."
        case .cofounder: "personal life, a job's work."
        case .privateRoom: "anything from the other rooms. It never appears in summaries or cross-room answers."
        }
    }
    var rule: String {
        switch self {
        case .personal: "it's the default room: everything personal starts here."
        case .work: "an employer's material never enters the brain. Only your own notes about your work."
        case .cofounder: "it pushes toward buyers and revenue, and it may one day be shared with a partner."
        case .privateRoom: "it's private. Other rooms don't read it, and it's left out of every brief and summary."
        }
    }
    var hubText: String {
        switch self {
        case .personal:
            "# My life, as it stands\n\n## This week\n- **The one thing that matters:** [not yet]\n- **Dates coming up:** [not yet]\n\n## By area\n| Area | What's active | Next step | Note |\n|---|---|---|---|\n\n## Long projects\n\n## Parked\n"
        case .work:
            "# My jobs, as they stand\n\n## This week\n- **The one thing that matters:** [not yet]\n\n## By job\n| Job | Hours | What's due | Who I owe | Note |\n|---|---|---|---|---|\n\n## Wins to remember\n"
        case .cofounder: ""
        case .privateRoom: "# Just for me\n\n[not yet]\n"
        }
    }
}

enum Brain {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Env.selfTest ? Env.support.appendingPathComponent("selftest-brain") : docs.appendingPathComponent("My Brain")
    }
    static var starter: URL? { Bundle.main.url(forResource: "brain-starter", withExtension: nil) }
    static var exists: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) }
    static var rooms: [RoomKind] {
        RoomKind.allCases.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.folder).path) }
    }

    /// Creates the brain (once) and any rooms asked for that don't exist yet.
    static func build(owner: String, ai: String, rooms want: [RoomKind]) -> String? {
        let fm = FileManager.default
        guard let st = starter else { return "The brain starter isn't inside the app." }
        if !exists {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            for f in [
                "AGENTS.md", "BRAIN.md", "HELP.md", "LICENSE.md", "README.md", "CLAUDE.md", "GEMINI.md", "owner.yaml", "starter.yaml", "agents",
                "skills", "templates",
            ] {
                let src = st.appendingPathComponent(f)
                if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: root.appendingPathComponent(f)) }
            }
            let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let oy = root.appendingPathComponent("owner.yaml")
            if var y = try? String(contentsOf: oy, encoding: .utf8) {
                y = y.replacingOccurrences(of: "name: \"\"   ", with: "name: \"\(owner)\"", options: [], range: y.range(of: "name: \"\"   "))
                y = y.replacingOccurrences(of: "computer: \"\"", with: "computer: \"mac\"")
                y = y.replacingOccurrences(of: "tool: \"\"", with: "tool: \"one-app\"")
                y = y.replacingOccurrences(of: "set_up: \"\"", with: "set_up: \"\(today)\"")
                y += "\n# Kept by the One app: rooms are local folders on this Mac. Backup is the app's job.\nstorage: local\n"
                try? y.write(to: oy, atomically: true, encoding: .utf8)
            }
        }
        var all = Set(rooms)
        all.insert(.personal)
        want.forEach { all.insert($0) }
        let ordered = RoomKind.allCases.filter { all.contains($0) }
        for k in ordered where !fm.fileExists(atPath: root.appendingPathComponent(k.folder).path) {
            let dest = root.appendingPathComponent(k.folder)
            let tpl = st.appendingPathComponent(k == .cofounder ? "templates/cofounder-room" : "templates/room")
            do { try fm.copyItem(at: tpl, to: dest) } catch { return "Couldn't make the \(k.title): \(error.localizedDescription)" }
            let others = ordered.filter { $0 != k }.map { "the \($0.title) (`../\($0.folder)/`)" }.joined(separator: ", ")
            let fill: [String: String] = [
                "{{OWNER}}": owner, "{{AI}}": ai, "{{ROOM}}": k.folder, "{{ROOM_TITLE}}": k.title,
                "{{HOLDS}}": k.holds, "{{NEVER}}": k.never, "{{HUB}}": k.hub, "{{RULE}}": k.rule,
                "{{OTHER_ROOMS}}": others.isEmpty ? "No other rooms yet." : "Other rooms: \(others).",
                "{{CONFIDENTIAL}}":
                    "money figures, health detail, other people's private information, anything \(owner) wouldn't want read out loud.",
            ]
            if let en = fm.enumerator(at: dest, includingPropertiesForKeys: nil) {
                for case let f as URL in en where ["md", "yaml", "json"].contains(f.pathExtension) {
                    guard var t = try? String(contentsOf: f, encoding: .utf8), t.contains("{{") else { continue }
                    for (a, b) in fill { t = t.replacingOccurrences(of: a, with: b) }
                    try? t.write(to: f, atomically: true, encoding: .utf8)
                }
            }
            if !k.hubText.isEmpty {
                let hub = dest.appendingPathComponent(k.hub)
                try? fm.createDirectory(at: hub.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: hub.path) { try? k.hubText.write(to: hub, atomically: true, encoding: .utf8) }
            }
            // One row per room in the brain's table.
            let ag = root.appendingPathComponent("AGENTS.md")
            if var t = try? String(contentsOf: ag, encoding: .utf8) {
                let row = "| \(k.title.capitalized) | `\(k.folder)/` | \(ai) | `\(k.hub)` | \(k.holds) | \(k.never) |\n"
                t = t.replacingOccurrences(
                    of: "<!-- add-room adds one row per room above this line -->",
                    with: row + "<!-- add-room adds one row per room above this line -->")
                try? t.write(to: ag, atomically: true, encoding: .utf8)
            }
            let mem = dest.appendingPathComponent("memory")
            try? fm.createDirectory(at: mem, withIntermediateDirectories: true)
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let line = "- Decided (\(owner), \(day)): the \(k.title) was set up in the One app.\n"
            let mf = mem.appendingPathComponent("\(day).md")
            if let h = try? FileHandle(forWritingTo: mf) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(to: mf, atomically: true, encoding: .utf8)
            }
        }
        return nil
    }

    /// Mirrors the brain into iCloud Drive (plain copy, newest wins). Returns an error or nil.
    static func backupToICloud() -> String? {
        let icloud = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: icloud.path) else { return "iCloud Drive isn't turned on for this Mac." }
        let dest = icloud.appendingPathComponent(Env.selfTest ? "One selftest backup" : "My Brain (backup)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", "--exclude", ".DS_Store", root.path + "/", dest.path + "/"]
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return error.localizedDescription }
        return p.terminationStatus == 0 ? nil : "The copy to iCloud didn't finish."
    }
}

// MARK: - Who the assistant is (written into One's own Hermes)

enum Persona {
    static func write(assistant: String, user: String, connections: [String], passwords: String) {
        let who = user.isEmpty ? "the user" : user
        let soul = """
            You are \(assistant.isEmpty ? "the assistant" : assistant), \(who)'s personal assistant. You run on their own Mac, not in the cloud.

            How you talk:
            - Like a helpful friend: short, warm, plain words. No jargon.
            - Never mention Hermes, models, terminals, config files or tools unless they ask how you work.
            - If they want to give you a new name, change the line `assistant: "…"` in ~/Documents/My Brain/owner.yaml to the new name (keep the quotes) and say it's done. The app shows the new name everywhere right after.
            - Offer one clear next step, not a menu.
            - When you ask them to decide something, end your message with one last line listing 2 to 4 short answers they can tap, exactly like: [choices: Yes, go ahead | Not now | Change the plan]. Keep each answer under 5 words. Don't list them anywhere else in the message.

            Helpers: anything that needs work (looking something up, browsing, research, comparing, making a file, tidying, watching a price, checking something every day) goes to helpers, never done here, so you stay free to talk. Split a job with separate parts into several helpers so they run at the same time. Say in one short line that you're sending a helper, then add a line exactly like:
            [helper: Flight to Quebec | Find the cheapest flight from PHL or EWR to Quebec City (YQB), Dec 20 to 24 2026, and keep an eye on the price.]
            The title is 2 to 4 words. After the | write the whole job with every detail, because the helper can't see this conversation. One line per job. You stay free to keep talking. Only answer yourself when you already know it or it's just conversation.
            When a helper finishes, its orb turns orange and holds the result; they tap it to read it and can keep talking to that helper there. Don't repeat a helper's result or ask its question in this chat. Never break off what you're saying for a helper: when One tells you one is done, add just one line, like "By the way, Flight to Quebec is done. Tap it to take a look." Only for a good morning, good afternoon, good evening or a status report do you give the helpers' results yourself, in one combined report once they're all back.
            These helper rules are for you, the main assistant, only, not for helpers. If your first message says you're one of the helpers, do the job yourself with your own tools and never write [helper: …] lines; they do nothing there.
            \(HelperStop.soul)

            Always ask for a yes first before you: buy anything, move money, send a message or email as them, post anywhere, delete anything, or change a password. Say exactly what you're about to do and what it costs.

            If the Mac is closed or off, you're off. Say so if they ask why you didn't do something.

            This app (One) is what they see. You know its screen: the orb in the middle, the chat under it with a box that says "Or say it your way…", a Ready for you list on the right, and a row of buttons along the top: Voice on/off, your brain and voice, Rooms, Connections (what you can reach: Email, Calendar, Passwords, Browser, Files and more), Push to talk, Folders, Switch AI, and Stop. There is no Settings, gear, preferences or "Passwords & Logins" screen, and they never use a terminal. Never point them to those, even if a tool message says so; point to these buttons by name instead.

            Logins: when a job needs them to be signed in to a site (a bank, Monarch, Amazon…), don't send them hunting. Ask one simple question, ending with [choices: My password manager | My browser is signed in | I'll sign in myself | Something else]. Then:
            - Password manager: tell them to click Connections at the top, then Passwords, then pick theirs (KeePass, 1Password, Bitwarden, or Something else) and walk them through it step by step.
            - Browser: ask which browser they use, then tell them to click Connections, then Browser, and pick it, so you can use the sites they're already signed in to.
            - Sign in themselves: open the site in the browser and let them type the password there; never ask them to type a password into this chat.
            Once it's connected, carry on with the job without making them ask again.

            Folders you can open: \(Access.folders.isEmpty ? "none yet" : Access.folders.joined(separator: ", ")), plus their brain. Anything else is locked by the Mac. If they ask about another folder, say you don't have access yet and that they can add it with the Folders button.

            Your memory is their brain: the folder "\(Brain.root.path)". Its AGENTS.md says how it works: one room at a time, the personal room by default, a new room only when the rules differ, never just for a topic. Follow it. In this app the rooms are local folders: skip any GitHub, repository, git-crypt or key steps in its skills; backup is handled by the app. When they ask what you remember, read the room first. If they ask how your memory works, say it in plain words: it's theirs, it lives on this Mac as files, and it stays even if they switch AIs.
            """
        try? soul.write(to: Env.hermesHome.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let mem = Env.hermesHome.appendingPathComponent("memories", isDirectory: true)
        try? FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        var facts = ["The user's name is \(user). They call their assistant \(assistant)."]
        if !connections.isEmpty {
            facts.append(
                "They want these connected: \(connections.joined(separator: ", ")). Not connected yet; help them connect each one when it first comes up."
            )
        }
        if !passwords.isEmpty { facts.append("For logins: \(passwords).") }
        if let n = try? String(contentsOf: Env.hermesHome.appendingPathComponent("owner-notes.md"), encoding: .utf8), !n.isEmpty {
            facts.append(n.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? facts.joined(separator: "\n§\n").write(to: mem.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
    }
}
