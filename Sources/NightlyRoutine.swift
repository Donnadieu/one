import Foundation

// MARK: - The "Nightly review" routine, made by One for everyone
// About 3:30 AM every night, on the Routines dial like any routine (Run now, Pause). Its pre-run script is
// `One --improve night prepare`, which waits until nothing else is working, measures the day, copies what the
// review may edit and hands the AI only the moments that matter. The review stays silent (`[SILENT]`): what it
// found reaches the person as 3 lines in the morning brief (`One --improve night morning`).
// Its first week is suggestions only (`improve/settings.json` mode "suggest"); "edit" turns on safe edits.
// One makes it once (first launch, or the first launch after an update) and never again: removed by the person,
// it stays removed. Design: Made by Iris, "2026-11-05 One gets better by itself - design.md", section 7.

enum NightlyRoutine {
    static let name = "Nightly review"
    static let schedule = "30 3 * * *"
    static let version = 1  // bump when the prompt or script changes; the next launch updates the routine in place
    static let scriptName = "one-nightly-review.sh"
    static var scriptFile: URL { Env.hermesHome.appendingPathComponent("scripts/\(scriptName)") }
    static var markerFile: URL { Improve.dir.appendingPathComponent("routine.json") }

    /// The pre-run script. It refuses to call a copy of One older than this feature (that copy would open its window).
    static func script(exe: String) -> String {
        let app = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().path
        return """
            #!/bin/bash
            # One's nightly review, before the AI runs. Written by One at every launch: edits here are replaced.
            ONE='\(exe.replacingOccurrences(of: "'", with: "'\\''"))'
            V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' '\(app.replacingOccurrences(of: "'", with: "'\\''"))/Info.plist' 2>/dev/null)
            IFS=. read -r A B C <<< "${V:-0.0.0}"
            if [ ! -x "$ONE" ] || [ $(( ${A:-0} * 1000000 + ${B:-0} * 1000 + ${C:-0} )) -lt 9090 ]; then
              echo "Skipped: this Mac's One (${V:-not found}) is older than 0.9.90, which brings the nightly review."
              echo '{"wakeAgent": false}'
              exit 0
            fi
            exec "$ONE" --improve night prepare --wait 45

            """
    }

    static let prompt = """
        One's nightly review. Nobody is watching: never ask anything, never send, post, buy or delete, never open a \
        browser. Work only from the Script Output above and the files it names.

        1. For each moment in the Script Output, decide: was it really a mistake (a correction, something that broke, a \
        wall, a job far too slow)? If not, skip it. If yes: what went wrong, and what one short rule would have \
        prevented it. Give it a short pattern key (like helper-result-not-visible) and the recipe it belongs to (from \
        "Recipes you may add a lesson to"; none if nothing fits). Never read whole conversations, any confidential/ \
        folder, a private room or a shared room.
        2. Match each lesson against the ledger. Status: "seen once" (first time: recorded only), "rule" (the same key \
        on 2 different days or in 2 different jobs, or the person said it outright with always/never), "retired" (a \
        rule that drew a correction itself). Append one JSON line per new or changed lesson to the LESSONS LEDGER: \
        {"key", "skill", "rule", "status", "evidence": [conversation ids], "date"}. No evidence, no lesson. An \
        "Incident" (a one-off burst) is one lesson about its cause, never many.
        3. MODE suggest: change no recipe, note or setting at all. MODE edit: only for lessons with status "rule", add \
        or edit ONE bullet under a "## Lessons" heading at the end of that recipe's SKILL.md (make the heading if it's \
        missing), like "- [L-<key>] <rule> (seen <dates>)". Stay within the number of recipes MODE allows, one change \
        per recipe, small edits in place, never rewrite a recipe, never make a new one, never touch SOUL, policy.yaml, \
        AGENTS.md, room notes or the person's own stated rules. Keep each SKILL.md under 12 KB and its Lessons under \
        25 lines (merge or retire one first if it's full). In edit mode you may also trim repeated lines in the notes \
        file listed, only when it's over 90% full.
        4. Write the REVIEW FILE as JSON: {"date", "mode", "lessons": [{"key", "skill", "rule", "status", "evidence", \
        "applied": true or false}], "ask": {"text": "...", "choices": ["Yes", "Not now"]} or null}. "ask" is at most \
        one thing that needs the person's yes (a new recipe from 2 or more real jobs, a routine, a change to One \
        itself, a setting), in plain words.
        5. Run the WHEN DONE command.
        6. Reply with exactly [SILENT].
        """

    static func writeScript(exe: String = Bridge.exe) {
        let fm = FileManager.default
        try? fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = script(exe: exe)
        if (try? String(contentsOf: scriptFile, encoding: .utf8)) != text { try? text.write(to: scriptFile, atomically: true, encoding: .utf8) }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
    }

    static func jobs() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: Routines.cron.appendingPathComponent("jobs.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [] }
        return (j["jobs"] as? [[String: Any]]) ?? []
    }
    static func marker() -> (id: String, version: Int)? {
        guard let d = try? Data(contentsOf: markerFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let id = j["id"] as? String
        else { return nil }
        return (id, (j["version"] as? Int) ?? 0)
    }
    static func saveMarker(_ id: String) {
        try? FileManager.default.createDirectory(at: Improve.dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["id": id, "version": version]).write(to: markerFile)
    }

    /// Makes the routine once and keeps its script and words current. Before every engine start (`ensureEngine`).
    /// Returns what it did, for the log and the checks.
    @discardableResult static func ensure() async -> String {
        Improve.ensureSettings()
        writeScript()
        let all = jobs()
        if let m = marker() {
            guard all.contains(where: { ($0["id"] as? String) == m.id }) else { return "removed by the person: left removed" }
            guard m.version < version else { return "already there" }
            let (code, out) = await hermesRun(["cron", "edit", m.id, "--prompt", prompt, "--script", scriptName])
            if code == 0 { saveMarker(m.id) }
            return code == 0 ? "updated" : "couldn't update: \(out.suffix(200))"
        }
        if let j = all.first(where: { ($0["name"] as? String) == name }), let id = j["id"] as? String {
            saveMarker(id)  // made by hand before One shipped it: adopt it
            return "adopted"
        }
        let (code, out) = await hermesRun(["cron", "create", schedule, prompt, "--name", name, "--script", scriptName, "--deliver", "local"])
        guard code == 0, let id = jobs().first(where: { ($0["name"] as? String) == name })?["id"] as? String else {
            BrowserGuard.log("nightly review: couldn't make the routine: \(out.suffix(200))")
            return "couldn't make it: \(out.suffix(200))"
        }
        saveMarker(id)
        return "made"
    }
}
