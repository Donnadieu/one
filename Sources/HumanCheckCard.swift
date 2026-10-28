import AppKit
import SwiftUI

// MARK: - The small One card beside the human-check Chrome window
//
// Approved design (Made by Elias "2026-10-28 Human check window.png"): a normal Chrome window with its own
// address bar showing the site, and beside it a smoked-glass One card: "<Site> needs you to tick “I'm human”.
// I'll close this when you're done." with Done and I'm not at the Mac. The card and the window close by
// themselves once the check passes (HumanCheck.run).

@MainActor
enum HumanCheckCard {
    static var panel: NSPanel?
    nonisolated static let size = CGSize(width: 380, height: 256)

    /// "Claude Design" for claude.ai/design pages, else the site itself.
    nonisolated static func siteName(site: String, url: String) -> String {
        if site.hasSuffix("claude.ai") && url.contains("/design") { return "Claude Design" }
        return site
    }

    nonisolated static func action(_ kind: String) -> String {
        switch kind {
        case "code": return "enter the code"
        case "passkey": return "use your passkey"
        case "security_key": return "use your security key"
        case "approve": return "approve it on your phone"
        case "signin": return "sign in"
        default: return "tick “I'm human”"
        }
    }

    static func show(id: String, site: String, url: String, kind: String, pid: pid_t?) {
        close()
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        let card = HumanCheckCardView(site: siteName(site: site, url: url), action: action(kind), name: Shelf.who) { answer in
            Model.shared.answerHumanStep(id, answer)
        }
        p.contentView = NSHostingView(rootView: card.environment(\.colorScheme, .dark))
        panel = p
        place(pid: pid)
        p.orderFrontRegardless()
    }

    /// Beside the Chrome window (right side if there's room, else left, else inside its right edge).
    static func place(pid: pid_t?) {
        guard let p = panel, let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        var origin = CGPoint(x: vis.maxX - size.width - 24, y: vis.midY - size.height / 2)
        if let pid, let r = chromeFrame(pid: pid) {
            // CGWindow bounds are top-left based; flip to AppKit's bottom-left.
            let top = screen.frame.maxY - r.minY
            let y = min(max(top - r.height / 2 - size.height / 2, vis.minY + 12), vis.maxY - size.height - 12)
            if r.maxX + 16 + size.width <= vis.maxX {
                origin = CGPoint(x: r.maxX + 16, y: y)
            } else if r.minX - 16 - size.width >= vis.minX {
                origin = CGPoint(x: r.minX - 16 - size.width, y: y)
            } else {
                origin = CGPoint(x: min(r.maxX, vis.maxX) - size.width - 24, y: y)
            }
        }
        p.setFrameOrigin(origin)
    }

    /// The largest on-screen window of that Chrome (bounds need no screen-recording permission).
    static func chromeFrame(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: CGRect?
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if r.width * r.height > (best.map { $0.width * $0.height } ?? 0) { best = r }
        }
        return best
    }

    /// Render `check-card` (One --render-world).
    static func scene() -> AnyView {
        AnyView(
            HumanCheckCardView(site: "Claude Design", action: action("check"), name: "Elias") { _ in }.padding(30)
                .background(WorldLook.bg).environment(\.colorScheme, .dark))
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct HumanCheckCardView: View {
    let site: String
    let action: String
    let name: String
    let answer: (String) -> Void
    static let ink = Color(hex: 0x141416)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Orb(size: 26, active: false).frame(width: 34, height: 34)
                Text(name).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7))
            }
            .padding(.bottom, 14)
            (Text(site).fontWeight(.semibold) + Text(" needs you to ") + Text(action).fontWeight(.semibold)
                + Text(". I'll close this when you're done."))
                .font(.system(size: 17)).foregroundStyle(WorldLook.cream).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            HStack(spacing: 10) {
                Button {
                    answer("done")
                } label: {
                    Text("Done").font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.ink).padding(.horizontal, 22).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 11).fill(WorldLook.cream))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                Button {
                    answer("away")
                } label: {
                    Text("I'm not at the Mac").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.75)).padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 11).stroke(WorldLook.cream.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text(
                "This is Chrome, with the sign-ins I keep for you. Nothing of mine is attached while you click. It hides again by itself once the check passes."
            )
            .font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: HumanCheckCard.size.width, height: HumanCheckCard.size.height, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0x1C1B1A).opacity(0.72))
                RoundedRectangle(cornerRadius: 22).stroke(WorldLook.cream.opacity(0.14), lineWidth: 1)
            })
    }
}
