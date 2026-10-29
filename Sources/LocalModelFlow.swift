import Foundation
import SwiftUI

extension Model {
    /// Keep the current AI until a local choice has actually answered. A failed switch restores it.
    func chooseLocal(_ server: LocalServer, model: String) async -> String? {
        let (_, oldProvider) = await hermesRun(["config", "get", "model.provider"])
        let (_, oldModel) = await hermesRun(["config", "get", "model.default"])
        let (baseStatus, oldBase) = await hermesRun(["config", "get", "model.base_url"])
        let (contextStatus, oldContext) = await hermesRun(["config", "get", "model.context_length"])
        let previousProvider = oldProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousModel = oldModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousProvider.isEmpty, !previousModel.isEmpty else { return "I couldn't read your current AI, so I didn't change it." }
        if helpers.contains(where: { $0.state == "working" }) || thinking {
            switchWaitMessage = SwitchAI.waitMessage(for: "this local model", helpers: helpers, thinking: thinking)
        }
        while switchingAI && (helpers.contains(where: { $0.state == "working" }) || thinking) {
            try? await Task.sleep(for: .seconds(2))
        }
        switchWaitMessage = nil
        guard !onboarded || switchingAI else { return "The switch was cancelled." }
        func restore() async {
            _ = await hermesRun(["config", "set", "model.provider", previousProvider])
            _ = await hermesRun(["config", "set", "model.default", previousModel])
            if baseStatus == 0 {
                _ = await hermesRun(["config", "set", "model.base_url", oldBase.trimmingCharacters(in: .whitespacesAndNewlines)])
            } else {
                _ = await hermesRun(["config", "unset", "model.base_url"])
            }
            if contextStatus == 0 {
                _ = await hermesRun(["config", "set", "model.context_length", oldContext.trimmingCharacters(in: .whitespacesAndNewlines)])
            } else {
                _ = await hermesRun(["config", "unset", "model.context_length"])
            }
            _ = await Engine.shared.start()
        }
        let (providerStatus, providerError) = await hermesRun(["config", "set", "model.provider", "custom"])
        let (modelStatus, modelError) = await hermesRun(["config", "set", "model.default", model])
        let (urlStatus, urlError) = await hermesRun(["config", "set", "model.base_url", server.baseURL])
        let (contextSetStatus, contextError) = await hermesRun(["config", "set", "model.context_length", "65536"])
        guard providerStatus == 0, modelStatus == 0, urlStatus == 0, contextSetStatus == 0 else {
            await restore()
            let detail =
                [providerError, modelError, urlError, contextError].first { $0.lowercased().contains("error") } ?? "The settings couldn't be saved."
            return "I kept your old AI. \(String(detail.suffix(180)))"
        }
        if let problem = await Engine.shared.start() {
            await restore()
            return "I kept your old AI. The local model couldn't start: \(problem)"
        }
        let got = Box("")
        Engine.shared.onText = { got.v += $0 }
        let stop = await Engine.shared.prompt("Reply with exactly one word: ready")
        Engine.shared.onText = nil
        guard !stop.hasPrefix("error"), !got.v.isEmpty else {
            await restore()
            return "I kept your old AI. The local model didn't answer: \(stop)"
        }
        providerRaw = "local"
        if onboarded {
            switchingAI = false
            step = .done
            await say("All set. I'm using \(model) on this Mac now.")
        } else {
            step = .nameAssistant
            await say("It works. Now, what would you like to call me?")
        }
        if LocalModels.weakTools(model) {
            await say("This small model may struggle with tools and helpers. Keep a cloud AI for those jobs.")
        }
        return nil
    }
}

/// The local choice lives inside Switch AI; it does not ask for a server address or a terminal.
struct LocalModelPicker: View {
    @ObservedObject var m: Model
    let back: () -> Void
    @State private var servers: [LocalServer] = []
    @State private var finding = true
    @State private var busy = false
    @State private var consent = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("On this Mac").font(.title2)
            Text("Private and free, but slower and less capable.").foregroundStyle(.secondary)
            if finding {
                ProgressView("Looking for local models…")
            } else if servers.isEmpty {
                Text("I didn't find a local model yet.").foregroundStyle(.secondary)
                let pick = LocalModels.recommendation
                if consent {
                    Text("This downloads \(pick.download) for \(pick.model). OK?").font(.subheadline)
                    HStack {
                        Button("Yes, download") { Task { await install() } }.buttonStyle(.borderedProminent)
                        Button("Not now") { consent = false }.buttonStyle(.link)
                    }
                } else {
                    Button("Set up Ollama and \(pick.model)") { consent = true }.buttonStyle(.borderedProminent)
                    Text("Picked for this Mac's memory.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(servers) { server in
                    Text(server.name).font(.headline)
                    ForEach(server.models, id: \.self) { model in
                        Button {
                            Task {
                                busy = true
                                problem = await m.chooseLocal(server, model: model)
                                busy = false
                            }
                        } label: {
                            HStack {
                                Text(model)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(10)
                        }.buttonStyle(.plain)
                        if LocalModels.weakTools(model) {
                            Text("May struggle with tools and helpers. Keep a cloud AI for those jobs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            if busy { ProgressView("Working on the local model…") }
            Button("Back") { back() }.buttonStyle(.link).disabled(busy)
        }.frame(maxWidth: 430)
            .task { await refresh() }
    }

    private func refresh() async {
        finding = true
        servers = await LocalModels.discover()
        finding = false
    }

    private func install() async {
        busy = true
        problem = await LocalModels.installRecommended()
        busy = false
        consent = false
        if problem == nil { await refresh() }
    }
}
