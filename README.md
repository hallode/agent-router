# agent-router

Automatically pick a suitable model when starting a new CLI coding task without
spending a model call on the decision. The source repository supports Claude Code and Codex, but each host
gets its own installation, configuration, wrapper, budget state, and log.

## Install

Requires Bash, `jq`, and whichever host CLI you use. From this checkout:

```sh
bash install.sh
bash install.sh --with-agents   # optional helper roles for Claude and Codex
bash tests/run.sh
bash tests/verify-install.sh
```

The installed layout is intentionally separate:

| Claude Code | Codex |
|---|---|
| `~/.claude/router/config.json` | `~/.codex/router/config.json` |
| `~/.claude/router/bin/ccr` | `~/.codex/router/bin/cxr` |
| `~/.claude/router/hooks/claude-*.sh` | `~/.codex/router/hooks/codex-advisor.sh` |
| `~/.claude/router/shell/claude.zsh` | `~/.codex/router/shell/codex.zsh` |
| `~/.claude/router/state.json` | `~/.codex/router/state.json` |

Each also has its own `bin/router` for `status`, `why`, `state`, `probe`, `log`,
`stats`, `enforce`, and `launch-model`. No Codex executable is installed under
Claude's router directory, and no Claude executable is installed under Codex's.
The checkout's `config.example.json` is a combined source template; the
installer writes host-specific configs. Existing config values are preserved
when migrating from an older combined installation. The original combined
files are moved to `~/.local/share/agent-router/pre-split/` for recovery.

Day-to-day, use `claude` or `codex` normally. The only router command you need
to call yourself is `agent-router status`. It shows recent hook activity, the
observed host and model, or `idle` if no activity was observed in five minutes.
Recent activity is evidence of a hook firing, not proof that the process remains
open. An empty status after installation means routing has not yet been observed
in a session; open a new session to verify the hooks.

When an observed session changes models, its hook sends one short user-visible
notice with the old and new model. Claude uses `PostModelSwitch`; Codex compares
the model reported by consecutive lifecycle events. CLI task launches show the
initial choice, and Codex rate-limit fallback shows the actual model transition
in the terminal. No notice is emitted for an unchanged model. These notices
report observed changes; they do not themselves switch an interactive model.

Add the host-specific wrappers to `~/.zshrc`:

```sh
source ~/.claude/router/shell/claude.zsh
source ~/.codex/router/shell/codex.zsh
```

They affect only their matching command. `claude "<task>"` and
`codex "<task>"` route automatically. The internal `ccr` and `cxr` executables
are not part of the daily workflow. Subcommands and flags pass through to the real
CLI. `claude!` and `codex!` bypass their wrappers. A bare interactive launch
cannot classify a prompt it has not seen, but may start on a cheaper model
when that host's budget state is tight.

## Hooks

Claude settings in `~/.claude/settings.json` should call only these files:

```text
~/.claude/router/hooks/claude-subagent.sh   PreToolUse: Agent
~/.claude/router/hooks/claude-advisor.sh    UserPromptSubmit
~/.claude/router/hooks/claude-session.sh    SessionStart, PostModelSwitch
~/.claude/router/hooks/claude-session.sh    SessionEnd
```

Codex hooks in `~/.codex/config.toml` should call only its advisor:

```toml
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "$HOME/.codex/router/hooks/codex-advisor.sh"
timeout = 10

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "$HOME/.codex/router/hooks/codex-advisor.sh"
timeout = 10

[[hooks.SessionEnd]]
[[hooks.SessionEnd.hooks]]
type = "command"
command = "$HOME/.codex/router/hooks/codex-advisor.sh"
timeout = 10
```

Codex supports user-level hook configuration in `~/.codex/config.toml`;
see the [official configuration guide](https://learn.chatgpt.com/docs/config-file/config-advanced).
The Codex hook provides budget context. It cannot change the model of an
already-running Desktop or interactive session; prompt-based model choice is
for new CLI tasks launched through the ordinary `codex "<task>"` wrapper.

## Choices

The classifier uses three task sizes: `trivial` for narrow lookups and
mechanical changes, `execution` for ordinary implementation, and `reasoning`
for design, diagnosis, and review. Unclear requests use `execution`. No model
call is made to classify a prompt.

```sh
~/.claude/router/bin/router why "find the booking handler"
~/.codex/router/bin/router why "implement the booking endpoint"
agent-router status
```

Claude can also route delegated work by helper name. The optional definitions
are `router-scout` (lookup), `router-builder` (bounded implementation),
`router-inspector` (independent check), and `router-navigator` (ordered work
map). Their names describe the result they return, not their importance.

Effort follows the task too. On Claude, the `effort` map in config sets
`--effort` for a prompted launch (execution=medium, reasoning=high; an unmapped
tier keeps the host default). The Agent tool cannot carry effort, so each
Claude role sets its own `effort:` frontmatter: scout low, builder medium,
inspector and navigator high. On Codex, `--with-agents` (or
`~/.codex/router/bin/router agents`) writes the same four roles to
`~/.codex/agents/` with the model and effort from `codex_chains`. Each Codex
SessionStart refreshes those files for the current budget state. It never
touches a role file it did not write.

No hook can switch a running session's model, but you can in one command.
When a prompt clearly does not fit the session, the advisor says so once per
session: for example, a large model on execution work, or a small model on a
reasoning task. On Claude it suggests `/model sonnet` and `/effort medium`; on
Codex it names the model and effort to pick with `/model`. A mid-size session
is never prompted.

Claude's advisor also watches the resent context. Once the latest turn's
context passes `compact.threshold` (160k, or 250k on a `[1m]` model), it
suggests `/compact` once, then again after each further 60k of growth.

Agent roles defined outside this router are routed by mapping their names in
your own config's `agent_type_tiers`. On Codex, pin those roles where they are
defined; this router writes only its own role files.

Each host's budget responds only to its own state. The four states are
`NORMAL`, `CONSERVE`, `CRITICAL`, and `DEPLETED`. A tight Codex budget lowers
the task tier; entries later in a model chain are availability fallbacks after
a rate limit, never a cheaper step. The Codex quota probe reads Codex's local
records. Claude's quota probe is blank by default, so a Codex limit never
silently changes Claude's model.

```sh
agent-router status
~/.codex/router/bin/router probe
```

Project-specific `.agent-router.json` overrides are merged over the matching
host config for that task. Do not put host-specific keys for the other host in
the project override.

## Checks and limits

`bash tests/run.sh` exercises the classifier, fallback, hooks, and wrappers
against fixtures. `bash tests/verify-install.sh` checks both live runtimes and
fails if their hook paths or files are crossed. `bash tests/audit-readme.sh`
checks documented entry points.

The router does not guarantee a token reduction for every task. A task placed
on too-small a model may need a costly retry. `router why` and dry runs let
you inspect a decision before relying on it. A failed task is not retried by
the shell wrapper; only a router startup failure falls back to the native CLI.

## License

MIT
