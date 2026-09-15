"""Stage only source-supported floor changes; retain unresolved map surfaces."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from bake_navigation_floors import bake, plane
from ground_floor_policy import ground_policy_mask


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value,separators=(',',':')))


def refine_local_columns(original, new_floor, metadata, native, raw, changed_faces, override_scope):
    """Use the verified local floor overlay only at affected native columns."""
    refined=copy.deepcopy(original)
    nav_vertices=np.asarray(native['vertices']).reshape(-1,3)/100
    nav_vertices[:,1]*=-1
    nav_faces=np.asarray(native['triangles']).reshape(-1,4)
    related=[set() for _ in nav_vertices]
    for parent,a,b,c in nav_faces:
        for i in (a,b,c): related[i].add(int(parent))
    selected=sorted(set(map(int,changed_faces))|set(override_scope))
    if not selected:
        return refined, []
    shapes=shapely.polygons(raw['points'][raw['faces'][selected],:2])
    shapes=shapes[shapely.area(shapes)>1e-12]
    domain=shapely.union_all(shapes)
    floor=new_floor['floorMesh']
    fv=np.asarray(floor['vertices']).reshape(-1,3).astype(float)
    uv=fv[:,:2].copy()/floor['coordinateScale']; ui=metadata['uiTransform']
    fv[:,0]=(uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier'])
    fv[:,1]=-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier'])
    fv[:,2]/=100
    ff=np.asarray(floor['triangles']).reshape(-1,4)
    triangles=fv[ff[:,1:]]
    polygons=shapely.polygons(triangles[:,:,:2]); tree=shapely.STRtree(polygons)
    changes=[]
    for i,seed in enumerate(nav_vertices):
        point=shapely.Point(seed[:2])
        if domain.distance(point)>1e-8: continue
        heights=[]
        for f in tree.query(point.buffer(1e-8),predicate='intersects'):
            if ff[f,0] not in related[i]: continue
            coefficients=plane(triangles[f]); z=float(np.dot(coefficients,[seed[0],seed[1],1]))
            if seed[2]-.60001<=z<=seed[2]+.30001: heights.append(z)
        if not heights: continue
        value=max(heights)*100
        before=refined['refinedFloorHeightsCm'][i]
        if abs(value-before)<=.001: continue
        refined['refinedFloorHeightsCm'][i]=value
        check=refined['checks'][i]
        check.update(accepted=True,refinedZCm=value,materialCategory='opaque',verifiedLocalFloorOverlay=True)
        check.pop('sourceFace',None)
        check.pop('estimatedFromMedianLift',None)
        changes.append({'vertex':i,'beforeCm':before,'afterCm':value})
    return refined,changes


def stage(name, base_root, facing_root, navigation_root, support_proof, convex_proof, output_root):
    baseline, output=base_root/name, output_root/name
    if output.exists(): raise ValueError('Verified floor candidates require a fresh output directory.')
    metadata=json.loads((baseline/'geometry.json').read_bytes())
    audit=json.loads((baseline/'native-slot-audit.json').read_bytes())
    if not audit['stageReady'] or digest(baseline/'geometry.npz')!=metadata['geometrySha256']:
        raise ValueError('Native Art baseline is not frozen/verified.')
    proof=json.loads(support_proof.read_bytes())
    row=next(m for m in proof['maps'] if m['map']==name)
    if row['nativeCandidateGeometrySha256']!=metadata['geometrySha256']:
        raise ValueError('Pawn support refers to another Art source.')
    navigation=navigation_root/f'{name}_source_xyz.json'
    native=json.loads(navigation.read_bytes())
    output.mkdir(parents=True)
    for filename in ('geometry.npz','floor-mesh.json','floor-refinement.json'):
        shutil.copy2(baseline/filename,output/filename)
    shutil.copy2(support_proof,output/'native-pawn-support.json')
    facing=json.loads((facing_root/name/'ground-facing.json').read_bytes())
    for filename in ('ground-facing.json',facing['signsFile']):
        shutil.copy2(facing_root/name/filename,output/filename)
    metadata['groundFacing']={'file':'ground-facing.json','sha256':digest(output/'ground-facing.json')}
    raw=np.load(output/'geometry.npz')
    policy={'schemaVersion':1,'map':name,'geometrySha256':metadata['geometrySha256'],'faceCount':len(raw['faces']),
        'defaultMode':'baseline-geometric-winding','baselinePointsDtype':str(raw['points'].dtype),
        'sourceProofFile':'native-pawn-support.json','sourceProofSha256':digest(output/'native-pawn-support.json'),
        'sourceNavigationXYZ':str(navigation.resolve()),'sourceNavigationXYZSha256':digest(navigation),
        'authoredFacingRanges':[],'excludedRanges':[],'overrideFloorMeshes':[],
        'standingSemantics':'Vertical support-surface height plus the existing nominal standing camera offset.',
        'limitations':['Unverified support retains the previous standing approximation.',
            'Capsule contact/clearance, movement step logic and camera code are not simulated.']}
    if name=='fracture':
        approved=[p for p in row['placements'] if p['classification']=='declared-pawn-blocking-complex']
        if len(approved)!=2: raise ValueError('Unexpected Fracture support scope.')
        for p in approved:
            policy['authoredFacingRanges'].append({'firstFace':p['firstFace'],'faceCount':p['faceCount'],
                'reason':'declared-pawn-blocking-complex','sourceRecordId':f"{name}:{p['firstFace']}"})
    elif name=='bind':
        convex=json.loads(convex_proof.read_bytes())
        for key,sha in [('sourceMesh','sourceMeshSha256'),('nativePlacementFile','nativePlacementSha256')]:
            if digest(convex[key])!=convex[sha]: raise ValueError('Native convex source changed.')
        hull=convex_proof.parent/convex['floorPatchFile']
        if digest(hull)!=convex['floorPatchSha256']: raise ValueError('Native convex hull changed.')
        source_face=convex['probe']['sourceFace']
        placed=next(p for p in row['placements'] if p['firstFace']<=source_face<p['firstFace']+p['faceCount'])
        shutil.copy2(convex_proof,output/'native-convex-support.json')
        shutil.copy2(hull,output/'native-convex-support.npz')
        policy['overrideFloorMeshes'].append({'file':'native-convex-support.npz','sha256':digest(output/'native-convex-support.npz'),
            'sourceProofFile':'native-convex-support.json','sourceProofSha256':digest(output/'native-convex-support.json'),
            'scopeArtFaces':placed['facingChangedFacesInFloorWindows'],'parentNavPolygons':placed['parentNavPolygons'],
            'sourceRecordId':f"{name}:{placed['firstFace']}",
            'reason':'verified-separate-native-convex-support'})
    else: raise ValueError('No player-support change has been approved for this map.')
    write_json(output/'ground-support.json',policy)
    metadata['groundSupport']={'file':'ground-support.json','sha256':digest(output/'ground-support.json')}
    write_json(output/'geometry.json',metadata)
    old_metadata=json.loads((baseline/'geometry.json').read_bytes())
    old_allowed,_,_=ground_policy_mask(baseline,old_metadata,raw,navigation)
    new_allowed,_,_=ground_policy_mask(output,metadata,raw,navigation)
    floor=bake(output,navigation,output/'floor-mesh.json')
    original=json.loads((baseline/'floor-refinement.json').read_bytes())
    refined,changes=refine_local_columns(original,floor,metadata,native,raw,np.flatnonzero(old_allowed!=new_allowed),
        [f for entry in policy['overrideFloorMeshes'] for f in entry['scopeArtFaces']])
    refined['groundFacingSha256']=metadata['groundFacing']['sha256']
    refined['groundSupportSha256']=metadata['groundSupport']['sha256']
    refined['verifiedFloorCorrection']={'toolSha256':digest(__file__),'localVertexChanges':changes,
        'standingSemantics':policy['standingSemantics'],'limitations':policy['limitations']}
    write_json(output/'floor-refinement.json',refined)
    if digest(output/'geometry.npz')!=metadata['geometrySha256']:
        raise ValueError('Floor-only correction changed original source geometry.')
    report={'schemaVersion':1,'map':name,'status':'staged-awaiting-independent-ground-verification',
        'geometrySha256':metadata['geometrySha256'],'baselineWorld':str(baseline),'candidateWorld':str(output),
        'geometryAndMaterialsUnchanged':True,'authoredFacingRanges':policy['authoredFacingRanges'],
        'overrideMeshCount':len(policy['overrideFloorMeshes']),'localVertexChanges':changes,
        'floorMeshSha256':digest(output/'floor-mesh.json'),'floorRefinementSha256':digest(output/'floor-refinement.json'),
        'groundFacingSha256':metadata['groundFacing']['sha256'],'groundSupportSha256':metadata['groundSupport']['sha256']}
    write_json(output/'verified-floor-correction.json',report)
    print(json.dumps(report),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-root',type=Path,required=True)
    parser.add_argument('--facing-root',type=Path,required=True)
    parser.add_argument('--navigation-root',type=Path,required=True)
    parser.add_argument('--support-proof',type=Path,required=True)
    parser.add_argument('--convex-proof',type=Path,required=True)
    parser.add_argument('--output-root',type=Path,required=True)
    parser.add_argument('--maps',nargs='+',required=True)
    args=parser.parse_args()
    for name in args.maps:
        stage(name,args.base_root,args.facing_root,args.navigation_root,args.support_proof,args.convex_proof,args.output_root)
