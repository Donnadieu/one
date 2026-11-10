import AppKit
import SwiftUI

// MARK: - `One --render-helper-tags <prefix> [reply.txt]`: what a reply with helper tags shows and says
// Nov 10, 2026: a [helper: …] job that ran over several paragraphs was read only to the end of its first line; the
// rest showed in the chat and was read aloud. This draws the chat bubble the person would see for a reply (the
// built-in sample, or the file given) and writes what goes to the voice and to each helper, so the fix can be seen
// without opening a window. Renders only: nothing is started, sent or saved.

enum HelperTagsRender {
    /// A reply shaped like the Nov 10 one: a job over several paragraphs quoting a choices tag and a link, then a
    /// second helper, a tell over two paragraphs and the reply's own job kind.
    static let sample =
        "Sending two helpers, and passing your note on.\n\n"
        + "[helper: Fix the icon | Fix the app's Dock icon. Read [the notes](https://example.com/notes) first.\n\n"
        + "(1) WRONG ICON. Check what the installed app's icon file holds against the picked one.\n\n"
        + "(2) Before replacing the open copy, ask \"Install it now?\" with [choices: Yes, install it | Not now].\n\n"
        + "Report what was wrong and what was tested.]\n\n"
        + "[helper: Check the build | Look only: see why last night's build failed.\n\nSay which step broke.]\n\n"
        + "[tell-helper: Flight to Quebec | Skip the tests.\n\nI just need the flight, ending with [choices: Cheapest | Fastest].]\n\n"
        + "[job-kind: app bug fixes]"

    static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--render-helper-tags"), k + 1 < args.count else { return }
        let reply = k + 2 < args.count ? ((try? String(contentsOfFile: args[k + 2], encoding: .utf8)) ?? sample) : sample
        MainActor.assumeIsolated { write(args[k + 1], reply: reply) }
        exit(0)
    }

    @MainActor static func write(_ prefix: String, reply: String) {
        let tags = Helpers.read(reply)
        let shown = Learning.tags(tags.said).clean  // what ModelChat leaves in the bubble once the turn is over
        let body = Choices.split(Helpers.strip(shown)).body
        var report = "SHOWN IN THE CHAT BUBBLE:\n\(body)\n\nREAD ALOUD:\n"
        report += Speaker.spoken(shown).joined(separator: "\n") + "\n"
        for (t, j) in tags.jobs { report += "\nHELPER \"\(t)\" GETS (\(j.count) characters):\n\(j)\n" }
        for (t, j) in tags.tells { report += "\nTOLD TO \"\(t)\":\n\(j)\n" }
        try? report.write(toFile: prefix + "-said.txt", atomically: true, encoding: .utf8)
        ChatText.still = true
        let v = VStack(alignment: .leading, spacing: 14) {
            Text("What the chat shows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MiniOrb().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                MarkdownText(text: body, size: 15).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Read aloud: " + Speaker.spoken(shown).joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            Text("Helpers started: \(tags.jobs.count) · messages passed on: \(tags.tells.count)").font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 720, alignment: .topLeading).background(WorldLook.bg).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let d = rep.representation(using: .png, properties: [:])
        {
            try? d.write(to: URL(fileURLWithPath: prefix + "-bubble.png"))
        }
        print("wrote \(prefix)-bubble.png and \(prefix)-said.txt")
    }
}
