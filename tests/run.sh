#!/usr/bin/env bash
# run.sh — agent-router test suite.
#
# No framework, bash 3.2 compatible, and hermetic: every test runs against a
# fixture config and temporary git repositories, never against the machine's
# real directories or the installed config.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT

export ROUTER_HOME="$REPO_ROOT"
export ROUTER_CONFIG="$TMP/config.json"
export ROUTER_STATE="$TMP/state.json"
export ROUTER_LOG="$TMP/decisions.jsonl"
ROUTER_HOME_SESS="$TMP/sessions"

# --- fixture ----------------------------------------------------------------
PERSONAL="$TMP/ws/personal"
WORK="$TMP/ws/work"
mkdir -p "$PERSONAL" "$WORK"

cp "$REPO_ROOT/config.example.json" "$ROUTER_CONFIG"

# Helpers: flip workspace accounting on/off against the fixture directories.
enable_workspaces() {
  python3 - "$ROUTER_CONFIG" "$PERSONAL" "$WORK" <<'PYX'
import json,sys
p,personal,work=sys.argv[1],sys.argv[2],sys.argv[3]
c=json.load(open(p))
c['workspaces']['enabled']=True
c['workspaces']['rules']=[{"prefix":personal,"account":"personal"},
                          {"prefix":work,"account":"employer"}]
c['workspaces']['default']=""
c['workspaces']['remote_patterns']=[{"pattern":r"git\.acme\.test","account":"employer"}]
c['codex']['allowed_accounts']=["personal"]
json.dump(c,open(p,'w'),indent=2)
PYX
}
disable_workspaces() {
  python3 - "$ROUTER_CONFIG" <<'PYX'
import json,sys
c=json.load(open(sys.argv[1]))
c['workspaces']['enabled']=False
c['codex']['allowed_accounts']=[]
json.dump(c,open(sys.argv[1],'w'),indent=2)
PYX
}

mkgit() { # mkgit <dir> <remote-url>
  mkdir -p "$1" && git -C "$1" init -q 2>/dev/null
  git -C "$1" remote add origin "$2" 2>/dev/null
}
mkgit "$WORK/company-svc"      "git@git.acme.test:core/company-svc.git"
mkgit "$PERSONAL/side-project" "git@github.com:someone/side-project.git"
mkgit "$PERSONAL/leaked-repo"  "git@git.acme.test:core/leaked.git"

. "$REPO_ROOT/lib/config.sh"
. "$REPO_ROOT/lib/classify.sh"
. "$REPO_ROOT/lib/governor.sh"
. "$REPO_ROOT/lib/workspace.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n    want=%s got=%s\n' "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "$2" "$3"; fi; }
tier() { classify_tier "${2:-}" "$1"; }

echo "== classify: reasoning =="
eq "architecture"    reasoning "$(tier 'design the system architecture for billing')"
eq "root cause"      reasoning "$(tier 'find the root cause of this flaky test')"
eq "race condition"  reasoning "$(tier 'there is a race condition in the worker pool')"
eq "security audit"  reasoning "$(tier 'do a security audit of the auth handler')"
eq "code review"     reasoning "$(tier 'review the code in billing.go')"
eq "why does"        reasoning "$(tier 'why does this query take 4 seconds')"
eq "debug"           reasoning "$(tier 'debug the panic in the sync job')"
eq "tradeoff"        reasoning "$(tier 'what are the trade-offs between sqlx and pgx')"
eq "bottleneck"      reasoning "$(tier 'profiling shows a bottleneck in the encoder')"
eq "design schema"   reasoning "$(tier 'design the billing schema')"
eq "design flow"     reasoning "$(tier 'design the new payment flow')"
eq "redesign svc"    reasoning "$(tier 'redesign the notification service')"
eq "non-english why" reasoning "$(tier 'kenapa endpoint ini lambat banget')"

echo "== classify: trivial =="
eq "list files"      trivial "$(tier 'list all files in the handlers package')"
eq "grep"            trivial "$(tier 'grep for TODO comments')"
eq "rename"          trivial "$(tier 'rename the variable ctx2 to reqCtx')"
eq "gofmt"           trivial "$(tier 'gofmt the repository')"
eq "git status"      trivial "$(tier 'git status and report the branch')"
eq "count"           trivial "$(tier 'how many handlers are registered')"
eq "typo"            trivial "$(tier 'fix the typo in the readme')"
eq "where defined"   trivial "$(tier 'where is ParseConfig defined')"
eq "leading space"   trivial "$(tier ' grep for TODO comments')"
eq "empty desc join" trivial "$(tier "$(printf '%s %s' '' 'grep for TODO comments')")"
eq "trailing space"  trivial "$(tier 'grep for TODO comments  ')"

