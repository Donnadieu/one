import AVFoundation
import AppKit

// MARK: - Check: the real audio line under load (`One --test-voice-stress [seconds]`)
//
// One 0.9.32, 0.9.50, 0.9.83 and 0.9.84 crashed with heap corruption ("memory corruption of free block",
// "pointer being freed was not allocated"), always with the voice's audio line up. This drives the REAL line
// (AVAudioEngine + player node, the bundled chimes and setup lines; no stand-in) the way the app does, from the
// threads the app does it from: replies read and hushed, helper chimes, the line rebuilt (Bluetooth call mode,
// a new output device), `sayNow` from a background task (setup, Connections, quitting with routines at work),
// the orb reading `heard()` 60 times a second. Build it with `-sanitize=thread` or `-sanitize=address`
// (tools/sanitizer-check.sh) to prove the line has no data race and no use-after-free.
// Run with ONE_SUPPORT_DIR set to an empty folder; the line plays at volume 0 and no window opens.
enum VoiceStress {
    nonisolated static func main(_ args: [String]) {
        guard let k = args.firstIndex(of: "--test-voice-stress") else { return }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        let secs = k + 1 < args.count ? Double(args[k + 1]) ?? 20 : 20
        NSApplication.shared.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            Task { @MainActor in exit(await run(seconds: secs)) }
        }
        NSApplication.shared.run()
    }

    @MainActor
    static func run(seconds: Double) async -> Int32 {
        let sp = Speaker.shared
        Speaker.prefs.set(false, forKey: "voiceMuted")
        let clips = ["chime-done", "chime-yes"].compactMap { Bundle.main.url(forResource: $0, withExtension: "mp3") }
        let lines =
            (try? FileManager.default.contentsOfDirectory(at: Bundle.main.resourceURL!, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mp3" && !$0.lastPathComponent.hasPrefix("chime") }.prefix(6) ?? []
        guard !clips.isEmpty else {
            print("FAIL no chimes in the bundle")
            return 1
        }
        let sounds = clips + lines
        // The voice: makes each sentence on its own queue like Kokoro does, then hands back a real sound to play.
        var n = 0
        sp.stand = { _ in
            Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.08))
            n &+= 1
            return sounds[n % sounds.count]
        }
        sp.standPlays = true
        sp.testVolume = 0  // the whole line runs and renders; nobody hears it
        sp.pretendReady()  // so sayNow really speaks, as it does with Kokoro up
        sp.wakeAudio()
        let reply = (1...6).map { "Sentence \($0) is long on purpose so that it is spoken on its own and not grouped with the next one." }
            .joined(separator: " ")
        let end = Date().addingTimeInterval(seconds)
        var rounds = 0
        // The orb: reads the voice 60 times a second, like Orb / FloatingOrb's TimelineView.
        let orb = Task { @MainActor in
            while !Task.isCancelled {
                _ = sp.heard()
                _ = sp.busy
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        while Date() < end {
            rounds += 1
            // Mostly replies left to play out (like real use); now and then everything else the app does to the line.
            switch Int.random(in: 0..<40) {
            case 0..<4: sp.read(reply)
            case 4: sp.hushReply()
            case 5, 6: HelperSound.ring(needsYes: Bool.random())
            case 7, 8: sp.enqueue(clips.randomElement()!)
            case 9: sp.rebuild()  // .AVAudioEngineConfigurationChange, and 0.6 s / 1.8 s after push to talk
            case 10: sp.ensureRoute()
            case 11, 12: Task.detached { _ = await sp.sayNow("Got it. I can see your calendar now.") }  // Connections, QuitHold
            case 13: sp.stop()
            default: break
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...80)))
        }
        orb.cancel()
        sp.hush()
        try? await Task.sleep(for: .milliseconds(500))
        print("voice-stress ok: \(rounds) rounds, \(sp.reached) sentences reached the line, \(sp.state)")
        return 0
    }
}
