"""Check colored overlay cannot add visibility where white coverage is exactly zero."""
import json,hashlib
from pathlib import Path
import numpy as np
from PIL import Image
R=Path("E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision")
folder=R/"ascent-component5-contact-v8";m=json.loads((folder/"manifest.json").read_text());art={s:Image.open(folder/f"{s}-8x-art.png").convert("RGBA") for s in ["attack","defense"]};records=[]
for row in m["cases"]:
 for name in ["focus","context"]:
  regs={r["kind"]:r for r in row["rasterRegions"] if r["scale"]==8 and r["name"]==name};v=np.array(Image.open(regs["visibility"]["path"]).convert("RGBA"));o=np.array(Image.open(regs["overlay"]["path"]).convert("RGBA"));a=np.array(art[row["side"]].crop(regs["overlay"]["pixelRect"]));
  # Exclude all art coverage/AA and require >2 integer RGB change.
  bad=(v[:,:,3]==0)&(a[:,:,3]==0)&np.any(np.abs(o[:,:,:3].astype(int)-np.array([16,16,20]))>2,axis=2)
  if bad.any():records.append({"side":row["side"],"id":row["id"],"name":name,"badPixels":int(bad.sum()),"overlay":regs["overlay"]["path"],"overlaySha256":hashlib.sha256(Path(regs["overlay"]["path"]).read_bytes()).hexdigest()})
print(records)
(R/"ascent-component5-v5-v8-evidence/overlay-zero-coverage-audit.json").write_text(json.dumps({"scope":__doc__,"testedCases":len(m["cases"]),"records":records},indent=2))
