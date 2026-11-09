import SwiftUI

/// Direction B's accounts screen (Omar's pick, Nov 9 2026): tap a provider in Switch AI, see every
/// signed-in account for it, pick a default, add another, or sign one out. Reads and drives Hermes's
/// own credential pool directly (Accounts.swift) — there's no separate "account list" of One's own to
/// drift out of sync. Switching which provider is the whole app's AI stays a separate step (the
/// "Switch to <provider>" button here, only shown when this one isn't already current).
struct ProviderAccountsView: View {
    @ObservedObject var m: Model
    let provider: Provider
    let isCurrent: Bool
    let back: () -> Void

    @State private var accounts: [AuthAccount] = []
    @State private var loading = true
    @State private var adding = false
    @State private var newName = ""
    @State private var signIn: SignIn?
    @State private var signInCode: String?
    @State private var signInNeedsPaste = false
    @State private var busyID: String?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text("\(provider.title) accounts").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if adding {
                addingView
            } else {
                list
            }
        }
        .task { await load() }
    }

    private var list: some View {
        VStack(spacing: 10) {
            if !isCurrent {
                Button("Switch to \(provider.title)") { Task { await m.choose(provider) } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            ForEach(accounts) { a in
                HStack(spacing: 12) {
                    Button {
                        Task { await makeDefault(a) }
                    } label: {
                        Circle().strokeBorder(a.priority == 0 ? Color.accentColor : .secondary, lineWidth: 2)
                            .background(Circle().fill(a.priority == 0 ? Color.accentColor : .clear).padding(3.5))
                            .frame(width: 16, height: 16)
                    }.buttonStyle(.plain).disabled(a.priority == 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.label).font(.subheadline).fontWeight(.semibold)
                        Text(a.priority == 0 ? "Default" : "Ready").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign out") { Task { await signOut(a) } }.buttonStyle(.link).font(.caption)
                }
                .padding(10).popupCard(10).opacity(busyID == a.entryID ? 0.5 : 1).disabled(busyID != nil)
            }
            Button {
                newName = Accounts.freeName(provider, existing: accounts, typed: "")
                adding = true
            } label: {
                Text("+ Add a \(provider.title) account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(10)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])))
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text("Tap a dot to make that account the default.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var addingView: some View {
        if let code = signInCode {
            VStack(spacing: 10) {
                Text("If the page asks for a code, enter:").foregroundStyle(.secondary)
                Text(code).font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Button("Cancel", action: cancelAdd).buttonStyle(.link)
            }
        } else if signInNeedsPaste {
            AccountPasteBox { code in signIn?.paste(code) }
            Button("Cancel", action: cancelAdd).buttonStyle(.link)
        } else if signIn != nil {
            VStack(spacing: 14) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                }
                Button("Cancel", action: cancelAdd).buttonStyle(.link)
            }
        } else {
            VStack(spacing: 10) {
                Text("What should I call this account?").foregroundStyle(.secondary)
                TextField("e.g. Work Claude", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                HStack {
                    Button("Continue", action: startAdd).buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { adding = false }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func load() async {
        loading = true
        accounts = await Accounts.list(provider)
        loading = false
    }

    private func startAdd() {
        problem = nil
        let label = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = SignIn()
        signIn = s
        s.start(provider, label: label) { ev in
            Task { @MainActor in
                switch ev {
                case .openPage(let u): NSWorkspace.shared.open(u)
                case .code(let c): signInCode = c
                case .needPaste: signInNeedsPaste = true
                case .done(let ok, let msg):
                    signIn = nil
                    signInCode = nil
                    signInNeedsPaste = false
                    adding = false
                    if ok {
                        await load()
                    } else {
                        problem = msg.isEmpty ? "That sign-in didn't finish. Try again?" : msg
                    }
                }
            }
        }
    }

    private func cancelAdd() {
        signIn?.cancel()
        signIn = nil
        signInCode = nil
        signInNeedsPaste = false
    }

    /// Promotes an account to priority 0. Every other signed-in account stays exactly as it was.
    private func makeDefault(_ a: AuthAccount) async {
        guard a.priority != 0 else { return }
        busyID = a.entryID
        _ = await Accounts.makeDefault(provider, entryID: a.entryID)
        await load()
        busyID = nil
    }

    /// Signs out one account by its own entry id, taken fresh off the account row on screen — never a
    /// stale index — so it can never land on the wrong one.
    private func signOut(_ a: AuthAccount) async {
        busyID = a.entryID
        _ = await Accounts.signOut(provider, entryID: a.entryID)
        await load()
        busyID = nil
    }
}

/// A small inline code-paste box for the "add account" sign-in, kept local to this screen (unlike
/// `SwitchAIPanel`'s own paste box, this one feeds a locally-held `SignIn`, not `Model`'s).
private struct AccountPasteBox: View {
    let onPaste: (String) -> Void
    @State private var paste = ""
    var body: some View {
        VStack(spacing: 10) {
            Text("Paste the code the page shows you:").foregroundStyle(.secondary)
            HStack {
                TextField("Code", text: $paste).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Continue", action: send).buttonStyle(.borderedProminent)
            }.frame(maxWidth: 360)
        }
    }
    private func send() {
        onPaste(paste)
        paste = ""
    }
}
