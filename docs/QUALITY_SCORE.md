# Quality score

| Area | Score | Gaps |
|---|---|---|
| Install + engine | 8/10 | pinned + fresh-install tested; not yet on a second Mac; builds go to `build/app.noindex` so the Mac's Apps view shows only the installed One |
| Folder lock | 8/10 | tested by preflight; per-connection paths added by hand; restart after a new folder tested by `--test-restart` (decision + helper stop), not yet live on a running One |
| Voice | 6/10 | works on Omar's Bluetooth headset; no automated check of playback; "stop talking just this once" (Esc / orb click) logic tested by `--test-voice` with a stand-in voice, not live |
| Helpers | 7/10 | trail + pick-up-after-restart (and stopped-with-Stop stays stopped) tested every preflight (`--test-helpers`, stand-in engine); a real restart mid-helper on a running One not yet seen |
| Connections | 5/10 | KeePass verified; Mail/Calendar setup flow untested live |
| Rooms + sharing | 5/10 | two-Mac iCloud share untested |
| Shipped skills | 7/10 | copy/update/keep tested by preflight; Basecamp sign-in from a never-connected Mac untested |
| Updater | 7/10 | detection and announce-once tested every preflight (`--test-updates`); full swap not automated; live notification and spoken line not yet seen on a real Mac |
| Code health | 7/10 | split into 25 area files; all files under 600 lines (baseline empty) |

Updated: 2026-10-26
