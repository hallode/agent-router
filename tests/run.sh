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
hook() { printf '%s' "$1" | bash "$REPO_ROOT/hooks/claude-subagent.sh"; }
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
OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"general-purpose","prompt":"grep for TODO comments"}}' "$TMP/ovr" | bash "$REPO_ROOT/hooks/claude-subagent.sh")
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
adv() { printf '%s' "$1" | bash "$REPO_ROOT/hooks/claude-advisor.sh"; }
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

echo "== wrapper: a refusal is never turned into a real run =="
# The shell wrapper must fall back to the host CLI only when the router could
# not start. Falling back on a deliberate refusal would perform exactly the
# action that was refused.
WRAP="$TMP/wrap.zsh"
cat > "$WRAP" <<'ZSH'
FELL_BACK=0
command() { FELL_BACK=1; return 0; }
source "$REPO_ROOT/shell/router.zsh"
ZSH

wrap_rc() { # wrap_rc <exit-code-the-router-returns> -> "<rc> <fellback>"
  local fake="$TMP/fakebin"; mkdir -p "$fake"
  printf '#!/bin/sh\nexit %s\n' "$1" > "$fake/cxr"; chmod +x "$fake/cxr"
  zsh -c "
    REPO_ROOT='$REPO_ROOT'; TMP='$TMP'
    FELL_BACK=0
    command() { FELL_BACK=1; return 0; }
    ROUTER_HOME='$fake/..'
    source '$REPO_ROOT/shell/router.zsh'
    _router_run codex '$fake/cxr' 'do some bounded work'
    rc=\$?
    print -- \"\$rc \$FELL_BACK\"
  " 2>/dev/null
}

eq "refusal (3) not retried"      "3 0"   "$(wrap_rc 3)"
eq "task failure (1) not retried" "1 0"   "$(wrap_rc 1)"
eq "usage error (2) not retried"  "2 0"   "$(wrap_rc 2)"
eq "provider code (7) preserved"  "7 0"   "$(wrap_rc 7)"
eq "infra (126) does fall back"   "0 1"   "$(wrap_rc 126)"

echo "== wrapper: subcommands belong to the host CLI =="
isprompt() { # isprompt <host> <arg>
  zsh -c "source '$REPO_ROOT/shell/router.zsh'; _router_is_prompt '$1' '$2' && echo yes || echo no" 2>/dev/null
}
for sub in exec resume login logout help doctor review update mcp; do
  eq "codex $sub passes through" no "$(isprompt codex "$sub")"
done
for sub in mcp config doctor update help; do
  eq "claude $sub passes through" no "$(isprompt claude "$sub")"
done
eq "a real prompt routes"      yes "$(isprompt codex 'fix the login bug')"
eq "one word is not a prompt"  no  "$(isprompt codex 'resume')"
eq "unknown word routes"       yes "$(isprompt codex 'refactorise')"
eq "flags pass through"        no  "$(isprompt codex '--resume')"

echo "== cxr/ccr: 126 only when the router cannot start =="
( ROUTER_CONFIG="$TMP/nope.json" bash "$REPO_ROOT/bin/cxr" -n "anything" >/dev/null 2>&1 )
eq "cxr missing config -> 126" 126 "$?"
( ROUTER_CONFIG="$TMP/nope.json" bash "$REPO_ROOT/bin/ccr" -n "anything" >/dev/null 2>&1 )
eq "ccr missing config -> 126" 126 "$?"

echo "== governor: refreshes stale quota before a model is chosen =="
QJSON="$TMP/quota.json"
set_quota() { printf '{"used_percent":%s}\n' "$1" > "$QJSON"; }
python3 - "$ROUTER_CONFIG" "$QJSON" <<'PYQ'
import json,sys
c=json.load(open(sys.argv[1]))
c['quota']['command']="cat %s" % sys.argv[2]
c['quota']['max_age_seconds']=1
json.dump(c,open(sys.argv[1],'w'),indent=2)
PYQ

age_state() { # backdate the stored reading so it counts as stale
  python3 - "$ROUTER_STATE" "$1" <<'PYA'
import json,sys,time
p,age=sys.argv[1],int(sys.argv[2])
d=json.load(open(p)); d['updated']=int(time.time())-age
json.dump(d,open(p,'w'))
PYA
}

set_quota 97
governor_set NORMAL "quota:0%" 0 >/dev/null; age_state 600
governor_refresh_if_stale 300
eq "stale + 97% -> DEPLETED" DEPLETED "$(governor_state)"

set_quota 70
governor_set NORMAL "quota:0%" 0 >/dev/null; age_state 600
governor_refresh_if_stale 300
eq "stale + 70% -> CONSERVE" CONSERVE "$(governor_state)"

set_quota 10
governor_set NORMAL "quota:0%" 0 >/dev/null; age_state 600
governor_refresh_if_stale 300
eq "stale + 10% -> NORMAL" NORMAL "$(governor_state)"

set_quota 99
governor_set NORMAL "quota:0%" 0 >/dev/null
governor_refresh_if_stale 3600
eq "fresh reading is not re-probed" NORMAL "$(governor_state)"

