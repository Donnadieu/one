import SwiftUI

/// The card's BRAIN part (Direction B, Omar's pick Nov 9 2026): three pills that also set how hard the AI thinks,
/// with "More options" opening the thinking levels that model really has. An Other AI or a local model has no
/// three pills: its model shows as one row with "Pick another model…".
struct BrainSection: View {
    @ObservedObject var m: Model
    @State private var model = BrainSection.still?.model ?? MeCard.currentModel()
    @State private var effort = BrainSection.still.map(\.effort) ?? Effort.current()
    @State private var byHand = BrainSection.still?.byHand ?? Effort.byHand
    @State private var levels: [String: [Effort]] = BrainSection.still?.levels ?? [:]
    @State private var open = BrainSection.still?.open ?? false
    @State private var anyModel = false
    @State private var search = ""
    @State private var others: [String] = []
    @State private var aiName = BrainSection.still?.name ?? ""
    @State private var busy = false
    /// Renders only: what the engine would have said, and the disclosure open or not.
    nonisolated(unsafe) static var still: (model: String, levels: [String: [Effort]], effort: Effort?, open: Bool, byHand: Bool, name: String)?

    private var builtIn: Provider? { Provider(rawValue: m.providerRaw) ?? (m.providerRaw.isEmpty ? .claude : nil) }
    private var engineID: String { builtIn?.hermesID ?? (m.providerRaw == "local" ? "custom" : m.providerRaw) }
    private var tiers: [(String, String)] { builtIn?.tiers ?? [] }
    private var here: [Effort] { m.providerRaw == "local" ? [] : levels[model] ?? [] }
    private var tierIndex: Int? { tiers.firstIndex { $0.1 == model } }
    private var shownEffort: Effort? {
        guard let e = effort, !here.isEmpty else { return nil }
        if here.contains(e) { return e }
        let order = Effort.allCases
        return here.last { order.firstIndex(of: $0)! <= order.firstIndex(of: e)! && $0 != .off } ?? here.first { $0 != .off }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BRAIN").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                Spacer()
                Text(builtIn?.title ?? (aiName.isEmpty ? (m.providerRaw == "local" ? "On this Mac" : m.providerRaw) : aiName))
                    .font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.45))
            }
            if tiers.isEmpty { oneRow } else { pills }
            if builtIn == .openrouter || (builtIn == nil && m.providerRaw != "local") { anyModelList }
            Button {
                open.toggle()
            } label: {
                Text(open ? "More options ⌄" : "More options ›").font(.system(size: 12.5))
            }.buttonStyle(.plain).foregroundStyle(WorldLook.cream.opacity(0.6))
            if open { thinking }
        }
        .disabled(busy)
        .task { await load() }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            ForEach(Array(tiers.enumerated()), id: \.1.1) { i, t in
                let lv = levels[t.1]
                let sub = lv.map { t.1 + "\n" + Effort.pillLine(Effort.preset(tier: i, levels: $0), levels: $0) } ?? t.1
                MeCard.pillView(t.0, model == t.1, sub: sub, dot: byHand && model == t.1) { pick(t.1, tier: i) }
            }
        }
    }

    private var oneRow: some View {
        Text(model.isEmpty ? "—" : model).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WorldLook.cream.opacity(0.55), lineWidth: 1))
    }

    @ViewBuilder private var anyModelList: some View {
        Button(anyModel ? "Hide the full list" : "Pick another model…") {
            anyModel.toggle()
            if anyModel && others.isEmpty && builtIn == nil { Task { others = await AICatalog.models(engineID) } }
        }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
        if anyModel {
            let all = builtIn == .openrouter ? MeCard.allOpenRouter() : others
            TextField("Search, e.g. gemini, llama, gpt", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(all.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.prefix(60), id: \.self) { id in
                        Button {
                            pick(id, tier: nil)
                        } label: {
                            HStack {
                                Text(id).font(.system(size: 12.5))
                                Spacer()
                                if model == id { Image(systemName: "checkmark") }
                            }
                        }.buttonStyle(.plain).foregroundStyle(WorldLook.cream.opacity(0.85))
                    }
                }
            }.frame(height: 140)
        }
    }

    @ViewBuilder private var thinking: some View {
        Divider().overlay(WorldLook.cream.opacity(0.1))
        Text("Thinking").font(.system(size: 13, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(here.isEmpty ? 0.4 : 0.9))
        if here.isEmpty {
            Text("This brain doesn't have thinking levels.").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
        } else {
            VStack(spacing: 5) {
                ForEach(here) { e in
                    Button {
                        choose(e)
                    } label: {
                        HStack(spacing: 0) {
                            Text(e.word).font(.system(size: 12.5, weight: .semibold)).frame(width: 82, alignment: .leading)
                            Text(e.meaning).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.6))
                            Spacer()
                        }
                        .foregroundStyle(WorldLook.cream.opacity(shownEffort == e ? 1 : 0.8))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(WorldLook.cream.opacity(shownEffort == e ? 0.12 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(WorldLook.cream.opacity(shownEffort == e ? 0.55 : 0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Text(why).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        Text("Helpers and routines use this too.").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.4))
    }

    private var why: String {
        let tail = "Higher thinks longer and more carefully, but answers slower."
        if byHand { return "You changed this by hand. Picking a brain above resets it." }
        if let i = tierIndex, let e = shownEffort { return "\(tiers[i].0) set this to \(e.word). " + tail }
        return tail
    }

    private func load() async {
        guard BrainSection.still == nil else { return }
        let ids = tiers.isEmpty ? [model] : tiers.map(\.1)
        levels = await AICatalog.efforts(engineID, models: ids.filter { !$0.isEmpty })
        if builtIn == nil, m.providerRaw != "local" {
            aiName = (await AICatalog.providers()).first { $0.id == m.providerRaw }?.name ?? ""
        }
    }

    /// A brain pill (or a model from the list): the model, and the thinking level that goes with it, in one restart.
    private func pick(_ id: String, tier: Int?) {
        guard !busy, id != model || byHand else { return }
        busy = true
        Task { @MainActor in
            while !SwitchAI.ready(m.helpers, thinking: m.thinking) { try? await Task.sleep(for: .seconds(2)) }
            var lv = levels[id] ?? []
            if levels[id] == nil { lv = (await AICatalog.efforts(engineID, models: [id]))[id] ?? [] }
            levels[id] = lv
            let old = (model, effort)
            let next = Effort.preset(tier: tier ?? 1, levels: lv)
            let (status, _) = await hermesRun(["config", "set", "model.default", id])
            if let next { _ = await Effort.save(next) }
            if status == 0, await Engine.shared.start() == nil {
                model = id
                effort = next ?? effort
                byHand = false
                Effort.byHand = false
            } else {
                _ = await hermesRun(["config", "set", "model.default", old.0])
                if let e = old.1 { _ = await Effort.save(e) }
                _ = await Engine.shared.start()
                m.bubbles.append(Bubble(fromMe: false, text: "That AI didn't start. I kept the one you were using."))
            }
            busy = false
        }
    }

    /// A level picked by hand: saved for every new chat, helper and routine; the engine restarts so this chat has it too.
    private func choose(_ e: Effort) {
        guard !busy, e != shownEffort || !byHand else { return }
        busy = true
        Task { @MainActor in
            while !SwitchAI.ready(m.helpers, thinking: m.thinking) { try? await Task.sleep(for: .seconds(2)) }
            if await Effort.save(e) {
                effort = e
                byHand = true
                Effort.byHand = true
                _ = await Engine.shared.start()
            }
            busy = false
        }
    }
}
