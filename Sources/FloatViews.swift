import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

/// The assistant itself: the same living rings as the world screen (Claude Design), so it looks
/// like one being everywhere. Breathes when idle, moves like a voice while it works.
struct Orb: View {
    var size: CGFloat = 130
    var active = false
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(WorldLook.start)
            let voice = active ? 0.35 + 0.65 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
            Presence(t: t, lean: .zero, voice: voice, energy: 0)
                .frame(width: 280, height: 280)
                .scaleEffect(size / 100)
                .frame(width: size * 2, height: size * 2)
        }
    }
}

// MARK: - Floating orb (One minimized)
// When One is minimized it becomes a small orb that floats above every window. Hold it to talk
// (let go to send), double-click to open the full window. It glows while One works.

enum FloatState { case idle, listening, working }

struct FloatingOrb: View {
    var state: FloatState
    var size: CGFloat = 72
    /// Fixed time for renders; nil = live animation.
    var fixedT: Double? = nil
    var body: some View {
        if let t = fixedT {
            face(t)
        } else {
            TimelineView(.animation) { tl in face(tl.date.timeIntervalSince(WorldLook.start)) }
        }
    }

    private func face(_ t: Double) -> some View {
        let listening = state == .listening
        let working = state == .working
        let voice: Double =
            listening
            ? 0.45 + 0.4 * abs(sin(t * 4.1) * sin(t * 2.3 + 0.7))
            : working ? 0.3 + 0.35 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
        let energy: Double = working ? 0.45 + 0.25 * sin(t * 2) : listening ? 0.2 : 0
        let k = size / 168  // outer ring (~68pt + wobble) fits inside the disc
        let glow = working ? 0.30 + 0.10 * sin(t * 2.2) : listening ? 0.26 : 0.10
        return ZStack {
            Circle().fill(WorldLook.bg.opacity(0.96))
                .overlay(
                    Circle().fill(
                        RadialGradient(
                            colors: [WorldLook.cream.opacity(listening ? 0.10 : 0.05), .clear],
                            center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.6)))
            Presence(t: t, lean: .zero, voice: voice, energy: energy, line: 1.5 / k)
                .frame(width: 280, height: 280)
                .scaleEffect(k)
                .frame(width: size, height: size)
                .clipShape(Circle())
            Circle().strokeBorder(WorldLook.cream.opacity(listening ? 0.30 : 0.07), lineWidth: 0.75)
            if working {
                // A soft light travelling around the edge: "busy" without a spinner.
                Circle()
                    .trim(from: 0, to: 0.36)
                    .stroke(
                        AngularGradient(
                            colors: [Color(hex: 0xFFE2C2, 0), Color(hex: 0xFFE2C2, 0.55), Color(hex: 0xFFF3E6, 1)],
                            center: .center, startAngle: .degrees(0), endAngle: .degrees(130)),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    .frame(width: size + 9, height: size + 9)
                    .rotationEffect(.degrees(t * 150 + 115))
            }
        }
        .frame(width: size, height: size)
        .background(
            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(hex: 0xFFF1E2, glow), Color(hex: 0xFFF1E2, glow * 0.3), .clear],
                        center: .center, startRadius: size * 0.45, endRadius: size * (working ? 0.82 : 0.7)))
                if listening {
                    // Two gentle ripples while it hears you.
                    ForEach(0..<2, id: \.self) { i in
                        let p = (t * 0.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(WorldLook.cream.opacity(0.55 * (1 - p)), lineWidth: 1.5 - 0.7 * p)
                            .frame(width: size * (1.1 + 0.32 * p), height: size * (1.1 + 0.32 * p))
                    }
                }
            }
            .frame(width: size * 1.8, height: size * 1.8)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .scaleEffect(listening ? 1.08 : 1)
    }
}

/// Small plain-words label next to the orb.
struct FloatHint: View {
    let text: String
    var body: some View {
        Text(text)
            .lineLimit(3).multilineTextAlignment(.leading)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(WorldLook.cream.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: 0x1E1E22, 0.92)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .frame(maxWidth: 250, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What One is hearing while you hold the orb.
struct FloatTranscript: View {
    let text: String
    var level: Double = 0.6
    var t: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.4]
                        let h = 4 + 8 * shape[i] * (0.75 + 0.25 * level * abs(sin(t * 5 + Double(i) * 1.3)))
                        Capsule().fill(Color(hex: 0xFFE2C2, 0.9)).frame(width: 2, height: h)
                    }
                }.frame(height: 12)
                Text("Listening").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.7))
            }
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(WorldLook.cream)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Let go to send").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.62))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1E1E22, 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Render-only: the floating orb parked in the bottom-right corner of a sample dark desktop.
struct FloatScene: View {
    let state: FloatState
    var t: Double = 12.3
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(hex: 0x2A2F3D), Color(hex: 0x15161C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").fontWeight(.semibold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Text("Go")
                    Spacer()
                    Text("Fri 23 Oct  9:41")
                }
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14).frame(height: 24).background(Color.black.opacity(0.35))
                Spacer()
            }
            // A background window, for scale
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x23252C))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) {
                                Circle().fill(Color(hex: UInt32($0), 0.85)).frame(width: 10, height: 10)
                            }
                        }
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)).frame(
                                width: [220, 180, 240, 150, 200, 120][i], height: 9)
                        }
                    }.padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .frame(width: 330, height: 200)
                .position(x: 200, y: 150)
            HStack(alignment: .center, spacing: state == .listening ? 26 : 18) {
                switch state {
                case .idle: FloatHint(text: "Hold to talk · Double-click to open")
                case .listening: FloatTranscript(text: "Move my call with Dana to Thursday at 3, and let her know", level: 0.7, t: t)
                case .working: FloatHint(text: "Moving your call with Dana…")
                }
                FloatingOrb(state: state, size: 72, fixedT: t)
            }
            .padding(.trailing, 44).padding(.bottom, 44)
        }
        .environment(\.colorScheme, .dark)
    }
}