echo "== governor: a live override outranks the probe =="
set_quota 10
governor_set DEPLETED "rate-limit:codex" 3600 >/dev/null; age_state 600
governor_refresh_if_stale 300
eq "unexpired override kept" DEPLETED "$(governor_state)"

set_quota 10
governor_set CRITICAL "manual" 3600 >/dev/null; age_state 600
governor_refresh_if_stale 300
eq "manual override kept" CRITICAL "$(governor_state)"

echo "== governor: a failing probe changes nothing =="
python3 - "$ROUTER_CONFIG" <<'PYF'
import json,sys
c=json.load(open(sys.argv[1]))
c['quota']['command']="exit 1"
json.dump(c,open(sys.argv[1],'w'),indent=2)
PYF
governor_set CONSERVE "quota:60%" 0 >/dev/null; age_state 600
governor_refresh_if_stale 1
eq "probe failure is graceful" CONSERVE "$(governor_state)"

python3 - "$ROUTER_CONFIG" <<'PYG'
import json,sys
c=json.load(open(sys.argv[1]))
c['quota']['command']=""
json.dump(c,open(sys.argv[1],'w'),indent=2)
PYG
governor_set NORMAL reset 0 >/dev/null
governor_refresh_if_stale 1
eq "no quota command is graceful" NORMAL "$(governor_state)"

echo "== cxr: failover actually retries down the chain =="
# Everything above dry-runs the chain. This exercises the execution path with a
# stub `codex` on PATH, which is the only way to prove the retry semantics the
# whole design rests on: a rate limit advances, a task failure does not.
STUB="$TMP/stub"; mkdir -p "$STUB"
CALLS="$TMP/calls.txt"

make_stub() { # make_stub <behaviour>
  cat > "$STUB/codex" <<STUBEOF
#!/usr/bin/env bash
# record which model each attempt used
for a in "\$@"; do case "\$a" in model=*) echo "\${a#model=}" >> "$CALLS" ;; esac; done
case "$1" in
  always-limited) echo "Error: 429 rate limit reached" >&2; exit 1 ;;
  limited-once)
    if [ "\$(wc -l < "$CALLS" | tr -d ' ')" -le 1 ]; then
      echo "Error: 429 rate limit reached" >&2; exit 1
    fi
    echo ok; exit 0 ;;
  plain-failure) echo "compile error: undefined symbol" >&2; exit 2 ;;
  ok) echo ok; exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB/codex"
}

run_cxr() { # run_cxr <tier> -> exit code; PATH-stubbed
  : > "$CALLS"
  ( cd "$PERSONAL" && PATH="$STUB:$PATH" \
      bash "$REPO_ROOT/bin/cxr" -t "$1" "do a bounded thing" >/dev/null 2>&1 )
  echo $?
}
calls()  { wc -l < "$CALLS" | tr -d ' '; }
models() { tr '\n' ' ' < "$CALLS" | sed 's/ $//'; }

governor_set NORMAL x 0 >/dev/null

make_stub limited-once
RC=$(run_cxr execution)
eq "recovers on the next link"  0 "$RC"
eq "took exactly two attempts"  2 "$(calls)"
case "$(models)" in
  *" "*) ok ;;
  *) bad "second attempt used a different model" "two models" "$(models)" ;;
esac

governor_set NORMAL x 0 >/dev/null
make_stub always-limited
RC=$(run_cxr execution)
eq "exhausted chain fails"        1 "$RC"
eq "tried every link"             3 "$(calls)"
case "$(governor_state)" in
  NORMAL) bad "rate limits escalate the governor" "not NORMAL" "NORMAL" ;;
  *) ok ;;
esac

governor_set NORMAL x 0 >/dev/null
make_stub plain-failure
RC=$(run_cxr execution)
eq "task failure is not retried"  2 "$RC"
eq "only one attempt made"        1 "$(calls)"
eq "governor untouched by a task failure" NORMAL "$(governor_state)"

governor_set NORMAL x 0 >/dev/null
make_stub ok
RC=$(run_cxr trivial)
eq "success runs once"            0 "$RC"
eq "no needless retry"            1 "$(calls)"

echo "== cxr: a rate-limited run is logged as such =="
jq -e 'select(.action == "rate-limited")' "$ROUTER_LOG" >/dev/null 2>&1 && ok \
  || bad "rate limit recorded in the log" "an entry" "none"
governor_set NORMAL x 0 >/dev/null

echo "== codex hook: injects budget state, never a model =="
chook() { printf '%s' "$1" | bash "$REPO_ROOT/hooks/codex-advisor.sh"; }
cctx()  { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

governor_set NORMAL x 0 >/dev/null
OUT=$(chook "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$PERSONAL\"}")
case "$(cctx "$OUT")" in
  *"budget state NORMAL"*) ok ;;
  *) bad "SessionStart reports state" "NORMAL" "$(cctx "$OUT")" ;;
esac
eq "SessionStart names the right event" SessionStart \
   "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')"