echo "== classify: execution is the default =="
eq "implement"       execution "$(tier 'implement the retry middleware')"
eq "write tests"     execution "$(tier 'write unit tests for the billing package')"
eq "fix bug"         execution "$(tier 'fix the off by one in the pagination')"
eq "add endpoint"    execution "$(tier 'add a POST /invoices endpoint')"
eq "empty"           execution "$(tier '')"
eq "unknown verb"    execution "$(tier 'wire up the new feature flag')"

echo "== classify: precedence =="
eq "reasoning>trivial" reasoning "$(tier 'list the packages then design the new module layout')"
eq "design not a noun" execution "$(tier 'follow the existing design and add a field')"
LONG=$(printf 'find the handler %.0s' $(seq 1 200))
eq "long is not trivial" execution "$(tier "$LONG")"

echo "== classify: roles outrank prompt text =="
eq "explorer" trivial   "$(tier 'anything at all' cc-explorer)"
eq "planner"  reasoning "$(tier 'anything at all' cc-planner)"
eq "worker"   execution "$(tier 'anything at all' cc-worker)"
eq "reviewer" reasoning "$(tier 'anything at all' cc-reviewer)"
eq "codex naming" reasoning "$(tier 'anything' cc_reviewer)"
eq "role beats text"  reasoning "$(tier 'grep for TODO' cc-planner)"
eq "Plan builtin"     reasoning "$(tier 'grep for TODO' Plan)"
eq "statusline"       trivial   "$(tier 'anything' statusline-setup)"

echo "== standard roles route deterministically =="
eq "router-explorer" trivial   "$(tier 'design the entire architecture' router-explorer)"
eq "router-worker"   execution "$(tier 'grep for TODO' router-worker)"
eq "router-reviewer" reasoning "$(tier 'grep for TODO' router-reviewer)"
eq "router-planner"  reasoning "$(tier 'grep for TODO' router-planner)"

echo "== governor: state machine =="
eq "default"   NORMAL   "$(governor_state)"
governor_set CONSERVE test 0 >/dev/null
eq "set"       CONSERVE "$(governor_state)"
eq "escalate1" CRITICAL "$(governor_escalate_name CONSERVE)"
eq "escalate2" DEPLETED "$(governor_escalate_name CRITICAL)"
eq "escalate3" DEPLETED "$(governor_escalate_name DEPLETED)"
governor_set NORMAL reset 0 >/dev/null
governor_record_limit codex >/dev/null
eq "limit escalates" CONSERVE "$(governor_state)"

echo "== governor: expiry decays back to NORMAL =="
governor_set CRITICAL test 1 >/dev/null
python3 -c "
import json,time,os
p=os.environ['ROUTER_STATE']
d=json.load(open(p)); d['expires']=int(time.time())-5
json.dump(d,open(p,'w'))"
eq "expired" NORMAL "$(governor_state)"

echo "== governor: tier -> model per state =="
governor_set NORMAL x 0 >/dev/null
eq "N reasoning" opus   "$(governor_model reasoning)"
eq "N execution" sonnet "$(governor_model execution)"
eq "N trivial"   haiku  "$(governor_model trivial)"
eq "reviewer != worker family" "opus|sonnet" "$(governor_model reasoning)|$(governor_model execution)"
governor_set CONSERVE x 0 >/dev/null
eq "C reasoning" sonnet "$(governor_model reasoning)"
eq "C execution" sonnet "$(governor_model execution)"
governor_set CRITICAL x 0 >/dev/null
eq "X execution" haiku  "$(governor_model execution)"
governor_set DEPLETED x 0 >/dev/null
eq "D reasoning" haiku  "$(governor_model reasoning)"
governor_set NORMAL x 0 >/dev/null

echo "== hook: routing end to end =="
hook() { printf '%s' "$1" | bash "$REPO_ROOT/hooks/agent-router.sh"; }
m() { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.model // "NONE"'; }
p() { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.prompt // "NONE"'; }

OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"find","prompt":"grep for TODO comments"}}')
eq "trivial->haiku" haiku "$(m "$OUT")"
OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"d","prompt":"design the system architecture"}}')
eq "reasoning->opus" opus "$(m "$OUT")"
OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"i","prompt":"implement the retry middleware"}}')
eq "execution->sonnet" sonnet "$(m "$OUT")"

echo "== hook: escape hatch =="
OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"x","prompt":"!! grep for TODO comments"}}')
eq "bypass sets no model" NONE "$(m "$OUT")"
eq "bypass strips marker" "grep for TODO comments" "$(p "$OUT")"

