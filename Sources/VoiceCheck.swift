import Foundation

/// `One --test-voice`: proves that stopping the voice just this once (Esc, or a click on the orb while it
/// talks) drops the rest of that reply's sentences, never turns the mute on, and lets the next reply speak.
/// Run with ONE_SUPPORT_DIR set to an empty folder. The voice process is a stand-in (no Kokoro, no sound)
/// and the mute is read from the test's own settings, so the person's real settings are only read, never written.
enum VoiceCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        check("runs as a command-line tool with its own settings", Env.commandLine && Env.selfTest && Speaker.prefs != .standard)
        let suite = Speaker.prefs
        suite.set(false, forKey: "voiceMuted")
        let realBefore = UserDefaults.standard.object(forKey: "voiceMuted") as? Bool
        let sp = Speaker.shared
        // The stand-in makes each sentence slowly, so a hush lands while most are still being made.
        sp.stand = { text in
            Thread.sleep(forTimeInterval: text.hasPrefix("One") ? 0.05 : 0.4)
            return nil
        }
        func settle(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

        // Sentences are grouped up to 160 characters, so these long ones make replies of several parts.
        let pad = " This sentence is long on purpose so that the next one is spoken on its own."
        func reply(_ heads: [String]) -> String { heads.map { $0 + pad }.joined(separator: " ") }
        let first = reply(["One is first.", "Two comes next.", "Three is here.", "Four is last."])
        let second = reply(["One more reply.", "And its second line."])
        let n2 = Speaker.spoken(second).count
        check("the test replies have several parts (\(Speaker.spoken(first).count), \(n2))", Speaker.spoken(first).count >= 3 && n2 >= 2)
        var started = 0
        let base = sp.reached
        sp.read(first) { started += 1 }
        await settle(0.3)
        check("a reply starts speaking", started == 1 && sp.reached - base == 1)
        sp.hushReply()
        await settle(2.0)
        check("hush drops the rest of that reply", sp.reached - base == 1)
        check("hush never turns the mute on", !suite.bool(forKey: "voiceMuted"))
        check("nor the person's own mute setting", (UserDefaults.standard.object(forKey: "voiceMuted") as? Bool) == realBefore)

        var next = 0
        let base2 = sp.reached
        sp.read(second) { next += 1 }
        // The dropped sentences may still be made first (the stand-in makes them one by one), so give it time.
        for _ in 0..<40 where sp.reached - base2 < n2 { await settle(0.1) }
        await settle(0.5)
        check("the next reply is spoken, every sentence (\(next), \(sp.reached - base2))", next == 1 && sp.reached - base2 == n2)

        suite.set(true, forKey: "voiceMuted")
        var muted = 0
        let base3 = sp.reached
        sp.read("One line while muted.") { muted += 1 }
        await settle(0.5)
        check("the real mute still keeps it quiet", muted == 1 && sp.reached == base3)

        sp.stand = nil
        UserDefaults.standard.removePersistentDomain(forName: "ai.forjado.one.voice-test")
        print(fails == 0 ? "voice ok" : "voice FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
