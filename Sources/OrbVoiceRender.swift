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
