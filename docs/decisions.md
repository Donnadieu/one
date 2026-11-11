# Decisions

Design decisions that are easy to undo by accident. Newest first. Each says what was picked, what was rejected and
the evidence.

## Hand-offs keep the helper's own tab (0.9.113, Nov 11 2026)

**Problem.** From 0.9.58 (Oct 28 2026, `HumanCheck.wanted` widened from robot checks to every kind) to 0.9.112, a step
only the person can do made One close the hidden browser (`HumanCheck.closeHidden`, `HumanCheck.swift:84` at
v0.9.112) and open the same profile as a visible Chrome window on the same address (`HumanCheck.swift:86`); after Done
it quit that window and reopened the address again in a new hidden tab (`HumanCheck.swift:143`). A step that lives
only in the open tab can't survive that. Proved on DocuSign's free developer sign-up (throwaway headless Chrome, email
code only, Nov 11 2026): opening the "Check your email" step's own address in a new tab of the SAME running browser
shows a fresh "Create Your Free Account" form. Omar was shown DocuSign's log-in page twice. 0.9.112 (keeping
session cookies through the close) didn't help, because the cookies weren't what was lost. Robot checks and Claude
sign-ins had worked through it because those pages come back on a reload.

**Picked: by the step's kind, never reopen the tab.**
1. Code: no browser at all. Inbox first (Gmail tokens the engine already has), else One's card asks for the code in
   a box, or their phone chat when they're away (their reply is the code). The engine types it into the still-open
   tab and checks the page moved on. Works at the Mac, from the phone, and with no screen (cloud).
2. Sign-in, approve: the same live tab in One's window (StepWindow: the page's real address on top, a picture from
   the first moment, clicks and typing passed to the page), or the phone link (PhoneSession) when away.
3. Robot check, passkey, security key: the plain Chrome window, as before. A click through DevTools is refused by
   Cloudflare (proved Oct 28), and a hidden browser can't show the Mac's passkey sheet; these pages come back on a
   reopen.

**Rejected: run the hidden browsers as normal (headful) Chrome kept off screen and bring the same window forward.**
Spike on a GitHub macOS runner (branch `spike-headful-window`, Nov 11 2026): bringing the SAME window and tab on
screen and back works (typed text and page state kept). But a normal Chrome is a regular app: it sits in the Dock and
Cmd-Tab the whole time (`ApplicationType=Foreground`; `lsappinfo setinfo` can't change it), its window shows on
screen and takes the focus at start (`-30000,-30000` is clamped to `0,31`; the app is active), and off-screen
positions are clamped. That breaks the no-surprise-windows rule for every hidden browser, all day, to fix one step.

**Guard.** `make handoff` (fresh-install CI): pages that exist only as a POST answer (`tests/handoff/post_server.py`;
a GET bounces to log-in). It fails if the tab is ever reopened, the browser closed, or the code doesn't land in the
same tab. Red on 0.9.112 (run 43058647342), green on 0.9.113.
