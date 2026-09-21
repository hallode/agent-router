# agent-router

Sends each piece of coding-agent work to the cheapest model that can actually do
it — and keeps working when a provider says you are out of quota.

Works with [Claude Code](https://code.claude.com) and the
[Codex CLI](https://developers.openai.com/codex/cli/).
Plain `bash` and `jq`. No daemon, no build step, no API key, and no model call in
the routing path.

---

## The problem

**You pay top rates for trivial work.** Choosing a model by hand means either
thinking about it on every prompt, or not thinking about it and letting the most
expensive model rename your variables.

**And when you hit the rate limit, everything stops.** You are halfway through a
task, the provider cuts you off, and the reset is hours away. Nothing gets
cheaper. It just ends.

## Quickstart

You need `bash` (macOS's built-in 3.2 is fine), `jq`, and Claude Code.

```sh
git clone https://github.com/hallode/agent-router ~/.claude/router
~/.claude/router/install.sh
```

The installer copies the files, creates a config, runs the test suite, and prints
a block of hook configuration. Paste that block into `~/.claude/settings.json`.

It never edits `settings.json` for you — hooks run arbitrary commands on every
tool call, so that file is worth reading before something appends to it.

Then check it is alive:

```sh
~/.claude/router/bin/router status
```

```
state      NORMAL
enforce    true
tier map   trivial=haiku execution=sonnet reasoning=opus
decisions  none yet
```

That is the whole setup. The shipped config works unmodified — no directory
convention, no account setup, nothing to fill in.

**Before you trust it, run it in dry-run for a few days:**

```sh
~/.claude/router/bin/router enforce false   # decide and log, change nothing
# ... work normally ...
~/.claude/router/bin/router log 30          # read what it would have done
~/.claude/router/bin/router enforce true    # switch it on
```

Every router misclassifies something. Far better to find yours in a log than in a
subagent that quietly had the wrong model.

## What actually changes

Nothing you type. The router runs as a hook, so it is invisible until you look at
the log.

When your assistant delegates work to a subagent, the router intercepts that call
and sets the model:

```
you: "find every caller of ParseConfig"
  assistant delegates  ->  mechanical      ->  runs on Haiku

you: "add a POST /invoices endpoint"
  assistant delegates  ->  implementation  ->  runs on Sonnet

you: "why does this deadlock under load?"
  assistant delegates  ->  needs judgement ->  runs on Opus
```

Check what it did, any time:

```sh
router log 20
router stats
```

## How it decides

### Three tiers

| tier | the work | model |
|---|---|---|
| `trivial` | mechanical, read-only, deterministic | Haiku |
| `execution` | ordinary implementation — **the default** | Sonnet |
| `reasoning` | design, debugging, audits, review | Opus |

Two rules keep this honest:

- **When unsure, the middle tier.** `execution` is the fallback, never `trivial`.
  Giving Haiku a real task costs a retry, which is more expensive than just
  having used Sonnet.
- **No model call to pick a model.** A classifier that asks an LLM which LLM to
  use has already lost. Classification is regular expressions: a few
  milliseconds, zero tokens.

### Roles beat guessing

Reading a prompt is guesswork. Knowing an agent's *role* is not. Four standard
roles ship with the router, and where one is used the prompt is never classified
at all:

| role | use it for | tier |
|---|---|---|
| `router-explorer` | locating code, read-only investigation | `trivial` |
| `router-worker` | a settled, bounded change plus its checks | `execution` |
| `router-reviewer` | checking work something else produced | `reasoning` |
| `router-planner` | ordering a change large enough to get wrong | `reasoning` |

The reasoning behind that split:

- A **planner** runs once, and everything downstream inherits its mistakes.
- A **reviewer** has to catch what another model already convinced itself was
  fine — and one drawn from a different model family has different blind spots.
  With `router-worker` on Sonnet and `router-reviewer` on Opus, you get that for
  free.
- A **worker** is where token volume goes.
- An **explorer** is high-count and shallow.

Their models are *not* hardcoded in the agent files — each is `model: inherit`,
and the tier map decides. One place to change routing, and the quota governor can
still degrade them.

To install the roles, re-run the installer with `--with-agents`:

```sh
~/.claude/router/install.sh --with-agents
```

That copies the four role definitions into `~/.claude/agents/`, puts
`ROUTING.md` beside your `CLAUDE.md`, and references it with `@ROUTING.md`.
`ROUTING.md` is a short standing instruction telling your assistant when to
delegate — and, just as importantly, when not to.

New agent definitions are picked up when a session starts, so they become
available in your **next** Claude Code session, not the one you are in.

## Staying alive at the rate limit

This is the part cost-only routers leave out.

| state | trigger | effect |
|---|---|---|
| `NORMAL` | — | full tier map |
| `CONSERVE` | ≥60% of quota used | reasoning drops to Sonnet |
| `CRITICAL` | ≥85% | execution drops to Haiku |
| `DEPLETED` | limit reached | everything on Haiku; Codex chains take over |

Degradation is gradual rather than a wall, and a rate-limit event decays after an
hour, so one bad minute does not cripple your afternoon.

```sh
router probe
```

```
state      DEPLETED
primary    100.0% of a 5h window, resets Mon 21:19
secondary   16.0% of a 7d window, resets Mon 16:19
```

Codex publishes its own quota — every session records a 5-hour and a weekly
percentage with reset times — so the governor sees a Codex wall coming. Claude
Code records no equivalent figure, so on that side the governor reacts to
rate-limit errors after they happen. That difference is in what the hosts record,
not in how the router treats them.

## Claude and Codex, same behaviour

Switching hosts should not mean switching habits. Both share one classifier, one
set of tier names, one governor state file, and one decision log.

| | Claude Code | Codex |
|---|---|---|
| pick the model from a prompt | `ccr` | `cxr` |
| budget state injected each session | `SessionStart` hook | `SessionStart` hook |
| warned when the budget is tight | `UserPromptSubmit` hook | `UserPromptSubmit` hook |
| tier names | trivial / execution / reasoning | same |
| governor state | shared | shared |
| decision log | `decisions.jsonl` | same file, `host` field |
| per-repo override | `.agent-router.json` | same file |
| quota read before choosing | on rate-limit errors | real percentages |
| **enforce a subagent's model** | **yes**, `PreToolUse` | **no** — see below |

One asymmetry cannot be closed. Codex's hook API is otherwise close to Claude
Code's — `PreToolUse` rewrites tool input with the same `updatedInput` shape —
but its documentation is explicit that hooks cannot influence which model a
subagent uses: `SubagentStart` carries only `systemMessage` and
`additionalContext`. So subagent enforcement exists on one host and not the
other, and this ships the context injection Codex *can* do rather than
pretending the gap is not there.

Install the Codex side by adding to `~/.codex/config.toml`:

```toml
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "$HOME/.claude/router/hooks/codex-hook.sh"
timeout = 10

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "$HOME/.claude/router/hooks/codex-hook.sh"
timeout = 10
```

Because the governor state is shared, a rate limit on one host makes the other
cheaper too — which is what you want when the two are backed by different
accounts and only one is exhausted.

### Codex failover

```sh
cxr "implement the retry middleware"   # classify, pick a model, run codex exec
cxr -t reasoning "why is this slow"    # force a tier
cxr -n "<task>"                        # dry run: print the chain
```

Each tier gets its own chain. On a rate limit `cxr` moves to the next link and
tells the governor, instead of dying:

```json
"codex_chains": {
  "execution": [
    {"model": "<your-primary>",  "effort": "medium"},
    {"model": "<your-fallback>", "effort": "medium"},
    {"model": "<your-reserve>",  "effort": "medium"}
  ]
}
```

Give each tier a different *model*, not one model at three effort levels — a
small model thinking hard is rarely the same trade as a large one thinking
briefly. Model availability differs per account, so list yours:

```sh
jq -r '.models[] | "\(.slug)\t\([.supported_reasoning_levels[]?.effort] | join("/"))"' \
  ~/.codex/models_cache.json
```

Most accounts carry a spare or reserve model that never gets used, because nothing
falls back to it. That is the last link worth having.

## Commands

```sh
router status              # state, tier map, any active override
router why "<prompt>"      # explain a classification before trusting it
router log [n]             # recent routing decisions
router stats               # counts by host and model
router enforce true|false  # enforce vs dry-run
router state set CONSERVE  # force a budget state
router probe               # refresh state from quota
router test                # run the test suite

ccr "<prompt>"             # start a Claude session on the right model
cxr "<task>"               # run a Codex task, with failover
router-learn               # mine past sessions for what spend actually bought
```

### When the router picks wrong

Override it — but know that the override is the useful part:

```sh
cxr -t reasoning "<task>"   # force a tier for one run
cxr -n "<task>"             # see the choice without running it
```

In Claude Code, `/model <name>` changes the session, and a `!!` prefix on a
subagent prompt bypasses routing for that call.

Both a forced tier and a `!!` bypass are recorded as **manual overrides**, kept
separate from automatic decisions:

```sh
router stats
```

```
--
4  manual overrides (forced tier)
1  manual bypasses (!!)
Each one is a case the classifier got wrong. Worth reading:
  reasoning  normalise the phone format across the importer
```

If one kind of task is always overridden, change the map instead of overriding
forever — `agent_type_tiers` and `codex_chains` in the config, or a
`.agent-router.json` for a single repository. `router why "<prompt>"` shows how
anything classifies before you commit to it.

### Escape hatch

Prefix a subagent prompt with `!!` and the router leaves it alone. The marker is
stripped before the agent sees it.

```
!! audit this migration end to end
```

## Optional extras

Both are **off by default**, and most people never need them.

<details>
<summary><b>Per-directory accounts</b> — if you hold more than one subscription</summary>

<br>

Useful only when you care which account a directory bills. Labels are yours; the
router just compares them.

```json
"workspaces": {
  "enabled": true,
  "rules": [
    {"prefix": "$HOME/src/oss",  "account": "personal"},
    {"prefix": "$HOME/src/acme", "account": "employer"}
  ],
  "remote_patterns": [
    {"pattern": "git\\.acme\\.example", "account": "employer"}
  ]
},
"codex": { "allowed_accounts": ["personal"] }
```

The path prefix assigns the account; the git remote is then cross-checked against
it, so a repository cloned under the wrong prefix gets flagged instead of quietly
billed to the wrong place. `cxr` refuses to run where the account is not allowed —
and with `allowed_accounts` empty, it never refuses.

</details>

<details>
<summary><b>Per-repository overrides</b> — if one project needs different routing</summary>

<br>

Drop `.agent-router.json` at a repository root. The router walks up from the
working directory, finds the nearest one, and merges it over the global config for
that call only.

```json
{
  "agent_type_tiers": {"schema-migration-agent": "reasoning"},
  "degrade": {"NORMAL": {"execution": "opus"}}
}
```

Objects merge recursively and arrays replace wholesale, so a project states only
what differs. The global config is never written to, and a malformed project file
is ignored rather than breaking routing.

</details>

<details>
<summary><b>Learning from your own history</b></summary>

<br>

Claude Code records the model, effort and token usage of every assistant turn.
`router-learn` reads those transcripts and reports where the money went, how often
each model was followed by a correction, and what the classifier would have chosen
instead.

```sh
router-learn            # report and suggestions
router-learn --apply    # same, and write the router-owned parts
```

Read-only by default; it never retunes itself. Correction detection is a keyword
proxy over your follow-up messages, not a verdict — on a small sample it will be
wrong, and where it disagrees with how a model felt to use, the feeling is the
better evidence.

</details>

## Known limitations

Read these before deciding what this will save you.

**The main session cannot be routed.** No hook can change a running session's
model — `PreModelSwitch` can only block a switch someone else requested. The
router prices *delegated* work. In a session that does everything inline, its
effect is whatever delegation it causes, not a percentage off the whole bill.
`ccr` exists so that at least the session starts on the right model.

**Per-model effort does not reach subagents.** Measured on a real run: with
`modelSettings` setting Sonnet to `high` and the session at `xhigh`, a routed
subagent came back as Sonnet at `xhigh`. The model rewrite was honoured; the
effort setting was not. So routing buys the model saving — the large one, roughly
15x on output between top and bottom tier — but not the effort saving.

**Cursor cannot be routed at all.** Its hook API has no model control:
`beforeSubmitPrompt` may return only `continue` and `user_message`, `preToolUse`
answers allow/deny without rewriting tool input, the hook is not told which model
is running, and there is no agent CLI to launch with one. Nothing here pretends
otherwise.

**Correction rates are a weak signal.** See the `router-learn` note above.

## Design notes

**Fails open, always.** Every hook exits 0 and emits nothing on any error. A
broken router must never block a tool call — that trade is not close.

**bash 3.2 compatible.** No associative arrays, no `${var,,}`. macOS ships bash
3.2 and will not ship anything newer; a router that only runs on Linux is not a
router for most of the people who need one.

**`.enforce // true` is a trap.** jq's `//` treats `false` as empty, so that
expression turns `false` into `true` and dry-run mode never engages. The config is
read with `if has("enforce") then .enforce else true end` instead. Worth knowing
before adding any other boolean setting.

**A fork is never routed.** A forked agent inherits the parent model by design and
a model override there is ignored, so the router passes it through untouched.

## Prior art

- [tzachbon/claude-model-router-hook](https://github.com/tzachbon/claude-model-router-hook) — four hook events, heuristics with an optional Haiku fallback. Defers the switch to the next session.
- [bmersereau/claude-router](https://github.com/bmersereau/claude-router) — injects routing context and spawns tiered subagents. Costs roughly 3.4k tokens of overhead per subagent.
- [maiha28781-cloud/claude-smart-model-router](https://github.com/maiha28781-cloud/claude-smart-model-router) — classifies and recommends; you still approve each one.
- [lm-sys/RouteLLM](https://github.com/lm-sys/routellm) — trained routers for API calls. A different layer: no notion of an agent with tools.

None of them degrade under a rate limit, which is the case that started this.

## License

MIT
