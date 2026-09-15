"""Bind the observed Snowman support overpaint to the frozen source IDs."""
import hashlib,json
from pathlib import Path
import numpy as np
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 measurePath=REV/'support-prop-overpaint-v4.json';measure=json.loads(measurePath.read_text());collisionPath=REV/'floor-support-collision-audit-v1/icebox.json';collision=json.loads(collisionPath.read_text())
 m=next(r for r in measure['rows']if '/Snowman_0_PreRound/'in r['sourceObjectPath']);c=next(r for r in collision['rows']if r['sourceFirstFace']==m['sourceFirstFace'])
 assert c['classification']=='excluded-no-collision' and c['useDefaultCollision'] is False and c['componentTemplate'] is None
 assert c['meshPath']=='/Game/Environment/Asset/Props/Snowman/0/Snowman_0_PreRound.2'
 assert len(m['fullPackFaceIds'])==149 and m['metrics']['maxHeightAboveNavM']>.49
 mappingPath=REV/'full-height-input-v1/icebox/source-correspondence.npz';mapping=np.load(mappingPath)['sourceFaces'];ids=np.array(m['fullPackFaceIds'],int)
 assert np.all((mapping[ids]>=c['sourceFirstFace'])&(mapping[ids]<c['sourceFirstFace']+c['sourceFaceCount']))
 evidence=[{'path':str(p),'sha256':sha(p)}for p in [measurePath,collisionPath,mappingPath]]+measure['evidence']+collision['evidence']
 evidence=list({r['path']:r for r in evidence}.values())
 for e in evidence:assert sha(Path(e['path']))==e['sha256']
 report={'schemaVersion':1,'map':'icebox','status':'audited-support-only-prop-exclusion','productionMutation':False,'sourceGeometrySha256':collision['sourceGeometrySha256'],'fullHeightSourcePackSha256':sha(REV/'full-height-input-v1/icebox/icebox.height.bin.gz'),'evidence':evidence,'rows':[{'sourceObjectPath':c['sourceObjectPath'],'sourceFirstFace':c['sourceFirstFace'],'sourceFaceCount':c['sourceFaceCount'],'fullPackFaceIds':ids.tolist(),'originalSourceFaceIds':mapping[ids].tolist(),'supportDecision':'exclude-from-standing-support','visibilityDecision':'unchanged-not-audited','basis':'Exact noncolliding Snowman prop component; its disconnected upward curved surfaces overpaint detailed main navigation by up to49.66cm. This is a support-only exclusion of149observed admitted faces, not a NoCollision floor filter.','collisionEvidence':{k:c[k]for k in ['effectiveBody','componentTemplate','meshPath','useDefaultCollision','nativeActor','componentName']},'geometricEvidence':{'metrics':m['metrics'],'maximumExample':m['maximumExample']}}]}
 out=REV/'floor-support-snowman-exclusions-v1';out.mkdir(exist_ok=True);(out/'icebox.json').write_text(json.dumps(report,indent=2));print(out/'icebox.json')
if __name__=='__main__':main()
