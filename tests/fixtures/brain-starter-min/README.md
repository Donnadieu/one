# A minimal stand-in brain starter (CI only)

The real brain starter is a private repo, so GitHub runners can't bundle it. The fresh-install workflow builds One
with this stand-in (`BRAIN_STARTER`), which has only what `Brain.build` copies: AGENTS.md, owner.yaml and the room
templates. It proves One's own first-launch steps, not the starter's content. The release job of the same workflow
repeats the test on the real released app, which carries the real starter.
