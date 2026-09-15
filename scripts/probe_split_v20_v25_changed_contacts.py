"""Frozen changed-mask source audit, without geometry edits."""
import json,gzip,bisect,hashlib
from pathlib import Path
from collections import Counter
import numpy as np
from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
R=Path("E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision")
versions=(20,25)
folders=[R/"component7-contact-v20",R/"component7-contact-v25"]
ms=[json.loads((p/"manifest.json").read_text()) for p in folders]
w=json.loads(gzip.decompress(Path(ms[1]["displayWarpFile"]).read_bytes()))
cs=[R/f"split-wall-family-normalized-candidate-v{v}" for v in versions]
casters=[NativeReferenceModel(p/"split.height.bin.gz",R/"native-tactical-rays-build/Release/tactical_reference_cast.dll") for p in cs]
chains=[[np.load(p/"correspondence.npz")["sourceFaces"],np.load(R/"global-ground-complete-v2/split/correspondence.npz")["sourceFaces"],np.load(R/"full-height-input-v1/split/source-correspondence.npz")["sourceFaces"]] for p in cs]
meta=Path("E:/IcarusWorldAudit/2026-09-06/supplemented-v2/world/split/geometry.json")
objects=json.loads(meta.read_text())["objects"];starts=[o["firstFace"] for o in objects]
fixtures={r["id"]:r for r in json.loads((R/"gallery-component7-v25-fixtures/split-fixtures.json").read_text())["cases"]}
result=[]
for cid in ["corner-190-start-eye-1.75","corner-200-start-eye-1.75","wall-198-interior-eye-5","wall-201-interior-eye-8.25"]:
 rows=[next(r for r in m["cases"] if r["id"]==cid and r["side"]=="attack") for m in ms]
 assert rows[0]["query"]==rows[1]["query"]
 gs=[PhysicalGeometry(w,r,np.fromfile(r["prefix"]+"-shadow.f32",dtype="<f4")) for r in rows]
 center=np.array(fixtures[cid]["sourceDirectedTargetSvg"])
 xx,yy=np.meshgrid(np.arange(center[0]-9,center[0]+9,.125),np.arange(center[1]-9,center[1]+9,.125));pts=np.c_[xx.ravel(),yy.ravel()]
 inside=gs[1].in_frustum(pts,margin=False);cl=[g.clear(pts)&inside for g in gs];ids=np.flatnonzero(cl[0]!=cl[1])
 # At most 80 evenly distributed changed pixels; raster-mask sampling, not exhaustive source-ray proof.
 ids=ids[np.linspace(0,len(ids)-1,min(80,len(ids)),dtype=int)] if len(ids) else ids
 samples=[]
 for ii in ids:
  target=gs[1].native(pts[ii])[0]; q=np.array(rows[1]["query"]);rec={"targetSvg":pts[ii].tolist(),"clearV20":bool(cl[0][ii]),"clearV25":bool(cl[1][ii]),"hits":[]}
  for caster,chain in zip(casters,chains):
   h=caster.cast(q[:3],np.r_[target,q[2]])
   if h:
    chainids=[h["face"]]
    for c in chain:chainids.append(int(c[chainids[-1]]))
    oi=bisect.bisect_right(starts,chainids[-1])-1
    rec["hits"].append({"sourceObject":oi,"sourcePath":objects[oi]["path"],"faceChain":chainids,"hitNative":h["point"]})
   else:rec["hits"].append(None)
  samples.append(rec)
 print(cid,"changed",int(np.count_nonzero(cl[0]!=cl[1])),"sample objects",[Counter(s["hits"][v]["sourceObject"] if s["hits"][v] else None for s in samples) for v in (0,1)],flush=True)
 result.append({"id":cid,"query":rows[0]["query"],"changedGridSamples":int(np.count_nonzero(cl[0]!=cl[1])),"samples":samples})
out=R/"component7-v20-v25-evidence/changed-mask-source-probe.json"
out.write_text(json.dumps({"scope":__doc__,"limits":"Samples actual changed shadow coverage before receiver mask; in-frustum only. Source-ground-relative height remains provisional; sampled source identities do not prove wall roles.","sourceMetadataSha256":hashlib.sha256(meta.read_bytes()).hexdigest(),"records":result},indent=2))
