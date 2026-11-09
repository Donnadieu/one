import SwiftUI

/// A pool failover Hermes already made on its own (Accounts.detectSwitch), shown as a plain-words card.
struct LimitNotice: Equatable {
    let provider: Provider
    let fromLabel: String
    let toLabel: String
    let toEntryID: String
}

@MainActor
extension Model {
    /// Called once after each main-conversation turn (never for helpers: a helper keeps working on
    /// whichever account it already had). Looks at which account Hermes is using now for the provider
    /// that just answered; if that moved since the last look, it's a limit the pool already rode out —
    /// say so, once, with a one-tap way to keep the new account as the default going forward.
    func checkAccountLimit(_ p: Provider) async {
        let accounts = await Accounts.list(p)
        guard let nowActive = accounts.first(where: \.isActive) else { return }
        defer { lastActiveEntry[p.rawValue] = nowActive.entryID }
        guard let wasActive = lastActiveEntry[p.rawValue], wasActive != nowActive.entryID,
            let from = accounts.first(where: { $0.entryID == wasActive })
        else { return }
        limitNotice = LimitNotice(provider: p, fromLabel: from.label, toLabel: nowActive.label, toEntryID: nowActive.entryID)
    }

    /// "Switch to <account>": pins the account Hermes already failed over to as the new default, so it
    /// stays in front even after the limited one's window reopens. Declining just clears the card —
    /// Hermes's own pool still reverts to the original account by itself once it's ready again.
    func keepLimitSwitch() async {
        guard let n = limitNotice else { return }
        _ = await Accounts.makeDefault(n.provider, entryID: n.toEntryID)
        limitNotice = nil
    }
    func dismissLimitNotice() { limitNotice = nil }
}

struct LimitNoticeCard: View {
    let n: LimitNotice
    let keep: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("\(n.fromLabel) hit its limit").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            Text("I'm still on it — I moved to \(n.toLabel) to keep going.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Switch to \(n.toLabel)", action: keep).buttonStyle(.borderedProminent)
                Button("No, switch back when it's ready", action: dismiss).buttonStyle(.link)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.orange.opacity(0.3)))
    }
}
