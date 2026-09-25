# Router field guide

Use a helper only when its assignment is clear and independent enough to return
a useful result. The current session owns the conversation and final decision.
Do not pass an explicit model: the router reads the helper name and current
budget to select one.

| helper | hand it |
|---|---|
| `router-scout` | a narrow, read-only question about the code |
| `router-builder` | a bounded change with settled requirements |
| `router-inspector` | a finished result to check against what it was meant to do |
| `router-navigator` | a multi-step change that needs an order and checks |

Keep tiny edits in the current session. Do not split a task when coordinating
the pieces would take longer than doing it. If a helper needs the full dialogue
to make a decision, keep that decision here and delegate only the separable work.
Independent assignments may run in parallel.

An agent definition that explicitly selects a model keeps that choice. To
bypass routing for one delegated prompt, prefix it with `!!` and state why.
