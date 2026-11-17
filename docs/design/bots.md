# Bots (design, not built)

Status: design proposal, Nov 17 2026. Nothing here is built. Two directions are drawn in Claude Design
(project "One bots design": `Bots A - Bots shelf.dc.html`, `Bots B - Moons.dc.html`); Omar picks one before any
code. The screen it starts from is One 0.9.122 (read from tag `v0.9.122`; the home and Routines views did not
change since 0.9.119, whose renders are used as "today").

## Why

Omar's friends use Grok Bot, Meta's Muse and OpenAI's dots. His friend Danny runs a "Growth bot" that only grows
his business and an "Intake bot" that answers leads. One already sends helpers, but a helper is one job that ends.
Omar wants bots he can always go back to, each focused on one thing: the same use as those products, not the same
interface.

## The idea in one line

**A bot is a helper you keep.** Iris stays the front door. A bot is who; a routine is when.

## Concepts

| Word | Plain meaning | Already in One? |
|---|---|---|
| Iris (the assistant) | The front door. Routes, answers, sends helpers, makes bots. Never replaced. | Yes |
| Helper | One job that ends. Its orb drifts back when done. | Yes |
| **Bot** | A helper you keep: one purpose, a name and colour, its own chat that stays, its own memory of what it did, and only the connections it needs. | New |
| Routine | Something that runs at a time. Can now belong to a bot. Stays on the Routines dial. | Yes |
| Room | A part of life with its own rules. Every bot lives in one room. | Yes |

What a bot is made of:

