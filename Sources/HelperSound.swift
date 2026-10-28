import Foundation

// MARK: - The helper sound: One's organ swell when a helper's orb turns orange

/// Plays with the orange pulse: the organ swell when a helper is done, the organ "question" when it needs a yes.
/// It goes on the voice's always-running audio line (so Bluetooth is awake and doesn't swallow the start), after
/// any sentence being spoken, and plays with One in the background. Never while push to talk listens, never when
/// muted, and one sound for helpers finishing together.
@MainActor
enum HelperSound {
    enum Decision: Equatable { case play, muted, listening, tooSoon }

    /// Helpers finishing within this many seconds of the last sound make no second sound (the pulse still shows).
    static let quietGap: TimeInterval = 4

    static func decide(muted: Bool, listening: Bool, sinceLast: TimeInterval) -> Decision {
        if muted { return .muted }
        if listening { return .listening }
        if sinceLast < quietGap { return .tooSoon }
        return .play
    }

    private static var last = Date.distantPast
    private static var gathering = false
    private static var wantsYes = false
    /// Sounds that passed every rule (self-tests count them; there they make no sound).
    private(set) static var rung: [String] = []
    /// A sound is still being gathered (self-tests wait on this instead of a fixed pause; slow CI runners need it).
    static var gatheringNow: Bool { gathering }

    /// A helper's orb just turned orange. Waits a moment so helpers finishing together make one sound
    /// (the "needs your yes" one wins), and waits for a sentence being spoken to end.
    static func ring(needsYes: Bool) {
        wantsYes = wantsYes || needsYes
        guard !gathering else { return }
        gathering = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<80 where Speaker.shared.talking { try? await Task.sleep(for: .milliseconds(250)) }
            let yes = wantsYes
            wantsYes = false
            gathering = false
            play(needsYes: yes)
        }
    }

    private static func play(needsYes: Bool) {
        let d = decide(
            muted: Speaker.prefs.bool(forKey: "voiceMuted"), listening: Listener.shared.listening,
            sinceLast: Date().timeIntervalSince(last))
        guard d == .play else { return }
        last = Date()
        let name = needsYes ? "chime-yes" : "chime-done"
        rung.append(name)
        guard !Env.selfTest, Speaker.shared.stand == nil, let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        Speaker.shared.enqueue(url)
    }
}
