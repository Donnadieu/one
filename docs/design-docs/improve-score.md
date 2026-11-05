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
| broke | cut_off, picked_back_up, helper_failed, engine_stop, routine_not_done, routine_partly, routine_failed, failed_steps, repeated_step | "Gateway shutting down: this turn was interrupted"; the gateway guard's "didn't finish … picking it back up / stopped"; SIGTERM in gateway.log; the report's `## Response` saying "Not done:", "Partly done:" or `[CRON_FAILURE]`; 3 failed steps in a row; the same tool call twice in a row (polling tools left out) |
| wall | handoff, handoff_answered, folder_lock, signed_out, rate_limit | a handoff request; a FAILED step (non-zero exit, an error, `success: false`) mentioning "Operation not permitted", a 401 / signed out / expired token, or a rate limit / quota |
| slow | helper_long, many_steps, command_timeout | a helper's first full answer more than 3× the median of similar past jobs (same first skill opened; else all helpers) and over 15 min; more than 2× the usual steps (20 or more); a command at the time limit |
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
- **Walls**: handoffs + folder lock + signed out + rate limits. **Slow jobs**: helpers over 30 min + commands at the time limit.
- A week with fewer than 20 helpers shows "not enough jobs this week" instead of a %. Each line also carries `kinds` (job kind → [helpers, right]).
- **Incidents** (design 6.2): a signal more than 5× its usual daily level (median of the 14 days before; at least 6)
  becomes one incident record and its events leave the day's list (counts stay). The person's corrections never fold.

## Private stays private
A conversation is private when the person's own words, the assistant's words or a step's arguments mention the
Nyx room (`nyx-room`, the word Nyx), a `confidential/` path or a shared room (`One Rooms/`, iCloud Drive, each
shared room's folder), or a step's result shows such a path. Its events keep counts but no quote, and moments
leave the whole conversation out (and drop any line that mentions one). One's hidden notes don't count, since
they name every room.
