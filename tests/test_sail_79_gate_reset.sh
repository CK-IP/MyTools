#!/usr/bin/env bash
# test_sail_79_gate_reset.sh — issue #79: a resumed run-dir keeps stale terminal gate status,
# masking a gate-finding fix. Fix: in --diff mode, store a diff-content fingerprint when gates
# run; on resume, if the diff SCOPE (target/diff_ref) or CONTENT changed (or no fingerprint was
# stored / it is uncomputable), reset terminal gates to pending so they re-run. If unchanged,
# preserve terminal status (no needless re-run).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

mk_target() {  # $1 = dir — a git repo with mod.py committed clean, then a working-tree change
  local d="$1"; mkdir -p "$d"
  printf 'print("hi")\n' > "$d/mod.py"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf 'import os\nprint("hi")\n' > "$d/mod.py"   # working-tree change -> non-empty diff
}

TGT="$WORK/target"; mk_target "$TGT"
BASE="$(git -C "$TGT" rev-parse HEAD)"
RD="$WORK/rd"; STATE="$RD/run-state.json"; DLOG="$RD/decision-log.md"

state_key() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1" "$2"; }
reset_marks(){ grep -c 'gate-reset' "$DLOG" 2>/dev/null || true; }

# --- Initial diff-mode run: populates run-state with a per-run diff fingerprint. ---
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
[ -f "$STATE" ] || { echo "FAIL: no run-state after initial run"; exit 1; }
FP1="$(state_key "$STATE" gates_diff_hash)"
[ -n "$FP1" ] && [ "$FP1" != "None" ] || { echo "FAIL: gates_diff_hash not stored on a --diff run (got '$FP1')"; exit 1; }
echo "PASS A: --diff run stores gates_diff_hash"

# --- AC#1: changed diff on resume -> ALL terminal gates reset & re-run, verdict logged AFRESH ---
# Run A above produced terminal gates at their NATURAL seqs (1..N) and logged each. We do NOT
# tamper seqs: the realistic completed-round case is exactly where a naive "clear seq to None"
# fix collapses next_seq back to 1 and re-collides with round-1's decision-log keys, suppressing
# the re-run verdict (redteam-4c2dc5a2a662). The assertions below catch that collision directly.
python3 - "$STATE" "$DLOG" > "$WORK/pre.json" <<'PY'
import json,sys,re
state,dlog=sys.argv[1:3]
d=json.load(open(state))
terminal={"passed","failed","skipped"}
n_terminal=sum(1 for g in d["gates"] if g.get("status") in terminal)
seqs=[int(m) for m in re.findall(r"\[gate=[^\]]* seq=(\d+)\]", open(dlog).read())]
gate_lines=len(re.findall(r"^\[gate=", open(dlog).read(), re.M))
json.dump({"n_terminal":n_terminal,"max_seq":max(seqs or [0]),"gate_lines":gate_lines}, sys.stdout)
PY
MARKS_BEFORE="$(reset_marks)"
printf 'print("hi")\nprint("bye")\n' > "$TGT/mod.py"   # the "gate-finding fix": diff content changes
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true

python3 - "$STATE" "$DLOG" "$FP1" "$MARKS_BEFORE" "$(reset_marks)" "$WORK/pre.json" <<'PY' || exit 1
import json,sys,re
state,dlog,fp1,mb,ma,prep=sys.argv[1:7]
pre=json.load(open(prep))
d=json.load(open(state)); gates=d["gates"]; log=open(dlog).read()
terminal={"passed","failed","skipped"}
# (a) fingerprint updated to the new diff content.
if d.get("gates_diff_hash")==fp1:
    print("FAIL AC#1: gates_diff_hash did not update after diff content changed",file=sys.stderr); raise SystemExit(1)
# (b) a gate-reset marker was recorded this round.
if int(ma)<=int(mb):
    print("FAIL AC#1: no gate-reset marker recorded on changed-diff resume",file=sys.stderr); raise SystemExit(1)
# (c) Re-run seqs are MONOTONIC across rounds: every gate's current seq must EXCEED the max seq
#     present in the log before the resume. The seq-collision bug restarts seqs at 1 -> fails here.
for g in gates:
    if (g.get("seq") or 0) <= pre["max_seq"]:
        print(f"FAIL AC#1: gate {g['name']} seq={g.get('seq')} did not exceed pre-resume max {pre['max_seq']} (seq collision -> de-dup suppresses re-run verdict)",file=sys.stderr); raise SystemExit(1)
