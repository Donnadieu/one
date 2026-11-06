import AppKit
import SwiftUI

// MARK: - Render-only (`--render-long <prefix>`, from a test copy): long messages folded and open, under the orb and in
// Message history, the "Paste as a file or as text?" pop-up, the pasted-text chip and a sent message with it, each in
// a big window (1180 × 760, with Ready for you) and a narrow one (620 × 700), to check against Claude Design
// "Long Paste" option 1 · Fold. Fills Model.shared with made-up chat: never run on the real One.

enum LongRender {
    static let transcript: String = {
        let said = [
            ("Omar", "Okay, so the main thing today is picking which problem we go after first."),
            ("Ek", "Right. I keep coming back to the intake calls. Firms miss so many of them after hours."),
            ("Omar", "How many do you think a small firm misses in a week?"),
            ("Ek", "From what I saw at my old firm, maybe ten to fifteen. And each one could be a real case."),
            ("Omar", "That's the money part. If one case is worth a few thousand, that adds up fast."),
            ("Ek", "Exactly. And nobody likes the answering services they use now."),
            ("Omar", "Let's write down who signs off on buying something like this."),
            ("Ek", "Usually the managing partner. Sometimes the office manager if it's under a few hundred a month."),
        ]
        return (0..<214).map { i in
            let (who, line) = said[i % said.count]
            let s = 252 + i * 7
            return String(format: "[00:%02d:%02d] ", s / 60 % 60, s % 60) + "\(who): \(line)"
        }.joined(separator: "\n")
    }()
    static let reply = """
        ## What you decided

        1. **Start with the intake calls.** Ek's numbers: 10 to 15 missed calls a week at a small firm.
        2. **The managing partner signs.** The office manager can say yes under a few hundred a month.
        3. **Talk to five firms first.** Before building anything.

        ## What's still open

        - How much a missed call is really worth. You both guessed a few thousand.
        - Which answering services firms use now, and what they pay.
        - Who reaches out to the first five firms. Ek has two in mind.

        ## Next step

        Ek sends you the two firm names by Friday. You draft the first message.

        Want me to put the open questions in the Co-Founder room?
        """

    /// `--render-long <prefix>`: writes <prefix>-<name>-wide.png and -narrow.png for every state.
    @MainActor static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--render-long"), k + 1 < args.count else { return }
        let out = args[k + 1]
        ChatText.still = true
        HistoryStrip.still = true
        let states = ["folded", "open", "reply", "history", "pages", "find", "ask", "chip", "sent"]
        for s in states {
            for wide in [true, false] {
                let p = "\(out)-\(s)-\(wide ? "wide" : "narrow").png"
                draw(s, wide: wide, to: p)
                print("wrote \(p)")
            }
        }
        exit(0)
    }

    @MainActor static func draw(_ state: String, wide: Bool, to path: String) {
        let size = wide ? CGSize(width: 1180, height: 760) : CGSize(width: 620, height: 700)
        let m = Model.shared
        _ = HomeRender.scene(4)  // the same made-up helpers and shelf as every home render
        if !wide { m.shelf = [] }
        let ask = Bubble(fromMe: true, text: transcript)
        let older = [
            Bubble(fromMe: true, text: "What's on my calendar this afternoon?"),
            Bubble(fromMe: false, text: "A call with Ek at 2, then nothing until 5."),
        ]
        UserDefaults.standard.removeObject(forKey: LongFold.key)
        m.files = []
        m.pasteOffer = nil
        switch state {
        case "open":
            m.bubbles = older + [ask, Bubble(fromMe: false, text: "Got it. Reading the whole call now.")]
            UserDefaults.standard.set(LongFold.key(ask), forKey: LongFold.key)
        case "reply":
            m.bubbles = older + [Bubble(fromMe: true, text: "What did Ek and I decide on today's call?"), Bubble(fromMe: false, text: reply)]
        case "history":
            m.bubbles = [ask, Bubble(fromMe: false, text: reply), Bubble(fromMe: true, text: "Thanks. Put the open questions in the room.")]
        case "pages", "find":
            // Earlier messages a page at a time (ChatPager): two days, a routine report, a picked choice, a long reply.
            m.bubbles =
                MessageHistoryRender.sample + [
                    Bubble(fromMe: true, text: "What did Ek and I decide on today's call?"), Bubble(fromMe: false, text: reply),
                    Bubble(fromMe: true, text: "Thanks. Put the open questions in the room."),
                    Bubble(fromMe: false, text: "Done. They're in the Co-Founder room under today's date."),
                    Bubble(fromMe: true, text: "Is the promo video ready to share?"),
                ]
            ChatPager.shared.sync(live: Array(m.bubbles.dropLast()))
            FindPanel.stillQuery = state == "find" ? "flight" : ""
        case "ask", "chip":
            m.bubbles = older
            HomeView.stillDraft = "Here's today's call with Ek. What did we decide?"
            if state == "ask" {
                m.pasteOffer = PasteOffer(text: transcript, lines: LongPaste.lines(transcript), into: nil)
            } else {
                m.files = [
                    SharedFile(
                        name: "Pasted text, 214 lines", copy: URL(fileURLWithPath: "/tmp/Pasted text.txt"), textCopy: nil,
                        preview: String(transcript.prefix(while: { $0 != "\n" })))
                ]
            }
        case "sent":
            m.bubbles =
                older + [
                    Bubble(fromMe: true, text: "📄 Pasted text, 214 lines\nHere's today's call with Ek. What did we decide?"),
                    Bubble(fromMe: false, text: "You picked the intake calls first, and the managing partner is who signs. Want the full list?"),
                ]
        default:
            m.bubbles = older + [ask, Bubble(fromMe: false, text: "Got it. Reading the whole call now.")]
        }
        defer {
            HomeView.stillDraft = ""
            m.pasteOffer = nil
            m.files = []
            PopupLook.behind = nil
        }
        let history = ["history", "pages", "find"].contains(state)
        HomeView.stillFinding = state == "find"
        defer {
            HomeView.stillFinding = false
            FindPanel.stillQuery = ""
        }
        // Read while the still is drawn (not when the view is built), so they stay set until the end of draw().
        HomeView.stillBottom = true
        defer {
            HomeView.stillHistory = false
            HomeView.stillBottom = false
        }
        if state == "ask" {
            // The pop-up's glass blurs what's behind it, like the real window: draw home once without it first.
            let offer = m.pasteOffer
            m.pasteOffer = nil
            HomeView.stillHistory = false
            PopupLook.behind = image(window(size, history: false), size)
            PopupLook.behindAt = CGPoint(x: 0, y: 52)
            m.pasteOffer = offer
        }
        HomeView.stillHistory = history
        guard let img = image(window(size, history: history), size), let tiff = img.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    @MainActor static func image(_ v: AnyView, _ size: CGSize) -> NSImage? {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height))
        r.scale = 2
        return r.nsImage
    }

    /// The window as HomeRender draws it, at any size; `history` opens Message history.
    @MainActor static func window(_ size: CGSize, history: Bool) -> AnyView {
        let m = Model.shared
        let home = HomeView(m: m)
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                    }
                    NamePill(name: m.name) {}
                    Spacer()
                    TopBarButtons(name: m.name, voiceOff: false, paused: false)
                }
                .padding(.leading, 18).padding(.trailing, 16).frame(height: 52)
                home.frame(height: size.height - 52, alignment: .top).clipped()
            }
            .withStars(top: 52)
            .background(HomeBackdrop(outer: true))
            .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark))
    }
}
