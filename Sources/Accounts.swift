import Foundation

/// One login Hermes's own credential pool already tracks for a provider (`hermes auth list`). One never
/// keeps its own account store: this reads and drives Hermes's pool directly, so it can never drift from
/// what the engine actually uses, and nothing here can overwrite a login already there — `hermes auth add`
/// always appends a fresh pool entry, `hermes auth remove`/`priority` only ever touch the one target given.
struct AuthAccount: Identifiable, Equatable {
    var index: Int  // 1-based, as `hermes auth list` prints it
    var label: String
    var type: String  // "oauth" or "api_key"
    var entryID: String  // the id= value: stable across reordering, what `remove`/`priority` take
    var priority: Int
    /// The `←` marker: the one credential Hermes would try first on the very next request.
    var isActive: Bool
    var id: String { entryID }
}

enum Accounts {
    /// Parses `hermes auth list <provider>` text, e.g.:
    ///   #1  anthropic-oauth-1    oauth   id=7d3e62 priority=0 hermes_pkce ←
    ///   #2  Work Claude          oauth   id=ab12cd priority=1 hermes_pkce
    /// A label itself never contains "id=" or "priority=", so splitting on those markers is safe even
    /// when the label has spaces ("Work Claude").
    static func parse(_ text: String) -> [AuthAccount] {
        var out: [AuthAccount] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#"), let sp = line.firstIndex(of: " ") else { continue }
            guard let idx = Int(line[line.index(after: line.startIndex)..<sp]) else { continue }
            var rest = line[sp...].trimmingCharacters(in: .whitespaces)
            let isActive = rest.hasSuffix("←")
            if isActive { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
            let cols = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let typeAt = cols.firstIndex(where: { $0 == "oauth" || $0 == "api_key" || $0 == "api-key" }) else { continue }
            let label = cols[..<typeAt].joined(separator: " ")
            let type = cols[typeAt]
            var entryID = ""
            var priority = 0
            for c in cols[(typeAt + 1)...] {
                if c.hasPrefix("id=") { entryID = String(c.dropFirst(3)) }
                if c.hasPrefix("priority=") { priority = Int(c.dropFirst(9)) ?? 0 }
            }
            out.append(
                AuthAccount(
                    index: idx, label: label, type: type, entryID: entryID.isEmpty ? "\(idx)" : entryID, priority: priority, isActive: isActive))
        }
        return out.sorted { $0.priority < $1.priority }
    }

    static func list(_ p: Provider) async -> [AuthAccount] {
        let (status, out) = await hermesRun(["auth", "list", p.hermesID])
        guard status == 0 || out.contains("#") else { return [] }
        return parse(out)
    }

    /// A new login for this provider, under its own name. Never touches any account already signed in:
    /// `hermes auth add` only ever appends a fresh pool entry.
    @discardableResult
    static func add(_ p: Provider, label: String) -> SignIn {
        let s = SignIn()
        s.start(p, label: label) { _ in }
        return s
    }

    /// Signs out one account by its entry id. Never the only way in: the caller always has the account
    /// list on screen first, so this can never be pointed at the wrong one by a stale index.
    @discardableResult
    static func signOut(_ p: Provider, entryID: String) async -> Bool {
        let (status, _) = await hermesRun(["auth", "remove", p.hermesID, entryID])
        return status == 0
    }

    /// "Make default": moves this account to priority 0, so Hermes tries it first. Every other signed-in
    /// account stays exactly as it was, just later in line — nothing is removed or signed out.
    @discardableResult
    static func makeDefault(_ p: Provider, entryID: String) async -> Bool {
        let (status, _) = await hermesRun(["auth", "priority", p.hermesID, entryID, "0"])
        return status == 0
    }

    /// A name nobody else has for this provider yet: "Claude" when free, else "Claude 2", "Claude 3"...
    static func freeName(_ p: Provider, existing: [AuthAccount], typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = typed.isEmpty ? p.title : typed
        let taken = Set(existing.map(\.label))
        guard taken.contains(wanted) else { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    /// Hermes's own pool can fail a credential over to another one mid-conversation, before One ever
    /// sees an error (that's the whole point of a pool: a helper's turn still gets an answer). The only
    /// way One finds out is by noticing the `←` moved since the last time it looked. Pure and testable:
    /// nil unless there are at least two accounts and the active one actually changed.
    static func detectSwitch(before: [AuthAccount], after: [AuthAccount]) -> (from: AuthAccount, to: AuthAccount)? {
        guard after.count > 1, let from = before.first(where: \.isActive), let to = after.first(where: \.isActive), from.entryID != to.entryID
        else { return nil }
        return (from, to)
    }
}
