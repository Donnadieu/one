import SwiftUI

// MARK: - The health line under the orb, and its small list (Claude Design "One Safety Features", Direction A)

/// What the home screen shows of the watchdog (HealthWatch.swift, HealthRun.swift).
@MainActor final class HealthBoard: ObservableObject {
    static let shared = HealthBoard()
    @Published var rows: [HealthRow] = []
    @Published var done: [HealthStore.Done] = []
    @Published var open = false
    @Published var acting: Set<String> = []
    var now: () -> Date = Date.init

    func show(_ rows: [HealthRow], done: [HealthStore.Done]) {
        self.rows = rows.filter { !acting.contains($0.id) }
        self.done = done
        if rows.isEmpty && fresh == nil { open = false }
    }
    /// A done line from the last hour: shown under the orb when nothing else is.
    var fresh: String? { done.last.flatMap { now().timeIntervalSince1970 - $0.at < 3600 ? $0.line : nil } }
    /// "Your Mac is almost full: 21 GB left · 1 more", or the latest done line.
    var line: (text: String, more: Int)? {
        if let first = rows.first { return (first.short, rows.count - 1) }
        return fresh.map { ($0, 0) }
    }
    var critical: Bool { rows.contains { $0.critical } }

    func tap(_ row: HealthRow) {
        acting.insert(row.id)
        rows.removeAll { $0.id == row.id }
        Task { @MainActor in
            let line = await Task.detached { await HealthWatch.act(row) }.value
            acting.remove(row.id)
            done.append(.init(at: Date().timeIntervalSince1970, line: line))
        }
    }
    func leave(_ row: HealthRow) {
        rows.removeAll { $0.id == row.id }
        let id = row.id
        Task.detached { HealthStore.leave(id) }
        if rows.isEmpty { open = false }
    }
}

enum HealthLook {
    static let warm = Color(hex: 0xF6B46E)
}

/// Which board the line and the list show: the shared one, or a render's own.
struct HealthBoardKey: EnvironmentKey {
    static let defaultValue: HealthBoard? = nil  // nil: the shared one
}
extension EnvironmentValues {
    var healthBoard: HealthBoard? {
        get { self[HealthBoardKey.self] }
        set { self[HealthBoardKey.self] = newValue }
    }
}

/// The quiet line under the orb: a small dot (orange only when it's critical), the first warning, "· N more".
struct HealthLine: View {
    @Environment(\.healthBoard) var board
    var body: some View { HealthLineIn(b: board ?? .shared) }
}
struct HealthLineIn: View {
    @ObservedObject var b: HealthBoard
    var body: some View {
        if let l = b.line {
            Button {
                b.open = true
            } label: {
                HStack(spacing: 7) {
                    if b.rows.isEmpty {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.5))
                    } else {
                        Circle().fill(b.critical ? HealthLook.warm : WorldLook.cream.opacity(0.55)).frame(width: 6, height: 6)
                    }
                    Text(l.text).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.72)).lineLimit(1)
                    if l.more > 0 { Text("· \(l.more) more").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.4)).fixedSize() }
                }
                .padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("See what's slowing your Mac").transition(.opacity)
            .accessibilityLabel(l.text + (l.more > 0 ? ", and \(l.more) more" : ""))
        }
    }
}

/// The small list: one row per warning with its buttons, then the lines of what One cleaned up by itself.
struct HealthList: View {
    @ObservedObject var b: HealthBoard
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(b.rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().overlay(WorldLook.cream.opacity(0.08)) }
                HealthRowView(row: r, tap: { b.tap(r) }, leave: { b.leave(r) }).padding(.trailing, i == 0 ? 26 : 0)
            }
            ForEach(Array(b.done.suffix(3).enumerated()), id: \.offset) { i, d in
                if i > 0 || !b.rows.isEmpty { Divider().overlay(WorldLook.cream.opacity(0.08)) }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Text(d.line).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12).padding(.trailing, b.rows.isEmpty && i == 0 ? 26 : 0)
            }
            if b.rows.isEmpty && b.done.isEmpty {
                Text("Your Mac is doing fine.").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7)).padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 6).frame(width: 400, alignment: .leading)
    }
}

struct HealthRowView: View {
    let row: HealthRow
    let tap: () -> Void
    let leave: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(row.critical || !row.gentle ? HealthLook.warm : WorldLook.cream.opacity(0.55)).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = row.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let a = row.act { HealthButton(title: a, filled: !row.gentle, action: tap) }
                    if !(row.gentle && row.act != nil) { HealthButton(title: row.leave, filled: false, action: leave) }
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 12)
    }
}

