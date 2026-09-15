"""Capture the first source-parent containment failure without changing gates."""
import gzip,json,argparse
import numpy as np
from build_split_connected_tower import REV
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from authored_region_cells import region_fragments
from build_split_normalized_wall_families import cut


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--family');parser.add_argument('--out',default='split-barrier-containment-diagnostic-v1');args=parser.parse_args()
    out=REV/args.out;out.mkdir(exist_ok=True)
    family=json.loads((REV/args.family).read_text()) if args.family else next(f for f in json.loads((REV/'split-tower-connected-declarations-v27.json').read_text())['families'] if f['edge']==200123)
    _,arrays=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz')
    full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];original=full[control]
    selected=np.flatnonzero(np.isin(original,family['reviewedSourceFaces']))
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));a=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@a.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3))
    for parent in selected:
        xyz=arrays['vertices'][arrays['faces'][parent]].copy();xyz[:,:2]=xyz[:,:2]@a.T+o
        inside,_=cut(list(np.column_stack((xyz,np.eye(3)))),family['box'])
        if len(inside)<3:continue
        try:region_fragments(np.array(inside),family,warp)
        except Exception as error:
            report=dict(controlParent=int(parent),originalSourceFace=int(original[parent]),error=str(error),data=np.array(inside).tolist())
            (out/'failure.json').write_text(json.dumps(report,indent=2));(out/'region-declaration.json').write_text(json.dumps(family,indent=2));print(report);return
    print('All selected source parents pass')


if __name__=='__main__':main()
