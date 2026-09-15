"""Cumulative V21 diagnostic with the reviewed finite mailroom U region."""
import json
import numpy as np
from build_split_connected_tower import declarations, REV, bake
from declare_split_doorframe_region import declaration as doorway
from declare_split_component2_cover_region import declarations as body_and_cover
from declare_split_component7_catwalk_region import declaration as catwalk
from declare_split_mailroom_region import declaration as mailroom


if __name__ == '__main__':
    families, proof = declarations()
    body, cover = body_and_cover()
    regions = [doorway(), body, cover, catwalk(), mailroom()]
    for i, region in enumerate(regions):
        for previous in regions[:i]:
            common = set(region['reviewedSourceFaces']) & set(previous['reviewedSourceFaces'])
            if not common:
                continue
            a, b = np.array(region['box']), np.array(previous['box'])
            assert np.any(a[2:] <= b[:2]) or np.any(b[2:] <= a[:2]), 'Shared source IDs require disjoint finite region interiors'
    owned = {face for region in regions for face in region['reviewedSourceFaces']}
    for family in families:
        family['reviewedSourceFaces'] = [face for face in family['reviewedSourceFaces'] if face not in owned]
    for region in regions:
        region['status'] = 'Reviewed bounded diagnostic candidate; no production promotion.'
    families.extend(regions)
    proof['families'] = families
    proof['regionComposition'] = 'Repeated source IDs are permitted only in disjoint finite region interiors with independently verified identity boundaries. Original source fragments outside those interiors retain identity.'
    (REV / 'split-tower-connected-declarations-v21.json').write_text(json.dumps(proof, indent=2))
    bake(out=REV / 'split-wall-family-normalized-candidate-v21', extra_families=families)
