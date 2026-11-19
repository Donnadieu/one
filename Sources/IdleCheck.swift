import AppKit
import SwiftUI

// MARK: - Check: One costs next to nothing when it's open and idle (`One --test-idle`)
//
// Ek, Nov 19 2026: "Having One open really slows down my computer. It definitely slows things down when there are
// workers running, but I think it just slows things down when it's open and not doing anything too." The smooth check
// on 0.9.136 already showed the main thread 16-20% busy with nothing but bots on screen. This opens the real home
// screen (with the floating orb and One's own main loops running, as in the app) on the CI runner's screen and
// measures, in each state a person leaves One in:
// - in front with nothing working, in the background (another app in front), tucked away into the orb (the red
//   button), minimized, and in front with 1 to 4 helpers at work (each streaming words), plus 4 at work tucked away;
// - for each: the main thread's share of one core, the whole app's CPU, wakeups a second, and how many moving
//   pictures were drawn a second on the home screen and on the floating orb (`Motion.drawn`, `Motion.orbDrawn`).
// Budgets in `Budget`; any state over one fails. Test copy only, its own settings and scratch folder.
enum IdleCheck {
    enum Budget {
        /// The home screen draws nothing at all while its window isn't on screen (tucked away or minimized).
        static let hiddenHomeDraws = 0.5  // a second
        /// The floating orb at rest (nothing working, nobody talking): a slow breath, a few frames a second.
        static let restingOrbDraws = 20.0  // a second
        /// A CI runner draws without a graphics chip, so a frame costs its main thread several times what it costs a
        /// Mac. 0.9.137 on the runner: tucked away 29% main thread, 35% app, 136 wakeups/s, home drawing 401 times a
        /// second; in front 19%; behind another app 16%.
        /// Main thread, tucked away or minimized, nothing working: the resting orb and the loops only.
        static let hiddenMain = 0.05
        /// The whole app's CPU in the same states (every thread: drawing, files, the loops).
        static let hiddenApp = 0.06
        /// Wakeups a second in the same states (Activity Monitor's "Idle Wake Ups" plus interrupts).
        static let hiddenWakeups = 50.0
        /// In front or behind another app with nothing working.
        static let frontMain = 0.12
        static let backMain = 0.06
        /// In front with 4 helpers at work (each streaming ~10 pieces a second): their lights at full rate.
        static let workersMain = 0.30
        /// Tucked away with 4 helpers at work: the orb's working light and the words coming in.
        static let workersHiddenMain = 0.25
    }

