"""Local 199 opening frame shares its frontage datum; remote doorway stays put."""
import json
import numpy as np
import shapely
from build_split_connected_tower import REV
from declare_split_connected_mid_region import declaration as connected_mid
from declare_split_component2_cover_region import grid
from authored_region_cells import barycentric


def declaration(parent=None):
    parent=parent or connected_mid()
    raw=np.load(REV/'split-component7-opening-frame-review-v1/tower-opening-frame-and-upper-attachments-full-source.npz')
    selected=raw['sourceObjectIds']==6962
    source=np.array(parent['sourceVerticesSvg']);target=np.array(parent['targetVerticesSvg']);cells=np.array(parent['triangles'])
    polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons)
    def shared(x,y):
        point=np.array([[x,y]]);hits=tree.query(shapely.Point(x,y),predicate='intersects')
        assert len(hits)
        cell=cells[hits[0]];return (barycentric(point,source[cell])@target[cell])[0]
    xs=sorted({125.,129.,130.39134668356203,132.8130294286565,134.,137.})
    ys=sorted({177.,179.,180.45546434281476,181.15800406420908,181.375100,
               181.9488944269132,183.,187.})
    result=dict(edge=206962,mappingType='piecewise-affine-region-v1',objects=[6962],
        reviewedSourceFaces=raw['sourceFaceIds'][selected].tolist(),
        reviewedAuthoredSpans=[s for s in parent['reviewedAuthoredSpans'] if s['completeSpan']==199],
        role='Local opening-frame frontage shares the connected wall199 field. Original Z/UV and doorway gaps are preserved. The distant source Y195..210 doorway remains outside this identity-bounded region.',
        sharedParentRegion=parent['edge'],sourceSharedFrontageBox=[130.39134668356203,181.15800406420908,132.8130294286565,181.375100],
        sourceRemoteDoorwayY=[195.,210.13708898391585],status='Bounded reviewed source proposal; requires finite-seam and baked profile proof.')
    result.update(grid(xs,ys,shared));return result


if __name__=='__main__':
    out=REV/'split-local-opening-frame-region-proposal-v1';out.mkdir(exist_ok=True)
    (out/'region-declaration.json').write_text(json.dumps(declaration(),indent=2));print(out)
