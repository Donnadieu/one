import AppKit
import SwiftUI

// MARK: - "Earlier versions" in the note readers (rooms map note, file reader)

/// The hourly copies of one note that differ, newest first. Pick one to read it, then "Put this one back":
/// One saves the version there now first (a copy labeled "before restore"), so putting one back can be undone too.
struct EarlierVersions: View {
    let path: String
    /// Renders only: made-up versions, and which one is open.
    var fixed: [History.Version]? = nil
    var still = false
    /// Called with a plain line after a version was put back, nil for Back.
    let done: (String?) -> Void
    @State var versions: [History.Version]? = nil
    @State var pick: String? = nil
    @State var working = false
    @State var problem: String? = nil
    static let cream = WorldLook.cream

    init(path: String, fixed: [History.Version]? = nil, still: Bool = false, pick: String? = nil, done: @escaping (String?) -> Void) {
        self.path = path
        self.fixed = fixed
        self.still = still
        self.done = done
        _versions = State(initialValue: fixed)
        _pick = State(initialValue: pick)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if pick != nil { pick = nil } else { done(nil) }
            } label: {
                Label(pick == nil ? "Back to the note" : "All earlier versions", systemImage: "chevron.left").font(.system(size: 12.5))
            }
            .buttonStyle(.plain).foregroundStyle(Self.cream.opacity(0.6))
            if let v = versions?.first(where: { $0.id == pick }) {
                open(v)
            } else {
                Text("EARLIER VERSIONS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Self.cream.opacity(0.4))
                    .padding(.top, 18).padding(.bottom, 10)
                if let vs = versions {
                    if vs.isEmpty {
                        Text("No earlier versions yet. One keeps a copy of your notes every hour, and changed ones show up here.")
                            .font(.system(size: 13)).foregroundStyle(Self.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    } else if still {
                        list(vs)
                    } else {
                        ScrollView { list(vs) }
                    }
                } else {
                    Text("Looking for earlier versions…").font(.system(size: 13)).foregroundStyle(Self.cream.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            guard fixed == nil else { return }
            let p = path
            versions = await Task.detached { History.versions(of: p) }.value
        }
    }

    func list(_ vs: [History.Version]) -> some View {
        VStack(spacing: 6) {
            ForEach(vs) { v in
                Button {
                    pick = v.id
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(History.when(v.changed)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Self.cream.opacity(0.92))
                            Text(Self.detail(v)).font(.system(size: 11.5)).foregroundStyle(Self.cream.opacity(0.45))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Self.cream.opacity(0.35))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle()).popupCard(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One version open: when it's from, the note as it was, and the button that puts it back.
    func open(_ v: History.Version) -> some View {
        let text = v.isDir ? "A folder of earlier files." : NotePanel.body(v.url.path)
        let shown = text.isEmpty ? "Nothing was written here then." : text
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Self.cream.opacity(0.85))
                VStack(alignment: .leading, spacing: 3) {
                    Text(History.when(v.changed)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Self.cream.opacity(0.92))
                    Text(Self.detail(v)).font(.system(size: 11.5)).foregroundStyle(Self.cream.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.cream.opacity(0.4)))
            .padding(.top, 16)
            Group {
                if still {
                    Color.clear.overlay(alignment: .topLeading) {
                        GeometryReader { g in Image(nsImage: NoteText.snapshot(shown, width: g.size.width, height: g.size.height)) }
                    }
                    .clipped()
                } else {
                    NoteText(text: shown, size: 14)
                }
            }
            .padding(.top, 14).frame(minHeight: 120)
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color(hex: 0xF2A97E)).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            HStack(spacing: 12) {
                Button {
                    putBack(v)
                } label: {
                    Text(working ? "Putting it back…" : "Put this one back").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WorldLook.bg).padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Self.cream))
                }
                .buttonStyle(.plain).disabled(working)
                Text("What's there now is kept too.").font(.system(size: 11.5)).foregroundStyle(Self.cream.opacity(0.45))
            }
            .padding(.top, 14)
        }
    }

    func putBack(_ v: History.Version) {
        working = true
        problem = nil
        let (p, from, when) = (path, v.snapshot.name, History.when(v.changed))
        Task {
            let r = await Task.detached { History.restore(p, from: from) }.value
            working = false
            switch r {
            case .success: done("Put back the version from \(when). What you had before is kept too, so you can undo this.")
            case .failure(let e): problem = e.text
            }
        }
    }

    /// "3 KB", "3 KB · saved before a restore".
    static func detail(_ v: History.Version) -> String {
        let s = History.size(v.size)
        guard let l = v.snapshot.label else { return s }
        let words =
            l.hasPrefix("before restore")
            ? "saved before a restore" : l.hasPrefix("before nightly") ? "saved before the nightly tidy" : l.replacingOccurrences(of: "-", with: " ")
        return s + " · " + words
    }
}
