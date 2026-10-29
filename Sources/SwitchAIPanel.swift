import SwiftUI

/// Switch AI as its own pop-up over the real chat (not the first-run setup screen): one clean
/// title (never a persisted chat bubble, so it can never duplicate), every provider in a
/// scrollable list so none are ever clipped off-screen, the current one marked, a plain wait
/// message with Cancel instead of a blank blurred screen, and the X/Esc/click-outside every
/// pop-up gets for free from `onePopup`.
struct SwitchAIPanel: View {
    @ObservedObject var m: Model
    let close: () -> Void
    @State private var current: Provider?
    @State private var localPicker = false
    @State private var loadedCurrent = false
    /// Renders only: ImageRenderer draws ScrollView contents and ProgressView blank, so a still
    /// capture (`--render-switch-ai`) skips both and shows a static dot instead.
    nonisolated(unsafe) static var renderStill = false

    var body: some View {
        VStack(spacing: 14) {
            if m.step == .signingIn {
                signingIn
            } else if let msg = m.switchWaitMessage {
                waiting(msg)
            } else if localPicker {
                LocalModelPicker(m: m) { localPicker = false }
            } else {
                picker
            }
        }
        .padding(28)
        .frame(minWidth: 380, maxWidth: 440)
        .task { await loadCurrent() }
    }

    private var picker: some View {
        VStack(spacing: 14) {
            Text("Which AI should I use?").font(.title2)
            providerList
                .frame(maxHeight: 360)
            if let p = m.signInProblem { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    @ViewBuilder private var providerList: some View {
        let rows = VStack(spacing: 10) {
            ForEach(Provider.allCases) { p in
                providerRow(
                    symbol: p.symbol, title: p.title,
                    subtitle: m.signedIn[p] == true ? "Already signed in" : p.subtitle,
                    isCurrent: current == p
                ) { Task { await m.choose(p) } }
            }
            providerRow(
                symbol: "desktopcomputer", title: "Local model",
                subtitle: "Private and free, but slower and less capable.",
                isCurrent: current == nil && loadedCurrent && m.providerRaw == "local"
            ) { localPicker = true }
        }
        if SwitchAIPanel.renderStill {
            rows
        } else {
            ScrollView { rows }
        }
    }

    private func providerRow(symbol: String, title: String, subtitle: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if isCurrent { Text("Current").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(12).contentShape(Rectangle())
                .popupCard(12)
        }.buttonStyle(.plain).disabled(m.busy)
    }

    private func waiting(_ message: String) -> some View {
        VStack(spacing: 16) {
            if SwitchAIPanel.renderStill { Circle().fill(.secondary).frame(width: 8, height: 8) } else { ProgressView() }
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Cancel") {
                m.switchingAI = false
                m.switchWaitMessage = nil
                close()
            }.buttonStyle(.link)
        }
    }

    @ViewBuilder private var signingIn: some View {
        VStack(spacing: 14) {
            if let p = m.signInChoice {
                Text("I need to open your browser to sign in to \(p.title). Can I show you the window?")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Yes, show it") { Task { await m.confirmSignIn(p) } }.buttonStyle(.borderedProminent)
                    Button("Not now") {
                        m.signInChoice = nil
                        m.step = .pickAI
                    }.buttonStyle(.bordered)
                }
            } else {
                if let c = m.signInCode {
                    Text("If the page asks for a code, enter:").foregroundStyle(.secondary)
                    Text(c).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
                if m.signInNeedsPaste {
                    SigningInPaste(m: m)
                }
                if m.signInCode == nil && !m.signInNeedsPaste {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                    }
                }
                Button("Cancel") {
                    m.cancelSignIn()
                    m.step = .pickAI
                }.buttonStyle(.link)
            }
        }
    }

    private func loadCurrent() async {
        let config = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        current = SwitchAI.currentProvider(config)
        loadedCurrent = true
        for p in Provider.allCases { m.signedIn[p] = await SignIn.isSignedIn(p) }
    }
}

/// The code-paste box, split out so `SwitchAIPanel.signingIn` stays simple.
private struct SigningInPaste: View {
    @ObservedObject var m: Model
    @State private var paste = ""
    var body: some View {
        VStack(spacing: 10) {
            Text("Paste the code the page shows you:").foregroundStyle(.secondary)
            HStack {
                TextField("Code", text: $paste).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Continue", action: send).buttonStyle(.borderedProminent)
            }.frame(maxWidth: 420)
        }
    }
    private func send() {
        m.pasteCode(paste)
        paste = ""
    }
}
