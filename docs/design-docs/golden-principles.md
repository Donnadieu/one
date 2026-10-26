# Golden principles

Each rule names what enforces it. A rule without an enforcer is a gap.

| Rule | Enforced by |
|---|---|
| Files stay under 600 lines | `one-lint: file-length` |
| No hardcoded assistant name in UI | `one-lint: assistant-name` |
| No jargon in UI text | `one-lint: ui-jargon` |
| No broad process kills | `one-lint: broad-kill` |
| No Telegram/WhatsApp | `one-lint: no-messaging` |
| Programs only run from services | `one-lint: process-area` |
| Test hooks never touch real state | `one-lint: test-selftest` |
| Email is never sent by One | `one-lint: no-mail-send` |
| No secrets in source or in the app | `one-lint: no-secrets`, preflight "no keys or tokens bundled" |
| Consistent formatting | `swift-format lint` (`.swift-format`) |
| Old lint debt only shrinks | `tools/lint/check-baseline.sh` |
| Folder lock blocks unapproved folders | preflight "a folder you never approved is blocked" |
| KeePass survives engine installs | preflight "KeePass overlay" checks |
| Engine version is pinned | preflight "Hermes version pinned" + fresh-install check |
| Old copies see updates | preflight "Updater" |
| Screens render | preflight "Screens" |
| Private notes don't leak into shared rooms | `SharedGuard` + preflight "Guards" |
| Experimental connections are off until tested | `ExperimentalGuard` (`skills.disabled`) + preflight "Guards" |
| Complaints are captured | `FrictionLog` + preflight "Guards" |
| The three core jobs work end to end (sort files, inbox draft-only, price watch asks before buying) | `make jobs` (`tools/jobs-check.sh` → `One --test-jobs`) |
| The mail bridge has no send command | `make jobs` ("bridge has no send command") |
| Shipped skills reach every install and never overwrite an edited copy | `BundledSkills` + preflight "Shipped skills" (`One --test-skills`) |
