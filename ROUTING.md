# Delegation standard

Four standard roles exist. Each one's model is set by `~/.claude/router/config.json`
and enforced by a `PreToolUse` hook, and degraded automatically when quota runs
low. Use them by name; do not pass an explicit `model`.

| role | for | runs on |
|---|---|---|
| `router-explorer` | locating code, read-only investigation, fan-out search | Haiku |
| `router-worker` | a settled, bounded change plus its checks | Sonnet |
| `router-reviewer` | checking work something else produced | Opus |
| `router-planner` | ordering a change large enough to get wrong | Opus |

## When to delegate

Delegate the parts that stand alone. Keep in this session the judgement, the
decisions, and anything that needs the conversation so far.

- Searching, locating, listing, counting → `router-explorer`.
- A change whose requirements are already settled → `router-worker`.
- Verifying a result before relying on it → `router-reviewer`.
- More than a few dependent steps across components → `router-planner` first.

Delegate in parallel when the parts are independent.

## When not to delegate

Do not delegate work that needs context this session holds and the subagent does
not — a subagent starts blind and cannot ask. Do not delegate a decision; make it
here and delegate the execution. Do not split work so finely that assembling the
pieces costs more than doing it. A one-line edit is not worth a subagent.

If an explicit model is genuinely needed, prefix the subagent prompt with `!!` to
bypass routing, and say why.

## Why

The main session is the orchestrator and cannot change its own model — no hook
can. Everything done inline is billed at the orchestrator's rate. Delegation is
the only mechanism that prices work by what it actually needs, so the split
between what stays here and what goes out is the whole saving.
