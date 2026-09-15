"""Attach conservative, independently reviewed empty-sheet regions to an atlas."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely


def run(revision):
    atlas_path=revision/'local-floor-atlas-v1/split.npz'
    certificate_path=revision/'sheet-transit-certificate-v1/split.json'
    data=np.load(atlas_path);arrays={key:data[key] for key in data.files}
    certificate=json.loads(certificate_path.read_text())
    verification=json.loads((certificate_path.parent/'split-verification.json').read_text())
    if verification['failures']:
        raise ValueError('Transit certificate has unresolved verification failures')
    parents=certificate['parents'];index={parent['parent']:i for i,parent in enumerate(parents)}
    sheet_ids={parent:sheet['id'] for sheet in certificate['sheets'] for parent in sheet['parents']}
    polygons,ranges,groups,sheets=[],[],[],[]
    face_group={}
    for parent in parents:
        polygon=np.array(shapely.from_geojson(parent['polygon']).exterior.coords)[:-1]
        ranges.append([len(polygons),len(polygon)]);polygons.extend(polygon)
        groups.append(parent['exactPlaneGroup']);sheets.append(sheet_ids[parent['parent']])
        for face in parent['sourceFaces']:
            previous=face_group.setdefault(face,parent['exactPlaneGroup'])
            if previous!=parent['exactPlaneGroup']:
                raise ValueError('A source face belongs to conflicting exact plane groups')
    adjacency=np.zeros((len(parents),len(parents)),dtype=np.uint8)
    for transition in certificate['transitions']:
        adjacency[index[transition['incomingParent']],index[transition['outgoingParent']]]=1
    arrays.update(transitPolygons=np.array(polygons),transitRanges=np.array(ranges,dtype=np.int32),
                  transitGroups=np.array(groups,dtype=np.int32),transitSheets=np.array(sheets,dtype=np.int32),
                  transitCellGroups=np.array([face_group.get(int(face),-1) for face in arrays['sourceFaces']],dtype=np.int32),
                  transitAdjacency=adjacency)
    output=atlas_path.with_name('split-with-transit.npz')
    np.savez_compressed(output,**arrays)
    (output.with_suffix('.json')).write_text(json.dumps(dict(atlasSha256=hashlib.sha256(atlas_path.read_bytes()).hexdigest(),
        certificateSha256=hashlib.sha256(certificate_path.read_bytes()).hexdigest(),bytes=output.stat().st_size,
        parents=len(parents),sheets=len(certificate['sheets']),status='bounded-native-experiment'),indent=2)+'\n')
    print(output,output.stat().st_size,'bytes',len(parents),'parents',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('revision',type=Path)
    run(parser.parse_args().revision)
