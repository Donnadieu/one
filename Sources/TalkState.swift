import AVFoundation
import Foundation

// MARK: - Push to talk: which turn a recognizer callback belongs to, and what to do when nothing came back
// Omar, Nov 17 2026: "speech-to-text… It's clunky. Sometimes it doesn't recognize my voice. Sometimes it says
// 'Didn't catch that', or it's red and it's not even sending stuff."
// Two causes found in Listener.swift (0.9.127):
// 1. Callbacks were never tied to their own press. Letting go waits up to 1.6 s for the recognizer's last word; a new
//    press in that time started a new recognition, and then the old press's late "final" (or its cancel, which the
//    recognizer also reports as final) landed on the new one: it was marked finished before he spoke, or the old
//    clean-up cancelled the new recognition and cleared it, so letting go found nothing ("I didn't catch that").
// 2. Recognition runs on the Mac only when the Mac can, which hears accents and quiet speech worse. When the Mac's
//    recognizer gives nothing back but the mic clearly heard speech, the same audio is now tried once more with
//    Apple's server recognizer before saying it didn't catch anything.

/// One press of push to talk at a time. A callback from an older press is dropped.
struct TalkState {
    private(set) var turn = 0
    private(set) var text = ""
    private(set) var gotFinal = false
    private(set) var peak = 0.0  // loudest the mic was during this press (0…1, as the level meter shows it)

    /// A new press: returns its number.
    mutating func start() -> Int {
        turn += 1
        text = ""
        gotFinal = false
        peak = 0
        return turn
    }
    /// A recognizer callback for press `n`. False when it belongs to an older press (and nothing changes).
    @discardableResult mutating func heard(_ n: Int, _ t: String?, final: Bool) -> Bool {
        guard n == turn else { return false }
        if let t { text = t }
        if final { gotFinal = true }
        return true
    }
    mutating func level(_ n: Int, _ v: Double) {
        guard n == turn else { return }
        peak = max(peak, v)
    }
}

/// What letting go does with what came back.
enum TalkOutcome: Equatable {
    case send(String)  // words came back: send them
    case tryServer  // nothing came back, but the mic heard speech and the Mac's own recognizer was used: try again
    case unclear  // the mic heard speech, but no recognizer made out words
    case nothing  // the mic heard nothing to speak of

    /// The level meter's scale (Listener.tap): ordinary speech near the mic reads 0.3 to 1, a quiet room under 0.1.
    static let speechLevel = 0.18

    var logLine: String {
        switch self {
        case .send: return "words came back"
        case .tryServer: return "nothing from the Mac's recognizer though it heard speech: trying Apple's server"
        case .unclear: return "heard speech, no words came back"
        case .nothing: return "nothing heard"
        }
    }

    static func after(text: String, peak: Double, onDevice: Bool) -> TalkOutcome {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return .send(t) }
        guard peak >= speechLevel else { return .nothing }
        return onDevice ? .tryServer : .unclear
    }
}

/// The audio of one press, kept so it can be heard again by another recognizer. Filled on the audio thread.
final class TalkTape: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0
    /// About 2 minutes at 48 kHz: longer presses keep their start (recognition of a very long press is rare anyway).
    static let maxFrames: AVAudioFrameCount = 48_000 * 120

    func reset() {
        lock.withLock {
            buffers = []
            frames = 0
        }
    }
    func add(_ b: AVAudioPCMBuffer) {
        guard let c = TalkTape.copy(b) else { return }
        lock.withLock {
            guard frames + c.frameLength <= TalkTape.maxFrames else { return }
            buffers.append(c)
            frames += c.frameLength
        }
    }
    var all: [AVAudioPCMBuffer] { lock.withLock { buffers } }
    var count: AVAudioFrameCount { lock.withLock { frames } }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let n = Int(b.frameLength)
        let chans = Int(b.format.channelCount)
        if let src = b.floatChannelData, let dst = c.floatChannelData {
            for ch in 0..<chans { dst[ch].update(from: src[ch], count: n) }
        } else if let src = b.int16ChannelData, let dst = c.int16ChannelData {
            for ch in 0..<chans { dst[ch].update(from: src[ch], count: n) }
        } else {
            return nil
        }
        return c
    }
}
