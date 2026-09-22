# router.zsh — make routing invisible.
#
#   source ~/.claude/router/shell/router.zsh
#
# Wraps `claude` and `codex` so you keep typing what you already type. When the
# invocation carries a prompt, the router picks the model from it; a flag, a
# subcommand, or a bare interactive launch runs the real binary untouched.
#
# Two rules this file exists to get right:
#
#   1. A refusal is not a failure. When the router declines to run something on
#      purpose — the wrong account for this directory — falling back to the real
#      CLI would perform exactly the action that was refused. Only an inability
#      to run the router at all is a reason to fall back.
#
#   2. A task that may already have started is never retried. A nonzero exit
#      from a run that reached the provider can mean the work partly happened;
#      re-running it risks doing the side effects twice.
#
# So the wrapper falls back on one exit code only: 126, which the router uses for
# "I could not start" and nothing else.

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"

# Exit codes the router itself defines.
_ROUTER_RC_INFRA=126   # router could not start — safe to fall back
_ROUTER_RC_REFUSED=3   # refused on purpose — must NOT fall back
_ROUTER_RC_USAGE=2

# Subcommands belong to the host CLI, never to the router. Taken from the
# installed interfaces; unknown words are treated as prompts, which is the
# harmless direction — an unrecognised subcommand reaching the real CLI as a
# prompt is a worse failure than a prompt being routed.
_ROUTER_CODEX_SUBCOMMANDS=(
  exec e review login logout mcp plugin app-server remote-control app
  completion update doctor sandbox debug apply a resume queue archive
  delete migrate-rollouts unarchive fork cloud exec-server features help
)
_ROUTER_CLAUDE_SUBCOMMANDS=(
  mcp config doctor update install migrate-installer setup-token
  plugin agents help
)

_router_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# _router_is_prompt <host> <args...>
# True only for a single non-flag argument that is not a known subcommand.
# A subcommand is one bare word, so anything containing whitespace is a prompt.
_router_is_prompt() {
  local host="$1"; shift
  [ "$#" -eq 1 ] || return 1
  [ -n "$1" ] || return 1
  case "$1" in
    -*) return 1 ;;
  esac
  case "$1" in
    *[[:space:]]*) return 0 ;;   # has a space: cannot be a subcommand
  esac
  case "$host" in
    codex)  _router_in_list "$1" "${_ROUTER_CODEX_SUBCOMMANDS[@]}"  && return 1 ;;
    claude) _router_in_list "$1" "${_ROUTER_CLAUDE_SUBCOMMANDS[@]}" && return 1 ;;
  esac
  return 0
}

# A bare launch — `codex` or `claude` with nothing after it — is the common case
# and has no prompt to classify. Tier routing cannot help, but the budget still
# can: when quota is tight, start on the cheaper model instead of discovering the
# limit halfway through. When the budget is fine, change nothing.
_router_bare_launch() {
  local host="$1" m eff
  m=$("$ROUTER_HOME/bin/router" launch-model "$host" 2>/dev/null)
  [ -n "$m" ] || { command "$host"; return $?; }
  case "$host" in
    claude) command claude --model "$m" ;;
    codex)
      eff=${m#*$'\t'}; m=${m%%$'\t'*}
      [ "$eff" = "$m" ] && eff=medium
      command codex -c "model=$m" -c "model_reasoning_effort=$eff" ;;
  esac
}

_router_run() {
  # _router_run <host> <router-bin> <args...>
  local host="$1" bin="$2"; shift 2
  if [ "$#" -eq 0 ] && [ -x "$ROUTER_HOME/bin/router" ]; then
    _router_bare_launch "$host"
    return $?
  fi
  if ! _router_is_prompt "$host" "$@" || [ ! -x "$bin" ]; then
    command "$host" "$@"
    return $?
  fi
  "$bin" "$1"
  local rc=$?
  if [ "$rc" -eq "$_ROUTER_RC_INFRA" ]; then
    # The router could not start. Nothing ran, so running it directly is safe.
    command "$host" "$@"
    return $?
  fi
  # Every other code is the router's or the task's own answer. A deliberate
  # refusal stays refused; a failed task is not silently repeated.
  return $rc
}

claude() { _router_run claude "$ROUTER_HOME/bin/ccr" "$@"; }
codex()  { _router_run codex  "$ROUTER_HOME/bin/cxr" "$@"; }

# Escape hatches: the real binaries, always reachable.
alias claude!='command claude'
alias codex!='command codex'