echo "== hook: fails open =="
eq "fork untouched"   "" "$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"fork","prompt":"grep"}}')"
eq "non-Agent tool"   "" "$(hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
eq "garbage input"    "" "$(hook 'not json at all')"
eq "empty stdin"      "" "$(hook '')"
OUT=$(hook '{"tool_name":"Agent","tool_input":{}}')
eq "empty input->default" sonnet "$(m "$OUT")"

echo "== hook: preserves unrelated fields =="
OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"d","prompt":"look","isolation":"worktree"}}')
eq "keeps isolation"    worktree "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.isolation')"
eq "keeps subagent"     Explore  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.subagent_type')"
eq "keeps description"  d        "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.description')"

echo "== hook: governor degrades live routing =="
governor_set CRITICAL x 0 >/dev/null
OUT=$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"i","prompt":"implement the retry middleware"}}')
eq "CRITICAL exec->haiku" haiku "$(m "$OUT")"
governor_set NORMAL x 0 >/dev/null

echo "== hook: dry-run changes nothing =="
python3 -c "
import json,os
p=os.environ['ROUTER_CONFIG']; c=json.load(open(p)); c['enforce']=False
json.dump(c,open(p,'w'))"
eq "dry-run silent" "" "$(hook '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"grep for TODO"}}')"
python3 -c "
import json,os
p=os.environ['ROUTER_CONFIG']; c=json.load(open(p)); c['enforce']=True
json.dump(c,open(p,'w'))"

echo "== workspace: OFF by default =="
eq "account empty"   "" "$(workspace_account "$WORK")"
eq "remote empty"    "" "$(workspace_remote_account "$WORK/company-svc")"
eq "no mismatch"     "" "$(workspace_mismatch "$PERSONAL/leaked-repo")"
workspace_account_allowed codex "$WORK"; eq "guard inert" 0 "$?"
( cd "$WORK" && bash "$REPO_ROOT/bin/cxr" -n "grep TODO" >/dev/null 2>&1 )
eq "cxr runs anywhere" 0 "$?"

echo "== workspace: ON, path decides the account =="
enable_workspaces
eq "employer path"   employer "$(workspace_account "$WORK")"
eq "employer nested" employer "$(workspace_account "$WORK/company-svc")"
eq "personal path"   personal "$(workspace_account "$PERSONAL")"
eq "personal nested" personal "$(workspace_account "$PERSONAL/side-project")"
eq "unmatched empty" ""       "$(workspace_account "$TMP")"

echo "== workspace: ON, remote cross-check =="
eq "matching remote"  employer "$(workspace_remote_account "$WORK/company-svc")"
eq "unmatched remote" ""       "$(workspace_remote_account "$PERSONAL/side-project")"
eq "no repo"          ""       "$(workspace_remote_account "$TMP")"
eq "aligned is quiet" ""       "$(workspace_mismatch "$WORK/company-svc")"
eq "unknown is quiet" ""       "$(workspace_mismatch "$PERSONAL/side-project")"
case "$(workspace_mismatch "$PERSONAL/leaked-repo")" in
  *employer*) ok ;;
  *) bad "mismatched repo flags" "warning" "$(workspace_mismatch "$PERSONAL/leaked-repo")" ;;
esac

echo "== cxr: account guard applies only when configured =="
( cd "$WORK"     && bash "$REPO_ROOT/bin/cxr" -n "grep TODO" >/dev/null 2>&1 )
eq "refuses wrong account"   3 "$?"
( cd "$WORK"     && bash "$REPO_ROOT/bin/cxr" -n -f "grep TODO" >/dev/null 2>&1 )
eq "force overrides"         0 "$?"
( cd "$PERSONAL" && bash "$REPO_ROOT/bin/cxr" -n "grep TODO" >/dev/null 2>&1 )
eq "allows right account"    0 "$?"
( cd "$TMP"      && bash "$REPO_ROOT/bin/cxr" -n "grep TODO" >/dev/null 2>&1 )
eq "unknown account allowed" 0 "$?"
disable_workspaces

echo "== cxr: chain selection =="
OUT=$( cd "$PERSONAL" && bash "$REPO_ROOT/bin/cxr" -n "implement the retry middleware" 2>/dev/null )
case "$OUT" in *"model_reasoning_effort=medium"*) ok ;; *) bad "execution picks medium" medium "$OUT" ;; esac
OUT=$( cd "$PERSONAL" && bash "$REPO_ROOT/bin/cxr" -n "why is this endpoint slow" 2>/dev/null )
case "$OUT" in *"model_reasoning_effort=high"*) ok ;; *) bad "reasoning picks high" high "$OUT" ;; esac

