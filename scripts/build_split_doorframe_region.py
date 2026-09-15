"""Bounded cumulative V16 with one continuous doorway-attachment mapping."""
import json
from build_split_connected_tower import declarations,REV,bake
from declare_split_doorframe_region import declaration

if __name__=='__main__':
    families,proof=declarations();region=declaration();owned=set(region['reviewedSourceFaces'])
    for family in families:
        family['reviewedSourceFaces']=[i for i in family['reviewedSourceFaces'] if i not in owned]
    families.append(region);proof['families']=families
    (REV/'split-tower-connected-declarations-v16.json').write_text(json.dumps(proof,indent=2))
    bake(out=REV/'split-wall-family-normalized-candidate-v16',extra_families=families)
