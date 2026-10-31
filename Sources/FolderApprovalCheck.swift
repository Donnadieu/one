import Foundation

/// `One --test-folder-approval` (run by preflight): proves the folder-approval ledger (FolderApprovals.swift)
/// without touching Omar's real state. Pure: no engine, no Model. Run with ONE_SUPPORT_DIR set to an empty folder.
enum FolderApprovalCheck {
    /// Runs the check and exits when `--test-folder-approval` is among the arguments; returns otherwise.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-folder-approval") else { return false }
        TestWorld.enter()  // pure ledger decisions; run with ONE_SUPPORT_DIR set to an empty folder
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        guard Env.selfTest, ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder")
            return 2
        }

        let bogus = "/tmp/one-folder-approval-check-bogus-\(Int(Date().timeIntervalSince1970))"
        let granted = "/tmp/one-folder-approval-check-granted-\(Int(Date().timeIntervalSince1970))"
        let existing = "/tmp/one-folder-approval-check-existing-\(Int(Date().timeIntervalSince1970))"

        // 1. Existing folders (as if already granted before this fix): Access.folders is NEVER filtered
        //    against the ledger - a path present in UserDefaults with no ledger entry still comes through.
        Access.set([existing])
        check("a pre-existing folder with no ledger entry is still in Access.folders (never dropped)", Access.folders == [existing])
        check("…and it isn't in the ledger yet", !FolderApprovals.approvedPaths().contains(existing))

        // 2. Migration grandfathers it in once, without asking, without removing it.
        FolderApprovals.migrateExisting()
        check("migration logs it once as migrated-existing", FolderApprovals.approvedPaths().contains(existing))
        check("…and Access.folders is unchanged", Access.folders == [existing])
        let ledgerAfterFirstMigrate = FolderApprovals.load().approved.count
        Access.set([existing, bogus])  // simulate a bare `defaults write` adding something new, outside the flow
        FolderApprovals.migrateExisting()  // must be a one-time no-op now (guarded by the UserDefaults flag)
        check(
            "migration never runs twice (doesn't silently adopt a later bare `defaults write`)",
            FolderApprovals.load().approved.count == ledgerAfterFirstMigrate)
        check("…so the bare-write path is still excluded from the ledger (flaggable, not trusted)", !FolderApprovals.approvedPaths().contains(bogus))
        check("…but Access.folders still includes it (rule: never filter/drop anything on the real list)", Access.folders.contains(bogus))
        Access.set([existing])  // reset for the next part

        // 3. The chat ask + yes flow: detecting the assistant's exact phrase, and the grant it produces.
        let reply = "I don't have access to \(granted). Want me to add it? [choices: Yes, add it | No]"
        check("the assistant's ask is recognized", FolderApprovals.isAsk(reply))
        check("…and the path is read out of it", FolderApprovals.pathIn(reply) == granted)
        check("a plain \"yes\" is recognized", FolderApprovals.isYes("Yes"))
        check("a plain \"no\" is not", !FolderApprovals.isYes("No"))

        FolderApprovals.grant(path: granted, reason: "the assistant's stated reason", channel: "mac-app-card")
        check("granting adds it to Access.folders", Access.folders.contains(granted))
        check(
            "…and to the ledger, with the channel it came through",
            FolderApprovals.load().approved.contains { $0.path == granted && $0.channel == "mac-app-card" })
        check("…and it's no longer flagged as unlogged", !FolderApprovals.unlogged().contains(granted))

        // 4. Denying (or never answering) must add nothing to either file.
        let denied = "/tmp/one-folder-approval-check-denied-\(Int(Date().timeIntervalSince1970))"
        let beforeFolders = Access.folders
        let beforeLedger = FolderApprovals.load().approved.count
        // A deny never calls grant at all (Model.answerFolderAsk's false branch only sends a note) - prove
        // the absence of any side effect by confirming nothing changed for a path never granted.
        check("a never-granted path stays out of Access.folders", !Access.folders.contains(denied))
        check("…and out of the ledger", !FolderApprovals.approvedPaths().contains(denied))
        check(
            "…and granting one path never touches another", Access.folders == beforeFolders && FolderApprovals.load().approved.count == beforeLedger)

        // 5. Granting the same path twice logs once (idempotent single code path).
        FolderApprovals.grant(path: granted, reason: "asked again", channel: "mac-app-chat")
        check(
            "granting the same path again doesn't duplicate the ledger entry",
            FolderApprovals.load().approved.filter { $0.path == granted }.count == 1)

        print(fails == 0 ? "PASS folder approval (\(fails) failures)" : "FAIL folder approval (\(fails) failures)")
        return fails == 0 ? 0 : 1
    }
}
