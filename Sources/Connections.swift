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

// MARK: - Connections: Calendar and Mail through the Mac's own apps
// The engine runs inside the folder lock and can't touch Calendar or Mail itself, so it calls
// One's own binary ("One --cal …" / "One --mail …"). macOS then asks the person once, in One's name.
enum Bridge {
    static var exe: String { Bundle.main.executablePath ?? "/Applications/One.app/Contents/MacOS/One" }
    static let store = EKEventStore()
    static var calendarOK: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static func askCalendar() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }
    /// Calendars from a real account (Google, iCloud, Outlook…), not only the empty one on this Mac.
    static var calendarAccounts: Int {
        let st = EKEventStore()
        return Set(
            st.calendars(for: .event).compactMap { c -> String? in
                guard let src = c.source, src.sourceType != .local, src.sourceType != .birthdays, c.type != .birthday else { return nil }
                return src.sourceIdentifier
            }
        ).count
    }
    static let accountsPage = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
    static var mailAccounts: Int {
        let r = applescript("tell application \"System Events\" to (name of processes) contains \"Mail\"")
        _ = r
        return Int(applescript("tell application \"Mail\" to count of accounts") ?? "") ?? 0
    }
    @discardableResult static func applescript(_ src: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            FileHandle.standardError.write("mail error: \(err[NSAppleScript.errorMessage] ?? err)\n".data(using: .utf8)!)
            return nil
        }
        return out?.stringValue
    }
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func date(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
    static let show: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    /// Handles "--cal" / "--mail" command lines. Returns an exit code, or nil if this isn't a bridge call.
    static func run(_ a: [String]) -> Int32? {
        guard let k = a.firstIndex(where: { $0 == "--cal" || $0 == "--mail" }) else { return nil }
        let rest = Array(a[(k + 1)...])
        let cmd = rest.first ?? "help"
        func out(_ s: String) { print(s) }
        if a[k] == "--cal" {
            guard calendarOK else {
                out("Calendar isn't connected yet. Tell them to open One and tap Connect next to Calendar.")
                return 3
            }
            switch cmd {
            case "list":
                let days = Double(rest.dropFirst().first ?? "7") ?? 7
                let from = rest.count > 2 ? (date(rest[2]) ?? Date()) : Calendar.current.startOfDay(for: Date())
                let pred = store.predicateForEvents(withStart: from, end: from.addingTimeInterval(days * 86400), calendars: nil)
                let evs = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
                if evs.isEmpty { out("Nothing on the calendar in that time.") }
                for e in evs {
                    let when =
                        e.isAllDay
                        ? "all day " + show.string(from: e.startDate).components(separatedBy: ",").first!
                        : show.string(from: e.startDate) + " to "
                            + DateFormatter.localizedString(from: e.endDate, dateStyle: .none, timeStyle: .short)
                    var line = "- \(when): \(e.title ?? "(no title)") [\(e.calendar.title)] id=\(e.eventIdentifier ?? "")"
                    if let l = e.location, !l.isEmpty { line += " at \(l)" }
                    out(line)
                }
            case "calendars":
                for c in store.calendars(for: .event) { out("- \(c.title)\(c.allowsContentModifications ? "" : " (read only)")") }
            case "add":
                guard rest.count >= 4, let st = date(rest[2]), let en = date(rest[3]) else {
                    out("usage: --cal add \"title\" START END [calendar]  (dates like 2026-10-24T15:00)")
                    return 2
                }
                let e = EKEvent(eventStore: store)
                e.title = rest[1]
                e.startDate = st
                e.endDate = en
                e.calendar =
                    rest.count > 4
                    ? (store.calendars(for: .event).first { $0.title == rest[4] } ?? store.defaultCalendarForNewEvents)
                    : store.defaultCalendarForNewEvents
                do {
                    try store.save(e, span: .thisEvent)
                    out("Added: \(rest[1]), \(show.string(from: st)) [\(e.calendar.title)] id=\(e.eventIdentifier ?? "")")
                } catch {
                    out("Couldn't add it: \(error.localizedDescription)")
                    return 1
                }
            case "remove":
                guard rest.count > 1, let e = store.event(withIdentifier: rest[1]) else {
                    out("No event with that id.")
                    return 2
                }
                do {
                    try store.remove(e, span: .thisEvent)
                    out("Removed: \(e.title ?? "")")
                } catch {
                    out("Couldn't remove it: \(error.localizedDescription)")
                    return 1
                }
            default: out("Calendar commands: list [days] [from], calendars, add \"title\" START END [calendar], remove ID")
            }
            return 0
        }
        if FakeMail.path != nil { return FakeMail.run(cmd, rest) }
        switch cmd {
        case "accounts":
            out(
                applescript("tell application \"Mail\" to get name of every account as string")
                    ?? "Mail isn't set up, or One isn't allowed to use it yet.")
        case "list":
            let n = Int(rest.dropFirst().first ?? "15") ?? 15
            let src = """
                set out to ""
                tell application "Mail"
                  set msgs to messages of inbox
                  set c to count of msgs
                  if c > \(n) then set c to \(n)
                  repeat with i from 1 to c
                    set m to item i of msgs
                    set out to out & "- " & (date received of m as string) & " | from " & (sender of m) & " | " & (subject of m) & " | " & (read status of m as string) & " | id=" & (id of m) & linefeed
                  end repeat
                end tell
                return out
                """
            guard let r = applescript(src) else {
                out("Mail isn't set up, or One isn't allowed to use it yet.")
                return 3
            }
            out(
                r.isEmpty
                    ? "The inbox is empty."
                    : r.replacingOccurrences(of: "| true |", with: "| read |").replacingOccurrences(of: "| false |", with: "| NEW |"))
        case "read":
            guard rest.count > 1, let id = Int(rest[1]) else {
                out("usage: --mail read ID")
                return 2
            }
            let src = """
                tell application "Mail"
                  set m to first message of inbox whose id is \(id)
                  return "From: " & (sender of m) & linefeed & "Subject: " & (subject of m) & linefeed & "Date: " & (date received of m as string) & linefeed & linefeed & (content of m)
                end tell
                """
            out(applescript(src) ?? "Couldn't open that email.")
        case "search":
            guard rest.count > 1 else {
                out("usage: --mail search WORDS")
                return 2
            }
            let q = esc(rest[1])
            let src = """
                set out to ""
                tell application "Mail"
                  set msgs to (messages of inbox whose subject contains "\(q)" or sender contains "\(q)")
                  set c to count of msgs
                  if c > 20 then set c to 20
                  repeat with i from 1 to c
                    set m to item i of msgs
                    set out to out & "- " & (date received of m as string) & " | from " & (sender of m) & " | " & (subject of m) & " | id=" & (id of m) & linefeed
                  end repeat
                end tell
                return out
                """
            out(applescript(src).map { $0.isEmpty ? "No emails match." : $0 } ?? "Mail isn't set up, or One isn't allowed to use it yet.")
        case "draft":
            guard rest.count >= 4 else {
                out("usage: --mail draft TO SUBJECT BODY")
                return 2
            }
            let src = """
                tell application "Mail"
                  set m to make new outgoing message with properties {subject:"\(esc(rest[2]))", content:"\(esc(rest[3]))", visible:true}
                  tell m to make new to recipient at end of to recipients with properties {address:"\(esc(rest[1]))"}
                  activate
                end tell
                return "ok"
                """
            out(applescript(src) == "ok" ? "Draft is open in Mail for them to read and press Send. Nothing was sent." : "Couldn't make the draft.")
        default:
            out(mailHelp)
            return cmd == "help" ? 0 : 2
        }
        return 0
    }
    /// Everything the assistant can do with email. There is deliberately no send.
    static let mailCommands = ["accounts", "list", "read", "search", "draft"]
    static let mailHelp = "Mail commands: accounts, list [n], read ID, search WORDS, draft TO SUBJECT BODY (opens a draft; never sends)"

    /// Told to the assistant every turn, so it knows what's connected and how to use it.
    static var note: String {
        var parts: [String] = []
        let fake = FakeMail.path != nil  // a test inbox: nothing else from this Mac
        if calendarOK && !fake {
            parts.append(
                "CALENDAR is connected: run `\(exe) --cal list 7` (next 7 days), `--cal add \"title\" 2026-10-24T15:00 2026-10-24T16:00`, `--cal remove ID`, `--cal calendars`. Before adding, check for clashes and say them. Adding to their own calendar is fine on your own; inviting other people needs their yes."
            )
        }
        if fake || UserDefaults.standard.bool(forKey: "mailConnected") {
            parts.append(
                "EMAIL is connected through the Mail app: `\(exe) --mail list 15`, `--mail read ID`, `--mail search WORDS`, `--mail draft TO SUBJECT BODY`. You can never send: draft opens in Mail and they press Send. Never claim you sent anything."
            )
        }
        return parts.isEmpty
            ? "" : "\n\n(One app note, not from the user: " + parts.joined(separator: " ") + " Never tell them these can't be connected.)"
    }
}

