// One — a one-button personal assistant (test build 0.2).
// The face is this app. The engine is Hermes, run privately for One via ACP.
// Setup is a conversation the assistant leads. The user never sees a terminal.
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

final class OneDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--print-profile") {
            print(Access.profile())
            exit(0)
        }
        if CommandLine.arguments.contains("--check-update") {
            Task { @MainActor in
                await Updater.shared.check()
                print("current", Updater.shared.current, "available", Updater.shared.available.map { "\($0.version) \($0.zip)" } ?? "none")
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--test-updates") {
            Env.selfTest = true  // own settings suite and a fake release list; run with ONE_SUPPORT_DIR set to an empty folder
            guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
                print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
                exit(2)
            }
            Task { @MainActor in exit(await UpdaterCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--test-followups") {
            Env.selfTest = true  // throwaway Hermes home and brain; run from a copy with its own settings (tools/followups-check.sh)
            Task { @MainActor in exit(await FollowUpCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--test-human-step") {
            Env.selfTest = true  // throwaway folder and a test Chrome (tools/handoff-check.sh); never the shared browser
            Task { @MainActor in exit(await HumanStepCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--test-helpers") {
            Env.selfTest = true  // stand-in engine calls, in-memory saved helpers; run with ONE_SUPPORT_DIR set to an empty folder
            guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
                print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
                exit(2)
            }
            Task { @MainActor in exit(await HelperCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--test-voice") {
            Env.selfTest = true  // stand-in voice, its own settings suite; run with ONE_SUPPORT_DIR set to an empty folder
            guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
                print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
                exit(2)
            }
            Task { @MainActor in exit(await VoiceCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--auto-update") {
            Task { @MainActor in
                await Updater.shared.check()
                print("found", Updater.shared.available?.version ?? "none")
                await Updater.shared.install()
                print("state", Updater.shared.state ?? "")
            }
        } else if !Env.selfTest {
            Task { @MainActor in Updater.shared.loop() }
        }
        if CommandLine.arguments.contains("--test-guards") {
            Env.selfTest = true  // scratch brain; run with ONE_SUPPORT_DIR and ONE_CLOUD_DIR set to empty folders
            exit(GuardsCheck.run())
        }
        if CommandLine.arguments.contains("--test-restart") {
            Env.selfTest = true  // scratch Hermes home and in-memory folder lists; run with ONE_SUPPORT_DIR set to an empty folder
            Task { @MainActor in exit(await RestartCheck.run()) }
            return
        }
        if CommandLine.arguments.contains("--test-browser") {
            Env.selfTest = true  // pure decisions; never starts Chrome. Run with ONE_SUPPORT_DIR set to an empty folder
            exit(BrowserCheck.run())
        }
        if CommandLine.arguments.contains("--test-gateway") {
            Env.selfTest = true  // scratch Hermes home; run with ONE_SUPPORT_DIR set to an empty folder
            exit(GatewayCheck.run())
        }
        if CommandLine.arguments.contains("--test-shared") {
            Env.selfTest = true  // brain goes to a scratch copy, never the real one
            // Two people, one cloud folder: Omar makes a room, Sam joins, both add entries.
            let d = UserDefaults.standard
            d.set("Omar", forKey: "userName")
            d.set([String](), forKey: "sharedRooms")
            var out: [String] = []
            switch Shared.make(title: "Our business", moving: nil) {
            case .failure(let e): out.append("make failed: \(e.text)")
            case .success(let u):
                out.append(
                    "made \(u.lastPathComponent), files: "
                        + ((try? FileManager.default.contentsOfDirectory(atPath: u.path).sorted().joined(separator: ", ")) ?? ""))
                out.append("invites for Omar (should be 0): \(Shared.invites().count)")
                d.set("Sam", forKey: "userName")
                d.set([String](), forKey: "sharedRooms")
                let inv = Shared.invites()
                out.append("invites for Sam (should be 1): \(inv.count)")
                if let r = inv.first { Shared.join(r) }
                out.append("members now: \(Shared.info(u)?.members ?? [])")
                out.append("Sam's rooms: \(Shared.paths.map { URL(fileURLWithPath: $0).lastPathComponent })")
                out.append(
                    "entries: "
                        + ((try? FileManager.default.contentsOfDirectory(atPath: u.appendingPathComponent("entries").path).sorted().joined(
                            separator: " | ")) ?? ""))
                out.append("label for Sam: \(Shared.label(Shared.info(u)!))")
                out.append("sandbox allows it: \(Access.profile().contains(u.path))")
                out.append("note has rules: \(Shared.note(clashes: []).contains("Never edit or delete a file someone else wrote"))")
            }
            print(out.joined(separator: "\n"))
            exit(0)
        }
        // The hidden browser helpers use: started again with its saved sign-ins if it goes down.
        Task.detached {
            while true {
                BrowserKeeper.tend()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // Phone chat runs on its own loop, off the main thread: nothing on screen can hold it up.
        Task.detached {
            while true {
                Messenger.tend()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // A step only the person can do (a code, a passkey…): the page comes to the front within a second.
        Task { @MainActor in
            while true {
                Model.shared.tendHumanSteps()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { @MainActor in
            var tick = 0
            while true {
                Model.shared.scanShelf()
                Model.shared.tendFolders()
                if tick % 5 == 0 {
                    Model.shared.tendShared()
                    Model.shared.tendRoutines()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
        if Speaker.shared.installed {
            Speaker.shared.start()
        } else if Env.hermesPath != nil {
            Task.detached { if await Speaker.shared.install() { Speaker.shared.start() } }
        }
        MainActor.assumeIsolated {
            Floater.shared.setup()
            PictureIn.installPaste()
            TalkKeys.shared.apply()
            Listener.shared.warm()
            Model.shared.syncName()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Floater.shared.openMain()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        let previous = Engine.shared.enginePID
        Engine.shared.stop()
        Messenger.stop()
        Engine.stopStrayGateway(previousEngine: previous, caller: "quit")
    }
    /// Closing the window keeps One running as the orb, so it can still listen and talk. Quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct OneApp: App {
    @NSApplicationDelegateAdaptor(OneDelegate.self) var delegate
    var body: some Scene { WindowGroup("One") { RootView() }.windowResizability(.contentSize) }
}

// MARK: - Entry, with headless tests the agent can run

@main
struct Entry {
    static func runHeadless(_ body: @escaping @Sendable () async -> Void) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    static func main() {
        let args = CommandLine.arguments
        if let code = Bridge.run(args) { exit(code) }
        if args.contains("--browser-check") { runHeadless { exit(await BrowserKeeper.check()) } }
        if let k = args.firstIndex(of: "--say"), k + 1 < args.count {
            MainActor.assumeIsolated {
                Speaker.shared.start()
                Task { @MainActor in
                    for _ in 0..<60 where !Speaker.shared.ready { try? await Task.sleep(for: .milliseconds(500)) }
                    let d = await Speaker.shared.sayNow(args[k + 1])
                    print("ready", Speaker.shared.ready, "seconds", d, Speaker.shared.state)
                    try? await Task.sleep(for: .seconds(d + 1))
                    print("after", Speaker.shared.state)
                    exit(0)
                }
            }
            NSApplication.shared.run()
        }
        if let k = args.firstIndex(of: "--render-orb-working"), k + 1 < args.count {
            MainActor.assumeIsolated { OrbWorkingRender.run(out: args[k + 1], clip: k + 2 < args.count ? args[k + 2] : nil) }
            exit(0)
        }
        if let k = args.firstIndex(of: "--render-orb-voice"), k + 2 < args.count {
            MainActor.assumeIsolated { OrbVoiceRender.run(clip: args[k + 1], out: args[k + 2]) }
            exit(0)
        }
        if let k = args.firstIndex(of: "--render-rooms-fly"), k + 1 < args.count {
            MainActor.assumeIsolated { RoomsRender.fly(args[k + 1], room: k + 2 < args.count ? args[k + 2] : "Co-Founder") }
            exit(0)
        }
        if let k = args.firstIndex(of: "--render-world"), k + 1 < args.count {
            let out = args[k + 1]
            MainActor.assumeIsolated {
                let views: [(String, AnyView)] = [
                    ("tour", AnyView(WorldCanvas(t: 30, lit: 1, picking: false, linked: [:], speaking: true).background(WorldLook.bg))),
                    (
                        "md",
                        AnyView(
                            MarkdownText(
                                text:
                                    "## Downloads, tidied\n\nI moved **42 files** into 5 folders:\n\n1. **Receipts** (12)\n2. *Screenshots* (18)\n3. Installers (`.dmg`, 6)\n\n- Kept on top: `resume.pdf`\n  - nested item\n\n| Folder | Files |\n|---|---|\n| Receipts | 12 |\n| Screenshots | 18 |\n\n> Nothing was deleted.\n\nSee [Finder](https://apple.com) for details.",
                                size: 16
                            ).padding(18).frame(width: 520).background(RoundedRectangle(cornerRadius: 18).fill(Color.gray.opacity(0.15))).padding(20)
                                .background(WorldLook.bg).environment(\.colorScheme, .dark))
                    ),
                    (
                        "choices",
                        AnyView(
                            VStack(alignment: .leading, spacing: 12) {
                                MarkdownText(
                                    text: Choices.split(
                                        "I'll sort **555 files** into 12 folders by type. Nothing gets deleted.\n\n[choices: Yes, go ahead | Not now | Change the plan]"
                                    ).body, size: 16
                                ).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
                                    RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
                                ChoiceRow(choices: Choices.split("x\n[choices: Yes, go ahead | Not now | Change the plan]").choices) { _ in }
                            }.padding(24).frame(width: 600).background(WorldLook.bg).environment(\.colorScheme, .dark))
                    ),
                    (
                        "followups",
                        AnyView(
                            VStack(spacing: 12) {
                                StepLine(text: "Searching the web for “flights PHL to Quebec”…").foregroundStyle(.secondary)
                                Text("Find me a flight to Quebec City for Dec 20").font(.callout).foregroundStyle(Color.accentColor)
                                VStack(spacing: 6) {
                                    FollowUpLine(text: "Newark is fine too", tag: "Sent to Ava", waiting: false)
                                    FollowUpLine(text: "Window seat if you can", tag: "Sent to Ava", waiting: false)
                                    FollowUpLine(text: "And a hotel near the old town", tag: "Next up", waiting: true)
                                    FollowUpEditor(words: "Under $200 a night") { _ in }
                                }
                            }.padding(24).frame(width: 600).background(WorldLook.bg).environment(\.colorScheme, .dark))
                    ),
                    (
                        "human-step",
                        AnyView(
                            HumanStepCard(
                                a: HumanStepAsk(
                                    id: "x", site: "amazon.com", kind: "code", line: HumanStep.line(site: "amazon.com", kind: "code"), port: 0,
                                    target: "",
                                    url: "")
                            ) { _ in }.padding(24).frame(width: 600).background(WorldLook.bg).environment(\.colorScheme, .dark))
                    ),
                    ("orb", AnyView(Orb(size: 92, active: false).frame(width: 300, height: 300).background(WorldLook.bg))),
                    (
                        "hint-long",
                        AnyView(
                            ZStack(alignment: .trailing) {
                                Color(hex: 0x2A2F3D)
                                HStack(spacing: 18) {
                                    FloatHint(
                                        text: Plain.step(
                                            "browser_exec: # Checking Google Flights for PHL to Quebec City on Dec 20\nimport time click_at_xy(448, 375)"
                                        ))
                                    FloatingOrb(state: .working, size: 72, fixedT: 9)
                                }.padding(.trailing, 40)
                            }.environment(\.colorScheme, .dark))
                    ),
                    ("live-rooms", AnyView(RoomsView(m: Model.shared) {})),
                    ("rooms-overview", RoomsRender.scene()),
                    ("rooms-inside", RoomsRender.scene(room: "Co-Founder")),
                    ("rooms-note", RoomsRender.scene(room: "Personal", mainNote: true)),
                    ("rooms-note-reader", RoomsRender.note(path: "work-room/brain/principles.md")),
                    (
                        "rooms-note-select",
                        RoomsRender.note(path: "work-room/brain/principles.md", from: "Every commitment is checked", to: "notes, prompts or drafts.")
                    ),
                    ("cw-all", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40))),
                    ("cw-exp", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40, picked: "News", option: nil))),
                    ("cw-other", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40, picked: "Something else", option: nil))),
                    ("me-card", AnyView(MeCard(m: Model.shared))),
                    ("cw-passwords", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40, picked: "Passwords"))),
                    ("cw-calendar", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40, picked: "Calendar"))),
                    ("cw-news", AnyView(ConnectionsWorld(m: Model.shared, fixedT: 40, picked: "News"))),
                    (
                        "reader-noscroll",
                        AnyView(
                            ZStack {
                                Color(hex: 0x141416)
                                MarkdownText(
                                    text: (try? String(
                                        contentsOf: Shelf.folder.appendingPathComponent("2026-10-23 Quebec trip planning.md"), encoding: .utf8))
                                        ?? "missing", size: 15
                                ).padding(22)
                            }.environment(\.colorScheme, .dark))
                    ),
                    (
                        "reader",
                        AnyView(
                            ZStack {
                                Color(hex: 0x141416)
                                FileViewer(m: Model.shared, url: Shelf.folder.appendingPathComponent("2026-10-23 Quebec trip planning.md"))
                            }.environment(\.colorScheme, .dark))
                    ),
                    ("map", AnyView(MapScene())),
                    ("room-add", AnyView(RoomAddScene())),
                    ("room-confirm", AnyView(RoomAddScene(confirm: true))),
                    ("shelf", AnyView(ShelfScene())),
                    ("shelf-open", AnyView(ShelfScene(open: true))),
                    ("helpers", AnyView(HelpersScene())),
                    ("helper-open", AnyView(HelpersScene(open: true))),
                    (
                        "helpers-more",
                        AnyView(
                            VStack(spacing: -10) {
                                HelperOrb(state: .working, t: 21.7, size: 42)
                                HelperLabel(title: "Hotel in Quebec", line: "Working on it…")
                                HelperOverflow(count: 2).padding(.top, 22)
                            }.padding(30).background(WorldLook.bg).environment(\.colorScheme, .dark))
                    ),
                    ("away", AnyView(AwayScene())),
                    ("float-idle", AnyView(FloatScene(state: .idle))),
                    ("float-listen", AnyView(FloatScene(state: .listening))),
                    ("float-work", AnyView(FloatScene(state: .working))),
                    (
                        "picked",
                        AnyView(
                            WorldCanvas(t: 60, lit: nil, picking: true, linked: ["Email": 50, "Files": 52, "Calendar": 59.6], speaking: false)
                                .background(WorldLook.bg))
                    ),
                ]
                for (name, v) in views {
                    if name.hasPrefix("rooms-") {
                        RoomsRender.png(v, "\(out)-\(name).png")
                        print("wrote \(out)-\(name).png")
                        continue
                    }
                    let r = ImageRenderer(
                        content: v.frame(
                            width: name == "live-rooms" || name == "reader"
                                ? 960
                                : name.hasPrefix("connections")
                                    ? 560
                                    : name.hasPrefix("cw-") ? 720 : name == "me-card" ? 420 : (name.hasPrefix("shelf") || name == "map" ? 820 : 620),
                            height: name == "live-rooms" || name == "reader"
                                ? 600
                                : name == "connections"
                                    ? 600
                                    : name.hasPrefix("cw-")
                                        ? 680
                                        : name == "me-card"
                                            ? 400 : name == "connections-mail" ? 680 : (name.hasPrefix("shelf") || name == "map" ? 450 : 440)))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                        let png = rep.representation(using: .png, properties: [:])
                    {
                        try? png.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
                        print("wrote \(out)-\(name).png")
                    }
                }
            }
            exit(0)
        }
        if args.contains("--test-skills") {
            Env.selfTest = true  // scratch Hermes home; run with ONE_SUPPORT_DIR set to an empty folder
            guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
                print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
                exit(2)
            }
            exit(BundledSkills.check())
        }
        if args.contains("--apply-overlay") {
            print(Installer.applyOverlay() ? "overlay ok" : "overlay failed")
            print(Installer.applyHumanStep() ? "human-step overlay ok" : "human-step overlay failed")
            exit(0)
        }
        if args.contains("--install-test") {
            // Fresh-user test: set ONE_SUPPORT_DIR to an empty folder and OPENROUTER_API_KEY.
            // Without ONE_SUPPORT_DIR it would switch the person's real One to a test model (it did once).
            guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
                print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
                exit(2)
            }
            runHeadless {
                let t0 = Date()
                print("devtools missing:", Installer.devToolsMissing)
                let err: String? =
                    Env.hermesPath != nil
                    ? nil : await Installer.run { n, line in if line.hasPrefix("Install") || n % 5 == 0 { print("  [\(n)] \(line)") } }
                if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] {
                    try? "OPENROUTER_API_KEY=\(k)\n".write(to: Env.hermesHome.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
                }
                print("install:", err ?? "ok", "in \(Int(Date().timeIntervalSince(t0)))s", "hermes:", Env.hermesPath ?? "missing")
                guard err == nil else { return }
                await SignIn.makeDefault(.openrouter)
                _ = await hermesRun(["config", "set", "model.default", "openai/gpt-4o-mini"])
                Access.override = []
                Persona.write(assistant: "Juno", user: "EK", connections: [], passwords: "ask each time")
                if let e = await Engine.shared.start() {
                    print("engine:", e)
                    return
                }
                Engine.shared.onText = { print($0, terminator: "") }
                for q in ["Who are you and what's my name? One sentence.", "List 3 files in my Downloads folder."] {
                    print("\nQ:", q)
                    print("A:", terminator: " ")
                    let stop = await Engine.shared.prompt(q)
                    print(" [\(stop)]")
                }
                let previous = Engine.shared.enginePID
                Engine.shared.stop()
                Engine.stopStrayGateway(previousEngine: previous, caller: "install-test")
            }
        }
        if args.contains("--test-jobs") {
            Env.selfTest = true  // scratch brain and Hermes home; see JobsCheck.swift
            JobsCheck.run()
        }
        if args.contains("--reset") {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            print("reset onboarding")
            exit(0)
        }
        if args.contains("--selftest") {
            // Uses a throwaway Hermes home and an OPENROUTER_API_KEY from the environment.
            Env.selfTest = true
            runHeadless {
                print("hermes:", Env.hermesPath ?? "missing")
                for p in Provider.allCases { print("[\(p.title)] signed in (selftest home):", await SignIn.isSignedIn(p)) }
                await SignIn.makeDefault(.openrouter)
                try? FileManager.default.removeItem(at: Brain.root)
                print("brain:", Brain.build(owner: "Omar", ai: "Juno", rooms: [.work]) ?? "built at \(Brain.root.path)")
                print("rooms:", Brain.rooms.map(\.folder))
                print("backup:", Brain.backupToICloud() ?? "copied to iCloud Drive")
                Access.override = []
                Persona.write(assistant: "Juno", user: "Omar", connections: ["Gmail"], passwords: "use 1Password")
                let t0 = Date()
                if let e = await Engine.shared.start() {
                    print("engine start failed:", e)
                    return
                }
                print("engine started in \(Int(Date().timeIntervalSince(t0)))s")
                let out = Box("")
                Engine.shared.onText = { out.v += $0 }
                Engine.shared.onTool = { print("  tool:", $0) }
                Engine.shared.onPermission = { q, opts, ans in
                    print("  permission asked:", q, opts.map(\.0))
                    ans("deny")
                }
                for q in [
                    "Who are you, and what's my name? One sentence.",
                    "How does your memory work, and which rooms do I have? Two short sentences.",
                    "Remember that my daughter's birthday is March 3.",
                    "List 3 file names in my Downloads folder.",
                ] {
                    out.v = ""
                    let t1 = Date()
                    let stop = await Engine.shared.prompt(q)
                    print("Q: \(q)\nA (\(Int(Date().timeIntervalSince(t1)))s, \(stop)): \(out.v.prefix(300))")
                }
                Engine.shared.stop()
            }
        }
        if let i = args.firstIndex(of: "--signin-probe"), i + 1 < args.count, let p = Provider(rawValue: args[i + 1]) {
            // Starts a real sign-in, prints what the app would show, then cancels.
            Env.selfTest = true
            runHeadless {
                let s = SignIn()
                let seen = Box([String]())
                s.start(p) { ev in
                    switch ev {
                    case .openPage(let u): seen.v.append("would open page: \(u.absoluteString.prefix(90))")
                    case .code(let c): seen.v.append("would show code: \(c)")
                    case .needPaste: seen.v.append("would ask to paste a code")
                    case .done(let ok, let m): seen.v.append("finished ok=\(ok) \(m.prefix(120))")
                    }
                }
                try? await Task.sleep(for: .seconds(25))
                s.cancel()
                try? await Task.sleep(for: .seconds(2))
                seen.v.forEach { print($0) }
            }
        }
        OneApp.main()
    }
}
