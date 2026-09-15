"""Partition every original sewer entrance source face through a held XY proposal."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np

from authored_wall_profile_cells import inverse_in_cell
from declare_split_legacy105_connected_region import ROOT, REV, sha
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import verify_source_partition


def main(declaration, output):
    output.mkdir(exist_ok=False)
    family = json.loads(declaration.read_text())
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    wp = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(wp.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    offset = np.array(w['projection']['origin'])
    inverse = np.linalg.inv(matrix)
    ws = np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset
    wt = np.array(w['targetAttackSvg']).reshape(-1,2)
    cells = np.array(w['triangles']).reshape(-1,3)
    unwarp = explicit_warp(wt,ws-wt,cells)
    source = np.array(family['sourceVerticesSvg'])
    target = np.array(family['targetVerticesSvg'])
    mapping = explicit_warp(source,target-source,np.array(family['triangles']))
    parents, weights, regions, mapped, native_parts = [], [], [], [], []
    selected = np.array(family['reviewedSourceFaces'],dtype=int)
    for index, face in enumerate(selected):
        xyz = raw['points'][raw['faces'][face]].astype(float)
        data = np.column_stack((xyz.copy(),np.eye(3)))
        data[:,:2] = xyz[:,:2]@matrix.T+offset
        for fragment, warp_cell, region in region_fragments(data,family,unwarp,
                source_construction=native_source_rows(xyz,matrix,offset)):
            bary = fragment[:,3:]
            native = bary@xyz
            native[:,:2] = (inverse_in_cell(fragment[:,:2],unwarp,warp_cell)-offset)@inverse.T
            for j in range(1,len(fragment)-1):
                take = [0,j,j+1]
                parents.append(int(face))
                weights.append(bary[take])
                regions.append(region)
                mapped.append(fragment[take,:2])
                native_parts.append(native[take])
        if index%100 == 0:
            print('original source faces',index,len(selected),'fragments',len(parents),flush=True)
    parents = np.array(parents)
    weights = np.array(weights)
    mapped = np.array(mapped)
    native_parts = np.array(native_parts)
    originals = raw['points'][raw['faces'][parents]].astype(float)
    source_xyz = np.einsum('nij,njk->nik',weights,originals)
    source_svg = source_xyz[:,:,:2]@matrix.T+offset
    expected = mapping.apply(source_svg.reshape(-1,2)).reshape(mapped.shape)
    partition = verify_source_partition(parents,weights,selected.tolist())
    z_error = float(abs(native_parts[:,:,2]-source_xyz[:,:,2]).max())
    mapping_error = float(np.linalg.norm(mapped-expected,axis=2).max())
    assert z_error <= 1e-12
    assert weights.min() >= -1e-8
    assert mapping_error <= 1e-9
    metadata = json.loads(raw_path.with_suffix('.json').read_text())
    obj = metadata['objects'][6160]
    oid = np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
    tri = raw['points'][raw['faces'][oid]].astype(float)
    tri_svg = tri[:,:,:2]@matrix.T+offset
    rear_ids = oid[(tri_svg[:,:,0].max(1) <= family['preservedRearGrateSourceBand'][1])]
    rear = np.isin(parents,rear_ids)
    rear_error = float(abs(mapped[rear]-source_svg[rear]).max())
    assert rear_error <= 1e-10
    connector = np.isin(parents,oid) & (source_svg[:,:,0].min(1) < 369.21211956819684) & ~rear
    delta = np.linalg.norm(mapped-source_svg,axis=2)
    largest = np.unravel_index(np.argmax(np.where(connector[:,None],delta,-1)),delta.shape)
    uv = np.einsum('nij,njk->nik',weights,raw['uvs'][parents].astype(float))
    np.savez_compressed(output/'source-and-mapped-fragments.npz',rawSourceParents=parents,
        sourceBarycentrics=weights,regionCells=regions,originalSourceSvg=source_svg,
        originalSourceXyz=source_xyz,mappedSvg=mapped,mappedOriginalHeightNative=native_parts,
        originalMaterialIndices=raw['material_indices'][parents],interpolatedOriginalUvs=uv)
    report = dict(declarationSha256=sha(declaration),scriptSha256=sha(Path(__file__)),
        sourceGeometrySha256=sha(raw_path),displayWarpSha256=sha(wp),
        fragmentPacketSha256=sha(output/'source-and-mapped-fragments.npz'),
        rawSourceFaces=len(selected),generatedIncludingDegenerate=len(parents),sourcePartition=partition,
        minimumStoredSourceBarycentric=float(weights.min()),maximumOriginalZErrorMeters=z_error,
        maximumContinuousMappingErrorSvg=mapping_error,
        preservedRearGrate=dict(rawSourceFaces=rear_ids.tolist(),fragments=int(rear.sum()),
            maximumXYChangeSvg=rear_error,sourceBand=family['preservedRearGrateSourceBand']),
        rearConnector=dict(rawSourceFaces=np.unique(parents[connector]).tolist(),
            maximumVertexXYChangeSvg=float(delta[largest]),maximumChangeRawSourceFace=int(parents[largest[0]]),
            maximumChangeSourceSvg=source_svg[largest].tolist(),maximumChangeMappedSvg=mapped[largest].tolist()),
        productionMutation=False,scope='All complete original faces through the exact finite proposal field. Original Z and source attributes are carried barycentrically. This is a source partition proof, not a candidate pack, final standing-target oracle or app render.')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='sourcePartition'},indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--declaration',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    main(args.declaration,args.output)
