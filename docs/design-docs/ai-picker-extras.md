# AI picker extras: Other AIs and thinking effort

Status: design, waiting for Omar's pick (Direction A or B). No app code yet.
Code read at tag v0.9.101 (= main 5b574dc, which already has "One multiple AI accounts", PR #106).
Engine read: the bundled Hermes in `~/Library/Application Support/One/engine` (commit bf0203a794).
Claude Design project: https://claude.ai/design/p/b0df88c6-c437-4ad0-9601-781fa8ff2511 ("One AI additions").
Captioned PDF for Omar: `~/Documents/Made by Iris/2026-11-09 One AI picker extras design.pdf`.

Two small additions, both inside screens that exist today:

1. **Other AIs**: one more row in "Which AI should I use?", between OpenRouter and Local model, that opens
   every other AI the engine supports, each with a plain note that it needs its own API key and gets less
   hand-holding. Picking one adds the key and checks it answers.
2. **Thinking effort**: Smartest / Balanced / Fastest also set how hard the AI thinks (Smartest = the
   model's top level, Balanced = Medium, Fastest = Low), and a small "More options ›" under them shows a
   Thinking picker with only the levels that model has.

(Omar's request said "Smarter"; the app's label is "Smartest", `Sources/Installer.swift:316`. It stays.)

## 1. What's there today (v0.9.101)

### Switch AI ("Which AI should I use?")
- Pop-up: `Sources/SwitchAIPanel.swift`. Rows come from `Provider.allCases` (`:52-60`), then a hand-made
  "Local model" row (`:61-65`) that opens `LocalModelPicker` (`Sources/LocalModelFlow.swift`). A signed-in
  provider opens its accounts screen (`:58`, `ProviderAccountsView`, from PR #106).
- First-run setup has the same list a second time: `Sources/SetupViews.swift:243-276`.
- `enum Provider` (`Sources/Installer.swift:276-332`): claude, chatgpt, grok, openrouter, each with a
  title, subtitle, symbol, the engine id (`hermesID`, `:305-311`: anthropic, openai-codex, xai-oauth,
  openrouter), three `tiers` (`:314-322`) and fallback `models` (`:324-331`).
- Sign-in: `SignIn.start` runs `hermes auth add <id> --type oauth` (`Installer.swift:352-390`);
  `SignIn.isSignedIn` parses `hermes auth status <id>` (`:423-426`); `SignIn.makeDefault` sets
  `model.provider` + `model.default` (`:434-439`).
- Switching: `Model.choose` / `verify` (`Sources/ModelSetup.swift:208-320`): wait until no turn or helper is
  running (`SwitchAI.ready`, `Sources/SwitchAI.swift:12`), set the provider and model, restart the engine,
  send "Reply with exactly one word: ready", and on any failure put the old AI back.
- The current AI: `SwitchAI.currentProvider` reads `  provider:` from config.yaml and matches it against
  the four built-ins only (`Sources/SwitchAI.swift:6-10`). `Model.providerRaw` holds `claude`, `chatgpt`,
  `grok`, `openrouter` or `local`.
- Keys today: One has no key-paste screen. The only key it writes is the test path's
  `OPENROUTER_API_KEY` into `hermes/.env` through `Env.writeSecretEnv` (owner-only 0600,
  `Sources/Env.swift:88-91`, used at `Sources/App.swift:505`). `Env.vars()` strips provider keys from the
  engine's environment so a shell variable can't "sign in" anything (`Env.swift:79-82`).

### The assistant card (tap "Elias" at top left)
- `Sources/MeCard.swift`. BRAIN = three pills from `provider.tiers` (`:69-71`), "Pick any model…" only for
  OpenRouter (`:72-97`), VOICE, SEE-THROUGH, Done. Picking a pill = `pick(_:)` (`:140-157`): wait until
  idle, `hermes config set model.default <id>`, restart the engine, roll back if it doesn't start.
- `provider` falls back to `.claude` when `providerRaw` isn't one of the four (`:34`), so today a local
  model shows Claude's three pills. Picking one would set a Claude model on the local server. The design
  below fixes that for Other AIs and Local model.
- There's no other "agents/assistant setup" with tiers: the first-run setup only picks the provider
  (`SetupViews.swift:243`), and the card above is the one place tiers live.

### How helpers and routines get their brain
- Main chat and helpers are separate ACP sessions in one engine (`Engine.openSession`). A helper starts on
  the engine's default model; for a light lookup the router steps a Smartest pick down to Balanced with
  ACP `session/set_model` (`Sources/RoutingHelpers.swift:15-18`, `Sources/Routing.swift:199-205`, never on
  OpenRouter).
- Routines are Hermes cron jobs. A job may pin its own model and effort. On this Mac today (`cron/jobs.json`,
  read only): 22 jobs, 13 pin `claude-sonnet-5`, one ("Argo P009 check") pins `reasoning_effort: low`.
- One never sets effort today. The engine's `agent.reasoning_effort` in One's config is `high`
  (config.yaml:1097), left from the engine's default config.

Before pictures: `before-1-switch-ai.png` and `before-2-assistant-card.png` (rendered with
`One --render-switch-ai` and `One --render-world`), first page of the PDF.

## 2. What the engine offers (from its own code, not memory)

### Providers
- Source: `PROVIDER_REGISTRY` (`engine/hermes_cli/auth.py:172-248`) plus plugin profiles mirrored in
  (`hermes_cli/auth_plugin_providers.py:45-89`), and the picker list `provider_catalog()`
  (`hermes_cli/provider_catalog.py:66-108`) that the engine's own `hermes model` and desktop app show:
  53 rows. Cross-checked with https://hermes-agent.nousresearch.com/docs/integrations/providers.
- Already in One: anthropic, openai-codex, xai-oauth, openrouter, custom (Local model).
- There is **no CLI command that prints the list** (no `hermes providers`, no `--json` on `hermes model` or
  `hermes auth`). The engine's launcher has a machine boundary for this: `hermes --print-runtime-command`
  prints the exact interpreter + bootstrap (`_launchers.py:39-84`), and a short script run through it can
  print `provider_catalog()` as JSON (53 rows in 0.66 s, no network, no secret values).
- Docs vs engine: the docs table lacks `upstage`, `deepinfra`, `meta-ai` rows; the engine hides `solstice`
  (pre-release). Ollama, vLLM, LM Studio, Groq, Together etc. are "custom endpoints" in the docs, which One
  already covers with Local model.

**Which rows "Other AIs" shows (a rule, not a list in Swift):** `auth_type == api_key`, not one of the five
above, not hidden, no required extra setting (drops `azure-foundry`, which needs its own URL), not a local
server (`lmstudio`, covered by Local model), and not a token exchange (`copilot`, a GitHub token). On this
engine that's 38 rows: OpenAI API, Google AI Studio, Z.AI (GLM), Kimi / Moonshot, StepFun, Arcee AI,
GMI Cloud, Actual Computer, MiniMax, Qwen Cloud, DeepSeek, xAI, NVIDIA NIM, Vercel AI Gateway,
OpenCode Zen, OpenCode Go, Kilo Code, Hugging Face, Xiaomi MiMo, Tencent TokenHub, Tencent TokenPlan,
Ollama Cloud, CommandCode, DeepInfra, Fireworks AI, Meta Model API, Nebius Token Factory, NovitaAI,
Ramp Router, Upstage Solar, and the regional or plan variants (Kimi China, MiniMax China, the Alibaba
Coding/Token plans). OAuth-only ones (Nous Portal, Qwen OAuth, MiniMax OAuth) and cloud-SDK ones
(AWS Bedrock, Google Vertex AI) need a sign-in flow, not a key: left out of V1, mentioned once as a later idea.
(The Claude Design frames show Nous Portal in the list; the build follows this rule, so it won't be there.)

### Keys
- The engine's own screens save a key with `credential_lifecycle.save_provider_env_credential(var, key)`
  (`credential_lifecycle.py:164-194`): it writes `<api_key_env_vars[0]>=` into `hermes/.env` (the same file
  One already uses for keys, 0600) and mirrors it into the credential pool at once, so the next request
  uses it (a `.env`-only write once caused 401s, per its docstring).
- `hermes auth status <id>` then prints `<id>: logged in` (it exits 0 either way; One parses the text, as
  `SignIn.isSignedIn` already does).
- Never pass the key on a command line (`hermes config set VAR key` and `auth add --api-key` both put it in
  argv, visible to `ps`). One sends it on stdin to the same short script.

### Thinking effort
- One setting: `agent.reasoning_effort` (`hermes_constants.py:1192-1215`). Values `none minimal low medium
  high xhigh max` (`ultra` is internal). `hermes config set agent.reasoning_effort <v>` works but **does not
  check the value** (a typo silently means "unset") and prints a false "not a recognized config key"
  warning (upstream #85741). One checks the value itself before saving.
- The engine clamps to what the model has (`agent/reasoning_effort.py:127-157`, nearest weaker level, never
  higher) and sends it per provider:

| One's AI | Sent as | Levels (after the engine's clamp) | Smartest gets |
|---|---|---|---|
| Claude (anthropic, One's route = native Messages API, not Claude Code) | `thinking: adaptive` + `output_config.effort` (`agent/anthropic_adapter.py:616-646`) | Low, Medium, High, Extra high, Max on opus-5-5 / sonnet-5 / haiku-5-5. Off is not possible on Opus 5.5 | Max |
| ChatGPT (openai-codex) | `reasoning.effort` (`agent/transports/codex.py:293-343`) | gpt-6.1-sol: Low…Max. gpt-6-sol: Off, Low…Max. gpt-5.4-mini: Off, Low…Extra high | Max |
| Grok (xai-oauth) | `reasoning.effort`, only for an allowlist (`model_metadata.py:371-377`) | grok-4.6: Low…Extra high. **grok-4.20-0309-reasoning and -non-reasoning: none** (nothing sent) | Extra high |
| OpenRouter | Claude: top-level `verbosity`; others `reasoning.effort` from OpenRouter's catalog (`plugins/model-providers/openrouter/__init__.py:153-196`) | per model from the catalog (Claude 5.5: Low…Max; gemini-3-flash: Off…High) | the model's top |
| Local model (custom) | top-level `reasoning_effort` (`plugins/model-providers/custom/__init__.py:56-83`) | the engine can't tell; it always sends an explicit level, a server that refuses gets one retry without it | hidden (see below) |
| Other AIs | per family (`agent/reasoning_effort.py:51-94`, e.g. Kimi K3 Low/High/Max, DeepSeek V4 Low…Max, Gemini Low…High) | per family | the family's top |

Full wire details and the provider dump: `~/Library/Application Support/One/work/ai-picker-extras-notes/` (effort.md, providers.md, providers.json, one_list_providers.py), kept out of the repo.

## 3. The design

Surface: **Configure** (a small pop-up and a card). No new screen, no new top button, no cost shown.
Both directions keep One's look: dark #141416, cream text and hairlines, 12-radius cards, SF Pro, no accent.

### 3.1 Other AIs (both directions)
- New row "Other AIs", subtitle "Bring your own key. Less hand-held.", between OpenRouter and Local model,
  in Switch AI and in first-run setup.
- It opens inside the same pop-up, with "‹ Back". One note at the top, once: "Each of these needs its own
  API key from that company, and I give less help setting them up. If you pay for Claude, ChatGPT or Grok,
  use those instead."
- Pick one → **Add your <name> key**: "Get a key on <name>'s site, then paste it here. It stays on this
  Mac." + "Open <name>'s key page ↗" (the engine's `signup_url`) + a secure field + one button "Check and use
  it" (off until something is pasted) + Cancel.
- **Checking**: the button becomes "Checking <name> answers…" with Cancel.
- **It works**: "It works. I'm using <name> now." + the model (the engine's default for it) + Done.
- **Didn't work**: one plain line ("<name> said this key isn't valid." / "I couldn't reach <name>." /
  "<name> says there's a billing problem.") + ONE button that fixes the cause ("Paste a different key"), and
  "I kept your old AI." No second generic retry.
- A row with a key already saved says "Key added · tap to use or change it".
- **Direction A (List)**: search field + flat list, each row = name + one short line + a small "Needs a key"
  tag. The key step is one card.
- **Direction B (Grouped)**: no search, two-column tiles under small labels (Big AI companies / Open
  models / One key, many AIs); the key step is a numbered 3-step card (Get a key / Paste it / Check it),
  each step lighting up when done.

### 3.2 Thinking effort (both directions)
- Picking Smartest / Balanced / Fastest sets the model AND the effort: Smartest = the model's top level,
  Balanced = Medium, Fastest = Low (or the nearest level the model has). Off is never set by a preset.
- "More options ›" (closed by default) under the pills opens **Thinking** with only that model's levels and
  one line: "Smartest set this to Max. Higher thinks longer and more carefully, but answers slower."
  Changing it by hand puts a small dot on the pill and the line says "You changed this by hand. Picking a
  brain above resets it." Last line: "Helpers and routines use this too."
- A model with no levels (Grok's Balanced and Fastest, a local model): the row is greyed, "This brain
  doesn't have thinking levels."
- **Card on an Other AI or a local model**: no three pills (the engine has no tiers for them). BRAIN shows
  the model as one row with "Pick another model…" (the engine's model list for that AI), then More options.
- **Direction A**: Thinking is a row of small pills like the existing ones, inline under the brain.
- **Direction B**: each brain pill also says how it thinks under the model name ("thinks hardest"), and
  More options opens a short list of levels, each with a one-line meaning (Off "answers right away", Low
  "quick answers", Medium "a bit of thought", High "thinks it through", Extra high "thinks a long time",
  Max "slowest, most careful").

My recommendation: **Direction A** for both. It's the smallest change to screens people already know
(a search box and a list are the fastest way through ~40 names; B's groups are a judgement call the engine
doesn't make, so they'd need a hand-kept map that goes stale), and the pills match the brain pills right
above them. B's per-pill "thinks hardest" line is worth keeping if Omar wants the effort visible without
opening More options.

## 4. Data and code changes (for the build, after the pick)

New files (area: AI choice, next to `SwitchAIPanel.swift`):
- `Sources/EngineCatalog.swift`: runs the engine's interpreter (from `hermes --print-runtime-command`) with
  a bundled script `tools/one_engine_catalog.py` and decodes its JSON. Three calls:
  `providers` (the list, with `--status` for "Key added"), `efforts <provider> <model>` (the levels, from the
  engine's own `clamp_effort` / family tables / models.dev `supports_reasoning` / the Grok allowlist /
  OpenRouter's cached catalog), `save-key <provider>` (reads the key on stdin, calls
  `save_provider_env_credential`, prints only ok/error). Cached per engine version; never prints a key.
- `Sources/OtherAIs.swift` (+ `OtherAIsKey.swift` if it passes 600 lines): the list (filter rule from §2),
  the key step, the check, Direction A or B.
- `Sources/Effort.swift`: `enum Effort { off, low, medium, high, xhigh, max }` with plain words,
  `preset(tier:levels:)`, and `apply(_:)` = check the value, `hermes config set agent.reasoning_effort
  <none|low|…>`, restart like a brain pick does.

Changes:
- `SwitchAIPanel.swift` / `SetupViews.swift`: the Other AIs row; "Current" when `providerRaw` is an engine id.
- `ModelSetup.verify` gains a path for an engine id (string, not a `Provider` case): set `model.provider
  <id>` + `model.default <default_model>`, restart, "ready" prompt, restore on failure. Before that, a free
  check: `GET <models_url or base_url>/models` with the key (401/403 = "isn't valid", 200/429 = fine,
  offline = "couldn't reach"), the same probe the engine's own dashboard and `hermes doctor` use. Anthropic-
  style hosts (MiniMax) send `x-api-key`; MiniMax China and OpenCode Go have no `/models` and go straight to
  the "ready" check.
- `Model.providerRaw` may now hold an engine id (`deepseek`); `SwitchAI.currentProvider` returns nil for it
  and the Other AIs row shows "Current".
- `MeCard.swift`: tiers only for the four built-ins; Other AIs and Local model get the one-row brain
  (fixes the Claude-pills-on-a-local-model bug); "More options" + Thinking under the brain; `pick(_:)` also
  writes the preset's effort. UserDefaults `effortByHand` (Bool) drives the dot and resets on a pill pick.
- `Persona.write` (SOUL): one line that Switch AI has "Other AIs" for API keys, and the card has a Thinking
  level under More options (One's rule: SOUL describes One's real screens).
- `docs/SECURITY.md`: keys pasted in One go to `hermes/.env` (0600) through the engine, never argv or logs
  (doc-drift check maps secrets code to it).

What the effort setting reaches, plainly:
- **Main chat**: yes. Saving restarts the engine like a brain pick (after running turns and helpers
  finish), and the chat's session is re-read on load.
- **New helpers**: yes. A new ACP session reads config.yaml when it's created. A helper the router steps
  down to Balanced keeps your Thinking level (the engine re-reads it for the new model), not Balanced's
  Medium.
- **Helpers already running**: no, they finish on the level they started with (One already waits for them
  before restarting).
- **Routines**: yes, the engine re-reads config on every tick, including the 13 jobs that pin
  claude-sonnet-5 (they get your level for that model). **Not** a routine that pins its own effort: today
  "Argo P009 check" pins `low` and keeps it.
- **Sub-agents a helper starts**: yes, they inherit the helper's level.
- **Not reached**: the engine's side jobs (chat titles always think Off; compression, vision, approvals and
  the rest use the AI's own default), and models that take no effort at all (Grok 4.20 Balanced/Fastest).

### Also in this build: renders never touch the real settings
While making the before pictures for this doc (9:46 PM, Nov 9), `--render-switch-ai` and `--render-world` were
run from `build/app.noindex/One.app`, whose bundle id is the real `ai.forjado.one`. `HomeRender.scene`
(`Sources/HomeRender.swift:34-60`) sets `assistantName = "Elias"`, `userName`, `interviewOffered`,
`helpers`, `bubbles` and `shelf` on `Model.shared`, and those are `@AppStorage` or save on `didSet`
(`Sources/Model.swift:55-57, 161, 255, 262`), so the render wrote "Elias" into Omar's real settings and
Ready for you looked in "Made by Elias". (His live One re-saved its own helpers, chat and shelf over the
rest; the name was put back to Iris.) Fix: every render mode calls a guard that refuses under the
production bundle id (same as `TestWorld.enter()` does for tests), so renders only run from
`tools/test-copy.sh` copies with `ONE_SUPPORT_DIR` set to scratch; a preflight check proves a render under
the real id exits 2 and writes nothing (`defaults export` before/after).

## 5. Tests (all in CI, per the repo's rule; new `--test-other-ais` and `--test-effort` in preflight)

1. **The list loads from the engine**: run the catalog script against the bundled engine (fresh-install
   job, real engine) and against a fixture (PR check). Assert: the count equals the engine's own
   `provider_catalog()` after the filter rule; none of the five built-ins appear; every row has a name, a
   key variable and a check URL or an explicit "no free check"; no hardcoded name list exists in Swift
   (one-lint rule: no provider display names in `OtherAIs.swift`).
2. **Adding a key works**: in a scratch `ONE_SUPPORT_DIR`, save a fake key for `deepseek` through
   `save-key`: `hermes/.env` has `DEEPSEEK_API_KEY=` with mode 0600, `hermes auth status deepseek` says
   logged in, the key appears in no process argv (the script is spawned with an argv the test records), in
   no stdout/stderr, log or chat bubble. The check step against a local stub server: 200 → "It works",
   401 → "isn't valid" + "Paste a different key", offline → "couldn't reach", and in every failure
   config.yaml still has the old provider and model.
3. **Each preset sets the right effort**: for every built-in provider × tier, the effort written equals the
   table in §2 (Claude Max/Medium/Low, ChatGPT Max/Medium/Low, Grok Extra high/none/none, OpenRouter by
   catalog), read back from config.yaml with `hermes config get agent.reasoning_effort`; an unknown value
   is refused before it reaches the engine.
4. **The picker shows only supported levels**: `efforts` for opus-5-5, gpt-6.1-sol (no Off), gpt-5.4-mini
   (no Max), grok-4.6 (no Max), both Grok 4.20 models (empty → greyed), a local model (hidden),
   deepseek-flash; renders of each state checked by eye.
5. **The setting reaches helpers and routines** (fresh-install job, real engine, OpenRouter test key):
   after saving `low`, (a) the engine's `resolve_reasoning_config` for a new ACP session's model and for a
   cron job dict without a pin both return `low`, and for a job pinned `high` returns `high`; (b) one real
   helper session and one `hermes cron run` of a throwaway job each send `effort: low` on the wire (captured
   with the engine's request-dump hook), so the claim in §4 is proven, not assumed.
6. Renders: `--render-switch-ai other`, `other-key`, `other-fail`, and `me-card-effort`,
   `me-card-noeffort`, `me-card-other` in `--render-world`, checked with vision before the PR.

Not testable here: a real paid key for each of the ~38 AIs (only the fake-key path and OpenRouter in CI).

## 6. Later (not in V1)
- Sign-in AIs that aren't a key (Nous Portal, Qwen, MiniMax OAuth) and cloud accounts (Bedrock, Vertex).
- Several keys per Other AI (the accounts screen from PR #106 could list them; the engine pool supports it).