    nonisolated static func main(_ args: [String]) {
        guard args.contains("--test-idle") else { return }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in exit(await run()) }
        }
        NSApplication.shared.run()
    }

    // MARK: What is measured

    struct Usage {
        var wall = CACurrentMediaTime()
        var main = SmoothCheck.threadCPU()
        var app = 0.0
        var wakeups: UInt64 = 0
        var drawn = Motion.drawn
        var orb = Motion.orbDrawn
        var loops = IdleCheck.loops
        var layouts = IdleCheck.layouts
        init() {
            var r = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &r) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { return }
            var tb = mach_timebase_info()
            mach_timebase_info(&tb)
            app = Double(r.ri_user_time + r.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9
            wakeups = r.ri_pkg_idle_wkups + r.ri_interrupt_wkups
        }
    }

    struct Result {
        var name: String
        var main: Double
        var app: Double
        var wakeups: Double
        var homeDraws: Double
        var orbDraws: Double
        var loops = 0.0
        var layouts = 0.0
        var line: String {
            String(
                format:
                    "%@: main thread %.1f%% busy, app %.1f%% CPU, %.0f wakeups/s; drawn a second: home %.1f, floating orb %.1f; main loop woke %.0f/s, home laid out %.0f/s",
                name, main * 100, app * 100, wakeups, homeDraws, orbDraws, loops, layouts)
        }
    }

    @MainActor static func measure(_ name: String, seconds: Double = 5) async -> Result {
        let p = Pace.shared
        let w = NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
        print(
            "  [pace: home seen \(p.homeSeen), orb seen \(p.orbSeen), front \(p.front), voice \(p.voice), \(p.state); window \(w.map { "\(type(of: $0)) visible \($0.isVisible) mini \($0.isMiniaturized) occl \($0.occlusionState.rawValue)" } ?? "none"); \(NSApp.windows.count) windows]"
        )
        let tag = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(4).joined(separator: "-")
        await SmoothCheck.profile("idle-" + tag, seconds: 3)
        let a = Usage()
        try? await Task.sleep(for: .seconds(seconds))
        let b = Usage()
        let wall = max(b.wall - a.wall, 0.001)
        let orb = Double(b.orb - a.orb) / wall
        let r = Result(
            name: name, main: (b.main - a.main) / wall, app: (b.app - a.app) / wall, wakeups: Double(b.wakeups - a.wakeups) / wall,
            homeDraws: Double(b.drawn - a.drawn) / wall - orb, orbDraws: orb, loops: Double(b.loops - a.loops) / wall,
            layouts: Double(b.layouts - a.layouts) / wall)
        print(r.line)
        return r
    }

    // MARK: The run

    /// Times the main thread's run loop woke up, and times the home screen was laid out.
    nonisolated(unsafe) static var loops = 0
    nonisolated(unsafe) static var layouts = 0
    final class Host<V: View>: NSHostingView<V> {
        override func layout() {
            MainActor.assumeIsolated { IdleCheck.layouts += 1 }
            super.layout()
        }
    }

    @MainActor static func window() -> NSWindow {
        let view = HomeView(m: Model.shared).frame(minWidth: 1180, minHeight: 760).foregroundStyle(WorldLook.cream)
            .environment(\.colorScheme, .dark)
        let w = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = Host(rootView: view)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { IdleCheck.loops += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        return w
    }

    @MainActor static func working(_ n: Int) {
        let m = Model.shared
        var hs = m.helpers
        var k = 0
        for i in hs.indices where hs[i].bot == nil {
            hs[i].state = k < n ? "working" : "done"
            hs[i].line = k < n ? "Searching the web" : "Done"
            k += 1
        }
        m.helpers = hs
    }

    @MainActor static func run() async -> Int32 {
        UserDefaults.standard.set(true, forKey: "voiceMuted")
        UserDefaults.standard.set(0.87, forKey: Glass.key)  // Omar's See-through
        UserDefaults.standard.set(false, forKey: "botsCollapsed")
        let m = Model.shared
        m.assistantName = "Ava"
        m.userName = "Omar"
        m.onboarded = true
        SmoothCheck.world(bots: 4)
        // Bots and helpers all finished: nothing at work.
        m.helpers = m.helpers.map {
            var h = $0
            h.state = "done"
            h.line = "Done"
            return h
        }
        // Working helpers stream words the way the engine sends them: about 10 pieces a second each.
        var k = 0
        let stream = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                for h in Model.shared.helpers where h.state == "working" && h.bot == nil {
                    k += 1
                    Model.shared.helperStreamed(h.id, "word\(k % 97) ")
                }
            }
        }
        RunLoop.main.add(stream, forMode: .common)
        let win = window()
        Floater.shared.setup()
        m.startTending()
        try? await Task.sleep(for: .seconds(4))  // first loads, the shelf scan, layout settle
        var ok = true
        var fails: [String] = []
        func over(_ bad: Bool, _ what: String) {
            if bad {
                ok = false
                fails.append("FAIL " + what)
            }
        }
        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

        let front = await measure("in front, nothing working")
        over(front.main > Budget.frontMain, "in front: main thread \(pct(front.main)) (budget \(pct(Budget.frontMain)))")
        var four: Result?
        for n in 1...4 {
            working(n)
            try? await Task.sleep(for: .seconds(1))
            let r = await measure("in front, \(n) helper\(n == 1 ? "" : "s") at work", seconds: 4)
            if n == 4 { four = r }
        }
        if let four {
            over(four.main > Budget.workersMain, "4 at work: main thread \(pct(four.main)) (budget \(pct(Budget.workersMain)))")
            // Their circling lights still move at the screen's full rate (the smoothness Omar asked for, Nov 18).
            let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
            over(
                four.homeDraws < 4 * hz * 0.4, "4 at work: drew only \(String(format: "%.0f", four.homeDraws)) a second (their lights at \(Int(hz)))")
        }
        working(0)
        try? await Task.sleep(for: .seconds(1))

        // Another app in front: Finder, the way a click on the desktop does it.
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: finder) }
            finder.activate()
        }
        NSApp.deactivate()
        try? await Task.sleep(for: .seconds(1.5))
        let back = await measure("in the background (another app in front)\(NSApp.isActive ? " [One stayed active]" : "")")
        over(back.main > Budget.backMain, "in the background: main thread \(pct(back.main)) (budget \(pct(Budget.backMain)))")

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        Floater.shared.tuckAway(nil)  // the red button
        try? await Task.sleep(for: .seconds(1.5))
        let tucked = await measure("tucked away into the orb, nothing working")
        win.makeKeyAndOrderFront(nil)
        Floater.shared.openMain()
        try? await Task.sleep(for: .seconds(1))
        win.miniaturize(nil)
        try? await Task.sleep(for: .seconds(2))
        let mini = await measure("minimized\(win.isMiniaturized ? "" : " [didn't minimize]"), nothing working")
        for r in [tucked, mini] {
            over(r.homeDraws > Budget.hiddenHomeDraws, "\(r.name): home drew \(String(format: "%.1f", r.homeDraws)) a second (budget 0)")
            over(
                r.orbDraws > Budget.restingOrbDraws,
                "\(r.name): the resting orb drew \(String(format: "%.0f", r.orbDraws)) a second (budget \(Int(Budget.restingOrbDraws)))")
            over(r.main > Budget.hiddenMain, "\(r.name): main thread \(pct(r.main)) (budget \(pct(Budget.hiddenMain)))")
            over(r.app > Budget.hiddenApp, "\(r.name): app \(pct(r.app)) CPU (budget \(pct(Budget.hiddenApp)))")
            over(
                r.wakeups > Budget.hiddenWakeups,
                "\(r.name): \(String(format: "%.0f", r.wakeups)) wakeups a second (budget \(Int(Budget.hiddenWakeups)))")
        }

        win.deminiaturize(nil)
        Floater.shared.openMain()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))
        // Back from the Dock, everything moves again as before (not stuck at rest or still).
        _ = await measure("in front again after the Dock, nothing working", seconds: 3)
        try? await Task.sleep(for: .seconds(3))
        let again = await measure("in front again after the Dock, 5 s later", seconds: 3)
        over(
            again.homeDraws < front.homeDraws * 0.6,
            "back in front: home drew \(String(format: "%.0f", again.homeDraws)) a second, \(String(format: "%.0f", front.homeDraws)) before minimizing"
        )
        working(4)
        Floater.shared.tuckAway(nil)
        try? await Task.sleep(for: .seconds(1.5))
        let away = await measure("tucked away, 4 helpers at work", seconds: 4)
        over(away.homeDraws > Budget.hiddenHomeDraws, "tucked away at work: home drew \(String(format: "%.1f", away.homeDraws)) a second (budget 0)")
        over(away.main > Budget.workersHiddenMain, "tucked away at work: main thread \(pct(away.main)) (budget \(pct(Budget.workersHiddenMain)))")
        // Where the rest goes (printed, never judged): the same tucked-away state without the stars' clock, then with
        // nothing on the home screen moving at all.
        working(0)
        Stars.reduceMotion = true
        m.objectWillChange.send()
        try? await Task.sleep(for: .seconds(1))
        _ = await measure("[look] tucked away, stars still", seconds: 3)
        let keep = m.helpers
        m.helpers = []
        try? await Task.sleep(for: .seconds(1))
        _ = await measure("[look] tucked away, no helpers or bots, stars still", seconds: 3)
        win.makeKeyAndOrderFront(nil)
        Floater.shared.openMain()
        try? await Task.sleep(for: .seconds(1))
        _ = await measure("[look] in front, no helpers or bots, stars still", seconds: 3)
        m.helpers = keep
        Stars.reduceMotion = false
        stream.invalidate()
        win.close()
        fails.forEach { print($0) }
        print(ok ? "idle ok" : "idle: over budget")
        return ok ? 0 : 1
    }
}
