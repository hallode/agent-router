#!/usr/bin/env bash
# install.sh — copy agent-router into ~/.claude/router and print the hook config.
#
# Deliberately does not edit settings.json for you: hooks run arbitrary commands
# on every tool call, and that file is worth reading before something appends to
# it. The JSON to paste is printed at the end.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd -P)
DEST="${1:-$HOME/.claude/router}"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

mkdir -p "$DEST"
for d in lib hooks bin tests; do
  mkdir -p "$DEST/$d"
  cp "$SRC/$d"/* "$DEST/$d/" 2>/dev/null || true
done
chmod +x "$DEST"/lib/*.sh "$DEST"/hooks/*.sh "$DEST"/bin/* 2>/dev/null || true

if [ -f "$DEST/config.json" ]; then
  echo "kept existing $DEST/config.json"
else
  cp "$SRC/config.example.json" "$DEST/config.json"
  echo "created $DEST/config.json — edit workspaces.rules before relying on it"
fi

echo
echo "running tests..."
bash "$SRC/tests/run.sh" | tail -3

cat <<EOF

installed to $DEST

Add to ~/.claude/settings.json:

  "hooks": {
    "PreToolUse":       [{"matcher": "Agent", "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/agent-router.sh\\"", "timeout": 10}]}],
    "UserPromptSubmit": [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/advisor.sh\\"",      "timeout": 10}]}],
    "SessionStart":     [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/model-track.sh\\"",  "timeout": 5}]}],
    "PostModelSwitch":  [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/model-track.sh\\"",  "timeout": 5}]}]
  }

Then:

  $DEST/bin/router enforce false    # start in dry-run
  $DEST/bin/router status
  $DEST/bin/router log 20           # read these before enforcing

EOF
