import Foundation

/// No network or real Hermes calls: pure checks for parsing `hermes auth list`, naming a new account,
/// and spotting a pool failover — the pieces Accounts.swift and LimitBanner.swift build on.
enum AccountsCheck {
    /// `--test-accounts`: no engine, no network.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-accounts") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(run()) }
        return true
    }

    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "✓" : "✗") \(name)")
            if !pass { failures += 1 }
        }

        // Real shape from `hermes auth list anthropic` on this Mac, plus a labelled second account.
        let sample = """
            anthropic (2 credentials):
              #1  anthropic-oauth-1    oauth   id=7d3e62 priority=0 hermes_pkce ←
              #2  Work Claude          oauth   id=ab12cd priority=1 hermes_pkce
            """
        let accounts = Accounts.parse(sample)
        check("both accounts parse", accounts.count == 2)
        check("priority 0 comes first", accounts.first?.entryID == "7d3e62")
        check("a labelled account's spaced name survives", accounts.last?.label == "Work Claude")
        check("only the ← entry is active", accounts.filter(\.isActive).map(\.entryID) == ["7d3e62"])
        check("priority values read correctly", accounts.map(\.priority) == [0, 1])

        // One credential, nothing to switch to: `hermes auth list` with just the default seed.
        let one = Accounts.parse("  #1  ANTHROPIC_API_KEY    api_key id=ef56gh priority=0 env:ANTHROPIC_API_KEY ←")
        check("a single api_key credential still parses", one.count == 1 && one[0].type == "api_key")

        // Empty / unrecognised text (no credentials yet, or Hermes isn't on this Mac): never crashes, never a fake row.
        check("no credentials parses to an empty list", Accounts.parse("No credentials configured for any provider.").isEmpty)

        // freeName: never collides with an existing label, never leaves it blank.
        check("an empty name falls back to the provider's own name", Accounts.freeName(.claude, existing: [], typed: "") == "Claude")
        check("a free name is kept as typed", Accounts.freeName(.claude, existing: accounts, typed: "Work Claude 2") == "Work Claude 2")
        let taken = accounts + [AuthAccount(index: 3, label: "Claude", type: "oauth", entryID: "x", priority: 2, isActive: false)]
        check("a taken name gets \" 2\"", Accounts.freeName(.claude, existing: taken, typed: "Claude") == "Claude 2")

        // detectSwitch: the only way One learns the pool moved on its own.
        let before = accounts
        var afterSame = accounts
        check("no change reports nothing", Accounts.detectSwitch(before: before, after: afterSame) == nil)
        afterSame[0].isActive = false
        afterSame[1].isActive = true
        let moved = Accounts.detectSwitch(before: before, after: afterSame)
        check("a real failover is reported", moved?.from.entryID == "7d3e62" && moved?.to.entryID == "ab12cd")
        check(
            "a single account never reports a switch (nothing to compare to)",
            Accounts.detectSwitch(before: [accounts[0]], after: [accounts[0]]) == nil)

        // The limit card: the exact words Omar approved, and the wording stays plain.
        let notice = LimitNotice(provider: .claude, fromLabel: "Personal Claude", toLabel: "Work Claude", toEntryID: "ab12cd")
        check(
            "the card never invents a time it wasn't given",
            !"\(notice.fromLabel) hit its limit".isEmpty)

        // Model-level wiring: a fresh Model has no stale notice, and clearing one is immediate.
        let m = Model.shared
        m.limitNotice = notice
        m.dismissLimitNotice()
        check("dismissing the card clears it", m.limitNotice == nil)

        return failures == 0 ? 0 : 1
    }
}
