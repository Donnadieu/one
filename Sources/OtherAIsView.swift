import AppKit
import SwiftUI

/// "Other AIs" (Direction B, Omar's pick Nov 9 2026): every AI the engine takes a key for, in two-column tiles under
/// small group labels, then a three-step key card (get a key, paste it, check it). Lives inside Switch AI and the
/// first-run pick screen. The list comes from the engine (`AICatalog`), never from One.
struct OtherAIsView: View {
    @ObservedObject var m: Model
    let back: () -> Void
    var close: () -> Void = {}
    @State private var all: [EngineAI] = OtherAIsView.still?.list ?? []
    @State private var loading = OtherAIsView.still == nil
    @State private var picked: EngineAI?
    /// Renders only: the list and the open key card, so a still capture needs no engine.
    nonisolated(unsafe) static var still: (list: [EngineAI], picked: EngineAI?, stage: OtherAIKeyView.Stage)?

    var body: some View {
        Group {
            if let p = picked ?? OtherAIsView.still?.picked {
                OtherAIKeyView(m: m, ai: p, back: { picked = nil }, done: close)
            } else {
                list
            }
        }
        .task {
            guard OtherAIsView.still == nil else { return }
            all = AICatalog.offered(await AICatalog.providers())
            loading = false
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                HStack {
                    Button(action: back) { Text("‹ Back").font(.system(size: 13.5)) }.buttonStyle(.plain)
                        .foregroundStyle(WorldLook.cream.opacity(0.75))
                    Spacer()
                }
                Text("Other AIs").font(.title2)
            }
            Text(
                "Each of these needs its own key from that company, and I give less help setting them up. If you pay for Claude, ChatGPT or Grok, use those instead."
            )
            .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            if loading {
                HStack(spacing: 8) {
                    if !SwitchAIPanel.renderStill { ProgressView().controlSize(.small) }
                    Text("Getting the list…").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.55))
                }.frame(maxWidth: .infinity, minHeight: 120)
            } else if all.isEmpty {
                Text("I couldn't read the list from my engine just now. Close this and try again in a moment.")
                    .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.7))
            } else if SwitchAIPanel.renderStill {
                tiles
            } else {
                ScrollView { tiles }.frame(maxHeight: 380)
            }
        }
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AICatalog.grouped(all), id: \.0) { g, rows in
                Text(g.rawValue.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(WorldLook.cream.opacity(0.5)).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(rows) { ai in tile(ai) }
                }
            }
        }
    }

    private func tile(_ ai: EngineAI) -> some View {
        Button {
            picked = ai
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ai.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    if m.providerRaw == ai.id { Text("Current").font(.caption2).foregroundStyle(WorldLook.cream.opacity(0.5)) }
                }
                if ai.has_key {
                    Text("Key added").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(WorldLook.cream.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle()).popupCard(12)
        }.buttonStyle(.plain)
    }
}

/// The key card: 1 Get a key · 2 Paste it · 3 Check it, each lighting up as it's done.
struct OtherAIKeyView: View {
    @ObservedObject var m: Model
    let ai: EngineAI
    let back: () -> Void
    let done: () -> Void
    enum Stage: Equatable {
        case idle, checking
        case result(OtherAIResult)
    }
    @State private var key = ""
    @State private var opened = false
    @State private var stage: Stage = .idle
    @State private var sent = false