# The one thing a Codex hook must never claim to do.
case "$OUT" in
  *updatedInput*|*'"model"'*) bad "codex hook must not set a model" "no model field" "$OUT" ;;
  *) ok ;;
esac

governor_set CRITICAL x 0 >/dev/null
OUT=$(chook "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$PERSONAL\"}")
case "$(cctx "$OUT")" in
  *CRITICAL*) ok ;;
  *) bad "SessionStart escalates with the governor" "CRITICAL" "$(cctx "$OUT")" ;;
esac

echo "== codex hook: quiet unless it matters =="
governor_set NORMAL x 0 >/dev/null
eq "normal state says nothing" "" \
   "$(chook "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"add an endpoint\",\"cwd\":\"$PERSONAL\"}")"

governor_set DEPLETED x 0 >/dev/null
OUT=$(chook "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"add an endpoint\",\"cwd\":\"$PERSONAL\"}")
case "$(cctx "$OUT")" in
  *DEPLETED*) ok ;;
  *) bad "depleted state warns" "DEPLETED" "$(cctx "$OUT")" ;;
esac

echo "== codex hook: fails open =="
governor_set DEPLETED x 0 >/dev/null
eq "bypass prefix silent" "" \
   "$(chook '{"hook_event_name":"UserPromptSubmit","prompt":"!! do the thing"}')"
eq "slash command silent" "" \
   "$(chook '{"hook_event_name":"UserPromptSubmit","prompt":"/status"}')"
eq "empty prompt silent"  "" \
   "$(chook '{"hook_event_name":"UserPromptSubmit","prompt":""}')"
eq "unknown event silent" "" "$(chook '{"hook_event_name":"PreToolUse"}')"
eq "garbage silent"       "" "$(chook 'not json')"
eq "no stdin silent"      "" "$(chook '')"
governor_set NORMAL x 0 >/dev/null

echo "== defers to an agent that declares its own model =="
# Another tool may manage agent definitions. An explicit model there is a
# decision; the tier map is an inference, and inference must not overrule it.
AG="$TMP/proj-agents"; mkdir -p "$AG/.claude/agents"
mk_agent() { printf -- '---\nname: %s\nmodel: %s\n---\n\nbody\n' "$1" "$2" > "$AG/.claude/agents/$1.md"; }

mk_agent declared-agent opus
OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"declared-agent","prompt":"grep for TODO"}}' "$AG" | bash "$REPO_ROOT/hooks/claude-subagent.sh")
eq "declared model left alone" "" "$OUT"

mk_agent inherit-agent inherit
OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"inherit-agent","prompt":"grep for TODO"}}' "$AG" | bash "$REPO_ROOT/hooks/claude-subagent.sh")
eq "inherit means route it" haiku "$(m "$OUT")"

mk_agent quoted-agent '"sonnet"'
OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"quoted-agent","prompt":"grep for TODO"}}' "$AG" | bash "$REPO_ROOT/hooks/claude-subagent.sh")
eq "quoted model also honoured" "" "$OUT"

OUT=$(printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"no-such-agent","prompt":"grep for TODO"}}' "$AG" | bash "$REPO_ROOT/hooks/claude-subagent.sh")
eq "missing definition still routes" haiku "$(m "$OUT")"

eq "path traversal refused" "" "$(router_agent_declared_model "../../etc/passwd" "$AG")"
eq "empty type is safe"     "" "$(router_agent_declared_model "" "$AG")"

echo "== bare launch: quiet when the budget is fine =="
# A launch with no prompt cannot be classified. Overriding the host's default
# anyway would be noise, so silence here means "no override" and is the correct
# answer whenever quota is healthy.
lm() { ROUTER_CONFIG="$ROUTER_CONFIG" bash "$REPO_ROOT/bin/router" launch-model "$1" 2>/dev/null; }

governor_set NORMAL x 0 >/dev/null
eq "NORMAL: no claude override" "" "$(lm claude)"
eq "NORMAL: no codex override"  "" "$(lm codex)"

governor_set CONSERVE x 0 >/dev/null
eq "CONSERVE: claude steps down" sonnet "$(lm claude)"
case "$(lm codex)" in
  *[![:space:]]*) ok ;;
  *) bad "CONSERVE: codex names a model" "a model" "empty" ;;
esac

governor_set CRITICAL x 0 >/dev/null
eq "CRITICAL: claude on the cheapest" haiku "$(lm claude)"
governor_set DEPLETED x 0 >/dev/null
eq "DEPLETED: claude on the cheapest" haiku "$(lm claude)"

# Each step down must not reach past the end of the chain.
for st in CONSERVE CRITICAL DEPLETED; do
  governor_set "$st" x 0 >/dev/null
  M=$(lm codex | cut -f1)
  case "$M" in ""|null) bad "$st: codex chain index in range" "a model" "$M" ;; *) ok ;; esac
done
governor_set NORMAL x 0 >/dev/null

echo "== decisions log =="
[ -s "$ROUTER_LOG" ] && ok || bad "log written" "lines" "empty"
eq "log is valid jsonl" 0 "$(jq -e . "$ROUTER_LOG" >/dev/null 2>&1; echo $?)"

echo
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
