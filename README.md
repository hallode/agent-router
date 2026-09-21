# agent-router

Routes coding-agent work to the cheapest model that can actually do it — and keeps
working when a provider says you are out of quota.

Built for [Claude Code](https://code.claude.com) and the [Codex CLI](https://developers.openai.com/codex/cli/).
Pure `bash` + `jq`, no daemon, no build step, no LLM call in the hot path.

## Why

Two problems, one router.

**Overkill.** Picking a model by hand means you either think about it on every
prompt or you stop thinking about it and pay Opus rates to rename a variable.

**The wall.** You are halfway through a task, the provider rate-limits you, and
the reset is hours away. Nothing degrades — it just stops.

## What it actually does

Claude Code has one enforceable seam for model choice: a `PreToolUse` hook may
rewrite tool input, and the `Agent` tool's explicit `model` parameter outranks
both the agent's frontmatter and `CLAUDE_CODE_SUBAGENT_MODEL`. So that is where
this routes.

No hook can change the *main* session's model — `PreModelSwitch` can only block a
switch. Projects that claim to auto-switch your session either defer the change to
the next session or push all work into subagents. This one does neither: the main
session stays your orchestrator, and every subagent it spawns gets priced.

```
prompt / role  ──▶  classify  ──▶  tier  ──▶  governor  ──▶  model
                    (regex)                    (quota)
```

The same decision drives three entry points, because a model can only be chosen
at three moments:

| moment | tool | enforced? |
|---|---|---|
| starting a Claude session | `ccr` | yes — `claude --model <tier>` |
| spawning a subagent | `PreToolUse` hook | yes — rewrites the `model` param |
| running a Codex task | `cxr` | yes — picks the model and fails over |
| mid-session, Claude | — | **impossible** |

Cursor is not on that list and will not be. Its hook API has no model control:
`beforeSubmitPrompt` may return only `continue` and `user_message`, `preToolUse`
answers allow/deny without rewriting tool input, the hook is not told which model
is running, and there is no agent CLI to launch with one. Nothing here can route
it, so nothing here pretends to.

That last row is not a missing feature. No hook can change a running session's
model; `PreModelSwitch` can only block a switch someone else requested. Anything
promising prompt-by-prompt switching of the main session is either deferring it
to the next session or quietly moving the work into subagents. Start the session
on the right model instead.

A skill cannot do this either, for the same reason: a skill is context, not
control. It can advise the assistant to delegate; it cannot set a model.

### How automatic is it

Installed once, then nothing to invoke — the same shape as any tool hook. The
catch is not automation, it is *where the hook sits*:

| hook | intercepts | fires |
|---|---|---|
| a shell-command hook | `Bash` | constantly |
| this router | the `Agent` tool | only when work is delegated |

A session that does everything inline never spawns an agent, so the enforcing
hook never runs — and inline is where nearly all the spend is. Measuring 120
real sessions while building this: 113 were interactive, 0 were one-shot. A
launcher that classifies the opening prompt would have fired essentially never.

So the automatic path in a live session is the `UserPromptSubmit` advisor. It
cannot change the session model — nothing can — but it can tell the assistant to
delegate, and every delegation *is* routed and priced. It stays silent unless the
session is on an expensive model and the prompt classifies below it, so a
reasoning prompt on Opus draws no comment at all.

Set `advisor.delegate` to false to switch that off and keep enforcement only.

### Tiers

| tier | work | model |
|---|---|---|
| `trivial` | mechanical, read-only, deterministic | Haiku |
| `execution` | ordinary implementation — **the default** | Sonnet |
| `reasoning` | design, audit, debugging, review | Opus |

Two rules keep this honest:

- **When unsure, Sonnet.** `execution` is the fallback, never `trivial`. Handing
  Haiku a real task costs a retry, which is more expensive than just having used
  Sonnet.
- **Zero LLM calls.** A classifier that asks a model which model to use has
  already lost. Classification is regex, ~5ms, no tokens.

### Standard roles

Four agent definitions ship with the router. Their model is not written into the
frontmatter — each is `model: inherit`, and the tier map decides — so one config
governs routing and the governor can still degrade them when quota runs low.

| role | for | tier |
|---|---|---|
| `router-explorer` | locating code, read-only investigation | `trivial` |
| `router-worker` | a settled, bounded change plus its checks | `execution` |
| `router-reviewer` | checking work something else produced | `reasoning` |
| `router-planner` | ordering a change large enough to get wrong | `reasoning` |

Copy `agents/` into `~/.claude/agents/` and `ROUTING.md` next to your CLAUDE.md,
then reference it with `@ROUTING.md`. The roles make delegation deterministic:
"delegate this" stops meaning *a general-purpose agent whose tier is guessed from
the prompt text* and starts meaning *a named role whose price is already decided*.

A reviewer drawn from a different model family than the worker has different blind
spots — `router-worker` on Sonnet and `router-reviewer` on Opus gives that for free.

### Roles beat guessing

Where the agent's role is known, the router uses it instead of reading the prompt —
a role is a fact, a prompt is a guess. The role tiering follows
[context-circuit](https://github.com/)'s reasoning:

| role | tier | why |
|---|---|---|
| explorer | `trivial` | high-count and shallow |
| worker | `execution` | where token volume goes |
| planner | `reasoning` | runs once; everything downstream inherits its mistakes |
| reviewer | `reasoning` | must catch what another model already talked itself into |

A reviewer drawn from a different model family than the worker has different blind
spots — with `worker=Sonnet` and `reviewer=Opus`, you get that for free.

### Claude and Codex behave the same way

The point of running both is that switching hosts should not mean switching
habits. The same classifier, the same tier names, the same governor states and
the same decision log serve both:

| | Claude Code | Codex |
|---|---|---|
| pick the model from the prompt | `ccr` | `cxr` |
| enforce a subagent's model | `PreToolUse` hook | — |
| tier names | trivial / execution / reasoning | same |
| governor states | shared — one state file | shared |
| decision log | `decisions.jsonl` | same file, `host` field |
| per-repo override | `.agent-router.json` | same file |

`router status`, `router log` and `router stats` therefore describe both hosts at
once, and a rate limit on one degrades the tier map for the other — which is the
behaviour you want when the two are backed by different accounts and only one is
exhausted.

One asymmetry is real and worth stating: **Codex publishes its own quota** — every
session rollout carries a 5-hour and a weekly used-percentage with reset
timestamps — while Claude Code records no comparable figure. So the governor sees
a Codex wall coming and can only react to a Claude one after it hits. That is a
difference in what the hosts record, not in how the router treats them.

### The governor

The part the cost-only routers leave out.

| state | trigger | effect |
|---|---|---|
| `NORMAL` | — | full tier map |
| `CONSERVE` | ≥60% quota | reasoning drops to Sonnet |
| `CRITICAL` | ≥85% quota | execution drops to Haiku |
| `DEPLETED` | limit hit | everything on Haiku; Codex chains take over |

Degradation is gradual, not a wall. A rate-limit event escalates one level and
decays after an hour, so one bad minute does not cripple the rest of your day.

Quota comes from whatever you have. With no quota source it still works, driven by
observed rate-limit errors alone.

### Optional: per-directory accounts

**Off by default.** Skip this whole section unless you hold more than one
subscription and care which one a directory bills. With `workspaces.enabled`
false — the shipped default — nothing below applies and tier routing is
unaffected.

If you do juggle accounts, label them however you like; the router never
interprets a label, it only compares them.

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

A path prefix assigns the account. `remote_patterns` then cross-checks the git
remote against it, so a repository cloned under the wrong prefix is flagged
rather than silently billed to the wrong account. `cxr` refuses to run where the
account is not in `allowed_accounts` — and with that list empty, it never
refuses.

### Optional: per-repository overrides

The global config is the default and needs no setup. A repository that wants
different routing ships `.agent-router.json` at its root; the router walks up
from the working directory, finds the nearest one, and merges it over the global
config for that call only.

```json
{
  "agent_type_tiers": {"schema-migration-agent": "reasoning"},
  "degrade": {"NORMAL": {"execution": "opus"}}
}
```

Objects merge recursively, arrays replace wholesale, so a project states only
what differs. The global file is never written to, and a malformed project file
is ignored rather than breaking routing.

This is the difference from a workspace-scoped tool like context-circuit, which
keeps its config inside the workspace and expects you to set one up. Here the
zero-setup global path is the default and the per-repo file is the exception —
but a repo that needs to say something can still say it, and it travels with the
repo for anyone who clones it.

## Install

Requires `bash` (3.2 is fine — macOS system bash works), `jq`, and Claude Code.

```sh
git clone https://github.com/hallode/agent-router ~/.claude/router
~/.claude/router/install.sh
```

The shipped config works as-is: tier routing needs no directory convention, no
account setup, and no edits. Everything optional is off.

Then wire the hooks into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse":       [{"matcher": "Agent", "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/router/hooks/agent-router.sh\"", "timeout": 10}]}],
    "UserPromptSubmit": [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/router/hooks/advisor.sh\"",      "timeout": 10}]}],
    "SessionStart":     [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/router/hooks/model-track.sh\"",  "timeout": 5}]}],
    "PostModelSwitch":  [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/router/hooks/model-track.sh\"",  "timeout": 5}]}]
  }
}
```

Effort tiers are worth setting at the same time. Running every model at `xhigh`
costs more than any routing decision saves:

```json
"modelSettings": {
  "claude-opus-5":   {"effortLevel": "xhigh"},
  "claude-sonnet-5": {"effortLevel": "high"},
  "claude-haiku-4-5-20251001": {"effortLevel": "low"}
}
```

Tune the middle tier by how its output actually lands, not by what looks frugal.
`medium` reads like the obvious saving and is where the worker tier quietly stops
being good enough; `high` is usually the floor for real implementation work. The
saving comes from not running *everything* at `xhigh`, not from squeezing the
tier that does the work.

## Use

```sh
ccr "<prompt>"                # start a session on the model the prompt needs
router status                 # state, workspace, live tier map
router why "<prompt>"         # explain a classification before trusting it
router log 20                 # recent routing decisions
router stats                  # counts by model and action
router enforce false          # dry-run: log decisions, change nothing
router state set CONSERVE     # force a budget state
router test                   # run the suite
router-learn                  # mine past sessions for what spend actually bought
```

Start with `router enforce false` for a few days and read `router log`. Every
router misclassifies something; better to find out from a log than from a subagent
that quietly had the wrong model.

### Escape hatch

Prefix a subagent prompt with `!!` and the router leaves it alone. The marker is
stripped before the agent sees it.

```
!! audit this migration end to end
```

### Codex failover

```sh
cxr "implement the retry middleware"   # classify, pick a model, run codex exec
cxr -t reasoning "why is this slow"    # force a tier
cxr -n "<task>"                        # dry run: print the chain
cxr -f "<task>"                        # ignore the account guard
```

Each tier gets its own *model*, not one model at three effort levels — a smaller
model at high effort is rarely the same trade as a larger one at low. On a rate
limit `cxr` advances to the next link and tells the governor, instead of dying:

```json
"codex_chains": {
  "execution": [
    {"model": "<your-primary>",  "effort": "medium"},
    {"model": "<your-fallback>", "effort": "medium"},
    {"model": "<your-reserve>",  "effort": "medium"}
  ]
}
```

Model availability differs per account, so there is no sensible default to ship.
List what yours actually offers and fill the chains from that:

```sh
jq -r '.models[] | "\(.slug)\t\([.supported_reasoning_levels[]?.effort] | join("/"))"' \
  ~/.codex/models_cache.json
