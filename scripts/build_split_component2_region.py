"""Cumulative V17 diagnostic with the reviewed connected tower-battery assembly."""
import gzip,json
from build_split_connected_tower import declarations,REV,bake
from declare_split_doorframe_region import declaration as doorway
from declare_split_component2_region import declaration as battery

if __name__=='__main__':
    families,proof=declarations();regions=[doorway(),battery()]
    owned={i for region in regions for i in region['reviewedSourceFaces']}
    for family in families:
        family['reviewedSourceFaces']=[i for i in family['reviewedSourceFaces'] if i not in owned]
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    regions[-1]['reviewedAuthoredSpans']=[dict(completeSpan=s['span'],legacyStraightEdgeIndex=s['legacyStraightEdgeIndex'],startSvg=s['startSvg'],endSvg=s['endSvg']) for s in coverage['spans'] if s['span'] in [82,83,84,85]]
    regions[-1]['status']='Reviewed bounded whole assembly; diagnostic candidate, no production promotion.'
    families.extend(regions);proof['families']=families
    (REV/'split-tower-connected-declarations-v17.json').write_text(json.dumps(proof,indent=2))
    bake(out=REV/'split-wall-family-normalized-candidate-v17',extra_families=families)
