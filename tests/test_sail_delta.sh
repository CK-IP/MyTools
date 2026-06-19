#!/usr/bin/env bash
# test_sail_delta.sh — issue #34: finding-level delta (fingerprinting + multiset new-findings).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
cd "$REPO_ROOT"
if ! python3 - <<'PY' >"$LOG" 2>&1
import json, os, tempfile
import sail.delta as delta

def sarif(results): return {"runs":[{"results":results}]}
def res(rule,msg,uri,line):
    return {"ruleId":rule,"message":{"text":msg},
            "locations":[{"physicalLocation":{"artifactLocation":{"uri":uri},"region":{"startLine":line}}}]}

with tempfile.TemporaryDirectory() as td:
    rootA=os.path.join(td,"A"); rootB=os.path.join(td,"B")
    a=os.path.join(td,"a.sarif"); b=os.path.join(td,"b.sarif")
    # Same finding (rule+msg+relpath) under different roots AND different lines → same fingerprint.
    json.dump(sarif([res("E402","msg","file://"+rootA+"/pkg/app.py",18)]),open(a,"w"))
    json.dump(sarif([res("E402","msg","file://"+rootB+"/pkg/app.py",99)]),open(b,"w"))
    fpa=delta.fingerprints(a,"sarif",rootA); fpb=delta.fingerprints(b,"sarif",rootB)
    if fpa is None or fpb is None: raise SystemExit("FAIL: parseable artifact must yield a Counter, not None")
    if fpa!=fpb: raise SystemExit(f"FAIL: same finding under different roots/lines must match: {fpa} vs {fpb}")
    # new_findings: current=b (X pre-existing) + new F401 vs baseline=a (X) → only F401 is new.
    cur=os.path.join(td,"cur.sarif")
    json.dump(sarif([res("E402","msg","file://"+rootB+"/pkg/app.py",99),
                     res("F401","unused","file://"+rootB+"/pkg/app.py",5)]),open(cur,"w"))
    new=delta.new_findings(cur,a,"sarif",rootB,rootA)
    if new is None or len(new)!=1: raise SystemExit(f"FAIL: only the new F401 should be new: {new}")
    # current ⊆ baseline → []
    if delta.new_findings(a,cur,"sarif",rootA,rootB)!=[]: raise SystemExit("FAIL: current subset of baseline → []")
    # multiset: baseline 1×F, current 2×F → 1 new
    db=os.path.join(td,"db.sarif"); dc=os.path.join(td,"dc.sarif")
    json.dump(sarif([res("E402","m","file://"+rootA+"/x.py",1)]),open(db,"w"))
    json.dump(sarif([res("E402","m","file://"+rootA+"/x.py",1),res("E402","m","file://"+rootA+"/x.py",50)]),open(dc,"w"))
    nd=delta.new_findings(dc,db,"sarif",rootA,rootA)
    if nd is None or len(nd)!=1: raise SystemExit(f"FAIL: baseline 1x current 2x → 1 new: {nd}")
    if delta.new_findings(db,dc,"sarif",rootA,rootA)!=[]: raise SystemExit("FAIL: baseline 2x current 1x → []")
    # current unparseable / missing → None (error signal, never mask)
    bad=os.path.join(td,"bad.sarif"); open(bad,"w").write("{not json")
    if delta.new_findings(bad,a,"sarif",rootA,rootA) is not None: raise SystemExit("FAIL: unparseable current → None")
    if delta.fingerprints(bad,"sarif",rootA) is not None: raise SystemExit("FAIL: fingerprints(unparseable) → None")
    if delta.new_findings(os.path.join(td,"nope.sarif"),a,"sarif",rootA,rootA) is not None: raise SystemExit("FAIL: missing current → None")
    # missing baseline → all current new (safe over-report)
    nb=delta.new_findings(cur,os.path.join(td,"nope2.sarif"),"sarif",rootB,rootA)
    if nb is None or len(nb)!=2: raise SystemExit(f"FAIL: missing baseline → all current new: {nb}")
    # junit
    jbase=os.path.join(td,"jb.xml"); jcur=os.path.join(td,"jc.xml")
    open(jbase,"w").write('<testsuite><testcase classname="t.a" name="x"><failure/></testcase></testsuite>')
    open(jcur,"w").write('<testsuite><testcase classname="t.a" name="x"><failure/></testcase><testcase classname="t.b" name="y"><failure/></testcase></testsuite>')
    nj=delta.new_findings(jcur,jbase,"junit",td,td)
    if nj is None or len(nj)!=1: raise SystemExit(f"FAIL: only new junit failure: {nj}")
    # pip-audit
    pbase=os.path.join(td,"pb.json"); pcur=os.path.join(td,"pc.json")
    json.dump({"dependencies":[{"name":"req","vulns":[{"id":"V1"}]}]},open(pbase,"w"))
    json.dump({"dependencies":[{"name":"req","vulns":[{"id":"V1"}]},{"name":"foo","vulns":[{"id":"V2"}]}]},open(pcur,"w"))
    npa=delta.new_findings(pcur,pbase,"pipaudit",td,td)
    if npa is None or len(npa)!=1: raise SystemExit(f"FAIL: only new vuln: {npa}")
    # KIND_BY_ARTIFACT mapping
    for art,kind in {"ruff.sarif":"sarif","bandit.sarif":"sarif","semgrep.sarif":"sarif","mypy.junit.xml":"junit","junit.xml":"junit","pip-audit.json":"pipaudit"}.items():
        if delta.KIND_BY_ARTIFACT.get(art)!=kind: raise SystemExit(f"FAIL: KIND_BY_ARTIFACT[{art}] != {kind}")
print("PASS: sail.delta (#34) verified")
PY
then
  echo "FAIL: sail.delta (#34)"; sed 's/^/  /' "$LOG" >&2; exit 1
fi
echo "PASS: sail.delta (#34) verified"