1. **One job**, in its own words ("Find new customers for the heating business").
2. **A name and a colour**. Its picture is a small copy of One's orb in that colour, never an avatar.
3. **Its own chat**, kept forever (like Iris's, by day), reopened from the left side.
4. **Its own memory** of what it did: a dated log and the lasting rules it was told. Lives in its room, so it is
   backed up with the brain and survives switching AIs.
5. **Only the connections it needs** (Browser, Email drafts, Facebook…). Everything else is closed to it.
6. **How it checks in**: every morning / when something comes in / only when asked. Checking in on its own only
   reads and drafts; anything that sends, spends or posts waits for a yes.

## How you make one

- **By saying it.** "Make me a growth bot." Iris asks three quick questions, one at a time:
  1. What's its one job? (typed)
  2. What may it use? (chips, selected = outline + check)
  3. Should it check in on its own? `[Every morning | When something comes in | Only when I ask]`
  Then a preview card (name, room, what it uses, when it checks in, "asks before posting, sending or spending")
  with `[Make the bot | Change something]`. The room is the one the chat is in; Iris asks only if it could be two.
- **From a helper.** A finished helper gets **Keep as a bot** next to Got it. A small card: name (prefilled from
  the helper's title), six colour dots, room, "It keeps this chat and what it learned." `[Keep it | Not now]`.
- Changing a bot later is also by talking to it ("from now on, never text after 8 PM"). No settings page.

## The left side

A left column of bots balances Ready for you on the right.

- Grouped by room. Private rooms (Personal, Nyx) show a lock and a count ("2 bots") and hide names and lines until
  tapped. Shared rooms show only bots made in that room.
- Each row: colour orb, name, what it's doing now ("Answering 2 new leads…", "3 posts drafted · needs your yes" in
  orange, "Resting · next check 8:00 AM"), and an unread dot.
- Tap a bot: its chat opens in the middle with **‹ Back to Iris** at the top. Iris and her orb stay home.
- Collapses to coloured dots (orange ring = needs your yes; dot = unread).
- **+ New bot** at the bottom (asks Iris, same three questions).

**Decision: the left side appears only after the first bot.** Reasons:
- Omar's simplicity rule: a person who never makes a bot never sees an empty column or a new word.
- The natural way in is Keep as a bot on a helper that just did something useful, so discovery happens at the
  right moment, not as a blank panel on day one.
- One less state at first launch for non-technical people; the window keeps today's width.
- A one-time card ("New: keep a bot…") tells existing users once. Direction B shows the alternative (a single faint
  "New bot" circle always at the left edge) so Omar can see the trade-off.
- Exception: a box that ships with bots (below) shows the left side from first launch, because there is
  something in it.

## The two directions

| | A · Bots shelf | B · Moons |
|---|---|---|
| Left side | A panel, twin of Ready for you | No panel: small coloured orbs on the stage edge, names beside them |
| Working | Status line | Status line + a thread from the bot to Iris with a travelling light |
| Collapsed | 52 px strip of dots | Just the orbs; names fade |
| Bot chat | Takes over the middle; bot header + facts (uses, checks in, remembers N things) | Large card over the dimmed home; "What it did" strip of dated beads |
| Make by chat | Three questions in the chat + preview card | One "New bot" card with steps 1-2-3, a new orb forming on the left |
| Keep as a bot | Button on the finished helper card + small card | Helper orb arcs into the column and turns into a bot |
| Routines filter | Chips under the title | The bots' orbs as a row under the title |
| First time | Hidden until the first bot | One faint "New bot" circle |

**Recommendation: B**, with A's three quiet facts (uses, checks in, remembers N things) added to the bot's chat
header. It keeps the left side Omar asked for in One's own world look, so it doesn't read as "what every other app
has", and a working bot's thread to Iris shows at a glance who is busy. A is the fallback if B gets crowded past
about eight bots. Omar decides.

Gaps the design tool filled with made-up content (not real data): business details (Oak Park, Riverside), sample
helpers and routines, and a "Business" room for the contractor's bots.

## Routines (stay their own page)

- The Routines page keeps the 24-hour dial. A routine can belong to a bot.
- New: a filter by bot under the title (`All · Iris · Growth bot · …`). Selected = outline + check.
- Each routine's mark on the dial takes its bot's colour; Iris's own routines stay cream. The detail card says
  "Belongs to Growth bot".
- Asking a bot "do this every morning" makes a routine owned by that bot (it shows on the dial at once).

## Same rules as today

- A bot asks before sending, spending or posting (orange, like a helper that needs your yes). Enforced the way
  helpers are today; nothing new to trust.
- A bot lives inside a room, follows that room's `policy.yaml`, and writes only there.
- "Tell Intake bot …" in Iris's chat passes the message on, like `[tell-helper: …]` (`HelperTell.swift`).
- The morning brief rolls up what each bot did, one line per bot, labelled by room; private-room bots only as a
  headline.
- Stop works on a bot the same way as on a helper. Hiding a bot keeps its memory and routines.

## The contractor box

A Mac mini running One, shipped with a **Growth bot** and an **Intake bot** preloaded from Danny's setup, with Grok
as the brain.

- First launch: Iris greets by name ("Hi Luis, I'm Iris. Two bots came with this Mac, set up by Danny."). The left
  side is open with both bots marked "Not set up yet".
- One plain card per bot: what it does in one sentence, the one thing it needs from them ("Your Facebook sign-in",
  "Your texts") and **Set it up**. Footer: "Nothing runs until you say so."
- "Thinking with Grok" shows quietly in the name area; Switch AI still works.
- A preloaded bot carries its job, rules, colour and routines (off until set up), never logins or someone else's
  chat history (the same line Grok Bot draws for shared templates).
- Setting up a bot reuses today's paths: Connections › Passwords for logins, the hidden browser for sign-ins,
  hand-off for codes. No time promises in the words.

## Data model sketch (for later; nothing built)

```text
Support/One/bots.json            # the list, like UserDefaults `helpers` today
  [{ id: UUID,
     name: "Growth bot",
     color: "amber",             # one of six
     room: "co-founder",         # folder name of the room
     job: "Find new customers for the heating business",
     uses: ["browser", "email-drafts", "facebook"],   # connection ids from ConnectionsWorld
     checkIn: "morning" | "incoming" | "asked",
     sid: "<engine session id>",  # its own kept conversation (session/load, like Iris's)
     routines: ["<cron job id>", …],
     hidden: false,
     from: "chat" | "helper:<helper id>" | "preloaded:<pack name>",
     setUp: true,                 # preloaded bots start false
     unread: 0, line: "Answering 2 new leads…", state: "working|needsYes|resting" }]

<room>/bots/<bot-name>/
  bot.md          # job, rules it was told to keep, what it may use (human-readable, linked from the room hub)
  memory/YYYY-MM-DD.md   # dated log of what it did (feeds "What it did" and the morning brief)
  chat/YYYY-MM-DD.json   # kept chat, by day (ChatArchive pattern)
```

- Ownership of a routine: a `bot` field written next to the cron job (One-side map keyed by job id, so the
  engine's `jobs.json` format is untouched).
- "Only the connections it needs": a per-session mark the engine plugin reads before each tool call, the same way
  `LookOnly` marks a helper today (`guard/look-only/<session>.json`).
- A box's preloaded bots: a "bot pack" folder (bot.md + routines with no logins) that One imports at first launch.

## Open questions

1. Name: "bot" is what Omar's friends say. Keep it, or a One word? (Rooms went through the same question.)
2. How many bots before the left side needs search or folding? Grok Bot uses pins and sections; rooms may be enough.
3. Can a bot send its own helpers, or only Iris?
4. Does a bot get a voice of its own, or speak in Iris's voice? (One person, one voice is today's rule.)
5. Phone chat: does "tell Intake bot …" from Telegram reach the bot, and do its approvals come to the phone?
6. A bot in a shared room (Co-Founder): can Ek talk to it too, and whose AI account does it use?
7. Enforcing "only the connections it needs" in code: which connections can the engine plugin really block per
   session today (Browser and Files yes; Email drafts via the Mail bridge)?
8. Contractor box: who updates a preloaded bot when Danny improves his setup (a new pack version, offered like an
   app update?), and who fixes a broken login remotely.
9. Grok as the brain on the box: which Grok plan, and do the bots' check-ins fit its weekly limit?
10. Deleting a bot: same ask-first rule; what happens to its routines and its notes in the room.

## Research (verified, Nov 17 2026)

Correction: these are three products from three companies. Grok's is **Grok Bot** (xAI, now SpaceXSI, run by
Cursor). **Muse** is Meta's. **dots** is OpenAI's.