struct HealthButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 26)
                .foregroundStyle(filled ? Color(hex: 0x2A1C10) : WorldLook.cream)
                .background(Capsule().fill(filled ? HealthLook.warm.opacity(hover ? 1 : 0.92) : WorldLook.cream.opacity(hover ? 0.12 : 0.06)))
                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(filled ? 0 : 0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize().onHover { hover = $0 }
    }
}

/// The list as a pop-up over the home column (closes with its X, a click outside and Esc).
struct HealthPopup: ViewModifier {
    @Environment(\.healthBoard) var board
    func body(content: Content) -> some View { content.modifier(HealthPopupIn(b: board ?? .shared)) }
}
struct HealthPopupIn: ViewModifier {
    @ObservedObject var b: HealthBoard
    func body(content: Content) -> some View {
        content.onePopup($b.open, align: .top, inset: EdgeInsets(top: 230, leading: 0, bottom: 0, trailing: 0)) { _ in
            HealthList(b: b)
        }
    }
}

extension View {
    func healthPopup() -> some View { modifier(HealthPopup()) }
}

// MARK: - Renders (`--render-world <prefix>`, from a test copy): `helper-stop-health` (the home screen with the list
// open) and `helper-stop-health-line` (the line under the orb, critical), both from the real rules on made-up readings.

@MainActor
enum HealthScene {
    /// The Nov 9 Mac, made up: 21 GB left of 500, a log growing fast, Docker holding 9 GB, a stopped helper's
    /// dev servers and Conductor's.
    static func sample() -> ([HealthRow], [HealthStore.Done]) {
        let home = NSHomeDirectory()
        func p(_ pid: pid_t, _ path: String, ppid: pid_t = 1, cwd: String = "", mem: UInt64 = 0, wrote: UInt64 = 0) -> HealthProc {
            HealthProc(p: ProcInfo(pid: pid, ppid: ppid, start: 100, path: path), cwd: cwd, cpu: 0, memory: mem, written: wrote)
        }
        var w = HealthWorld()
        w.home = home
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var r = HealthReading(at: t0, pressure: 4, swap: 3_000_000_000, free: 21_000_000_000, total: 500_000_000_000)
        r.procs = [
            p(10, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", mem: 9_000_000_000),
            p(11, home + "/bin/qa-runner", ppid: 400, wrote: 0),
            p(12, "/opt/homebrew/bin/node", cwd: home + "/conductor/workspaces/canvas"),
            p(13, "/opt/homebrew/bin/ruby", cwd: home + "/conductor/workspaces/ledger"),
        ]
        var l = HealthLimits()
        l.idle = 60
        var t = HealthWatch.Track()
        _ = HealthWatch.decide(r, world: w, track: &t, limits: l) { _ in nil }
        for k in 1...3 {
            r.at = t0.addingTimeInterval(Double(k) * 30)
            r.procs[1].written = UInt64(k) * 12_000_000_000
            _ = HealthWatch.decide(r, world: w, track: &t, limits: l) { _ in nil }
        }
        let plan = HealthWatch.decide(r, world: w, track: &t, limits: l) { _ in (home + "/Downloads/qa.log", 78_000_000_000) }
        let closed: [(proc: HealthProc, why: String)] = (0..<4).map { _ in
            (HealthProc(p: ProcInfo(pid: 20, ppid: 1, start: 1, path: "/opt/homebrew/bin/node")), "stopped")
        }
        let done = [HealthStore.Done(at: Date().timeIntervalSince1970 - 120, line: HealthWatch.doneLine(closed) ?? "")]
        return (plan.rows.filter { !$0.id.hasPrefix("tools:") }, done)
    }
    static func home() -> AnyView {
        let (rows, done) = sample()
        let b = HealthBoard()
        b.show(rows, done: done)
        b.open = true
        return AnyView(
            HomeRender.scene(4).environment(\.healthBoard, b).frame(width: 1180, height: 760).scaleEffect(820 / 1180).frame(width: 820, height: 560)
                .clipped())
    }
    static func lineOnly() -> AnyView {
        let (rows, done) = sample()
        let b = HealthBoard()
        b.show(rows, done: done)
        return AnyView(
            VStack(spacing: 14) {
                Orb(size: 92)
                HealthLineIn(b: b)
                HealthList(b: b).popupGlass(close: {})
            }
            .frame(width: 820, height: 560).background(WorldLook.bg).environment(\.colorScheme, .dark))
    }
    static var renders: [(String, AnyView)] { [("helper-stop-health", home()), ("helper-stop-health-line", lineOnly())] }
}
