import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

// MARK: - Check: the whole app under load for minutes (`One --test-soak [minutes]`)
//
// One 0.9.50 to 0.9.85 crashed with "memory corruption of free block" after running from half an hour to 8 hours:
// something wrote to memory that had already been freed, long before the crash. `--test-voice-stress` drives only the
// audio line; this drives what the person actually has going at once: the home screen live (orb, chat, helper orbs) in
// an off-screen window, the stand-in engine streaming a reply into the main chat and many helpers into theirs, every
// reply read aloud on the real audio line (volume 0), helper chimes, the line rebuilt (Bluetooth call mode), hushes.
// Run it with Apple's sampling guard at full rate (MallocProbGuard=1 MallocProbGuardSampleRate=1, tools/soak-check.sh):
// then a write to freed memory crashes right at the write, and the crash report names the code that did it.
// A test copy only (own settings, ONE_SUPPORT_DIR, ONE_TEST_ENGINE = tools/fake-engine.py); no window on screen.
enum SoakCheck {
    /// Frames the off-screen home screen really drew (proves the orb is live, not paused).
    @MainActor static var ticks = 0
    nonisolated static func main(_ args: [String]) {
        guard let k = args.firstIndex(of: "--test-soak") else { return }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil, Env.testEngine != nil else {
            print("refusing: run tools/soak-check.sh (a test copy, a scratch folder and the stand-in engine)")
            exit(2)
        }
        let minutes = k + 1 < args.count ? Double(args[k + 1]) ?? 5 : 5
        NSApplication.shared.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            Task { @MainActor in exit(await run(minutes: minutes)) }
        }
        NSApplication.shared.run()
    }

    @MainActor
    static func run(minutes: Double) async -> Int32 {
        guard let m = await HelperStress.setUp() else { return 2 }
        let sp = Speaker.shared
        Speaker.prefs.set(false, forKey: "voiceMuted")
        UserDefaults.standard.set(false, forKey: "voiceMuted")
        let clips = ["chime-done", "chime-yes"].compactMap { Bundle.main.url(forResource: $0, withExtension: "mp3") }
        let lines =
            (try? FileManager.default.contentsOfDirectory(at: Bundle.main.resourceURL!, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mp3" && !$0.lastPathComponent.hasPrefix("chime") }.prefix(8) ?? []
        let sounds = clips + lines
        guard !sounds.isEmpty else {
            print("FAIL no sounds in the bundle")
            return 1
        }
        var n = 0
        sp.stand = { _ in
            Thread.sleep(forTimeInterval: Double.random(in: 0.02...0.12))
            n &+= 1
            return sounds[n % sounds.count]
        }
        sp.standPlays = true
        sp.testVolume = 0
        sp.pretendReady()
        // ONE_SOAK_ROUTE=1: the line plays on the Mac's own speakers (nobody's listening there, volume 0), and their
        // format is switched back and forth every few seconds, the way a Bluetooth headset switches into call mode
        // and back around push to talk. Each switch is followed by what Listener.finish does after push to talk.
        let route = ProcessInfo.processInfo.environment["ONE_SOAK_ROUTE"] == "1" ? Route.builtInSpeakers() : nil
        if ProcessInfo.processInfo.environment["ONE_SOAK_ROUTE"] == "1" && route == nil {
            print("FAIL no built-in speakers to switch")
            return 1
        }
        sp.testDevice = route?.id
        sp.wakeAudio()
        sp.rebuild()
        var flips = 0
        let flipper = Task { @MainActor in
            guard let r = route else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 1200...4000)))
                flips += 1
                r.setRate(flips % 2 == 0 ? r.original : (r.original == 48000 ? 44100 : 48000))
                sp.rebuildSoon(after: 1.8, why: "soak: push to talk ended")  // what Listener.finish does
            }
        }
        let window = liveWindow(m)
        // The floating orb too (it reads the voice on its own), in the same off-screen world.
        let orb = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -9000, y: 0), size: CGSize(width: 150, height: 150)), styleMask: [.borderless],
            backing: .buffered, defer: false)
        orb.isReleasedWhenClosed = false
        orb.contentView = NSHostingView(rootView: FloatingOrb(state: .working))
        orb.orderFront(nil)
        let end = Date().addingTimeInterval(minutes * 60)
        let t0 = Date()
        var rounds = 0
        var sends = 0
        var spawned = 0
        var lastReport = Date()
        while Date() < end {
            rounds += 1
            switch Int.random(in: 0..<60) {
            case 0..<3 where !m.thinking:
                sends += 1
                Task { await m.send("STRESSLONG n=\(Int.random(in: 3...8)) secs=\(Int.random(in: 1...4))") }
            case 3 where !m.thinking:
                spawned += 1
                Task { await m.send("STRESSSPAWN \(Int.random(in: 2...5)) prefix=S\(spawned)x secs=1,2,4") }
            case 4: sp.hushReply()
            case 5, 6: if let c = clips.randomElement() { sp.enqueue(c) }
            case 7: sp.rebuild()
            case 8: sp.ensureRoute()
            case 9: sp.hush()
            case 10:
                if let h = m.helpers.filter({ $0.state != "working" }).randomElement() {
                    m.focusHelper(h.id)
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 50...400)))
                    m.focusHelper(h.id)
                }
            case 11: m.clearAway()
            case 12:
                // Keep the screen about as full as a busy day, not ever-growing.
                for h in m.helpers.filter({ $0.state != "working" }).prefix(max(0, m.helpers.count - 24)) { m.closeHelper(h.id) }
                if m.bubbles.count > 60 { m.bubbles.removeFirst(m.bubbles.count - 40) }
            case 14,
                15 where m.helpers.filter({ $0.state == "working" }).count < 12:
                spawned += 1
                m.spawnHelper(title: "D\(spawned)", task: "STRESSJOB D\(spawned) secs=\(Int.random(in: 1...6))")
            case 13:
                let s = NSSize(width: Double.random(in: 900...1300), height: Double.random(in: 800...1300))
                window.setFrame(NSRect(origin: window.frame.origin, size: s), display: true)
            default: break
            }
            if Date().timeIntervalSince(lastReport) > 30 {
                lastReport = Date()
                print(
                    String(
                        format: "   [%4.0fs] rounds %d, replies %d, helper batches %d, helpers %d, sentences %d, switches %d, frames %d, %@",
                        Date().timeIntervalSince(t0), rounds, sends, spawned, m.helpers.count, sp.reached, flips, ticks, sp.state))
                fflush(stdout)
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...120)))
        }
        flipper.cancel()
        route?.setRate(route?.original ?? 48000)  // the speakers' format exactly as it was
        sp.hush()
        orb.orderOut(nil)
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(500))
        print(
            "soak ok: \(rounds) rounds, \(sends) replies, \(spawned) helper batches, \(sp.reached) sentences on the line, \(flips) route switches, "
                + "\(ticks) orb frames, \(sp.state)")
        return 0
    }

    /// The real home screen, live, in an off-screen window (nothing shows on the person's screen).
    @MainActor
    static func liveWindow(_ m: Model) -> NSWindow {
        let size = CGSize(width: 1180, height: 1100)
        let view = HomeView(m: m).frame(minWidth: 800, minHeight: 700).background(HomeBackdrop(outer: true))
            .overlay(TimelineView(.animation) { tl in Color.clear.onChange(of: tl.date) { SoakCheck.ticks += 1 } })
            .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark)
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.orderFront(nil)
        return w
    }
}

/// The Mac's own speakers, for switching their format in `--test-soak` (restored at the end).
struct Route {
    let id: AudioDeviceID
    let original: Double

    static func builtInSpeakers() -> Route? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var t = UInt32(0)
            var ts = UInt32(MemoryLayout<UInt32>.size)
            var ta = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ta, 0, nil, &ts, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sa = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ss = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { continue }
            return Route(id: id, original: rate(id))
        }
        return nil
    }

    static func rate(_ id: AudioDeviceID) -> Double {
        var r = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &r)
        return r
    }

    func setRate(_ hz: Double) {
        var r = Float64(hz)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
    }
}
