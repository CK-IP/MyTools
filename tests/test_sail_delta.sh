#!/usr/bin/env bash
# test_sail_delta.sh — issue #34: finding-level delta (fingerprinting + multiset new-findings).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
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
    for art,kind in {"ruff.sarif":"sarif","bandit.sarif":"sarif","semgrep.sarif":"sarif","mypy.junit.xml":"junit","junit.xml":"junit","pip-audit.json":"pipaudit","shellcheck.json":"shellcheck","gitleaks.sarif":"sarif"}.items():
        if delta.KIND_BY_ARTIFACT.get(art)!=kind: raise SystemExit(f"FAIL: KIND_BY_ARTIFACT[{art}] != {kind}")

    # --- #48 Step 3: gitleaks delta reuses the SARIF extractor (gitleaks emits SARIF results
    #     with locations[].physicalLocation.artifactLocation.uri). Crafted gitleaks-style SARIF
    #     → expected (rel, ruleId, msg) fingerprint; cross-root match for diff-mode suppression. ---
    if delta.KIND_BY_ARTIFACT.get("gitleaks.sarif")!="sarif":
        raise SystemExit("FAIL: KIND_BY_ARTIFACT[gitleaks.sarif] must be 'sarif'")
    gla=os.path.join(td,"gla.sarif")
    json.dump(sarif([res("aws-access-key","AWS key found","file://"+rootA+"/creds.txt",2)]),open(gla,"w"))
    grecs=delta._sarif_records(gla,rootA)
    if len(grecs)!=1: raise SystemExit(f"FAIL: gitleaks SARIF → 1 record: {grecs}")
    if grecs[0]["fp"]!=("creds.txt","aws-access-key","AWS key found"):
        raise SystemExit(f"FAIL: gitleaks fp must be (rel,ruleId,msg): {grecs[0]['fp']}")
    # cross-root: same secret under a baseline-src root → identical fingerprint (diff suppression).
    glb=os.path.join(td,"glb.sarif")
    json.dump(sarif([res("aws-access-key","AWS key found","file://"+rootB+"/creds.txt",2)]),open(glb,"w"))
    if delta.new_findings(gla,glb,"sarif",rootA,rootB)!=[]:
        raise SystemExit("FAIL: pre-existing gitleaks secret must be suppressed in diff mode")

    # --- #48 Step 2: shellcheck delta kind (bare JSON array; integer `code` → SC<code>) ---
    def sc(file,code,msg,line=1):
        return {"file":file,"line":line,"code":code,"message":msg,"level":"warning"}
    # (a) two distinct findings → two fingerprints.
    sca=os.path.join(td,"sca.json")
    json.dump([sc(rootA+"/x.sh",2086,"Double quote",3), sc(rootA+"/x.sh",2046,"Quote this",5)],open(sca,"w"))
    recs=delta._shellcheck_records(sca,rootA)
    if len(recs)!=2: raise SystemExit(f"FAIL: shellcheck 2 findings → 2 records: {recs}")
    fps={r["fp"] for r in recs}
    if ("x.sh","SC2086","Double quote") not in fps:
        raise SystemExit(f"FAIL: shellcheck fp must be (rel,SC<code>,msg): {fps}")
    # (b) empty [] → zero records.
    sce=os.path.join(td,"sce.json"); open(sce,"w").write("[]")
    if delta._shellcheck_records(sce,rootA)!=[]: raise SystemExit("FAIL: shellcheck [] → [] records")
    if delta.new_findings(sce,sce,"shellcheck",rootA,rootA)!=[]: raise SystemExit("FAIL: shellcheck []/[] → [] new")
    # (c) RT-11 cross-worktree: same logical file under DIFFERENT absolute roots → identical
    #     fingerprints after _rel normalization (each artifact passed its matching root).
    scb=os.path.join(td,"scb.json")
    json.dump([sc(rootB+"/x.sh",2086,"Double quote",99)],open(scb,"w"))   # baseline-src root, diff line
    scc=os.path.join(td,"scc.json")
    json.dump([sc(rootA+"/x.sh",2086,"Double quote",3)],open(scc,"w"))    # target root
    fp_b=delta.fingerprints(scb,"shellcheck",rootB); fp_c=delta.fingerprints(scc,"shellcheck",rootA)
    if fp_b is None or fp_c is None: raise SystemExit("FAIL: parseable shellcheck artifact → Counter, not None")
    if fp_b!=fp_c: raise SystemExit(f"FAIL: same shellcheck finding under different roots must match: {fp_b} vs {fp_c}")
    # current (scc) ⊆ baseline (scb) for that fp → 0 new (diff-mode suppression).
    if delta.new_findings(scc,scb,"shellcheck",rootA,rootB)!=[]: raise SystemExit("FAIL: pre-existing shellcheck finding must be suppressed in diff mode")
print("PASS: sail.delta (#34) verified")
PY
then
  echo "FAIL: sail.delta (#34)"; sed 's/^/  /' "$LOG" >&2; exit 1
fi
echo "PASS: sail.delta (#34) verified"
