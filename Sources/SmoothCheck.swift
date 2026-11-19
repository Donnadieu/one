import AppKit
import Combine
import SwiftUI

// MARK: - Check: Home stays smooth (`One --test-smooth`)
//
// Omar, Nov 18 2026: "the animation and transitions, as well as typing, lag. Every time I type, the ball of light from
// the bots lags too, and the helpers' light going around seems to lag as well." His Mac then: 4 bots, several helpers,
// the glass at 87%. This opens the real home screen in a window on the CI runner's screen with 0, 4 and 8 bots and
// several helpers (4 of them streaming words the way a working helper does), and measures, for each:
// - idle: the main thread's share of one core while everything animates, the longest time it was busy at once, how
//   many frames came, how many were late (a hitch: more than 1.5 frames apart), and how often the model told every
//   view to redraw;
// - typing: 30 real keystrokes into the "Or say it your way…" box, each timed from the key to the drawn window;
// - transitions: a bot's chat, Routines and Rooms opened and closed, the longest frame gap in each.
// The main thread's own work is told apart from waiting: every 1 ms beat also reads the main thread's CPU time, so a
// long gap with the CPU busy is a hitch One caused (`burst`), and a long gap with the CPU idle is the Mac's drawing
// (a CI runner's graphics are slow and shared; frames per second there are printed, never judged).
// Budgets at the end (`Budget`); a run over any budget fails. Test copy only, its own settings and scratch folder.
enum SmoothCheck {
    /// The budgets: typing never drops a frame at 120 Hz, the main thread mostly free while the orbs move.
    enum Budget {
        static let keyP95 = 8.3  // ms of main-thread work for a keystroke, to the screen updated, 95th percentile (one 120 Hz frame)
        static let keyMax = 16.7  // ms, the slowest keystroke (one 60 Hz frame)
        static let idleBusy = 0.30  // the main thread's share of one core while 8 bots and the helpers animate
        static let burst = 16.7  // ms, the longest the main thread worked without a break, idle or typing
        static let hitches = 0.03  // beats late by more than a frame because the main thread was working
        static let publishes = 12.0  // redraws a second the model asks for while helpers stream words
        static let transition = 50.0  // ms, the longest main-thread burst while a screen opens or closes
    }

