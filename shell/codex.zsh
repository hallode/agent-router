# Codex-only shell entry point. Source from ~/.zshrc.
_CODEX_ROUTER_HOME="${CODEX_ROUTER_HOME:-${CODEX_HOME:-$HOME/.codex}/router}"
_CODEX_SUBCOMMANDS=(exec e review login logout mcp plugin app-server remote-control app completion update doctor sandbox debug apply a resume queue archive delete migrate-rollouts unarchive fork cloud exec-server features help)

_codex_router_prompt() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in -*) return 1 ;; *[[:space:]]*) return 0 ;; esac
  local sub
  for sub in "${_CODEX_SUBCOMMANDS[@]}"; do [ "$1" = "$sub" ] && return 1; done
  return 0
}

codex() {
  local m eff rc
  if [ "$#" -eq 0 ]; then
    m=$(ROUTER_HOME="$_CODEX_ROUTER_HOME" "$_CODEX_ROUTER_HOME/bin/router" launch-model 2>/dev/null)
    if [ -n "$m" ]; then
      eff=${m#*$'\t'}; m=${m%%$'\t'*}
      command codex -c "model=$m" -c "model_reasoning_effort=$eff"; return $?
    fi
    command codex; return $?
  fi
  if ! _codex_router_prompt "$@" || [ ! -x "$_CODEX_ROUTER_HOME/bin/cxr" ]; then
    command codex "$@"; return $?
  fi
  ROUTER_HOME="$_CODEX_ROUTER_HOME" "$_CODEX_ROUTER_HOME/bin/cxr" "$1"; rc=$?
  [ "$rc" -eq 126 ] && { command codex "$@"; return $?; }
  return "$rc"
}
alias codex!='command codex'
