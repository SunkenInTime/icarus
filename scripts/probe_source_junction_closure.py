"""Check a reviewed source-connected pair at explicit height events.

This is a sampled closure gate, not a proof of every possible ray or height.
Display line segments are split at actual W cells before measuring gaps.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def mapped_sections(triangles,z,matrix,origin,forward,cells,tree,clip):
    segments,_=sections(triangles,z);parts=[]
    for segment in segments:
        line=shapely.LineString(segment@matrix.T+origin)
        for cell in tree.query(line,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(line,cells[cell])):
                xy=shapely.get_coordinates(part)
                if len(xy)>=2:parts.append(shapely.LineString(forward.apply(xy)))
    return shapely.intersection(shapely.union_all(parts),clip) if parts else shapely.GeometryCollection()


def main(folder):
    proof=json.loads((folder/'bindings.json').read_text());before_path=Path(proof['sourceBackup']);after_path=folder/'split.height.bin.gz';_,before=pack(before_path);_,after=pack(after_path)
    full=np.load(before_path.parent/'correspondence.npz')['sourceFaces'];original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][full];parents=np.load(folder/'correspondence.npz')['sourceFaces']
    diagonal=json.loads((REV/'diagonal-wall-source-review-v1/split-84.json').read_text())['primaryPlaneSourceFaces'];metadata=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());obj=metadata['objects'][5932]
    groups=[np.isin(original,diagonal),(original>=obj['firstFace'])&(original<obj['firstFace']+obj['faceCount'])]
    geometry=[]
    for arrays,mapping in [(before,np.arange(len(original))),(after,parents)]:
        side=[]
        for group in groups:
            ids=np.flatnonzero(group[mapping]);assert not np.any(arrays['faceMasks'][ids]>=0),'Masked closure requires opacity-profile sampling'
            side.append(arrays['vertices'][arrays['faces'][ids]])
        geometry.append(side)
    wpath=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);source_svg=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(w['targetAttackSvg']).reshape(-1,2);indices=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(source_svg,target_svg-source_svg,indices);cells=shapely.polygons(source_svg[indices]);tree=shapely.STRtree(cells)
    bounds=[322,179,328,186];clip=shapely.box(*bounds)
    vertices=np.concatenate([tri.reshape(-1,3) for side in geometry for tri in side]);xy=vertices[:,:2]@matrix.T+origin;near=np.all((xy>=bounds[:2])&(xy<=bounds[2:]),axis=1);events=np.unique(vertices[near,2]);heights=np.unique(np.r_[events,(events[:-1]+events[1:])/2,.75,1.75,2.75]);records=[]
    for z in heights:
        geometries=[[mapped_sections(tri,float(z),matrix,origin,forward,cells,tree,clip) for tri in side] for side in geometry]
        distances=[None if any(g.is_empty for g in side) else float(shapely.distance(*side)) for side in geometries]
        old,new=distances
        status='source-not-connected-at-sample' if old is None or old>1e-7 else 'introduced-disconnection' if new is None or new>1e-6 else 'connection-preserved'
        records.append(dict(heightMeters=float(z),beforeGapSvg=old,afterGapSvg=new,status=status))
    result=dict(scope=__doc__,sourcePackSha256=hashlib.sha256(before_path.read_bytes()).hexdigest(),candidatePackSha256=hashlib.sha256(after_path.read_bytes()).hexdigest(),displayWarpSha256=hashlib.sha256(wpath.read_bytes()).hexdigest(),sourceGroups=dict(diagonalOriginalFaces=diagonal,returnObject5932=obj),clipBoundsSvg=bounds,heightMode='Frozen control-relative Z. Do not treat this as the pending source-absolute-Z lift or final floor policy.',samplePolicy='Every source/candidate vertex height within the local corner rectangle, midpoint between each neighboring event, and0.75/1.75/2.75m. Numerical connection thresholds are1e-7 before/1e-6 after SVG, not visual acceptance tolerances.',counts=dict(Counter(r['status'] for r in records)),records=records)
    (folder/'source-junction-closure-84-85.json').write_text(json.dumps(result,indent=2));print(result['counts'])


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('folder',type=Path);args=parser.parse_args();main(args.folder)
