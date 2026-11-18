# Omar's corrections, and what guards each one

Every time Omar corrects One (something broke, came back, or never worked), it gets a row here **before** the fix
ships, with the check that fails on the broken version and passes on the fixed one. A correction with no check is
listed as `none yet` so the gap stays visible: the Sunday "One bug-free week" routine reports how many are left.

`tools/corrections-index-check.py` (preflight) fails if a guard named here doesn't exist. A guard is a file in this
repo, a `--test-*` mode, a `Sources/CorrectionsCheck.swift` scenario (`corrections: <name>`), or `rule: <file>` for a
rule that lives in Omar's brain rather than in One's code.

Started Nov 18 2026 from the Iris self-review (Made by Iris, "Iris self-review.pdf"), which went through Oct 20 to
Nov 17 2026. His words are quoted as he wrote them, swear words trimmed.

| Date | His words | What broke | Guard |
|---|---|---|---|
| 2026-10-27 | "I do not want one to open browsers it should be hidden" | helpers opened visible Chrome windows | tools/browser-guard-check.py |
| 2026-10-27 | "We need to have a way to stop workers. This is ridiculous" | no way to stop a helper | tools/stop-plugin-check.py |
| 2026-10-28 | "We keep losing helpers" | helpers vanished after a restart | tools/helpers-check.sh |
| 2026-10-28 | "The human check release feature was a bust" | the step window had no address bar | tools/handoff-check.sh |
| 2026-11-05 | "We already introduced two bugs. Do we have tests in one?" | fixes shipped without a check of the real path | tools/corrections-check.sh |
| 2026-11-09 | (Telegram) choices showed as text, not buttons | phone choices | tools/phone-choices-check.py |
| 2026-11-10 | "I cannot stop this helper what is going on?" | a stopped helper woke up again | tools/stop-plugin-check.py |
| 2026-11-10 | "Yes, fix it" (to the nightly review's ask; the chat couldn't tell what it answered) | the review's ask never reached the chat | corrections: night-ask |
| 2026-11-11 | "Why did we break the sign-in flow? We had this conversation before." | the step window opened on a log-in page | tools/handoff-check.sh |
| 2026-11-11 | "the code didn't work. Type the newest code." loop | a code hand-off never ended | tools/handoff-check.sh |
| 2026-11-11 | "my limit is done but it's not true" | a false account-limit pause | tools/usage-meter-check.py |
| 2026-11-11 | "You were blocked for a few minutes. That's unacceptable" | the main chat busy for minutes | none yet |
| 2026-11-12 | "Who is using my chrome it keeps playing a video stop it" | a hidden browser played sound | --test-hidden-browser |
| 2026-11-16 | (Telegram) "The helper never started" | helper lines from the phone did nothing | tools/phone-tags-check.sh |
| 2026-11-16 | (Telegram, from the hospital) couldn't get his KeePass password on his phone | no way to prove it's him from the phone | none yet |
| 2026-11-17 | "I am confused. You never reply to me. Did you reply?" | main-chat turns cut off ("not processed") | corrections: main-chat-answers |
| 2026-11-17 | "you just name a helper… Another thing doesn't tell me absolutely anything" | helpers named from his first words | corrections: main-chat-answers |
| 2026-11-17 | "You don't have to say that you're free to talk" | a canned line instead of an answer | corrections: main-chat-answers |
| 2026-11-17 | "You sent it as a separate helper. It was the same … helper" | follow-ups became new helpers | corrections: main-chat-answers |
| 2026-11-17 | "Do not send a … helper… stop it" | his stop request became a helper | corrections: main-chat-answers |
| 2026-11-17 | "This seems like a bug that has happened to me before" (helper gone after a folder restart) | a helper waiting for a restart was cleared | tools/restart-wait-check.sh |
| 2026-11-17 | "speech-to-text… Sometimes it says 'Didn't catch that'" | push to talk lost what he said | --test-listener |
| 2026-11-17 | "if it's a lot of routines… it is going over our list or our cluster of skills" | the routines list ran over the skills | --test-routines-list |
| 2026-11-17 | "Again Ek is they/them. I have told you this several times." | a person's pronouns forgotten | rule: My Brain/assistant/how-to-work-with-me.md |
| 2026-11-17 | (routine) "X is signed out in the hidden browser" (also Nov 13) | X sign-in lost in the hidden browser | none yet |
