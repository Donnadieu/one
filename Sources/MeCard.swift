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

/// Tap the assistant's name: one small card with its brain and its voice. Nothing else.
struct MeCard: View {
    @ObservedObject var m: Model
    var close: () -> Void = {}
    @State var model: String = MeCard.currentModel()
    @State var voice: String = Speaker.voiceID
    @State var gender: String = Speaker.voiceID.hasPrefix("am") || Speaker.voiceID.hasPrefix("bm") ? "Male" : "Female"
    @State var anyModel = false
    @State var search = ""
    @State var busy = false
    @AppStorage("voiceMuted") var muted = false
    static let voices: [String: [(String, String)]] = [
        "Female": [("af_heart", "Warm"), ("af_bella", "Bright"), ("bf_emma", "British")],
        "Male": [("am_michael", "Calm"), ("am_fenrir", "Deep"), ("bm_george", "British")],
    ]
    static func currentModel() -> String {
        let y = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for l in y.split(separator: "\n") where l.trimmingCharacters(in: .whitespaces).hasPrefix("default:") {
            return l.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return ""
    }
    var provider: Provider { Provider(rawValue: m.providerRaw) ?? .claude }
    static func allOpenRouter() -> [String] {
        guard let d = try? Data(contentsOf: Env.hermesHome.appendingPathComponent("models_dev_cache.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let o = j["openrouter"] as? [String: Any], let ms = o["models"] as? [String: Any]
        else { return [] }
        return ms.keys.sorted()
    }
    func pill(_ t: String, _ on: Bool, sub: String? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 2) {
                Text(t).font(.system(size: 13.5, weight: .medium))
                if let sub { Text(sub).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45)).lineLimit(1) }
            }
            .foregroundStyle(on ? .white : WorldLook.cream.opacity(0.8))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(on ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WorldLook.cream.opacity(on ? 0.55 : 0.1), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    Text("To rename me, just ask.").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.5))
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BRAIN").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Text(provider.title).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.45))
                }
                HStack(spacing: 8) {
                    ForEach(provider.tiers, id: \.1) { t in pill(t.0, model == t.1, sub: t.1) { pick(t.1) } }
                }
                if provider == .openrouter {
                    Button(anyModel ? "Hide the full list" : "Pick any model…") { anyModel.toggle() }.buttonStyle(.plain)
                        .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    if anyModel {
                        TextField("Search, e.g. gemini, llama, gpt", text: $search).textFieldStyle(.roundedBorder)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(
                                    MeCard.allOpenRouter().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.prefix(60),
                                    id: \.self
                                ) { id in
                                    Button {
                                        pick(id)
                                    } label: {
                                        HStack {
                                            Text(id).font(.system(size: 12.5))
                                            Spacer()
                                            if model == id { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .buttonStyle(.plain).foregroundStyle(WorldLook.cream.opacity(0.85))
                                }
                            }
                        }.frame(height: 140)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("VOICE").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Button {
                        muted.toggle()
                        if muted { Speaker.shared.stop() }
                    } label: {
                        Label(muted ? "Muted" : "Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(muted ? 0.9 : 0.5))
                }
                HStack(spacing: 8) {
                    ForEach(["Female", "Male"], id: \.self) { g in
                        pill(g, gender == g) {
                            gender = g
                            let v = MeCard.voices[g]![0].0
                            choose(v)
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(MeCard.voices[gender]!, id: \.0) { v in
                        pill(v.1, voice == v.0, sub: voice == v.0 ? "✓ chosen" : "▶ hear it") { choose(v.0) }
                    }
                }
            }.opacity(muted ? 0.45 : 1)
            HStack {
                Spacer()
                Button("Done") { close() }.buttonStyle(.plain).font(.system(size: 13.5, weight: .medium)).foregroundStyle(
                    WorldLook.cream.opacity(0.7))
            }
        }
        .padding(22).frame(width: 420)
        .background(WorldLook.bg)
        .preferredColorScheme(.dark)
    }
    func choose(_ v: String) {
        voice = v
        Speaker.shared.use(voice: v, sample: muted ? nil : "Hi \(m.userName.isEmpty ? "there" : m.userName), this is how I'll sound.")
    }
    func pick(_ id: String) {
        guard id != model, !busy else { return }
        model = id
        busy = true
        Task { @MainActor in
            _ = await hermesRun(["config", "set", "model.default", id])
            _ = await Engine.shared.start()
            busy = false
        }
    }
}
