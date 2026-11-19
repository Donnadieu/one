import AppKit
import Combine
import QuartzCore
import SwiftUI

// MARK: - Pace: how often One's moving pictures draw
//
// Ek, Nov 19 2026: "Having One open really slows down my computer ... I think it just slows things down when it's open
// and not doing anything too." Up to 0.9.137 every orb, bot moon, drifting helper and the stars drew at the screen's
// full rate (120 a second on a ProMotion Mac) in every state: with the window tucked into the orb, minimized, covered
// or behind another app, and the floating orb drew while it was hidden too. On Omar's Mac that kept One's main thread
// about 40% busy with nothing on screen to see (`--test-idle`, IdleCheck.swift, holds the line). Now:
// - a window that isn't on screen (closed, tucked away, minimized, fully covered, One hidden) draws nothing;
// - in front, things at rest (the orb breathing, helpers drifting, the bots' moons) draw `calmFront` a second, and
//   only what shows work or a voice (a working helper's light, the orb at work or talking, listening) at full rate;
// - with another app in front, things at rest draw `calmBack` a second and the rest `quickBack`;
// - the floating orb at rest draws `orbRest` a second, at full rate only while it works or listens.
// Everything here changes on events (window, app and voice notices), never on a timer.
@MainActor final class Pace: NSObject, ObservableObject {
    static let shared = Pace()
    /// One's main window is on screen: open, not minimized, not tucked away or covered, One not hidden.
    @Published private(set) var homeSeen = true
    /// The floating orb is on screen.
    @Published private(set) var orbSeen = false
    /// One is the app in front.
    @Published private(set) var front = true
    /// A voice is playing (a reply read aloud): the orbs follow it at full rate.
    @Published private(set) var voice = false

    static let calmFront = 1.0 / 30
    static let calmBack = 1.0 / 10
    static let quickBack = 1.0 / 30
    static let orbRest = 1.0 / 15
    static let orbQuick = 1.0 / 30  // the floating orb at work or listening: small, so 30 a second looks smooth

    private var voiceUntil = Date.distantPast
    private weak var home: NSWindow?
    private var watching: [NSObjectProtocol] = []

    override private init() {
        super.init()
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        for n in names {
            watching.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Pace.shared.update() } })
        }
        watching.append(
            nc.addObserver(forName: Pace.voiceQueued, object: nil, queue: .main) { n in
                let until = n.userInfo?["until"] as? Date ?? Date()
                MainActor.assumeIsolated { Pace.shared.heard(until: until) }
            })
    }

    /// Posted by the voice line (Voice.swift) whenever a sentence is queued, with when it ends ("until").
    nonisolated static let voiceQueued = Notification.Name("one.pace.voiceQueued")

    /// Reads the windows again. Called on every window and app notice, and by Floater when it shows or hides the orb.
    func update() {
        // A window tucked away or minimized can't become main, so it's remembered from when it could.
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) { home = w }
        let seen = home.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? true
        set(\.homeSeen, seen && !NSApp.isHidden)
        set(\.orbSeen, Floater.shared.orbShown && !NSApp.isHidden)
        set(\.front, NSApp.isActive)
        retime()
    }

    private func set(_ k: ReferenceWritableKeyPath<Pace, Bool>, _ v: Bool) { if self[keyPath: k] != v { self[keyPath: k] = v } }

    private func heard(until: Date) {
        voiceUntil = max(voiceUntil, until)
        set(\.voice, true)
        // The voice's own wave fades for a moment after the last sentence (Speaker.heard): then back to rest.
        let wait = max(0.5, voiceUntil.timeIntervalSinceNow + 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated {
                if Date() >= Pace.shared.voiceUntil.addingTimeInterval(3) { Pace.shared.set(\.voice, false) }
            }
        }
    }

    // MARK: Clocks for the views

    /// Seconds between frames for a moving picture at rest, or nil when it runs on the screen's own clock (work, a
    /// voice, listening). Rest runs on one shared timer per window (`PaceTicker`): the screen's clock
    /// (`.animation(minimumInterval:)`) still woke the window and laid the whole home screen out on every refresh even
    /// when it skipped drawing, and a timer per picture laid it out once per picture (Nov 19 2026 CI: 107-120 layouts
    /// a second for 30 drawings each). One shared tick = every picture at rest moves in one pass.
    func calm(quick: Bool, orb: Bool = false) -> Double? {
        if quick || voice { return front || orb ? nil : Pace.quickBack }
        return orb ? Pace.orbRest : front ? Pace.calmFront : Pace.calmBack
    }
    /// A slow periodic clock (Routines' sky): one still moment while the window is unseen.
    func every(_ seconds: Double, from start: Date = WorldLook.start) -> PaceEvery { PaceEvery(start: start, seconds: seconds, on: homeSeen) }

    private var homeTimer: Timer?
    private var orbTimer: Timer?
    private var homeLink: CADisplayLink?
    private var orbLink: CADisplayLink?
    private var homeEvery = 0.0
    private var orbEvery = 0.0
    private var ticks = 0

    /// Starts, stops or re-times the shared timers: each runs only while its window is seen and something uses it.
    func retime() {
        let t = PaceTicker.self
        let moving = t.home.users + t.slow.users + t.stars.users > 0
        let h = !homeSeen ? 0 : moving ? max(front ? Pace.calmFront : Pace.calmBack, Motion.every ?? 0) : t.second.users > 0 ? 1 : 0
        let o = orbSeen && t.orb.users > 0 ? max(t.orb.quick > 0 || voice ? Pace.orbQuick : Pace.orbRest, Motion.every ?? 0) : 0
        if h != homeEvery {
            homeEvery = h
            homeTimer?.invalidate()
            homeLink?.invalidate()
            homeTimer = nil
            homeLink = nil
            // In step with the screen (its own drawing pass, so a keystroke never carries a tick's work), at `h`;
            // words alone once a second on a plain timer.
            if h > 0 && h < 1, let l = link(h, #selector(homeLinked)) {
                homeLink = l
            } else if h > 0 {
                homeTimer = timer(h) { Pace.shared.homeTick() }
            }
        }
        if o != orbEvery {
            orbEvery = o
            orbTimer?.invalidate()
            orbLink?.invalidate()
            orbTimer = nil
            orbLink = nil
            if o > 0 { orbLink = link(o, #selector(orbLinked)) }
            if o > 0 && orbLink == nil { orbTimer = timer(o) { PaceTicker.orb.tick(Date()) } }
        }
    }

    /// The screen's clock asked for `every` seconds between calls (it calls no more often than that).
    private func link(_ every: Double, _ sel: Selector) -> CADisplayLink? {
        guard #available(macOS 14.0, *), let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let l = screen.displayLink(target: self, selector: sel)
        let fps = Float(1 / every)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 8), maximum: fps, preferred: fps)
        l.add(to: .main, forMode: .common)
        return l
    }
    @objc private func homeLinked() { homeTick() }
    @objc private func orbLinked() { PaceTicker.orb.tick(Date()) }

    private func timer(_ every: Double, _ f: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: every, repeats: true) { _ in MainActor.assumeIsolated { f() } }
        t.tolerance = every * 0.1  // lets macOS fire it together with other wakeups
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// For `--test-idle`: what the shared timers are doing.
    var state: String {
        let t = PaceTicker.self
        return String(
            format: "home tick %.3f s (users %d, slow %d, stars %d, words %d), orb tick %.3f s (users %d)", homeEvery, t.home.users,
            t.slow.users, t.stars.users, t.second.users, orbEvery, t.orb.users)
    }

    /// One pass for the main window: the orb at rest every tick, the small slow things every second one, the stars
    /// every third, words once a second.
    private func homeTick() {
        let now = Date()
        ticks += 1
        PaceTicker.home.tick(now)
        if ticks % 2 == 0 { PaceTicker.slow.tick(now) }
        if ticks % 3 == 1 { PaceTicker.stars.tick(now) }  // 10 a second in front, 3 behind another app
        if Int(now.timeIntervalSince1970) != Int(PaceTicker.second.now.timeIntervalSince1970) { PaceTicker.second.tick(now) }
    }
}

