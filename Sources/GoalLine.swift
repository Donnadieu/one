import AppKit
import SwiftUI

// MARK: - The goal line: the only thing a standing goal adds to the screen
//
// One short line under the orb (the main chat) or inside a helper's thread while that conversation's goal is at work:
// what the goal is, which turn it's on, and Stop (in a helper's thread its own "Stop this helper" does that). Self-contained (a GoalLive and a stop action, nothing from HomeView),
// so a new chat design can place it anywhere.

struct GoalLine: View {
    let g: GoalLive
    /// nil: no Stop of its own (a helper's thread already has "Stop this helper", which ends its goal too).
    let stop: (() -> Void)?
    @State var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "target").font(.system(size: 12, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
            Text(Goals.short(g.goal)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .lineLimit(1).fixedSize()
            Text(Goals.line(g)).font(.system(size: 12).monospacedDigit()).foregroundStyle(WorldLook.cream.opacity(0.55)).fixedSize()
            if let stop {
                Button(action: stop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 8, weight: .medium))
                        Text("Stop").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 9).frame(height: 22)
                    .foregroundStyle(WorldLook.cream)
                    .background(Capsule().fill(WorldLook.cream.opacity(hover ? 0.1 : 0)))
                    .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.22)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).fixedSize().onHover { hover = $0 }
                .help("Stop working on this goal")
            }
        }
        .padding(.leading, 12).padding(.trailing, stop == nil ? 12 : 5).frame(height: 32)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working on a goal: \(g.goal). \(Goals.line(g)).")
    }
}

// MARK: - Renders (`--render-world <prefix>`, from a test copy): `goal-line`, `home-goal`, `helper-goal`

@MainActor
enum GoalRender {
    static let sample = GoalLive(
        goal: "Find the cheapest flight from PHL or Newark to Quebec City, Dec 20 to 24", status: "active", turns: 2, max: 20)
    /// A goal that counts its progress: the turn and the count, no limit (it grows while the count moves).
    static let counted = GoalLive(
        goal: "Build EK's Intake Tool, every requirement built", status: "active", turns: 33, max: 40, done: 120, total: 282)
    static let extended = GoalLive(
        goal: "Build EK's Intake Tool, every requirement built", status: "active", turns: 40, max: 60, done: 150, total: 282, extendedBy: 20)

    /// Draws `name` into `<out>-<name>.png`; false when the name isn't one of these.
    static func draw(_ name: String, _ out: String) -> Bool {
        switch name {
        case "goal-line": png(line(), "\(out)-\(name).png", width: 760, height: 430)
        case "home-goal": HomeRender.png(home(helperOpen: false), "\(out)-\(name).png", height: 760)
        case "helper-goal": HomeRender.png(home(helperOpen: true), "\(out)-\(name).png", height: 760)
        default: return false
        }
        print("wrote \(out)-\(name).png")
        return true
    }
    static let names = ["goal-line", "home-goal", "helper-goal"]

    /// The line alone, wide and in a narrow window, on One's background.
    static func line() -> AnyView {
        AnyView(
            VStack(spacing: 26) {
                StepLine(text: "Checking Google Flights for Dec 20…").foregroundStyle(.secondary)
                GoalLine(g: counted) {}
                GoalLine(g: extended) {}
                GoalLine(g: GoalLive(goal: "Fix the failing tests", status: "active", turns: 11, max: 20, done: 37)) {}
                GoalLine(g: sample) {}
                GoalLine(g: GoalLive(goal: "Tidy my Downloads folder", status: "active", turns: 11, max: 20)) {}
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(WorldLook.bg).foregroundStyle(WorldLook.cream)
            .environment(\.colorScheme, .dark))
    }

    /// The whole home screen while a goal works: in the main chat, or inside a helper's thread.
    static func home(helperOpen: Bool) -> AnyView {
        let m = Model.shared
        HomeView.stillBottom = true  // the line sits under the orb, below the fold at this height
        let v = HomeRender.scene(4)
        if helperOpen {
            var h = Helper(
                title: "Build EK intake tool", task: "Goal: " + counted.goal, sid: "render-helper", state: "working",
                line: "Running the retainer tests…")
            h.reply = "Retainers are in: 12 more requirements built, all their tests pass.\n\nProgress: 150/282"
            h.asked = nil
            m.helpers.insert(h, at: 0)
            m.openHelper = h.id
            m.goals = [h.id.uuidString: extended]
        } else {
            m.bubbles = [
                Bubble(
                    fromMe: true,
                    text: "/goal Find the cheapest flight from PHL or Newark to Quebec City, Dec 20 to 24"),
                Bubble(fromMe: false, text: "Dec 20 from PHL: $312 on United (1 stop). Next, Newark the same day."),
            ]
            m.thinking = true
            m.working = "Checking Google Flights for Dec 20…"
            m.goals = ["main": sample]
        }
        return v
    }

    static func png(_ v: AnyView, _ path: String, width: CGFloat, height: CGFloat) {
        let r = ImageRenderer(content: v.frame(width: width, height: height))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