```

Accounts often carry a spare or reserve model that never gets used because
nothing falls back to it. That is the last link worth having.

### Learning from your own history

Every assistant turn Claude Code records keeps the model, the effort level and
full token usage. `router-learn` reads those transcripts and reports where the
spend went, how often each model/effort combination was followed by a correction,
and what the classifier would have chosen instead.

```sh
router-learn            # report and suggestions
router-learn --apply    # same, and write the router-owned parts
```

It is read-only by default and never auto-applies anything. Correction detection
is a keyword proxy over your follow-up messages, not a verdict — on a small
sample it will be wrong, and where it disagrees with how a model felt to use,
the feeling is the better evidence. Defaults ship conservative precisely so this
stays an opt-in second step rather than something that quietly retunes itself.

## Known limitations

**Per-model effort does not reach subagents.** Measured on a real run: with
`modelSettings` setting Sonnet to `high` and a session-level `effortLevel` of
`xhigh`, a routed subagent came back as `claude-sonnet-5` at `xhigh`. The model
rewrite was honoured; the effort setting was not — the session's effort carried
over. So routing buys the model saving (the large one: roughly 15x on output
between the top and bottom tier) but not the effort saving. Lowering the
session-level `effortLevel` affects the session too, which is usually not what
you want.

**The main session cannot be routed.** Stated throughout, restated here because
it bounds everything: no hook can change a running session's model. In sessions
that do most work inline, the router's effect is whatever delegation it causes,
not a percentage off the whole bill.

**Correction rates are a weak signal.** `router-learn` detects follow-ups that
read like corrections using keywords. On small samples it will mislead. Treat it
as a prompt to look, never as a verdict.

## Design notes

**Fails open, always.** Every hook exits 0 and emits nothing on any error. A
broken router must never block a tool call — that trade is not close.

**bash 3.2 compatible.** No associative arrays, no `${var,,}`. macOS ships bash
3.2 and will not ship anything newer, and a router that only runs on Linux is not
a router for most people who need one.

**`.enforce // true` is a trap.** jq's `//` treats `false` as empty, so that
expression turns `false` into `true` and dry-run mode never engages. The config
is read with `if has("enforce") then .enforce else true end` instead. Worth
knowing before adding any other boolean setting.

**A fork is never routed.** `subagent_type: "fork"` inherits the parent model by
design; a model override there is silently ignored, so the router passes it
through untouched.

## Prior art

- [tzachbon/claude-model-router-hook](https://github.com/tzachbon/claude-model-router-hook) — four hook events, heuristics with an optional Haiku fallback. Defers switching to the next session.
- [bmersereau/claude-router](https://github.com/bmersereau/claude-router) — injects routing context and spawns tiered subagents. Costs ~3.4k tokens of overhead per subagent.
- [maiha28781-cloud/claude-smart-model-router](https://github.com/maiha28781-cloud/claude-smart-model-router) — classifies and recommends; you still approve.
- [lm-sys/RouteLLM](https://github.com/lm-sys/routellm) — trained routers for API calls. Different layer: no concept of an agent with tools.

None of them degrade under a rate limit, which is the case that started this.

## License

MIT