- **Grok Bot**: "a durable AI teammate with a name, a job, its own conversation, and working context that develops
  over time." Made with **+ New Bot** at the top of a sidebar: name, a shape and colour for its picture, then its
  first message sets its job and limits; existing Bots can create focused ones. A **primary Bot** is the main
  contact and coordinates the rest; "when the same kind of request keeps coming back … give it its own Bot." No
  settings page: change a Bot by telling it. Sidebar: pin, sections by project or business, hide (keeps working),
  compact mode. Memory keeps preferences, rules, facts and "a dated log of what it has worked on". Ask it to repeat a
  task and it becomes a routine. Shared templates carry the job and routines but never logins or history. All Bots
  share one cloud computer. Sources: docs.x.ai/grok-bot/bots, /get-started, /how-grok-bot-works,
  /chat-and-collaboration; x.ai/news/introducing-grok-bot (Aug 11 2026), x.ai/news/grok-bot-1-0 (Nov 2 2026).
- **dots** (OpenAI, Sep 29 2026): start with a "primary dot, give it a name, and make it your own"; teams and
  specialist dots later. "Set boundaries and specify what your dot can do on its own, when it should ask first, and
  what it should never do." Background checking uses read-only tools. Sources: openai.com/index/introducing-dots;
  OpenAI on X; TechCrunch, Wired, VentureBeat (Sep 29 2026).
- **Muse** (Meta, Sep 8 2026): one personal agent in a chat thread; name it, pick an avatar, set how it talks;
  goals become action plans. Muse for Small Business: "Give Muse a goal — like running your business or finding new
  customers"; "nothing publishes, sends, or spends without your approval." Sources: ai.meta.com/muse; about.fb.com
  "Muse for Small Business"; Axios (Sep 8 2026).

Ideas borrowed (not their interface): one job per bot; the main assistant stays the front door; make and change a
bot by talking; group bots by business (rooms); hide, don't delete; preloaded bots carry rules but never logins;
three plain limits (on its own / ask first / never) which One already has; checking in on its own is read-only.
What stays One's own: bots live on your Mac, inside a room, on the AI you already pay for, and Iris never goes away.
