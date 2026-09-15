"""Show the actual floor-panel side hit versus a clear standing-head ray."""
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from tactical_alignment_audit import pack
from verify_source_height_region_oracle import arrays
from lift_reviewed_wall_source_heights import sha


def main():
    root = Path('E:/IcarusWorldAudit/2026-09-06')
    rev = root/'tactical-visibility-revision'
    controls = rev/'real-standing-room-controls-v2/report.json'
    report = json.loads(controls.read_text())
    cases = [row for row in report['records'] if row['agent']=='Viper' and row['control']['kind']=='head-clear-floor-wall-blocked']
    complete = rev/'split-complete-control-original-height-v29-v2'
    pack_path = complete/'split.height.bin.gz'
    assert sha(pack_path)==report['completePackSha256']
    _, scene = pack(pack_path)
    comp = arrays(complete/'composition-provenance.npz')
    bindings = json.loads((rev/'split-wall-family-normalized-candidate-v29/bindings.json').read_text())
    original = Path(bindings.get('originalSourcePack',bindings['sourceBackup']))
    control_to_full = arrays(original.parent/'correspondence.npz')['sourceFaces']
    reviewed = arrays(rev/'split-source-height-region-oracle-v29-v1/original-source-provenance.npz')['fullSourceParents']
    lifted = arrays(rev/'split-source-world-fragments-v29-v1/source-world-fragments.npz')
    full_ids = np.empty(len(comp['group']),dtype=np.int64)
    lookup = [control_to_full,lifted['fullSourceParents'],lifted['discardedFullSourceParents'],reviewed]
    for group in range(4):
        selected = comp['group']==group
        full_ids[selected]=lookup[group][comp['inputId'][selected]]
    raw_ids=arrays(rev/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][full_ids]
    metadata=json.loads((root/'supplemented-v2/world/split/geometry.json').read_text())
    out=rev/'viper-standing-head-source-context-v1'
    out.mkdir(exist_ok=False)
    eye=np.array(cases[0]['originalEye'])
    targets=np.array([row['control']['target'] for row in cases])
    feet=np.array([row['control']['floorTarget'] for row in cases])
    low=np.minimum(eye,np.minimum(targets.min(0),feet.min(0)))-[1.5,1.5,1.]
    high=np.maximum(eye,targets.max(0))+[1.5,1.5,1.]
    meshes=[]
    for obj_id,color,label in [(577,'#be835c','Floor-panel side'),(5924,'#9aa7b0','Ramp stairs')]:
        obj=metadata['objects'][obj_id]
        selected=np.flatnonzero((raw_ids>=obj['firstFace'])&(raw_ids<obj['firstFace']+obj['faceCount']))
        triangles=scene['vertices'][scene['faces'][selected]]
        keep=(triangles.max(1)>=low).all(1)&(triangles.min(1)<=high).all(1)
        meshes.append((triangles[keep],color,label))
    fig=plt.figure(figsize=(16,7))
    for column,azimuth in enumerate([-60,120],1):
        ax=fig.add_subplot(1,2,column,projection='3d')
        for triangles,color,label in meshes:
            ax.add_collection3d(Poly3DCollection(triangles,facecolors=color,edgecolors=color,linewidths=.25,alpha=.45,label=label))
        ax.scatter(*eye,color='#222222',s=35)
        ax.text(*eye,'  Viper standing eye',fontsize=9)
        for index,row in enumerate(cases):
            target=np.array(row['control']['target']); foot=np.array(row['control']['floorTarget']); hit=np.array(row['control']['floorRayHit']['point'])
            ax.plot(*np.array([eye,target]).T,color='#168255',lw=2.2,label='Clear ray to standing head' if index==0 else None)
            ax.plot(*np.array([eye,foot]).T,color='#be3535',lw=1.5,linestyle='--',label='Ray to floor hits panel side' if index==0 else None)
            ax.plot(*np.array([foot,target]).T,color='#333333',lw=2)
            ax.scatter(*hit,color='#be3535',s=25)
            ax.scatter(*target,color='#168255',s=25)
        ax.set(xlim=(low[0],high[0]),ylim=(low[1],high[1]),zlim=(low[2],high[2]),xlabel='Native X, m',ylabel='Native Y, m',zlabel='Original Z, m')
        ax.set_box_aspect(high-low);ax.view_init(elev=22,azim=azimuth)
        ax.legend(loc='upper left',fontsize=8)
    fig.suptitle('Split: a floor-panel side can hide the floor while the standing head remains visible.\nActual extracted geometry and frozen Viper eye. Target support remains conditional; this is not a live-game capture.',fontsize=13)
    fig.tight_layout();fig.savefig(out/'viper-head-versus-floor-rays.png',dpi=140);plt.close(fig)
    (out/'report.json').write_text(json.dumps(dict(scope=__doc__,controlsSha256=sha(controls),completePackSha256=sha(pack_path),
        originalEye=eye.tolist(),caseIds=[row['id'] for row in cases],sourceObjects=[577,5924],
        sourceMeshTriangles=[len(row[0]) for row in meshes],rendererSha256=sha(Path(__file__))),indent=2)+'\n')


if __name__=='__main__':main()
