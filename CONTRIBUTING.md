# Contributing to One

Thanks for wanting to help.

## The one rule
Every change should make One simpler for a person who has never used a terminal. If a feature needs an explanation, it probably needs a different design.

## How to contribute
1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Fork the repo and work on a branch.
3. Build with `./build.sh` and, if you touch the engine bridge, run `--selftest`.
4. Open a pull request against `main` describing what changed and how you checked it. Screenshots help for UI changes (`--render-world` renders the world screen).

`main` is protected: changes land through reviewed pull requests merged by a maintainer.

## Ground rules
- Never commit API keys, tokens or personal data.
- Keep the human in the loop: anything that spends money, sends messages or deletes things must ask first.
- Be kind in issues and reviews.

## Security
Please report security problems privately through GitHub's "Report a vulnerability" button on the Security tab, not in a public issue.
