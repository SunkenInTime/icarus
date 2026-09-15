"""Bind three personally reviewed Split floor-role proposals to exact faces."""
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from probe_source_floor_regressions import load_support

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
OUT = REV / 'split-audited-floor-role-proposals-v1'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main(name='split', proposals=None, version='v1', reviewer='root'):
    global OUT
    OUT = REV / f'{name}-audited-floor-role-proposals-{version}'
    OUT.mkdir(exist_ok=True)
    inventory_path = REV / f'competing-floor-assemblies-v3/{name}.json'
    inventory = json.loads(inventory_path.read_text())
    support = load_support(REV, name, True)
    world = next(r for r in json.loads((ROOT / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if r['map'] == name)
    folder = Path(world['combinedWorldFolder'])
    raw = np.load(folder / 'geometry.npz')
    correspondence = np.load(REV / f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces']
    pack = REV / f'full-height-input-v1/{name}/{name}.height.bin.gz'
    support_file = REV / f'source-floor-support-all-walkable-v1/{name}.floor-support.npz'
    records = []
    for object_index, role in proposals or [(5924, 'structural-terrain'), (6952, 'structural-terrain'), (6561, 'raised-support'), (577, 'unresolved-buried-base')]:
        row = next(r for r in inventory['records'] if r['sourceObjectIndex'] == object_index)
        ids = np.array(row['admittedSupportIndices'])
        triangles = support.points[ids]
        normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
        normals /= np.linalg.norm(normals, axis=1)[:, None]
        eligible = normals[:, 2] >= .65
        full_ids = support.source_ids[ids]
        original_ids = correspondence[full_ids]
        obj = row['sourceObject']
        assert ((original_ids >= obj['firstFace']) & (original_ids < obj['firstFace'] + obj['faceCount'])).all()
        chosen = eligible if role in ('structural-terrain', 'raised-support') else np.zeros(len(ids), dtype=bool)
        records.append(dict(sourceObjectIndex=object_index, objectPath=row['objectPath'], sourceObject=obj, native=row['native'], role=role,
            proposedFullPackFaceIds=full_ids[chosen].tolist(), proposedOriginalSourceFaceIds=original_ids[chosen].tolist(),
            excludedSteepFullPackFaceIds=full_ids[~eligible].tolist(), admittedCount=len(ids), proposedCount=int(chosen.sum()),
            faces=[dict(supportIndex=int(i), fullPackFace=int(f), originalSourceFace=int(o), normal=n.tolist(), verticesNativeMeters=t.tolist(), proposed=bool(c)) for i,f,o,n,t,c in zip(ids,full_ids,original_ids,normals,triangles,chosen)]))
        fig = plt.figure(figsize=(13, 5))
        color = np.where(eligible, '#059669' if role == 'structural-terrain' else '#2563eb', '#dc2626')
        low, high = triangles.reshape(-1, 3).min(axis=0), triangles.reshape(-1, 3).max(axis=0)
        for panel, angle in enumerate((-45, 135), 1):
            ax = fig.add_subplot(1, 2, panel, projection='3d')
            ax.add_collection3d(Poly3DCollection(triangles, facecolors=color, edgecolors='#334155', linewidths=.2))
            ax.set_xlim(low[0], high[0]); ax.set_ylim(low[1], high[1]); ax.set_zlim(low[2], high[2]); ax.set_box_aspect(np.maximum(high-low, .1)); ax.view_init(25, angle)
            ax.set_xlabel('Native X, m'); ax.set_ylabel('Native Y, m'); ax.set_zlabel('Z, m')
        fig.suptitle(f"{name} object {object_index}: {role}\n{int(chosen.sum())} proposed of {len(ids)} admitted; {int((~eligible).sum())} steep strips red. Experimental nZ >= .65, not a recovered game rule")
        fig.tight_layout(); fig.savefig(OUT / f'object-{object_index}.png', dpi=140); plt.close(fig)
    report = dict(version=1,map=name,status='bounded-personally-reviewed-proposals-not-applied',productionMutation=False,reviewer=reviewer,
        evidence=f'{reviewer} personally inspected exact source assembly views and assigned the listed bounded terrain or raised-support proposals. Source-refined detailed navigation is corroboration only, not independent walkability proof. Every source face retains its independent plane and elevation layer; these proposals never merge elevations.',
        normalGate='Upward nZ >= .65 is a bounded experimental role filter, not a Valorant walkability rule. Steep strips keep their original visibility geometry.',
        sourceGeometrySha256=json.loads((folder / 'geometry.json').read_text())['geometrySha256'], fullPackSha256=sha(pack),supportSha256=sha(support_file),inventorySha256=sha(inventory_path),records=records)
    (OUT / f'{name}.floor-role-proposals.json').write_text(json.dumps(report, indent=2))
    print([(r['sourceObjectIndex'],r['proposedCount'],r['admittedCount']) for r in records], flush=True)
    if name != 'split':
        return
    # Compare the unresolved exact floor-panel instance with actual stair geometry.
    panel, stairs = [next(r for r in records if r['sourceObjectIndex']==i) for i in (577,5924)]
    meshes = []
    for row in (panel, stairs):
        obj = row['sourceObject']; mesh = raw['points'][raw['faces'][obj['firstFace']:obj['firstFace']+obj['faceCount']]]
        meshes.append(mesh)
    a = np.array(panel['faces'][0]['verticesNativeMeters'])
    panel_mesh, stair_mesh = meshes
    low, high = panel_mesh.reshape(-1,3).min(axis=0), panel_mesh.reshape(-1,3).max(axis=0)
    keep = np.all((stair_mesh[:,:,:2].max(axis=1)>=low[:2]-.4)&(stair_mesh[:,:,:2].min(axis=1)<=high[:2]+.4),axis=1)
    stair_mesh=stair_mesh[keep]
    fig=plt.figure(figsize=(14,5))
    for slot,angle in enumerate((-45,135),1):
        ax=fig.add_subplot(1,2,slot,projection='3d')
        ax.add_collection3d(Poly3DCollection(panel_mesh,facecolors='#f59e0b',edgecolors='#92400e',linewidths=.2,alpha=.5))
        ax.add_collection3d(Poly3DCollection(stair_mesh,facecolors='#10b981',edgecolors='#064e3b',linewidths=.3,alpha=.65))
        both=np.vstack((panel_mesh.reshape(-1,3),stair_mesh.reshape(-1,3))); lo,hi=both.min(axis=0),both.max(axis=0)
        ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(np.maximum(hi-lo,.1));ax.view_init(20,angle)
        ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_zlabel('Z, m')
    fig.suptitle('Exact original source overlay: FloorPanelB object 577 orange; ARampLongStairs object 5924 green')
    fig.tight_layout();fig.savefig(OUT/'floor-panel-stair-overlay.png',dpi=160);plt.close(fig)
    print([(r['sourceObjectIndex'],r['proposedCount'],r['admittedCount']) for r in records])

if __name__=='__main__':
    main()