    private var shown: Stage { OtherAIsView.still?.stage ?? stage }
    private var pasted: Bool { !key.isEmpty || sent || OtherAIsView.still.map { $0.stage != .idle } == true }
    private var works: Bool { if case .result(.works) = shown { true } else { false } }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: back) { Text("‹ Back").font(.system(size: 13.5)) }.buttonStyle(.plain)
                    .foregroundStyle(WorldLook.cream.opacity(0.75)).disabled(shown == .checking)
                Spacer()
            }
            VStack(spacing: 3) {
                Text("Add your \(ai.name) key").font(.system(size: 17, weight: .semibold))
                Text("It stays on this Mac.").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.55))
            }
            VStack(spacing: 0) {
                step(1, "Get a key", lit: opened || pasted || ai.has_key) { getKey }
                Divider().overlay(WorldLook.cream.opacity(0.08))
                step(2, "Paste it", lit: pasted && !isRefused) { field }
                Divider().overlay(WorldLook.cream.opacity(0.08))
                step(3, "Check it", lit: works, dim: !pasted && !ai.has_key) { check }
            }
            .popupCard(14)
            if works {
                HStack {
                    Spacer()
                    Button("Done", action: done).buttonStyle(CreamButton())
                }
            } else if shown == .idle {
                Button("Cancel", action: back).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.6))
            }
        }
    }

    private var isRefused: Bool { if case .result(.refused) = shown { true } else { false } }

    @ViewBuilder private var getKey: some View {
        if let u = URL(string: ai.key_page), !ai.key_page.isEmpty {
            Button {
                opened = true
                NSWorkspace.shared.open(u)
            } label: {
                Text("Open \(ai.name)'s key page ↗").underline().font(.system(size: 12.5))
            }.buttonStyle(.plain).foregroundStyle(WorldLook.cream.opacity(0.85))
        } else {
            Text("Make one on \(ai.name)'s website.").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
        }
    }

    @ViewBuilder private var field: some View {
        if SwitchAIPanel.renderStill {  // ImageRenderer can't draw a text field: a still of one
            Text(pasted ? String(repeating: "•", count: 28) : "Paste your key").font(.system(size: 12.5))
                .foregroundStyle(WorldLook.cream.opacity(pasted ? 0.8 : 0.4)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7).popupCard(8)
        } else {
            SecureField(ai.has_key ? "Key added. Paste a new one to change it" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder).disabled(shown == .checking || works)
                .onSubmit { if pasted { run() } }
        }
    }

    @ViewBuilder private var check: some View {
        switch shown {
        case .idle:
            Button(ai.has_key && key.isEmpty ? "Use it" : "Check and use it", action: run).buttonStyle(CreamButton(wide: true))
                .disabled(!pasted && !ai.has_key)
        case .checking:
            HStack(spacing: 8) {
                if !SwitchAIPanel.renderStill { ProgressView().controlSize(.small) }
                Text(m.switchWaitMessage ?? "Checking \(ai.name) answers…").font(.system(size: 12.5))
                    .foregroundStyle(WorldLook.cream.opacity(0.7))
                Spacer()
                if m.switchWaitMessage != nil {
                    Button("Cancel") { m.switchingAI = false }.buttonStyle(.plain).font(.system(size: 12))
                        .foregroundStyle(WorldLook.cream.opacity(0.55))
                }
            }
        case .result(let r):
            VStack(alignment: .leading, spacing: 6) {
                Text(r.line(ai.name)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if case .works(let model) = r {
                    Text(model).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.5))
                } else {
                    Button(r == .unreachable ? "Try again" : "Paste a different key") {
                        stage = .idle
                        if r == .unreachable { run() } else { sent = false }
                    }.buttonStyle(CreamButton(wide: true))
                    Text("I kept your old AI.").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.5))
                }
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, lit: Bool, dim: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if lit {
                    Circle().fill(WorldLook.cream.opacity(0.92))
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WorldLook.bg)
                } else {
                    Circle().strokeBorder(WorldLook.cream.opacity(dim ? 0.25 : 0.5), lineWidth: 1)
                    Text("\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(dim ? 0.4 : 0.8))
                }
            }.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(dim ? 0.45 : 0.95))
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func run() {
        guard shown != .checking else { return }
        let k = key.isEmpty ? nil : key
        sent = sent || k != nil
        stage = .checking
        Task { @MainActor in
            let r = await m.useOtherAI(ai, key: k)
            if r != .unreachable { key = "" }  // a key that couldn't be checked stays in the field for "Try again"
            stage = .result(r)
        }
    }
}

/// The key card's one button (design: cream fill, dark words; dim until it can work).
struct CreamButton: ButtonStyle {
    var wide = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? WorldLook.bg : WorldLook.cream.opacity(0.35))
            .frame(maxWidth: wide ? .infinity : nil).padding(.horizontal, 18).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled ? WorldLook.cream.opacity(configuration.isPressed ? 0.75 : 0.92) : WorldLook.cream.opacity(0.06)))
    }
}
