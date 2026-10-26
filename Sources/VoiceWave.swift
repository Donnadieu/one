import AVFoundation
import Foundation

/// What the assistant's voice is doing at one moment, measured from the sound being played
/// (never guessed from the text). Drives the orb's rings and the waves that leave it.
struct VoiceWave {
    /// Loudness now, 0...1.
    var now: Double = 0
    /// Loudness 0.05 s, 0.10 s, … ago (newest first). Each ring hears the voice a moment after the one inside it.
    var past: [Double] = []
    /// Recent word starts: how long ago (s) and how loud. Each sends one soft wave outward.
    var words: [(age: Double, amp: Double)] = []
    /// True while a voice clip is playing (also in the short gaps between words).
    var live = false
    static let still = VoiceWave()
    func ago(_ i: Int) -> Double { i <= 0 ? now : (i - 1 < past.count ? past[i - 1] : 0) }
}

/// The loudness of every clip that is playing or about to play, lined up with when it is heard.
struct VoiceTrack {
    struct Clip {
        let start: Date
        let env: [Float]  // loudness every 10 ms
        let words: [(at: Double, amp: Double)]
        var end: Date { start.addingTimeInterval(Double(env.count) / VoiceTrack.rate) }
    }
    static let rate = 100.0
    var clips: [Clip] = []

    mutating func add(_ b: AVAudioPCMBuffer, at start: Date) {
        clips.removeAll { $0.end < Date().addingTimeInterval(-3) }
        let (env, words) = VoiceTrack.envelope(b)
        clips.append(Clip(start: start, env: env, words: words))
    }

    /// Loudness (RMS, smoothed like a voice meter: quick to rise, slower to fall) and the start of each word.
    static func envelope(_ b: AVAudioPCMBuffer) -> ([Float], [(at: Double, amp: Double)]) {
        guard let ch = b.floatChannelData?[0] else { return ([], []) }
        let n = Int(b.frameLength)
        let hop = max(1, Int(b.format.sampleRate / rate))
        var env: [Float] = []
        var s: Float = 0
        var i = 0
        while i < n {
            let m = min(hop, n - i)
            var sum: Float = 0
            for j in 0..<m { sum += ch[i + j] * ch[i + j] }
            let r = min(1, (sum / Float(m)).squareRoot() * 5)
            s += (r - s) * (r > s ? 0.28 : 0.12)
            env.append(s)
            i += hop
        }
        return (env, wordStarts(env))
    }

    /// A word (or stressed syllable) starts when the voice rises clearly above its recent low,
    /// at most one every 0.15 s. Spoken words rarely go fully quiet, so silence alone misses most of them.
    static func wordStarts(_ env: [Float]) -> [(at: Double, amp: Double)] {
        var out: [(at: Double, amp: Double)] = []
        var low: Float = 0
        var armed = true
        var last = -100
        for (k, v) in env.enumerated() {
            low = min(low + 0.004, v)
            if v < low + 0.04 { armed = true }
            if armed && v > low + 0.12 && v > 0.15 && k - last >= 15 {
                let peak = env[k..<min(env.count, k + 15)].max() ?? v
                out.append((Double(k) / rate, Double(peak)))
                armed = false
                last = k
            }
        }
        return out
    }

    func level(_ t: Date) -> Double {
        for c in clips {
            let i = Int(t.timeIntervalSince(c.start) * VoiceTrack.rate)
            if i >= 0 && i < c.env.count { return Double(c.env[i]) }
        }
        return 0
    }

    /// The voice as heard at `t` (callers subtract the speaker's own delay first).
    func wave(at t: Date) -> VoiceWave {
        guard !clips.isEmpty else { return .still }
        var w = VoiceWave(now: level(t), past: (1...8).map { level(t.addingTimeInterval(-Double($0) * 0.05)) })
        for c in clips {
            if t >= c.start && t <= c.end.addingTimeInterval(0.3) { w.live = true }
            for word in c.words {
                let age = t.timeIntervalSince(c.start) - word.at
                if age >= 0 && age < 1.6 { w.words.append((age, word.amp)) }
            }
        }
        return w
    }
}
