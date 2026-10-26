import AVFoundation
import AppKit
import SwiftUI

/// `One --render-orb-voice <clip.wav> <out dir>`: draws the world frame by frame (30 fps) driven by the same
/// sound analysis the live orb uses (VoiceTrack), so the frames can be put back together with the clip
/// to check the rings move with the voice.
@MainActor
enum OrbVoiceRender {
    static func run(clip: String, out: String) {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: clip)),
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
            (try? f.read(into: b)) != nil
        else {
            print("can't read \(clip)")
            return
        }
        let start = Date()
        var track = VoiceTrack()
        track.add(b, at: start)
        let frames = Int(Double(f.length) / f.processingFormat.sampleRate * 30)
        for i in 0..<frames {
            let t = 30 + Double(i) / 30
            let v = WorldCanvas(
                t: t, lit: nil, picking: false, linked: [:], speaking: false, wave: track.wave(at: start.addingTimeInterval(Double(i) / 30))
            )
            .frame(width: WorldLook.W, height: WorldLook.H).background(WorldLook.bg)
            let r = ImageRenderer(content: v)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            {
                try? png.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, i)))
            }
        }
        print("wrote \(frames) frames, \(track.clips.first?.words.count ?? 0) words")
    }
}

/// `One --render-orb-working <out dir> [voice.wav]`: about 4.4 s of Working (the orb breathes, the step line
/// crossfades through plain-words steps made by `Plain.step`), then Speaking driven by the clip, at 30 fps.
/// Left: the home orb with its step line. Right: the floating orb with its hint.
@MainActor
enum OrbWorkingRender {
    static let steps = [
        "web_search: flights Philadelphia to Quebec City December",
        "terminal: python3 compare_flight_prices.py --top 3",
        "terminal: ls ~/Documents/My Brain/personal-room",
        "terminal: git push origin main",
    ]
    static let workFor = 4.4
    static func run(out: String, clip: String?) {
        let start = Date()
        var track = VoiceTrack()
        var speakFor = 2.5
        if let clip, let f = try? AVAudioFile(forReading: URL(fileURLWithPath: clip)),
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
            (try? f.read(into: b)) != nil
        {
            track.add(b, at: start.addingTimeInterval(workFor + 0.3))
            speakFor = min(4.5, Double(f.length) / f.processingFormat.sampleRate)
        }
        let frames = Int((workFor + 0.3 + speakFor) * 30)
        for i in 0..<frames {
            let s = Double(i) / 30
            let wave = track.clips.isEmpty ? VoiceWave.still : track.wave(at: start.addingTimeInterval(s))
            let png = frame(s: s, wave: wave)
            try? png?.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, i)))
        }
        print("wrote \(frames) frames (\(workFor) s working, then speaking)")
    }
    /// 1 while working; eases out over 0.3 s when the reply starts.
    static func work(_ s: Double) -> Double { s < workFor ? 1 : max(0, 1 - (s - workFor) / 0.3) }
    /// Step text and its opacity: each step shows 1.1 s, fading out then in over 0.19 s each way.
    static func step(_ s: Double) -> (String, Double) {
        let k = min(steps.count - 1, Int(s / 1.1))
        let into = s - Double(k) * 1.1
        let out = 1.1 - into
        let a = min(1, into / 0.19, k == steps.count - 1 ? 1 : out / 0.19)
        return (Plain.step(steps[k]), max(0, a))
    }
    static func frame(s: Double, wave: VoiceWave) -> Data? {
        let t = 30 + s
        let w = work(s)
        let (text, a) = step(s)
        let v = HStack(spacing: 40) {
            VStack(spacing: 6) {
                Presence(t: t, lean: .zero, voice: 0, energy: 0, wave: wave, work: w)
                    .frame(width: 280, height: 280).scaleEffect(92 / 100).frame(width: 184 * 1.4, height: 220)
                Text(w > 0.5 ? text : " ").foregroundStyle(WorldLook.cream.opacity(0.62)).opacity(a).frame(height: 20)
            }
            .frame(width: 330)
            VStack(spacing: 18) {
                FloatingOrb(state: w > 0.5 ? .working : .idle, size: 72, fixedT: t, fixedWork: w)
                FloatHint(text: w > 0.5 ? text : "Hold to talk · Double-click to open").opacity(w > 0.5 ? a : 1)
            }
            .frame(width: 260)
        }
        .frame(width: 680, height: 340).background(WorldLook.bg).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: v)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
