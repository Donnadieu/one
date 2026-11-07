import AppKit
import CoreAudio
import Foundation

// MARK: - Is the Mac really awake? Can the speaker start? (0.9.99)
//
// Nov 6 2026, 2:13 PM: the lid was closed. In one of the Mac's short "dark wakes" (it wakes for about a minute every
// 15 minutes to fetch mail and the like, with no screen and no sound) One installed an update and relaunched. The new
// copy started its speaker at launch; with no sound output in a dark wake, Apple's audio code raised an Objective-C
// exception in `AVAudioPlayerNode.play()` that Swift can't catch, and One ended (crash reports One-2026-11-06-141409 and
// One-2026-11-07-081753, both `Speaker.wakeAudio`). Nothing brought it back for 18 hours, and the phone chat with it.
// Now: the voice line starts only when the Mac is fully awake and has a speaker, every audio call that can raise goes
// through `OneCatch`, and a line that couldn't start tries again when the Mac wakes or a speaker appears.

/// Whether the Mac is fully awake (a person could be using it) or in a dark wake / with its screens off.
enum Awake {
    enum State: String {
        case full  // awake with a screen on
        case dark  // a dark wake: the Mac is up for a moment with no screen and no sound (lid closed, asleep)
        case screensOff  // fully awake, but every screen is asleep (lid open and idle, or lid closed)
    }
    /// Checks only (`--test-sleep-safe`, `--test-updates`): pretend the Mac is in this state.
    nonisolated(unsafe) static var fake: State?

    nonisolated static var now: State {
        if let f = fake { return f }
        if let caps = capabilities(), caps & 0x2 == 0 || caps & 0x4 == 0 { return .dark }  // no graphics or no audio: a dark wake
        return screensAsleep ? .screensOff : .full
    }
    /// Fully awake with a screen on: the only time an update may restart One.
    nonisolated static var full: Bool { now == .full }
    /// Sound can play (not a dark wake). Screens may be off: a routine's report is still read aloud in a quiet room.
    nonisolated static var soundAllowed: Bool { now != .dark }

    /// Every display asleep (or none at all, e.g. the lid closed with nothing plugged in).
    nonisolated static var screensAsleep: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success, n > 0 else { return true }
        return ids.prefix(Int(n)).allSatisfy { CGDisplayIsAsleep($0) != 0 || CGDisplayIsActive($0) == 0 }
    }

    /// The power manager's own view: CPU 0x1, graphics 0x2, audio 0x4, network 0x8. A dark wake has no graphics and no
    /// audio. Read from IOKit by name (not in the public headers); nil when this macOS doesn't have it.
    private typealias CapsFn = @convention(c) () -> UInt32
    nonisolated(unsafe) private static let capsFn: CapsFn? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let s = dlsym(h, "IOPMConnectionGetSystemCapabilities")
        else { return nil }
        return unsafeBitCast(s, to: CapsFn.self)
    }()
    nonisolated static func capabilities() -> UInt32? {
        guard let f = capsFn else { return nil }
        let c = f()
        return c == 0 ? nil : c
    }
}

/// Whether the voice line may start now, and a safe way to make audio calls that can raise.
enum AudioGate {
    /// Checks only: pretend there's no speaker at all.
    nonisolated(unsafe) static var fakeNoDevice = false

    /// The Mac's default sound output, or nil when there is none (asleep, unplugged, a headset switching over).
    nonisolated static func outputDevice() -> AudioDeviceID? {
        if fakeNoDevice { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    /// nil when the line may start now, else why not (in plain words, for the voice log).
    nonisolated static func blocked() -> String? {
        if !Awake.soundAllowed { return "the Mac is asleep (dark wake)" }
        if outputDevice() == nil { return "no sound output" }
        return nil
    }

    /// Runs an audio call that may raise an Objective-C exception (Apple's audio classes do, instead of returning an
    /// error). Returns false, and logs the reason, when it raised; One carries on without sound.
    @discardableResult
    nonisolated static func attempt(_ what: String, _ body: () -> Void) -> Bool {
        guard let why = OneCatch(body) else { return true }
        VoiceLine.log("\(what) failed, carrying on without sound: \(why)")
        return false
    }

    /// Retry delays while the line is down and nothing woke it: 5 s, 15 s, 1 min, then every 5 min.
    static let backoff: [Double] = [5, 15, 60, 300]
    static func delay(after tries: Int) -> Double { backoff[min(max(tries, 0), backoff.count - 1)] }
}

extension Speaker {
    /// Once: try the line again when the Mac wakes, a screen wakes or the sound output changes (a speaker or
    /// headset appears). Main thread.
    func watchForSound() {
        guard !watchingSound else { return }
        watchingSound = true
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.retrySoon(after: 2, why: "the Mac woke")
            }
        }
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.retrySoon(after: 1, why: "the sound output changed")
        }
    }

    /// Main thread. If the line is down, try it again after `s` seconds (sooner calls win).
    func retrySoon(after s: Double, why: String) {
        guard lineDown, stand == nil || standPlays else { return }
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.lineDown else { return }
            VoiceLine.log("trying the voice line again: \(why)")
            self.wakeAudio()
            if self.lineDown {
                self.retryTries += 1
                self.retrySoon(after: AudioGate.delay(after: self.retryTries), why: "still no sound")
            }
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
}
