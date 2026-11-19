import AppKit
import Combine
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
@MainActor final class Pace: ObservableObject {
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

    private var voiceUntil = Date.distantPast
    private var watching: [NSObjectProtocol] = []

    private init() {
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
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
        let seen = main.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? true
        set(\.homeSeen, seen && !NSApp.isHidden)
        set(\.orbSeen, Floater.shared.orbShown && !NSApp.isHidden)
        set(\.front, NSApp.isActive)
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

    /// A moving picture in the main window. `quick`: it shows work, listening or a voice.
    func home(quick: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: interval(quick: quick || voice), paused: !homeSeen)
    }
    func interval(quick: Bool) -> Double? {
        if front { return quick ? Motion.every : max(Motion.every ?? 0, Pace.calmFront) }
        return quick ? max(Motion.every ?? 0, Pace.quickBack) : Pace.calmBack
    }
    /// The floating orb's clock.
    func orb(quick: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: quick || voice ? Motion.every : Pace.orbRest, paused: !orbSeen)
    }
    /// A slow periodic clock in the main window (words once a second, the stars): one still moment while unseen.
    func every(_ seconds: Double, from start: Date = WorldLook.start) -> PaceEvery { PaceEvery(start: start, seconds: seconds, on: homeSeen) }
    /// The stars twinkle 12 times a second in front, 4 behind another app.
    var starsEvery: Double { front ? 1 / Stars.fps : 1 / 4 }
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