/// Connections, drawn as the onboarding world: the assistant in the middle, what it can reach floating around it.
/// Connected ones are tied to it by a living thread; ones not built yet hang faint at the edge.
struct ConnectionsWorld: View {
    @ObservedObject var m: Model
    var close: () -> Void = {}
    var fixedT: Double? = nil
    @State var picked: String? = nil
    @State var note: String? = nil
    @State var option: String? = nil
    /// What's connected, read off the main thread and kept, never per frame: the calendar check is a
    /// slow call to macOS (~40 ms), and running it on every animation frame made Connections come in
    /// at ~11 frames a second ("clack, clack, clack"). Home reads it ahead (`prefetch`), so the screen
    /// slides in already complete; it's read again on open and after a change.
    @State var status: Status? = nil
    @State var shown = ConnectionsWorld.cached != nil
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    struct Status: Sendable, Equatable {
        var on: [String: Double]
        var custom: [Custom]
        static func load() -> Status {
            var d: [String: Double] = [:]
            for (i, id) in ConnectionsWorld.connected().enumerated() { d[id] = -10 - Double(i) }
            return Status(on: d, custom: ConnectionsWorld.custom())
        }
    }
    static var cached: Status? = nil
    static func prefetch() async { cached = await Task.detached { Status.load() }.value }
    /// Renders (fixedT) have no time to wait, so they read it right away.
    var now: Status { status ?? ConnectionsWorld.cached ?? (fixedT != nil ? Status.load() : Status(on: [:], custom: [])) }
    var on: [String: Double] { now.on }
    /// Reads the status again; only what changed moves, in one short fade (or everything, the first time).
    func reload() async {
        let s = await Task.detached { Status.load() }.value
        let before = now
        ConnectionsWorld.cached = s
        if s == before && shown {
            status = s
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            status = s
            shown = true
        }
    }
    /// Connections the assistant built with the person ("Something else…"). It writes
    /// hermes/connections.json after a test passes: [{"id":"News","with":"Feedly","skill":"my-connections/feedly","tested":"2026-10-24"}]
    struct Custom: Codable, Hashable, Sendable {
        var id: String
        var with: String
        var skill: String?
        var tested: String?
    }
    nonisolated static var customFile: URL { Env.hermesHome.appendingPathComponent("connections.json") }
    nonisolated static func custom() -> [Custom] {
        guard let d = try? Data(contentsOf: customFile) else { return [] }
        return (try? JSONDecoder().decode([Custom].self, from: d)) ?? []
    }
    static func removeCustom(_ id: String) {
        let left = custom().filter { $0.id != id }
        if let d = try? JSONEncoder().encode(left) { try? d.write(to: customFile) }
    }
    nonisolated static func connected() -> [String] {
        var c = ["Files", "Web"]
        if BrowserKeeper.plan != nil { c.append("Browser") }  // a hidden browser is really set up (their Chrome's copy or One's own)
        for x in custom() where !c.contains(x.id) { c.append(x.id) }
        if Bridge.calendarOK && Bridge.calendarAccounts > 0 { c.append("Calendar") }
        if UserDefaults.standard.bool(forKey: "mailConnected") { c.append("Email") }
        if UserDefaults.standard.string(forKey: "passwordsWith") != nil { c.append("Passwords") }
        if UserDefaults.standard.bool(forKey: "googleConnected") {
            if !c.contains("Email") { c.append("Email") }
            if !c.contains("Calendar") { c.append("Calendar") }
        }
        return c
    }
    static let soon: Set<String> = ["Phone", "News"]
    static let how: [String: [String]] = [
        "Email": ["Gmail", "Outlook", "iCloud", "Yahoo", "Something else…"],
        "Passwords": ["KeePass", "1Password", "Bitwarden", "Something else…"],
        "Calendar": ["Google", "iCloud", "Outlook", "Something else…"],
        "Browser": ["Chrome", "Arc", "Something else…"],
        "Files": ["This Mac", "Something else…"],
        "Web": ["Built in", "Something else…"],
        "News": ["Something else…"],
        "Phone": ["Something else…"],
    ]
    static let other = Node(
        id: "Something else", symbol: "plus", line: "Not on the list? Tell me what you use and we'll build it together.", voice: nil)
    /// The usual connections, anything built together under a new name, and "Something else" last.
    static func nodes(_ made: [Custom] = custom()) -> [Node] {
        let known = Set(worldNodes.map(\.id))
        let extra = made.filter { !known.contains($0.id) }.map {
            Node(id: $0.id, symbol: "puzzlepiece.extension", line: "Built together with you: \($0.with).", voice: nil)
        }
        return worldNodes + extra + [other]
    }
    func state(_ id: String) -> String {
        id == ConnectionsWorld.other.id ? "other" : on[id] != nil ? "on" : ConnectionsWorld.soon.contains(id) ? "soon" : "off"
    }
    func options(_ id: String) -> [String] {
        var o = ConnectionsWorld.how[id] ?? []
        for x in now.custom where x.id == id && !o.contains(x.with) { o.insert(x.with, at: max(o.count - 1, 0)) }
        return o
    }
    var body: some View {
        let st = now
        let all = ConnectionsWorld.nodes(st.custom)
        let sel = picked.flatMap { id in all.first { $0.id == id } }
        ZStack {
            WorldLook.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(sel?.id ?? "Connections").font(.system(size: 12, weight: .medium)).tracking(0.4)
                        .foregroundStyle(WorldLook.cream.opacity(0.5))
                    Text(sel?.line ?? "What \(m.name) can reach for you.").font(.system(size: 22, weight: .medium)).tracking(-0.2)
                        .foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 460)
                    let exp = st.custom.count
                    // Until the status is read, a blank line of the same height, so nothing below moves when it arrives.
                    let counts = "\(st.on.count) connected\(exp > 0 ? ", \(exp) experimental" : ""). Tap one to see it or change it."
                    Text(sel == nil && (shown || fixedT != nil) ? counts : " ")
                        .font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.6))
                }.frame(minHeight: 110).padding(.top, 26).padding(.horizontal, 24)
                GeometryReader { geo in
                    let k = min(geo.size.width / WorldLook.W, geo.size.height / WorldLook.H, 1.2)
                    TimelineView(.animation) { tl in
                        WorldCanvas(
                            t: fixedT ?? tl.date.timeIntervalSince(WorldLook.start),
                            lit: picked.flatMap { id in all.firstIndex { $0.id == id } }, picking: picked == nil,
                            linked: st.on, speaking: false,
                            tap: { n in
                                withAnimation(.easeOut(duration: 0.3)) {
                                    picked = picked == n.id ? nil : n.id
                                    note = nil
                                }
                            },
                            dim: ConnectionsWorld.soon.subtracting(st.on.keys), nodes: all)
                    }.scaleEffect(k * (shown || fixedT != nil || reduceMotion ? 1 : 0.96)).frame(width: geo.size.width, height: geo.size.height)
                        .opacity(shown || fixedT != nil ? 1 : 0)
                }
                detail(sel).frame(height: 120).padding(.bottom, 22)
            }
        }.preferredColorScheme(.dark)
            .task { if fixedT == nil { await reload() } }
    }
    /// Connect: things One can do itself (Calendar on this Mac, a KeePass file) happen right here.
    /// Everything else is handed to the assistant, which walks them through it in the chat
    /// ("Something else…" = build a new connection together, experimental).
    func connect(_ id: String, _ with: String) {
        note = nil
        if id == "Passwords" && with == "KeePass" {
            let p = NSOpenPanel()
            p.message = "Pick your KeePass file (.kdbx)"
            p.allowedContentTypes = []
            p.allowsOtherFileTypes = true
            guard p.runModal() == .OK, let db = p.url else { return }
            var reads = (UserDefaults.standard.string(forKey: "connectorReads") ?? "").split(separator: "\n").map(String.init)
            if !reads.contains(db.path) { reads.append(db.path) }
            UserDefaults.standard.set(reads.joined(separator: "\n"), forKey: "connectorReads")
            UserDefaults.standard.set("KeePass", forKey: "passwordsWith")
            Task { @MainActor in
                _ = await hermesRun(["config", "set", "vault.keepass.database", db.path])
                _ = await Engine.shared.start()
                close()
                await m.send(
                    "I just connected my KeePass file (\(db.lastPathComponent)). Check that you can see my logins (names only), and if it needs my master password or a key file, help me set that up.",
                    toNova: true)
            }
            return
        }
        if GoogleSignIn.enabled && ((id == "Email" && with == "Gmail") || (id == "Calendar" && with == "Google")) {
            note = "Opening Google in your browser. Sign in there, then come back."
            Task { @MainActor in
                if let email = await GoogleSignIn.run() {
                    UserDefaults.standard.set(true, forKey: "googleConnected")
                    m.markConnected("Email")
                    m.markConnected("Calendar")
                    note = nil
                    picked = nil
                    close()
                    await m.send(
                        "I just signed in with Google as \(email). Gmail and Google Calendar are connected (use the google-workspace skill with GOOGLE_ACCOUNT=\(email)). Check my next 3 events and my unread count to make sure it works.",
                        toNova: true)
                } else {
                    note = "Google sign-in didn't finish. Tap Connect to try again."
                }
            }
            return
        }
        if id == "Browser" && with == "Chrome" {
            note = "Copying your Chrome's sign-ins into a hidden browser. Your Chrome stays open; no window will pop up."
            Task { @MainActor in
                note = await MyChrome.connect()
                if note != nil { return }
                close()
                await m.send(
                    "I just connected my Chrome in Connections › Browser. Check it with `\(Bridge.exe) --browser-check`, then open one site I'm signed in to in Chrome, in the hidden browser, and tell me in one line whether I'm signed in there. Read only: don't click, send or change anything.",
                    toNova: true)
            }
            return
        }
        if (id == "Email" || id == "Calendar") && !with.hasPrefix("Something") {
            Task { @MainActor in await connectMacAccount(id, with) }
            return
        }
        let ask =
            with.hasPrefix("Something")
            ? """
            \(id == "Something else" ? "I want to connect something new to you, something that isn't on the Connections list." : "I want to connect my \(id) to something One doesn't support yet.") Let's build it together.
            1. First tell me in one line: this is experimental, built by you, may break, use at my own risk.
            2. Follow your connect-goal-first skill. First ask what I want to happen, and who does what (one question with tap-choices built from outcomes, like "You text me" or "You read my texts"). Say my goal back in one line and wait for my yes. Then ask what I use. Pick a way that does THAT goal (check who sends, who receives, from whose number or account), say up front what it can't do, and if nothing free fits, tell me the honest options and their cost. Find the simplest way in: an official app or command-line tool on this Mac, an API, an export file, or my own browser. Do every step you can yourself; only ask me for things only I can do (approve a login, pick a file).
            3. Never put a password or code into this chat. Logins go through my password manager or the app's own sign-in. Still ask before any money, sending, posting or deleting.
            4. Save it as a skill in skills/my-connections/<short-name>/SKILL.md (my goal, how it works, what it can't do, what's off-limits).
            5. Test it in front of me: one real read-only check, or for a sending goal one test message I said yes to. Tell me plainly what worked, what didn't, and what that means for my goal.
            6. Only if the test passed, add an entry to \(ConnectionsWorld.customFile.path) (a JSON list; keep existing entries): {"id": "\(id == "Something else" ? "<a short name for it, e.g. Smart home>" : id)", "with": "<what I use>", "skill": "my-connections/<short-name>", "tested": "<today YYYY-MM-DD>"}. That makes it show up in Connections tagged Experimental.
            """
            : MyChrome.ask(id, with)
                ?? "Connect my \(id) using \(with). Walk me through it one step at a time, do every part you can yourself, and test it when we're done."
        close()
        Task { @MainActor in await m.send(ask, toNova: true) }
    }
    /// Email and Calendar use the accounts already on this Mac. If there's none yet, One opens
    /// Internet Accounts, says what to do, and watches until the account shows up (up to 10 minutes).
    func connectMacAccount(_ id: String, _ with: String) async {
        let isMail = id == "Email"
        if !isMail {
            guard await Bridge.askCalendar() else {
                note = "Calendar is still off. Turn it on in System Settings › Privacy & Security › Calendars › One."
                return
            }
        }
        // The calendar count is a slow call to macOS: keep it off the main thread so the screen keeps moving while it waits.
        func have() async -> Bool { isMail ? Bridge.mailAccounts > 0 : await Task.detached { Bridge.calendarAccounts > 0 }.value }
        func done() {
            if isMail { UserDefaults.standard.set(true, forKey: "mailConnected") }
            m.markConnected(id)
            note = nil
            picked = nil
            Task { await reload() }
            Task { _ = await Speaker.shared.sayNow(isMail ? "Got it. I can see your email now." : "Got it. I can see your calendar now.") }
        }
        if await have() {
            done()
            return
        }
        NSWorkspace.shared.open(Bridge.accountsPage)
        let who = (with == "Gmail" || with == "Google") ? "Google" : with
        let what = isMail ? "Mail" : "Calendars"
        let line = "In the window that just opened, click \(who), sign in, and keep \(what) switched on. I'll notice when it's done."
        note = line
        Task { _ = await Speaker.shared.sayNow(line) }
        for _ in 0..<200 {
            try? await Task.sleep(for: .seconds(3))
            if await have() {
                done()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
        note = "I didn't see a new account yet. Tap Connect when you've added it."
    }
    func disconnect(_ id: String) {
        let d = UserDefaults.standard
        if ConnectionsWorld.custom().contains(where: { $0.id == id }) {
            ConnectionsWorld.removeCustom(id)
            picked = nil
            Task { await reload() }
            return
        }
        switch id {
        case "Passwords": d.removeObject(forKey: "passwordsWith")
        case "Browser":
            Task {
                await MyChrome.disconnect()
                await reload()
            }
        case "Email", "Calendar":
            d.set(false, forKey: "googleConnected")
            d.set(false, forKey: "mailConnected")
        default: break
        }
        picked = nil
        Task { await reload() }
    }
    @ViewBuilder func detail(_ sel: Node?) -> some View {
        if let n = sel {
            VStack(spacing: 12) {
                let opts = options(n.id)
                let mine = now.custom.first { $0.id == n.id }
                if !opts.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(opts, id: \.self) { o in
                            let chosen =
                                option == o || (option == nil && (mine?.with == o || UserDefaults.standard.string(forKey: "passwordsWith") == o))
                                || (n.id == "Calendar" && o == "Google" && UserDefaults.standard.bool(forKey: "googleConnected"))
                                || (n.id == "Email" && o == "Gmail" && UserDefaults.standard.bool(forKey: "googleConnected"))
                                || (n.id == "Browser" && o == "Chrome" && on[n.id] != nil) || (n.id == "Files" && o == "This Mac")
                                || (n.id == "Web" && o == "Built in")
                            HStack(spacing: 5) {
                                if chosen { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                                Text(o).font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(chosen ? .white : WorldLook.cream.opacity(o.hasPrefix("Something") ? 0.55 : 0.85))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(WorldLook.cream.opacity(chosen ? 0.12 : 0.05)))
                            .overlay(
                                Capsule().stroke(
                                    WorldLook.cream.opacity(chosen ? 0.6 : 0.14),
                                    style: StrokeStyle(lineWidth: 1, dash: o.hasPrefix("Something") ? [3, 3] : []))
                            )
                            .contentShape(Capsule()).onTapGesture {
                                option = o
                                if o.hasPrefix("Something") { connect(n.id, o) }
                            }
                        }
                    }
                }
                switch state(n.id) {
                case "other":
                    VStack(spacing: 8) {
                        Button {
                            connect("Something else", "Something else…")
                        } label: {
                            Text("Build one with \(m.name)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x141416))
                                .frame(minWidth: 190).padding(.vertical, 11).background(Capsule().fill(WorldLook.cream))
                        }.buttonStyle(.plain)
                        Text("Experimental. \(m.name) builds it with you and tests it first. Use at your own risk.")
                            .font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.5))
                    }
                case "on":
                    HStack(spacing: 18) {
                        if let mine {
                            Label("Experimental · built by \(m.name)\(mine.tested.map { ", tested \($0)" } ?? "")", systemImage: "flask")
                                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color(hex: 0xE8C98A))
                        } else {
                            Label(
                                n.id == "Browser" && MyChrome.connected ? "Connected · your Chrome, \(MyChrome.copiedLine)" : "Connected",
                                systemImage: "checkmark"
                            ).font(.system(size: 14, weight: .medium)).foregroundStyle(
                                Color(hex: 0xBFE3CC))
                        }
                        Button("Disconnect") { disconnect(n.id) }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(
                            WorldLook.cream.opacity(0.55))
                    }
                case "off":
                    Button {
                        connect(n.id, option ?? ConnectionsWorld.how[n.id]?.first ?? n.id)
                    } label: {
                        Text("Connect").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x141416))
                            .frame(minWidth: 150).padding(.vertical, 11).background(Capsule().fill(WorldLook.cream))
                    }.buttonStyle(.plain)
                default:
                    Text("Not built yet. Tap Something else… to try building it together (experimental).").font(.system(size: 13)).foregroundStyle(
                        WorldLook.cream.opacity(0.5))
                }
                if let note {
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xE8B48A)).multilineTextAlignment(.center).frame(maxWidth: 440)
                }
            }
        } else {
            Button("Done") { close() }.buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.7))
        }
    }
}
