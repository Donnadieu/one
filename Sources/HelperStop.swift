import AppKit
import SwiftUI

// MARK: - Stopping one helper: from its orb (right-click or long press), its card, or the assistant's [stop-helper: …] line.
// A stopped helper keeps what it made, stays stopped after a restart, and can be started again with its original job.
// Updates never stop helpers: they're paused and pick back up by themselves after the restart.

enum HelperStop {
    /// Told to the assistant on every prompt (old conversations never see a new SOUL).
    static var note: String {
        "\n\n(One app note, not from the user: to stop a helper, when they say \"stop the <name> helper\", \"stop that one\" or \"stop all\", "
            + "add a line exactly like [stop-helper: <its exact title>] or [stop-helper: all], and confirm in one short line, like "
            + "\"Stopped Flight to Quebec. What it found so far stays under its orb.\" One stops it. Never stop one they didn't ask about. "
            + HelperClose.rule + ")"
    }
    /// The same rule in the assistant's SOUL (`Persona.write`).
    static let soul =
        "To stop a helper, when they say \"stop the <name> helper\", \"stop that one\" or \"stop all\", add a line exactly like [stop-helper: Flight to Quebec] (the helper's exact title) or [stop-helper: all], and confirm in one short line, like \"Stopped Flight to Quebec. What it found so far stays under its orb.\" Never stop one they didn't ask about. "
        + HelperClose.rule

    /// Pull "[stop-helper: Title]" and "[stop-helper: all]" out of the assistant's reply, on their own line or
    /// in the middle of one (the assistant sometimes runs it into its sentence).
    /// `tag: "done-helper"` (or the older "close-helper") reads the lines that take an orb off the screen the same way.
    static func extract(_ text: String, tag: String = "stop-helper") -> (String, [String]) {
        guard let re = try? NSRegularExpression(pattern: "[ \\t]*\\[\(tag):([^\\]\\n]*)\\][ \\t]*", options: [.caseInsensitive]) else {
            return (text, [])
        }
        let ns = text as NSString
        var names: [String] = []
        var out = ""
        var at = 0
        for r in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: r.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { names.append(n) }
            out += ns.substring(with: NSRange(location: at, length: r.range.location - at))
            let before = out.last
            let after = r.range.upperBound < ns.length ? ns.substring(with: NSRange(location: r.range.upperBound, length: 1)) : "\n"
            if let b = before, b != "\n", after != "\n" { out += "\n" }  // run into a sentence: keep the two sentences apart
            at = r.range.upperBound
        }
        guard !names.isEmpty else { return (text, []) }
        var seen = Set<String>()
        names = names.filter { seen.insert($0.lowercased()).inserted }  // the same line twice stops it once
        out += ns.substring(from: at)
        var lines = out.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return (lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n"), names)
    }
    /// While a reply streams in: hide a stop line, even half-written.
    static func hide(_ text: String) -> String {
        var t = extract(extract(extract(text).0, tag: "close-helper").0, tag: "done-helper").0
        if let k = t.lastIndex(of: "[") {
            let tail = t[k...].lowercased()
            for tag in ["[stop-helper", "[close-helper", "[done-helper"]
            where (tag + ":").hasPrefix(tail) || (tail.hasPrefix(tag) && !tail.contains("]")) {
                t = String(t[..<k]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return t
    }

    /// Which helpers a stop line means: "all" = every one still at work; otherwise the exact title
    /// (any case), the most recently sent on ties. Only helpers still at work (or waiting to pick back up) count;
    /// by name, one waiting for their yes counts too (it has to be stopped before it can come off the screen).
    static func match(_ name: String, in hs: [Helper]) -> [UUID] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))).lowercased()
        let live = hs.enumerated().filter { $0.element.state == "working" || $0.element.resumeQueued == true }
        if n == "all" { return live.map(\.element.id) }
        let same = hs.enumerated().filter { $0.element.title.lowercased() == n && HelperClose.busy($0.element) }
        let pick = same.max { a, b in
            (a.element.started ?? .distantPast, a.offset) < (b.element.started ?? .distantPast, b.offset)
        }
        return pick.map { [$0.element.id] } ?? []
    }
    static func notFound(_ name: String) -> String { "I couldn't find a helper called \"\(name)\" that's still working." }

    static let pausedLine = "Paused for the update · picks back up by itself"
    /// An update is about to restart One: a working helper is paused, not stopped. It picks back up after the
    /// restart like any helper a restart cut off, and the pause never counts toward the restart limit.
    @MainActor static func pauseForUpdate(_ h: inout Helper) {
        pause(&h, line: pausedLine, trail: "Paused for an update", reason: nil)
    }
    /// One restarts its engine to open a newly allowed folder: same as an update pause, its own words.
    @MainActor static func pauseForFolder(_ h: inout Helper) {
        pause(&h, line: FolderWatch.pausedLine, trail: "Paused so One could open a new folder", reason: "a new folder")
    }
    @MainActor private static func pause(_ h: inout Helper, line: String, trail: String, reason: String?) {
        guard h.state == "working" else { return }
        h.state = "stopped"
        h.resumeQueued = true
        h.updatePaused = true
        h.pausedFor = reason
        h.stoppedByYou = nil
        h.line = line
        HelperTrail.add(trail, to: &h)
    }

    /// The word next to a helper's title in its card.
    static func word(_ h: Helper) -> String {
        switch h.state {
        case "working": "working"
        case "needsYes": "needs your yes"
        case "stopped": h.resumeQueued == true ? "paused" : "stopped"
        default: "done"
        }
    }
}