    nonisolated static func main(_ args: [String]) {
        if let k = args.firstIndex(of: "--render-smooth-cost") { MainActor.assumeIsolated { cost(args, k) } }
        guard args.contains("--test-smooth") else { return }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        let bots = args.firstIndex(of: "--bots").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let counts = bots.map { $0.split(separator: ",").compactMap { Int($0) } } ?? [0, 4, 8]
        if let k = args.firstIndex(of: "--fps"), k + 1 < args.count, let f = Double(args[k + 1]), f > 0 { Motion.every = 1 / f }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in exit(await run(bots: counts)) }
        }
        NSApplication.shared.run()
    }

    /// `--render-smooth-cost [n] [bots]` (a test copy, ONE_SUPPORT_DIR set): what one model change costs the home screen,
    /// with no window at all: the real home view in a hosting view that is never shown, the model changed `n` times
    /// (a streamed word, as a helper sends them), each change's update and layout timed on the main thread's CPU.
    @MainActor static func cost(_ args: [String], _ k: Int) {
        guard TestWorld.enterRender() else { exit(2) }
        let n = k + 1 < args.count ? Int(args[k + 1]) ?? 200 : 200
        let bots = k + 2 < args.count ? Int(args[k + 2]) ?? 8 : 8
        UserDefaults.standard.set(false, forKey: "botsCollapsed")
        let m = Model.shared
        m.assistantName = "Ava"
        m.userName = "Omar"
        world(bots: bots)
        let env = ProcessInfo.processInfo.environment
        if env["ONE_COST_SHELF"] == "0" { m.shelf = [] }  // what each part costs: the same run without it
        UserDefaults.standard.set(env["ONE_COST_SHELF"] == "folded", forKey: "shelfCollapsed")
        if env["ONE_COST_SHELF"] == "older" {
            m.shelf = m.shelf.map {
                var i = $0
                i.made = i.made.addingTimeInterval(-30 * 86400)
                return i
            }
        }
        if env["ONE_COST_CHAT"] == "0" { m.bubbles = [] }
        let host = NSHostingView(
            rootView: HomeView(m: m).frame(width: 1180, height: 760).foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        host.layoutSubtreeIfNeeded()
        let working = m.helpers.filter { $0.state == "working" && !isBot($0) }.map(\.id)
        var each: [Double] = []
        for i in 0..<n {
            let c = threadCPU()
            if let id = working.isEmpty ? nil : working[i % working.count] { m.update(id) { $0.reply += "word " } }
            host.layoutSubtreeIfNeeded()
            each.append((threadCPU() - c) * 1000)
        }
        let s = each.sorted()
        print(
            String(
                format: "one model change, home with %d bots and %d cards: p50 %.2f ms, p95 %.2f ms, max %.2f ms", bots, m.shelf.count,
                s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last ?? 0))
        exit(0)
    }

    // MARK: What is recorded

    @MainActor static var frames: [CFTimeInterval] = []
    @MainActor static var beats: [(wall: CFTimeInterval, cpu: Double)] = []
    @MainActor static var publishes = 0
    @MainActor static var recording = false
    @MainActor static var cancel: AnyCancellable?

    struct Window {
        var frames: [Double]  // ms between frames
        var longestBusy: Double  // ms, the longest gap between beats (working or waiting)
        var busy: Double  // main-thread CPU ÷ wall time
        var publishes: Double  // a second
        var period: Double  // ms per frame on this screen
        var burst = 0.0  // ms of main-thread CPU in the longest gap between beats
        var hitchShare = 0.0  // gaps longer than a frame with the main thread working most of it, per frame of time
        var late: Int { frames.filter { $0 > period * 1.5 }.count }
        var lateShare: Double { frames.isEmpty ? 1 : Double(late) / Double(frames.count) }
        var fps: Double { frames.isEmpty ? 0 : 1000 / (frames.reduce(0, +) / Double(frames.count)) }
        var longestFrame: Double { frames.max() ?? 999 }
    }

    /// CPU time the calling (main) thread has used so far, in seconds.
    nonisolated static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let u = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let s = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return u + s
    }

    @MainActor static func start() -> (wall: CFTimeInterval, cpu: Double) {
        frames = []
        beats = []
        publishes = 0
        recording = true
        return (CACurrentMediaTime(), threadCPU())
    }

    @MainActor static func stop(_ from: (wall: CFTimeInterval, cpu: Double)) -> Window {
        recording = false
        let wall = CACurrentMediaTime() - from.wall
        let busy = (threadCPU() - from.cpu) / max(wall, 0.001)
        let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let period = 1000 / max(hz, 1)
        let gaps = zip(frames.dropFirst(), frames).map { ($0 - $1) * 1000 }
        let pairs = zip(beats.dropFirst(), beats).map { (wall: ($0.wall - $1.wall) * 1000, cpu: ($0.cpu - $1.cpu) * 1000) }
        let hitches = pairs.filter { $0.wall > period && $0.cpu > period * 0.8 }.count
        var w = Window(
            frames: gaps, longestBusy: pairs.map(\.wall).max() ?? 999, busy: busy, publishes: Double(publishes) / wall, period: period)
        w.burst = pairs.map(\.cpu).max() ?? 999
        w.hitchShare = Double(hitches) / max(1, wall * 1000 / period)
        return w
    }

    @MainActor static func record(_ seconds: Double) async -> Window {
        let from = start()
        try? await Task.sleep(for: .seconds(seconds))
        return stop(from)
    }

    // MARK: The made-up home

    @MainActor static func world(bots: Int) {
        let m = Model.shared
        let room = Env.support.appendingPathComponent("rooms/co-founder-room", isDirectory: true)
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        try? "title: Co-Founder\nprivate: false\n".write(to: room.appendingPathComponent("room.yaml"), atomically: true, encoding: .utf8)
        var hs: [Helper] = []
        for i in 0..<bots { if let b = bot(i, room: room) { hs.append(b) } }
        let jobs = ["Flight to Quebec", "Opus missing from Brain", "Smooth One", "Hotel search", "Read pasted text", "Score ideas"]
        for (i, j) in jobs.enumerated() {
            var h = Helper(title: j, task: j, state: i < 4 ? "working" : "done", line: i < 4 ? "Searching the web" : "Done")
            h.started = Date().addingTimeInterval(-Double(60 * (i + 1)))
            h.seen = i < 4 ? nil : true
            hs.append(h)
        }
        // Omar's Ready for you held 1,326 cards on Nov 18 2026: about that many, most of them older.
        if m.shelf.count != 1300 {
            m.shelf = (0..<1300).map { i in
                ShelfItem(
                    title: "Result \(i)", detail: "What a helper made", from: "Ava", path: Env.support.appendingPathComponent("made/\(i).md").path,
                    made: Date().addingTimeInterval(-Double(i) * 3700), fresh: i < 3)
            }
        }
        m.openHelper = nil
        m.routinesOpen = false
        m.helpers = hs
        m.gate = .ready
        m.bubbles = (0..<40).map { i in
            Bubble(
                fromMe: i % 2 == 0,
                text: i % 2 == 0
                    ? "Can you check turn \(i) for me, in a bit more detail than usual?"
                    : "Here's turn \(i): a reply long enough to need real text layout, with **bold** words and a [link](https://example.com).")
        }
    }

    // BOTS-START (tools/smooth-compare.sh swaps this part out for releases made before bots)
    static let botNames = [
        "Part-time Work Finder", "Business Picker", "AI Office Venture", "Ascend", "Lead Finder", "Weekly Update", "Inbox", "Prices",
    ]
    static func isBot(_ h: Helper) -> Bool { h.bot != nil }
    static func bot(_ i: Int, room: URL) -> Helper? {
        let name = botNames[i % botNames.count]
        var h = Helper(title: name, task: "a bot", state: i % 2 == 0 ? "working" : "done", line: "Reading the latest posts")
        h.bot = BotInfo(
            name: name, color: Bots.colors[i % Bots.colors.count].name, room: "Co-Founder", roomPath: room.path, job: "Find new customers")
        h.log = (0..<6).map { "**You:** check in \($0)\n\nDone: found \($0 + 2) new leads, notes saved." }
        return h
    }
    // BOTS-END

    @MainActor static func window() -> NSWindow {
        let view = HomeView(m: Model.shared).frame(minWidth: 1180, minHeight: 760)
            .overlay(TimelineView(.animation) { tl in Color.clear.onChange(of: tl.date) { if recording { frames.append(CACurrentMediaTime()) } } })
            .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark)
        let w = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 1180, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return w
    }

    /// `ONE_SMOOTH_SAMPLE=<dir>`: asks for a time profile of the next `seconds` by leaving <dir>/<name>.want; the
    /// workflow's loop runs Apple's `sample` on this process for it (it needs the runner's sudo) and writes <name>.txt.
    @MainActor static func profile(_ name: String, seconds: Int) async {
        guard let dir = ProcessInfo.processInfo.environment["ONE_SMOOTH_SAMPLE"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(getpid()) \(seconds)".write(toFile: "\(dir)/\(name).want", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(700))  // the loop looks twice a second, and sample takes a moment to attach
    }

    static func textView(in v: NSView) -> NSTextView? {
        if let t = v as? NSTextView, t.isEditable { return t }
        for s in v.subviews { if let t = textView(in: s) { return t } }
        return nil
    }

    // MARK: The run

    @MainActor static func run(bots: [Int]) async -> Int32 {
        UserDefaults.standard.set(true, forKey: "voiceMuted")
        UserDefaults.standard.set(0.87, forKey: Glass.key)  // Omar's See-through
        UserDefaults.standard.set(false, forKey: "botsCollapsed")
        let m = Model.shared
        m.assistantName = "Ava"
        m.userName = "Omar"
        // Redraws the model asked for: changes in the same turn of the main loop are drawn once, so they count once.
        var asked = false
        cancel = m.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard recording, !asked else { return }
                asked = true
                publishes += 1
                DispatchQueue.main.async { asked = false }
            }
        }
        // A fast heartbeat: a long gap between beats = the main thread was busy that long.
        let beat = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { if recording { beats.append((CACurrentMediaTime(), threadCPU())) } }
        }
        RunLoop.main.add(beat, forMode: .common)
        // Working helpers stream words the way the engine sends them: 4 helpers, about 10 pieces a second each.
        var k = 0
        let stream = Timer(timeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated {
                let working = Model.shared.helpers.filter { $0.state == "working" && !isBot($0) }
                guard !working.isEmpty else { return }
                k += 1
                Model.shared.helperStreamed(working[k % working.count].id, "word\(k % 97) ")
            }
        }
        RunLoop.main.add(stream, forMode: .common)
        world(bots: bots.first ?? 0)
        let win = window()
        try? await Task.sleep(for: .seconds(2))
        var ok = true
        var lines: [String] = []
        func over(_ bad: Bool, _ what: String) {
            if bad {
                ok = false
                lines.append("FAIL \(what)")
            }
        }
        for n in bots {
            world(bots: n)
            try? await Task.sleep(for: .seconds(1.5))
            if n == bots.max() { await profile("idle-\(n)-bots", seconds: 3) }
            let idle = await record(3)
            print(
                String(
                    format:
                        "bots %d, idle: main thread %.0f%% busy, longest burst %.1f ms, %.1f%% hitches; %.1f redraws/s asked; screen: %.0f fps, %d of %d frames late, longest %.1f ms",
                    n, idle.busy * 100, idle.burst, idle.hitchShare * 100, idle.publishes, idle.fps, idle.late, idle.frames.count, idle.longestFrame))
            if n == bots.max() { await profile("typing-\(n)-bots", seconds: 3) }
            let keys = await typing(win)
            print(
                String(
                    format:
                        "bots %d, typing: a keystroke's work p50 %.1f ms, p95 %.1f ms, max %.1f ms (to drawn on this runner p50 %.1f, p95 %.1f); longest burst %.1f ms, %.1f%% hitches; screen: %d of %d frames late",
                    n, keys.p50, keys.p95, keys.max, keys.drawnP50, keys.drawnP95, keys.window.burst, keys.window.hitchShare * 100, keys.window.late,
                    keys.window.frames.count))
            over(keys.p95 > Budget.keyP95, String(format: "bots %d: a keystroke's work p95 %.1f ms (budget %.1f)", n, keys.p95, Budget.keyP95))
            over(keys.max > Budget.keyMax, String(format: "bots %d: slowest keystroke %.1f ms (budget %.1f)", n, keys.max, Budget.keyMax))
            over(idle.burst > Budget.burst, String(format: "bots %d: a %.1f ms burst while idle (budget %.1f)", n, idle.burst, Budget.burst))
            over(
                keys.window.burst > Budget.burst,
                String(format: "bots %d: a %.1f ms burst while typing (budget %.1f)", n, keys.window.burst, Budget.burst))
            over(
                idle.hitchShare > Budget.hitches,
                String(format: "bots %d: %.1f%% hitches while idle (budget %.0f%%)", n, idle.hitchShare * 100, Budget.hitches * 100))
            over(
                keys.window.hitchShare > Budget.hitches,
                String(format: "bots %d: %.1f%% hitches while typing (budget %.0f%%)", n, keys.window.hitchShare * 100, Budget.hitches * 100))
            over(
                idle.publishes > Budget.publishes,
                String(format: "bots %d: %.0f model changes a second (budget %.0f)", n, idle.publishes, Budget.publishes))
            if n == bots.max() {
                over(
                    idle.busy > Budget.idleBusy,
                    String(format: "bots %d: main thread %.0f%% busy while idle (budget %.0f%%)", n, idle.busy * 100, Budget.idleBusy * 100))
            }
        }
        // Screen changes, with the most bots.
        world(bots: bots.max() ?? 0)
        try? await Task.sleep(for: .seconds(1))
        let bot = m.helpers.first { isBot($0) }?.id
        let steps: [(String, @MainActor () -> Void)] = [
            ("a bot's chat opens", { if let bot { m.focusHelper(bot) } }), ("back home", { m.openHelper = nil }),
            ("a helper's chat opens", { if let h = m.helpers.first(where: { !isBot($0) })?.id { m.focusHelper(h) } }),
            ("back home", { m.openHelper = nil }),
            ("Routines opens", { m.routinesOpen = true }), ("Routines closes", { m.routinesOpen = false }),
            ("Rooms opens", { RoomsWindow.show(m) }), ("Rooms closes", { RoomsWindow.panel?.close() }),
        ]
        for (what, act) in steps {
            if what.hasSuffix("opens") {
                await profile(what.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: ""), seconds: 1)
            }
            let from = start()
            withAnimation(.easeOut(duration: 0.3)) { act() }
            try? await Task.sleep(for: .seconds(0.8))
            let w = stop(from)
            print(
                String(
                    format: "%@: longest burst %.1f ms, main thread %.0f%% busy; screen: longest frame %.1f ms, %d of %d frames late", what, w.burst,
                    w.busy * 100, w.longestFrame, w.late, w.frames.count))
            over(w.burst > Budget.transition, String(format: "%@: a %.0f ms burst (budget %.0f)", what, w.burst, Budget.transition))
            try? await Task.sleep(for: .milliseconds(300))
        }
        win.close()
        lines.forEach { print($0) }
        print(ok ? "smooth ok" : "smooth: over budget")
        return ok ? 0 : 1
    }

    struct Keys {
        var p50: Double
        var p95: Double
        var max: Double
        var drawnP50 = 0.0
        var drawnP95 = 0.0
        var window: Window
    }

    /// 30 keystrokes into the ask box at about 12 a second, each timed from the key to the window drawn with it.
    @MainActor static func typing(_ win: NSWindow) async -> Keys {
        guard let root = win.contentView, let tv = textView(in: root) else {
            print("FAIL no ask box on the home screen")
            return Keys(p50: 999, p95: 999, max: 999, window: Window(frames: [], longestBusy: 999, busy: 1, publishes: 0, period: 16.7))
        }
        win.makeFirstResponder(tv)
        try? await Task.sleep(for: .milliseconds(300))
        var work: [Double] = []
        var drawn: [Double] = []
        let from = start()
        for ch in "the quick brown fox jumps over" {
            // The keystroke's own work: the box takes the letter, the screen's views and layout update, the window
            // draws and hands its layers over. `work` is the main thread's CPU for all of it (the same on any Mac);
            // `drawn` is the wall time, which on a CI runner includes waiting for its slow shared graphics.
            let a = CACurrentMediaTime()
            let c = threadCPU()
            tv.insertText(String(ch), replacementRange: tv.selectedRange())
            root.layoutSubtreeIfNeeded()
            win.displayIfNeeded()
            CATransaction.flush()
            work.append((threadCPU() - c) * 1000)
            drawn.append((CACurrentMediaTime() - a) * 1000)
            try? await Task.sleep(for: .milliseconds(80))
        }
        let w = stop(from)
        tv.string = ""
        tv.didChangeText()
        func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * p))]
        }
        return Keys(
            p50: pct(work, 0.5), p95: pct(work, 0.95), max: work.max() ?? 999, drawnP50: pct(drawn, 0.5), drawnP95: pct(drawn, 0.95), window: w)
    }
}