echo "== project override: .agent-router.json =="
PROJ="$TMP/proj/nested/deep"
mkdir -p "$PROJ"
eq "none found" "" "$(router_find_project_config "$PROJ")"
eq "falls back to global" "$ROUTER_CONFIG" "$(router_effective_config "$PROJ")"

printf '%s' '{"agent_type_tiers":{"my-agent":"reasoning"},"enforce":false}' > "$TMP/proj/.agent-router.json"
eq "found from below" "$TMP/proj/.agent-router.json" "$(router_find_project_config "$PROJ")"
EFF=$(router_effective_config "$PROJ")
router_is_temp_config "$EFF"; eq "merged is temp" 0 "$?"
eq "override applied"  reasoning "$(jq -r '.agent_type_tiers["my-agent"]' "$EFF")"
eq "override scalar"   false     "$(jq -r '.enforce' "$EFF")"
eq "global preserved"  reasoning "$(jq -r '.agent_type_tiers["cc-planner"]' "$EFF")"
eq "global degrade kept" opus    "$(jq -r '.degrade.NORMAL.reasoning' "$EFF")"
rm -f "$EFF"

printf '%s' 'not json' > "$TMP/proj/.agent-router.json"
eq "malformed ignored" "$ROUTER_CONFIG" "$(router_effective_config "$PROJ")"
rm -f "$TMP/proj/.agent-router.json"

echo "== project override: hook honours it =="
mkdir -p "$TMP/ovr"
printf '%s' '{"degrade":{"NORMAL":{"trivial":"opus","execution":"opus","reasoning":"opus"}}}' > "$TMP/ovr/.agent-router.json"
OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"general-purpose","prompt":"grep for TODO comments"}}' "$TMP/ovr" | bash "$REPO_ROOT/hooks/agent-router.sh")
eq "repo forces opus" opus "$(m "$OUT")"
rm -rf "$TMP/ovr"

echo "== ccr: session model from the opening prompt =="
ccrn() { bash "$REPO_ROOT/bin/ccr" -n "$1" 2>/dev/null | tail -1; }
case "$(ccrn 'why is the parcel sync deadlocking')" in *"--model opus"*) ok ;;
  *) bad "reasoning starts on opus" opus "$(ccrn 'why is the parcel sync deadlocking')" ;; esac
case "$(ccrn 'add a POST /invoices endpoint')" in *"--model sonnet"*) ok ;;
  *) bad "execution starts on sonnet" sonnet "$(ccrn 'add a POST /invoices endpoint')" ;; esac
case "$(ccrn 'rename ctx2 to reqCtx everywhere')" in *"--model haiku"*) ok ;;
  *) bad "trivial starts on haiku" haiku "$(ccrn 'rename ctx2 to reqCtx everywhere')" ;; esac
bash "$REPO_ROOT/bin/ccr" -n -t trivial 'design the whole system' 2>/dev/null | grep -q -- "--model haiku" && ok || bad "forced tier wins" haiku "?"
governor_set CRITICAL x 0 >/dev/null
case "$(ccrn 'why is the parcel sync deadlocking')" in *"--model sonnet"*) ok ;;
  *) bad "governor degrades launch" sonnet "$(ccrn 'why is the parcel sync deadlocking')" ;; esac
governor_set NORMAL x 0 >/dev/null
bash "$REPO_ROOT/bin/ccr" >/dev/null 2>&1 </dev/null
eq "no prompt is an error" 2 "$?"

echo "== advisor: nudges only when it pays =="
adv() { printf '%s' "$1" | bash "$REPO_ROOT/hooks/advisor.sh"; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
mkdir -p "$ROUTER_HOME_SESS"
SESSD="$TMP/sessions"; mkdir -p "$SESSD"

# cheap session: silent whatever the prompt
printf 'claude-sonnet-5' > "$SESSD/s1.model"
OUT=$(ROUTER_HOME="$REPO_ROOT" adv '{"prompt":"grep for TODO","session_id":"s1"}')
eq "cheap session silent" "" "$OUT"

echo "== advisor: escape hatches =="
eq "bypass prefix silent" "" "$(adv '{"prompt":"!! grep for TODO","session_id":"x"}')"
eq "slash command silent" "" "$(adv '{"prompt":"/commit","session_id":"x"}')"
eq "empty prompt silent"  "" "$(adv '{"prompt":"","session_id":"x"}')"
eq "garbage silent"       "" "$(adv 'not json')"

echo "== decisions log =="
[ -s "$ROUTER_LOG" ] && ok || bad "log written" "lines" "empty"
eq "log is valid jsonl" 0 "$(jq -e . "$ROUTER_LOG" >/dev/null 2>&1; echo $?)"

echo
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
