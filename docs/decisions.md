# Decisions

Design decisions that are easy to undo by accident. Newest first. Each says what was picked, what was rejected and
the evidence.

## The real window comes back for every step, on the helper's very page (0.9.115, Nov 12 2026)

**Problem.** 0.9.113 replaced the real Chrome window for sign-in and approve steps with One's own picture of the
hidden tab (StepWindow). Omar: the window must be the real browser, as before, with One's card beside it ("the live
view from previous versions stays forever"), and One decides what to show. On 0.9.114 the DocuSign helper called its
SMS code page "approve", so he got that picture instead of a code box, and it took no input. The older window
(0.9.58 to 0.9.112) had its own bug: it opened the page's address again, and DocuSign's code steps exist only as the
answer to a form, so a fresh load showed the sign-up form (reproduced live Nov 12: the window showed "Create Your Free
Account" at the code step's address).

**Picked.**
1. Every step can be shown in the real window (`HumanCheck.wanted` is every kind again); StepWindow is never shown.
2. A code is asked in the card's box first ("I need the code <site> sent you. Type it here and I'll take care of it."),
   with Show the window on the same card. After two codes that didn't work, the card says so and offers the window.
3. The window opens on the helper's very page (`StepPageCopy`): a page reached by sending a form (navigation
   `form_submit`, or Chrome has no copy to give) is kept as a still copy (fields as typed, the page's style sheets
   including rules scripts wrote, scripts left out) and shown at its real address through the window's DevTools
   socket (`Fetch.fulfillRequest`, once). What the person submits goes to the site itself. Pages the site sends in the
   window are kept as sent (`StepPageWatch`) so the helper's tab comes back on the person's last page with its scripts
   working. A page its address brings back opens by its address, as before.
4. The engine decides the kind from the page: a code box means a code step, whatever the helper asked.

**Rejected.** Replaying the page with its own scripts: DocuSign's React app drew the step twice. Reloading or
re-sending the form: a reload lands on the sign-up form, and re-sending would send another text.

**Proof.** Live DocuSign developer sign-up, throwaway accounts and browser, a test copy of One (`--qa-handoff`): email
code through the card (inbox) and through the window; Omar's texted code through the card's box (accepted, "Set your
password"), and his texted code typed in the real window (accepted, window closed, helper's tab on "Set your
password"). Guard in CI: `make handoff` part 3 (window on a POST-only step, never a GET of it) and the code loop's
part 2 (window offer) and part 8 (a code page called "approve" gets the code box).

## A code ask always ends, and never before a code was sent (0.9.114, Nov 11 2026)

**Problem.** On 0.9.113 a helper on DocuSign's SMS step pressed Send Code (the code box did appear, at the same address
as the phone-number step) and handed off; the text never reached Omar. In `code_step` (`one_human_step.py:794-812` at
v0.9.113) only `away` ended the wait: any other answer without a code fell to "Done with no code" and made a new ask,
and a wrong code made a new ask with no limit. "I'm not at the Mac" on the card did nothing once the phone had been
asked (`HumanStep.swift:123` + `:167` returned before writing an answer). A message to the helper waited behind the tool
call, and a Stop didn't end it (the tool thread kept polling with its cached tab id).
**Picked.** Two tries, then `code_failed`; every answer (and Stop, and a closed tab) ends the wait; a message to the
helper becomes the answer; the code ask refuses on a page with no code box. Proof: tests/handoff/e2e_code_loop.py,
phone_replies.py and `HumanStepWaysOutCheck` (red on v0.9.113, green after).
**Rejected.** Keeping the retry loop with a longer limit (Omar: never ask a third time on its own).

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