/// A shared tick for pictures at rest (`home`, `orb`), the stars (`stars`, a third as often) and words that change
/// once a second (`second`). Views count themselves in while on screen, so a timer runs only while something uses it.
@MainActor final class PaceTicker: ObservableObject {
    static let home = PaceTicker()
    static let slow = PaceTicker()  // every second tick: the small slow things (bots' moons, helpers drifting)
    static let stars = PaceTicker()
    static let second = PaceTicker()
    static let orb = PaceTicker()
    @Published private(set) var now = Date()
    var users = 0 {
        didSet { Pace.shared.retime() }
    }
    /// Of those, the ones showing work or listening right now (the floating orb's tick speeds up for them).
    var quick = 0 {
        didSet { Pace.shared.retime() }
    }
    func tick(_ d: Date) { now = d }
}

/// A view that moves with one of the shared ticks.
struct PaceRest<Content: View>: View {
    @ObservedObject var ticker: PaceTicker
    var quick = false
    @ViewBuilder let content: (Date) -> Content
    var body: some View {
        content(ticker.now)
            .onAppear {
                ticker.users += 1
                if quick { ticker.quick += 1 }
            }
            .onDisappear {
                ticker.users -= 1
                if quick { ticker.quick -= 1 }
            }
            .onChange(of: quick) { _, q in ticker.quick += q ? 1 : -1 }
    }
}

/// The clock every moving picture uses: the screen's own clock only while it shows work or a voice, the shared tick at
/// rest (`Pace.calm`), and nothing at all while its window (the main one, or the floating orb's) isn't on screen.
struct PaceClock<Content: View>: View {
    var quick = false
    var orb = false
    /// Small and slow at rest (a bot's moon, a helper drifting): every second tick is plenty.
    var slow = false
    @ViewBuilder let content: (Date) -> Content
    @ObservedObject private var pace = Pace.shared
    var body: some View {
        let seen = orb ? pace.orbSeen : pace.homeSeen
        if orb {  // the floating orb always rides its own tick: 15 a second at rest, 30 at work (Pace.retime)
            PaceRest(ticker: .orb, quick: quick, content: content)
        } else if let s = pace.calm(quick: quick, orb: orb) {
            if quick {  // at work behind another app: its own clock, a little slower
                TimelineView(.animation(minimumInterval: s, paused: !seen)) { tl in content(tl.date) }
            } else {
                PaceRest(ticker: slow ? .slow : .home, content: content)
            }
        } else {
            TimelineView(.animation(minimumInterval: Motion.every, paused: !seen)) { tl in content(tl.date) }
        }
    }
}

/// `.periodic` that stops when `on` is false (TimelineView's own periodic clock can't be paused).
struct PaceEvery: TimelineSchedule, Equatable {
    let start: Date
    let seconds: Double
    let on: Bool
    func entries(from begin: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard on else { return AnyIterator([Date()].makeIterator()) }
        let n = max(0, (begin.timeIntervalSince(start) / seconds).rounded(.down))
        var next = start.addingTimeInterval(n * seconds)
        return AnyIterator {
            defer { next = next.addingTimeInterval(seconds) }
            return next
        }
    }
}
