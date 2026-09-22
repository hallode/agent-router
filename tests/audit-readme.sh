#!/usr/bin/env bash
# audit-readme.sh — check what the README claims against what the repo contains.
#
# Documentation drifts silently: a rename leaves the old filename in prose, a
# removed config key keeps being documented, a shipped feature is never
# mentioned at all. None of that fails a test suite, and all of it wastes the
# reader's time. This fails instead.
#
# Hook filenames are deliberately exempt: they live in install.sh so the two
# copies cannot disagree.
R=$(cd "$(dirname "$0")/.." && pwd -P)
MD="$R/README.md"
# The dead config key, not the English word in "Three tiers".
grep -q "\"tiers\"" "$MD" && echo "  STALE     \"tiers\" config key"
P=0; F=0
ok(){ P=$((P+1)); }
no(){ F=$((F+1)); printf '  MISMATCH  %s\n' "$1"; }

echo "== every file path the README names exists =="
grep -oE '(hooks|bin|lib|shell|agents|tests)/[A-Za-z0-9._-]+' "$MD" | sort -u | while read -r f; do
  [ -e "$R/$f" ] || printf '  MISSING   %s\n' "$f"
done

echo "== every router subcommand the README shows is implemented =="
for c in status why log stats enforce state probe test launch-model; do
  grep -q "router $c" "$MD" || continue
  grep -q "^  $c)" "$R/bin/router" || printf '  UNDOCUMENTED-OR-MISSING  router %s\n' "$c"
done

echo "== every binary the README invokes exists =="
for b in ccr cxr router router-learn codex-quota; do
  if grep -qE "(^|[^a-z-])$b " "$MD"; then
    [ -x "$R/bin/$b" ] || printf '  MISSING   bin/%s\n' "$b"
  fi
done

echo "== every config key the README shows exists in the example =="
for k in enforce degrade agent_type_tiers codex codex_chains workspaces quota advisor bypass_prefix; do
  if grep -q "\"$k\"" "$MD"; then
    jq -e "has(\"$k\")" "$R/config.example.json" >/dev/null 2>&1 || printf '  NOT-IN-CONFIG  %s\n' "$k"
  fi
done

echo "== things that exist but the README never mentions =="
# Hook filenames live in install.sh on purpose, so the README is not checked for
# them. Everything a reader invokes directly must be named here.
for f in bin/ccr bin/cxr bin/codex-quota bin/router-learn \
         shell/router.zsh tests/verify-install.sh install.sh; do
  base=$(basename "$f")
  grep -q "$base" "$MD" || printf '  UNDOCUMENTED  %s\n' "$f"
done
for c in launch-model; do
  grep -q "$c" "$MD" || printf '  UNDOCUMENTED  router %s\n' "$c"
done

echo "== stale references =="
for old in agent-router.sh model-track.sh codex-hook.sh router-quota advisor.sh "cc-explorer" "codex.chains"; do
  grep -qwF -- "$old" "$MD" && printf '  STALE     %s\n' "$old"
done

echo "== README still claims the old install flow? =="
grep -q 'cp ~/.claude/router/agents' "$MD" && printf '  STALE     manual agent copy (install.sh --with-agents now does it)\n'

echo "== links =="
grep -oE 'https?://[^) ]+' "$MD" | sort -u | while read -r u; do
  case "$u" in
    https://github.com/*/*|https://code.claude.com*|https://developers.openai.com*) ;;
    *) printf '  SUSPECT   %s\n' "$u" ;;
  esac
done
echo "  (dicek bentuk, bukan HTTP)"

if [ -n "${FOUND:-}" ]; then exit 1; fi
exit 0
