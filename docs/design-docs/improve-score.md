# One gets better by itself, step 1: the score (look-only)

Design: "One gets better by itself" (Nov 5, 2026), sections 3a, 5, 6, 7 and build step 1. This step only
measures. Nothing here edits a skill, a note, a routine or a setting.

## What runs
- **Collector** (`Improve.collect`, no AI, seconds): reads the engine's history `hermes/state.db` read-only
  (`mode=ro`, `query_only`; when the file is in WAL mode and no `-wal` file exists, nobody is writing, so it's
  read as immutable), plus One's own files: `hermes/logs/{gateway,one-gateway-guard,one-routing,one-learning}.log`,
  `handoff/*.request.json`, `hermes/cron/output/*/*.md`, `learning.json` (helper id → conversation and title),
  `helpers/<id>.md` trails, and for health `hermes/memories`, `hermes/config.yaml`, the skills folders and
  `hermes/cron/jobs.json`. It writes `improve/days/<YYYY-MM-DD>.json` (counts, events, incidents).
- **Score** (`ImproveScore`): one line a day in `improve/score.jsonl`, one per ISO week in `improve/weeks.jsonl`.
- **Once a day by itself**: `Improve.tend()` runs from the app's every-few-seconds loop (3 minutes after launch,
  once per calendar day, in the background), so the score exists even without the nightly routine.

## Command line (for the nightly review routine and the morning brief)
    One --improve collect [--date YYYY-MM-DD | --since YYYY-MM-DD]   # default: last collected day (max 14 back) to today
    One --improve score [--week]          # 1-3 plain lines: this week (or last week) against the week before
    One --improve moments [--date D] [--max 20]   # default: yesterday; markdown, 2 replies before and after each event
    One --improve settings [show | set <key> <value>]   # improve/settings.json: mode suggest|edit, max_edits_per_night,
                                                         # max_edits_per_skill, snapshot_first, auto_undo_on_drop

## Signals (design 3a)
| Kind | Sub-kinds | Rule |
|---|---|---|
| correction | phrase, stated_rule, stopped, redo, undo | the person's message right after a reply matches `Corrections` (hidden notes, wrappers, routine reports and pasted transcripts left out; polite no's skipped; "always…/never…" = stated_rule); a trail ending "Stopped by you"; routing's `redo:` line; Undo in `one-learning.log` |
| broke | cut_off, picked_back_up, helper_failed, engine_stop, routine_not_done, routine_partly, routine_failed, failed_steps, repeated_step | an assistant row starting "Gateway shutting down: this turn was interrupted"; One's own "You were interrupted by a restart" note inside a helper's conversation (once a conversation a day; the gateway guard's log repeats one pick-up per engine, so it isn't counted); the gateway guard's "didn't finish … stopped"; SIGTERM in gateway.log; the report's `## Response` saying "Not done:", "Partly done:" or `[CRON_FAILURE]`; 3 failed steps in a row; the same tool call twice in a row (polling tools left out) |
| wall | handoff, handoff_answered, folder_lock, signed_out, rate_limit | a handoff request; a FAILED step (non-zero exit, an error, `success: false`) mentioning "Operation not permitted", a 401 / signed out / expired token, or a rate limit / quota |
| slow | helper_long, many_steps, command_timeout | a helper's first full answer more than 3× the median of similar past jobs (same first skill opened; else all helpers) and over 15 min; more than 2× the usual steps (20 or more); a command at the time limit in the engine's own words: `[Command timed out after Ns]` with exit code 124, "Error executing tool '…': timed out after", a code cell's `"status": "timeout"` (a step whose output only mentions a timeout doesn't count) |
| health | notes_near_full, skill_too_big, skill_twice, link_loop, routine_failing | MEMORY.md / USER.md at 90% of `memory_char_limit` / `user_char_limit` (2200 / 1375); a SKILL.md over 12 KB; one skill name in two places; a folder linking back into itself; an enabled routine whose last run failed. Only in today's file |