extension Model {
    /// The assistant wrote "[stop-helper: …]": stop the match. Returns a plain line if nothing matched.
    func stopHelpers(named name: String) -> String? {
        let ids = HelperStop.match(name, in: helpers)
        if ids.isEmpty {
            // Already stopped (the same line twice in one reply, or asked again): nothing to say.
            let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            if n == "all" || helpers.contains(where: { $0.stoppedByYou == true && $0.title.lowercased() == n }) { return nil }
            return HelperStop.notFound(name)
        }
        ids.forEach { stopHelper($0) }
        return nil
    }

    /// Just before an update restarts One: every working helper is paused and picks back up after the restart.
    func pauseHelpersForUpdate() {
        for k in helpers.indices where helpers[k].state == "working" {
            HelperStop.pauseForUpdate(&helpers[k])
            HelperTrail.flush(helpers[k])
        }
    }

    /// Just before One restarts its engine to open a new folder: every working helper is paused and picks back up after.
    func pauseHelpersForFolder() {
        for k in helpers.indices where helpers[k].state == "working" {
            HelperStop.pauseForFolder(&helpers[k])
            HelperTrail.flush(helpers[k])
        }
        saveHelpers()
    }
}

/// A long press on a working helper's orb: stop it?
struct HelperStopAsk: View {
    let title: String
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Stop \(title)?").font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 120)  // the X and "Esc to close"
            }.frame(minHeight: 28)
            Text("What it found so far stays here.").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7))
            HStack(spacing: 8) {
                Spacer()
                Button("Keep going") { done(false) }.buttonStyle(.bordered)
                Button {
                    done(true)
                } label: {
                    Text("Stop this helper").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 16).frame(height: 30).background(Capsule().fill(WorldLook.cream))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }.padding(.top, 6)
        }
        .foregroundStyle(WorldLook.cream)
        .padding(20).frame(width: 380, alignment: .leading)
    }
}

