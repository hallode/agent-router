#!/usr/bin/env bash
# Check the documented host entry points against the source checkout.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FAIL=0
for path in install.sh bin/ccr bin/cxr bin/claude-router bin/codex-router \
  bin/codex-quota shell/claude.zsh shell/codex.zsh \
  hooks/claude-subagent.sh hooks/claude-advisor.sh hooks/claude-session.sh \
  hooks/codex-advisor.sh tests/run.sh tests/verify-install.sh; do
  [ -f "$ROOT/$path" ] || { echo "missing: $path"; FAIL=$((FAIL+1)); }
done
if grep -qF '/.claude/router/hooks/codex-' "$ROOT/README.md"; then
  echo 'README routes a Codex hook through Claude'; FAIL=$((FAIL+1))
fi
if grep -qF '/.claude/router/shell/router.zsh' "$ROOT/README.md"; then
  echo 'README names the old mixed wrapper'; FAIL=$((FAIL+1))
fi
if grep -qF 'shared state' "$ROOT/README.md"; then
  echo 'README still claims shared budget state'; FAIL=$((FAIL+1))
fi
printf 'readme audit: %s issue(s)\n' "$FAIL"
[ "$FAIL" -eq 0 ]