Conversations: helper = first message "You're one of … helpers"; resumed = "You were interrupted by a restart";
main chat = `acp`/`local` otherwise; routine = `cron`; phone = `telegram`. Messages from the person count in main,
helper, resumed and phone conversations.

## Measures (design 5)
- **Right the first time**: helpers (by start day) with no correction, cut-off reply, stop, redo, pick-back-up or error stop.
- **Corrections per 100 messages**: correction phrases and stated rules ÷ messages from the person (stops, redos and Undo are events, not messages).
- **Same mistake again**: from `improve/lessons.jsonl` (written by the nightly review): a lesson's last line with
  `status` rule/proven/retired, `rule_since` and `seen` dates; each `seen` date after `rule_since` counts once. 0 until lessons exist.
- **Cut off**: interrupted replies + helpers picked back up whose conversation had no interrupted reply that day.
- **Walls**: handoffs + folder lock + signed out + rate limits (failed steps only). **Slow jobs**: helpers far longer than similar
  jobs (3× the median and over 15 min) + commands at the time limit. Helpers over 30 min stay in the line as their own number.
- A week with fewer than 20 helpers shows "not enough jobs this week" instead of a %. Each line also carries `kinds` (job kind → [helpers, right]).
- **Incidents** (design 6.2): a signal more than 5× its usual daily level (median of the 14 days before; at least 6)
  becomes one incident record and its events leave the day's list (counts stay). The person's corrections never fold.

## Private stays private
A conversation is private when the person's own words, the assistant's words or a step's arguments mention the
Nyx room (`nyx-room`, the word Nyx), a `confidential/` path or a shared room (`One Rooms/`, iCloud Drive, each
shared room's folder), or a step's result shows such a path. Its events keep counts but no quote, and moments
leave the whole conversation out (and drop any line that mentions one). One's hidden notes don't count, since
they name every room.

## Tuned against real records (Nov 2026)
Run on a read-only consistent copy of Omar's `state.db` (Oct 23 to Nov 4, 22:29) in a scratch One folder, summed over the
design's own weeks (Oct 23-29, Oct 30-Nov 5; local days). The first run was compared on ISO weeks (Oct 26-Nov 1, Nov 2-8),
which is most of the old gap: different days, not different counting.

| Measure | Design (wk 1 / wk 2) | Before tuning | After tuning |
|---|---|---|---|
| Helpers | 229 / 56 | 229 / 62 | 229 / 62 |
| Right the first time | 66% / 69% | 68% / 60% | 65% / 58% |
| Corrections per 100 messages | 6.5 / 9.3 | 6.3 / 9.2 | 6.3 / 9.2 |
| Cut off | 121 / 16 | 157 / 31 | 133 / 23 (121 / 16 replies + 12 / 7 helpers picked back up with no reply cut off) |
| Walls | 23 / 2 handoffs (+ ~130 folder lock, 14 signed out, 6 rate limits over both weeks) | 97 / 63 | 97 / 63 (handoffs 23 / 2, folder lock 69 / 53, signed out 4 / 8, rate limit 1 / 0) |
| Slow jobs | 59 + 123 / 22 + 156 (over 30 min + time limit) | 121 / 145 (over 30 min + time limit) | 113 / 146 (22 / 16 far longer than similar + 91 / 130 at the time limit) |

What's left, honestly: the design's week 2 ended Nov 5 3 am **UTC** and its days look like UTC days, so its weeks hold
other helpers (56, not 62). Its time-limit count matched any step whose output says "timed out after" (121 / 156 on this
copy), which also counts logs and test output; the collector keeps the engine's own words only. Its 59 / 22 helpers over
30 minutes couldn't be reproduced (the first full answer gives 31 / 10, the last reply 70 / 25). Right the first time is
lower because a helper picked back up after a restart counts as not right (step 1's rule), and the history holds 85 such
pick-ups that the design's 6 restarted conversations didn't see.