# (d) The decision log actually GREW by one fresh verdict line per re-run gate (not de-dup-suppressed).
gate_lines_now=len(re.findall(r"^\[gate=", log, re.M))
if gate_lines_now != pre["gate_lines"] + pre["n_terminal"]:
    print(f"FAIL AC#1: decision-log gate lines {pre['gate_lines']}->{gate_lines_now}, expected +{pre['n_terminal']} fresh re-run verdicts (suppressed?)",file=sys.stderr); raise SystemExit(1)
print(f"PASS AC#1: changed diff reset & re-ran all {pre['n_terminal']} terminal gates; {pre['n_terminal']} fresh verdicts logged at monotonic seqs > {pre['max_seq']}")
PY

# --- AC#2: genuine interrupted-run resume (unchanged diff) -> a non-terminal gate COMPLETES while a
#          terminal gate is preserved (NOT re-run). Models a real crash-mid-run, not just a no-op. ---
# gate[0] is a terminal green we must NOT touch; gate[1] is a half-finished (running) gate the resume
# must drive to completion. Proves the run actually continues (kills a mutation that returns before the
# checker loop on unchanged diffs) without relying on the `|| true`-swallowed exit code.
G1NAME="$(python3 -c "import json;print(json.load(open('$STATE'))['gates'][1]['name'])")"
python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
g0=d["gates"][0]; g0["status"]="passed"; g0["artifact"]="KEEPME.txt"; g0["rc"]=0; g0["finished_at"]="2026-01-02T00:00:00Z"
g1=d["gates"][1]; g1["status"]="running"; g1["artifact"]=None; g1["rc"]=None; g1["finished_at"]=None
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
MARKS_BEFORE="$(reset_marks)"
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
python3 - "$STATE" "$DLOG" "$G1NAME" "$MARKS_BEFORE" "$(reset_marks)" <<'PY' || exit 1
import json,sys
state,dlog,g1name,mb,ma=sys.argv[1:6]
d=json.load(open(state)); g0=d["gates"][0]
g1=[g for g in d["gates"] if g["name"]==g1name][0]
terminal={"passed","failed","skipped"}
# (a) the preserved terminal gate was NOT re-run.
if g0.get("artifact")!="KEEPME.txt":
    print(f"FAIL AC#2: unchanged-diff resume re-ran a terminal-green gate (artifact={g0.get('artifact')})",file=sys.stderr); raise SystemExit(1)
# (b) no gate-reset marker on an unchanged-diff resume.
if int(ma)!=int(mb):
    print("FAIL AC#2: gate-reset marker recorded on an UNCHANGED-diff resume",file=sys.stderr); raise SystemExit(1)
# (c) the interrupted (running) gate was driven to completion: it reached a terminal status AND got a
#     fresh finished_at (it was None when we set it running) — read from run-state, so it cannot be
#     satisfied by a prior step's log entry. Proves the resume actually continued the run.
if g1.get("status") not in terminal:
    print(f"FAIL AC#2: interrupted gate {g1name} not completed on resume (status={g1.get('status')})",file=sys.stderr); raise SystemExit(1)
if not g1.get("finished_at"):
    print(f"FAIL AC#2: interrupted gate {g1name} reached {g1.get('status')} but finished_at not set (did the loop run it?)",file=sys.stderr); raise SystemExit(1)
print("PASS AC#2: interrupted-run resume completed the pending gate and preserved the terminal gate (no needless re-run)")
PY

# --- AC#3: missing/never-stored fingerprint forces re-run (fail-safe; same code branch as uncomputable->None) ---
python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("gates_diff_hash",None)
g=d["gates"][0]; g["status"]="passed"; g["artifact"]="KEEPME.txt"; g["rc"]=0
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
MARKS_BEFORE="$(reset_marks)"
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
ART="$(python3 -c "import json;print(json.load(open('$STATE'))['gates'][0].get('artifact'))")"
[ "$ART" != "KEEPME.txt" ] || { echo "FAIL AC#3: missing fingerprint did NOT force a re-run (fail-safe violated)"; exit 1; }
[ "$(reset_marks)" -gt "$MARKS_BEFORE" ] || { echo "FAIL AC#3: no gate-reset marker when fingerprint was missing"; exit 1; }
# The marker must state the ACTUAL cause (fingerprint), not the hardcoded "diff content changed" (lens2-e13be82cb857).
grep -Eq 'gate-reset.*(fingerprint|missing|uncomputable)' "$DLOG" || { echo "FAIL AC#3: gate-reset marker did not name the fingerprint cause"; exit 1; }
echo "PASS AC#3: missing fingerprint forced a re-run (fail-safe) with a cause-accurate marker"

