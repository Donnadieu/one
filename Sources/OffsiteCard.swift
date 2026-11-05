import AppKit
import SwiftUI

// MARK: - The one-time "locked copy in iCloud" card on Home, and the recovery code after a yes

/// Shown once on Home (after the get-to-know-you card), never when iCloud Drive isn't on:
/// "Keep a locked copy of your brain in your iCloud? [Yes, keep a copy | Not now]". After a yes (here or in setup),
/// the same card asks them to save the recovery code, with Show and Copy inside One's window only.
struct OffsiteCard: View {
    @ObservedObject var m: Model
    @AppStorage("offsiteOffered") var offered = false
    @State var shown = false
    @State var copied = false
    @State var problem: String?
    @State var code: String? = Offsite.pendingCode
    /// Renders only: which state to draw.
    var still: String? = nil

    /// The card shows: the offer (once, iCloud Drive on, not on yet) or a recovery code still waiting to be saved.
    @MainActor static func shows(_ m: Model) -> Bool {
        guard m.openHelper == nil, !m.thinking, Brain.exists, m.interviewOffered else { return false }
        if Offsite.on { return Offsite.pendingCode != nil }
        return !UserDefaults.standard.bool(forKey: "offsiteOffered") && Offsite.available
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = code ?? (still == "code" ? Offsite.code(Data(repeating: 7, count: 32)) : nil) {
                Text("Your locked copy is on").font(.headline)
                Text("Save this recovery code in your password manager; without it, the iCloud copy can't be opened on another Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if shown || still != nil {
                    Text(c).font(.system(size: 14, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WorldLook.cream.opacity(0.06)))
                }
                HStack(spacing: 8) {
                    Button(shown || still != nil ? "Hide code" : "Show code") { shown.toggle() }.buttonStyle(.bordered)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c, forType: .string)
                        copied = true
                    }.buttonStyle(.bordered)
                    Button("I saved it") {
                        Offsite.codeSaved()
                        code = nil
                    }
                    .buttonStyle(.borderedProminent).tint(WorldLook.cream).foregroundStyle(WorldLook.bg)
                }
            } else {
                Text("Keep a locked copy of your brain in your iCloud?").font(.headline)
                Text(
                    "Each night I'd put one locked copy in iCloud Drive, so your notes are safe if something happens to this Mac. Only you can open it."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(.callout).foregroundStyle(Color(hex: 0xF2A97E)) }
                HStack(spacing: 8) {
                    Button("Yes, keep a copy") { yes() }
                        .buttonStyle(.borderedProminent).tint(WorldLook.cream).foregroundStyle(WorldLook.bg)
                    Button("Not now") {
                        offered = true
                        m.bubbles.append(Bubble(fromMe: false, text: "Okay. Your brain stays on this Mac, with a copy here every hour."))
                    }.buttonStyle(.bordered)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
    }

    func yes() {
        offered = true
        switch Offsite.turnOn() {
        case .failure(let e): problem = "I couldn't turn it on: \(e.text)"
        case .success: code = Offsite.pendingCode
        }
    }
}
