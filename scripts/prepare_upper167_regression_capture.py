"""Freeze root's previously late upper167 ray as a two-side cone control."""
import json,gzip,hashlib
from pathlib import Path
import numpy as np
from tactical_alignment_composite import explicit_warp
from build_global_tactical_candidate import GroundField
R=Path("E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision")
rpath=R/"split-wall-family-normalized-candidate-v26/root-upper167-regression.json"
proof=json.loads(rpath.read_text())
r=next(r for r in proof["records"] if r["before"]["relativeEyeHeightMeters"]==1.75 and r["before"]["tangentShiftSvg"]==0)
cfg=json.loads((R/"gallery-component7-v26-fixtures/candidate-config.json").read_text());c=cfg["maps"]["split"]
w=json.loads(gzip.decompress(Path(c["displayWarpFile"]).read_bytes()));src=np.array(w["sourceNativeMeters"]).reshape(-1,2);target=np.array(w["targetAttackSvg"]).reshape(-1,2);tri=np.array(w["triangles"]).reshape(-1,3);inverse=explicit_warp(target,src-target,tri)
start=np.array(r["before"]["startSvg"]);finish=np.array(r["before"]["finishSvg"]);contact=np.array(r["before"]["expectedContactSvg"])
s= inverse.apply(np.array([start,finish]));direction=s[1]-s[0];direction/=np.linalg.norm(direction)
legacy=np.array(json.loads(Path(c["projectionFile"]).read_text())["nativeToAttackSvg"]);saved=(start-legacy[:,2])@np.linalg.inv(legacy[:,:2]).T
ground=GroundField(Path(c["groundFieldFile"]));eye=float(ground.heights(s[:1])[0]+1.75)
cid="upper167-root-late-ray-eye-1.75";cq=[*s[0],1.75,*direction,12.,1.7976891295541593]
f=json.loads((R/"gallery-component7-v26-fixtures/split-fixtures.json").read_text());f["cases"]=[dict(id=cid,category="Frozen root previously-late ray; provisional relative eye",query=[*saved,eye,*direction,12.,1.7976891295541593],originSvg=start.tolist(),targetSvg=contact.tolist(),sourceNativeTarget=s[1].tolist(),relativeControlEyeMeters=1.75,authoredSpan=167,eyeHeightMode="absolute",agentIndex=8,rootRegression=r,rootRegressionFileSha256=hashlib.sha256(rpath.read_bytes()).hexdigest())]
for v in [25,26]:
 folder=R/f"gallery-upper167-v{v}";folder.mkdir(exist_ok=True)
 conf=json.loads((R/f"gallery-component7-v{v}-fixtures/candidate-config.json").read_text());cc=conf["maps"]["split"];cc["automaticQueries"]=False;cc["samePhysicalPoseAcrossSides"]=True;cc["queriesById"]={cid:cq}
 (folder/"candidate-config.json").write_text(json.dumps(conf,indent=2));(folder/"split-fixtures.json").write_text(json.dumps(f,indent=2))
view={"cases":{}}
for side in ["attack","defense"]:
 p=contact if side=="attack" else np.array(w["attackToDefenseSvg"]["origin"])-contact
 view["cases"][side+"/"+cid]=[dict(name="focus",svgRect=[p[0]-10.13,p[1]-10.29,p[0]+10.47,p[1]+10.61]),dict(name="context",svgRect=[p[0]-18.13,p[1]-18.29,p[0]+18.47,p[1]+18.61])]
(R/"upper167-viewports.json").write_text(json.dumps(view,indent=2))
print(cid,cq,"root delta",r["before"]["signedContactErrorSvg"],r["after"]["signedContactErrorSvg"])