# --- AC#4 (scope): resume the SAME run-dir against a DIFFERENT target with IDENTICAL diff content ---
# Proves the reset keys on diff SCOPE (target/diff_ref), not content alone: a same-content diff in a
# different repo must NOT preserve a stale gate (redteam-1fd74a2b0c7e). TGT_A and TGT_B are two FRESH,
# byte-identical repos, so `git diff HEAD` — and thus the fingerprint — is identical; only the resolved
# diff_ref (each repo's HEAD SHA) and target path differ. A reset here can ONLY be the scope check.
TGT_A="$WORK/scope_a"; mk_target "$TGT_A"
TGT_B="$WORK/scope_b"; mk_target "$TGT_B"
RD2="$WORK/rd2"; STATE2="$RD2/run-state.json"
python3 -m sail run --target "$TGT_A" --diff HEAD --run-dir "$RD2" --no-review >/dev/null 2>&1 || true
FP_A="$(state_key "$STATE2" gates_diff_hash)"
python3 - "$STATE2" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); g=d["gates"][0]
g["status"]="passed"; g["artifact"]="STALE-A.txt"; g["rc"]=0; g["finished_at"]="2026-01-03T00:00:00Z"
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
python3 -m sail run --target "$TGT_B" --diff HEAD --run-dir "$RD2" --no-review >/dev/null 2>&1 || true
FP_B="$(state_key "$STATE2" gates_diff_hash)"
[ "$FP_A" = "$FP_B" ] || { echo "FAIL AC#4: fixtures not content-identical (fp_A=$FP_A fp_B=$FP_B) — cannot isolate scope from content"; exit 1; }
ART2="$(python3 -c "import json;print(json.load(open('$STATE2'))['gates'][0].get('artifact'))")"
[ "$ART2" != "STALE-A.txt" ] || { echo "FAIL AC#4: resume against a DIFFERENT target reused a stale gate despite scope change (scope ignored)"; exit 1; }
# The marker must name the SCOPE cause, not the hardcoded "diff content changed" (lens2-e13be82cb857).
grep -Eq 'gate-reset.*scope' "$RD2/decision-log.md" || { echo "FAIL AC#4: gate-reset marker did not name the scope cause"; exit 1; }
echo "PASS AC#4: scope change (different target/diff_ref) forced a re-run with a cause-accurate marker"

# --- AC#5: the reset is REGISTRY-SCOPED — a stale gate not in the current checker registry (e.g. a
#          narrowed SAIL_CHECKERS) must NOT be reset to a never-completing pending, and must not be
#          counted in the gate-reset marker (lens2-da384f98abcb). ---
RD3="$WORK/rd3"; STATE3="$RD3/run-state.json"
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD3" --no-review >/dev/null 2>&1 || true
python3 - "$STATE3" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
# Inject a terminal gate whose name is NOT in any checker registry; the per-checker loop will never
# visit it, so resetting it to pending would strand it permanently non-green.
d["gates"].append({"name":"ghost-not-in-registry","status":"failed","artifact":"GHOST.txt","rc":2,
                   "reason":"stale","seq":999,"started_at":None,"finished_at":"2026-01-04T00:00:00Z","mode":"diff"})
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
printf 'print("hi")\nprint("zzz")\n' > "$TGT/mod.py"   # change diff so a reset is triggered
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD3" --no-review >/dev/null 2>&1 || true
python3 - "$STATE3" <<'PY' || exit 1
import json,sys
d=json.load(open(sys.argv[1]))
ghost=[g for g in d["gates"] if g["name"]=="ghost-not-in-registry"][0]
# A non-registry gate must be left untouched (never reset to a pending it can't escape).
if ghost.get("status")=="pending":
    print("FAIL AC#5: a non-registry gate was reset to pending (would strand it permanently non-green)",file=sys.stderr); raise SystemExit(1)
print("PASS AC#5: reset is registry-scoped (non-registry stale gate left untouched, not stranded pending)")
PY

echo "PASS: sail #79 gate-reset-on-changed-scope-or-content verified"