struct HelperCard: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        let parts = Choices.split(Helpers.strip(h.reply))  // a stray [helper: …] line never shows
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(h.title).font(.headline)
                Text("· " + HelperStop.word(h)).foregroundStyle(h.state == "needsYes" ? Color.orange : Color.secondary)
                Spacer()
                Button {
                    m.openHelper = nil
                } label: {
                    Label(m.name, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Back to \(m.name)")
            }
            if let a = h.asked, !a.isEmpty { ChatText(text: a, size: ChatText.callout, plain: true, accent: true) }
            if h.state == "working" {
                HelperProgressView(m: m, h: h)  // the real step, its time, its plan line; Nudge when it's gone quiet
                if !h.reply.isEmpty { ChatText(text: parts.body, size: 15).frame(maxWidth: .infinity, alignment: .leading) }
            } else if h.reply.isEmpty {
                Text(h.state == "stopped" ? h.line : "Nothing yet.").foregroundStyle(.secondary)
            } else {
                ChatText(text: parts.body, size: 15).frame(maxWidth: .infinity, alignment: .leading)
                if h.state == "stopped" {
                    // Its orb says "tap to see what it did"; in here they already see it.
                    Text(h.line.components(separatedBy: " · ").first ?? h.line).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !parts.choices.isEmpty && h.state != "working" && h.state != "stopped" {
                ChoiceRow(choices: parts.choices, disabled: m.paused || !m.isReady) { c in
                    Task { await m.choose(c) }
                } onOther: {
                }
            }
            buttons
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xF0A04B, h.state == "needsYes" ? 0.55 : 0), lineWidth: 1.2))
    }

    @ViewBuilder var buttons: some View {
        // Still at work or waiting for their yes: it can only be stopped here. "Got it" comes once it's done or stopped.
        if HelperClose.busy(h) {
            HStack {
                Spacer()
                Button {
                    m.stopHelper(h.id)
                } label: {
                    Label("Stop this helper", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered).help("Stops this job. What it found so far stays here.")
            }
        } else {
            HStack(spacing: 8) {
                Spacer()
                if h.state == "stopped" && h.resumeQueued != true {
                    Button {
                        m.startAgain(h.id)
                    } label: {
                        Label("Start again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).help("Sends this job out again, from the start")
                }
                // One of the only two ways an orb leaves the screen (the other is asking): never on its own, never from the orb.
                Button {
                    m.closeHelper(h.id)
                } label: {
                    Label("Got it", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                .help("Takes this helper off your screen. Its file stays in Ready for you.")
            }
        }
    }
}

/// Render-only (`--render-world helper-stop`): a stopped helper's orb next to a working one, and a stopped helper
/// opened as a conversation with the update card above it.
struct HelperStopScene: View {
    var working = false  // the opened helper is still at work: its Stop button
    var opened: String? = nil  // `helper-stop-got-it` / `helper-stop-needs-yes`: a done one (Got it) or one waiting for a yes (Stop only)
    static func helper(_ state: String, line: String, reply: String = "") -> Helper {
        var h = Helper(title: "Flight to Quebec", task: "Find the cheapest flight to Quebec City.", sid: nil, state: state, line: line)
        h.reply = reply
        h.stoppedByYou = state == "stopped" ? true : nil
        return h
    }
    @MainActor static func ready() {
        Updater.shared.available = (
            "0.9.28", "- Stop any helper from its orb or by asking\n- Updates no longer wait for helpers", URL(fileURLWithPath: "/")
        )
    }
    var body: some View {
        let stopped = Self.helper(
            "stopped", line: HelperTrail.stoppedLine, reply: "So far the cheapest is **$212** on Dec 20 (United, from EWR).")
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 26) {
                ForEach(Array([Self.helper("working", line: "Checking Google Flights…"), stopped].enumerated()), id: \.offset) { i, h in
                    VStack(spacing: -10) {
                        HelperOrb(state: h.viewState, t: 21.7 + Double(i) * 3.1, size: 42)
                        HelperLabel(title: h.title, line: h.line)
                    }
                }
            }.frame(width: 200)
            VStack(spacing: 14) {
                UpdateCard()
                HelperCard(m: Model.shared, h: card(stopped))
            }.frame(width: 520)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(WorldLook.bg).environment(\.colorScheme, .dark)
    }
    /// Its `--render-world` names: helper-stop, -working, -got-it (a done one), -needs-yes (Stop only).
    @MainActor static var renders: [(String, AnyView)] {
        [
            ("helper-stop", AnyView(Self())), ("helper-stop-working", AnyView(Self(working: true))),
            ("helper-stop-got-it", AnyView(Self(opened: "done"))), ("helper-stop-needs-yes", AnyView(Self(opened: "needsYes"))),
        ]
    }
    func card(_ stopped: Helper) -> Helper {
        if working { return Self.helper("working", line: "Checking Google Flights…") }
        if opened == "done" {
            return Self.helper("done", line: "Done", reply: "Cheapest is **$212** on Dec 20 (United, from EWR). Saved in Ready for you.")
        }
        if opened == "needsYes" {
            return Self.helper("needsYes", line: "Needs your yes", reply: "Found **$212** on Dec 20. Book it?\n\n[choices: Yes, book it | Not now]")
        }
        return stopped
    }
}
