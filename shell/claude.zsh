# Claude-only shell entry point. Source from ~/.zshrc.
_CLAUDE_ROUTER_HOME="${CLAUDE_ROUTER_HOME:-$HOME/.claude/router}"
_CLAUDE_SUBCOMMANDS=(mcp config doctor update install migrate-installer setup-token plugin agents help)

_claude_router_prompt() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in -*) return 1 ;; *[[:space:]]*) return 0 ;; esac
  local sub
  for sub in "${_CLAUDE_SUBCOMMANDS[@]}"; do [ "$1" = "$sub" ] && return 1; done
  return 0
}

claude() {
  local m rc
  if [ "$#" -eq 0 ]; then
    m=$(ROUTER_HOME="$_CLAUDE_ROUTER_HOME" "$_CLAUDE_ROUTER_HOME/bin/router" launch-model 2>/dev/null)
    [ -n "$m" ] && { command claude --model "$m"; return $?; }
    command claude; return $?
  fi
  if ! _claude_router_prompt "$@" || [ ! -x "$_CLAUDE_ROUTER_HOME/bin/ccr" ]; then
    command claude "$@"; return $?
  fi
  ROUTER_HOME="$_CLAUDE_ROUTER_HOME" "$_CLAUDE_ROUTER_HOME/bin/ccr" "$1"; rc=$?
  [ "$rc" -eq 126 ] && { command claude "$@"; return $?; }
  return "$rc"
}
alias claude!='command claude'
