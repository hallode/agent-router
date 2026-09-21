# router.zsh — make routing invisible.
#
#   source ~/.claude/router/shell/router.zsh
#
# Wraps `claude` and `codex` so you keep typing what you already type. When the
# invocation carries a prompt, the router picks the model from it; when it does
# not — a bare interactive launch, a flag, a subcommand — the real binary runs
# untouched.
#
# Conservative on purpose. These wrappers sit in front of tools you use all day,
# so anything that is not clearly a plain prompt passes straight through, and a
# router that errors falls back to the real binary rather than blocking you.

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"

_router_is_prompt() {
  # A prompt is a single non-flag, non-subcommand argument.
  [ "$#" -eq 1 ] || return 1
  case "$1" in
    -*) return 1 ;;
  esac
  return 0
}

claude() {
  if _router_is_prompt "$@" && [ -x "$ROUTER_HOME/bin/ccr" ]; then
    "$ROUTER_HOME/bin/ccr" "$1" && return 0
    command claude "$@"
  else
    command claude "$@"
  fi
}

codex() {
  # Only a bare `codex "prompt"` routes. Subcommands (exec, resume, login, ...)
  # and flags are Codex's own interface and are left alone.
  if _router_is_prompt "$@" && [ -x "$ROUTER_HOME/bin/cxr" ]; then
    "$ROUTER_HOME/bin/cxr" "$1" && return 0
    command codex "$@"
  else
    command codex "$@"
  fi
}

# Escape hatches: the real binaries, always reachable.
alias claude!='command claude'
alias codex!='command codex'
