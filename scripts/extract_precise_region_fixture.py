"""Freeze the two source-construction containment regressions as small inputs."""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from tactical_alignment_audit import pack
from prepare_ascent_connected_corners import REV


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    warp_path = REV / 'display-warps-v1/ascent.display-warp.json.gz'
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    rows = []
    for version, parent, cell, accepted, mode in [(4, 866034, 116, False, 'generated'), (5, 998587, 40, True, 'generated'), (6, 998588, 61, True, 'discarded')]:
        folder = REV / f'ascent-connected-boat-candidate-v{version}'
        binding = json.loads((folder / 'bindings.json').read_text())
        family = binding['families'][0]
        source_path = Path(binding['sourceBackup'])
        _, source = pack(source_path)
        provenance = np.load(folder / 'normalized-face-provenance.npz')
        parents = np.load(folder / 'correspondence.npz')['sourceFaces'][provenance['generatedFaceIds']] if mode=='generated' else provenance['discardedSourceFaces']
        cells = provenance[mode+'RegionCells']
        ids = np.flatnonzero((parents == parent) & (cells == cell))
        assert len(ids)
        source_cell = np.asarray(family['sourceVerticesSvg'])[np.asarray(family['triangles'])[cell]]
        candidates = []
        for index in ids:
            original = source['vertices'][source['faces'][parent]]
            bary = provenance[mode+'Barycentrics'][index]
            points = (original[:1] + bary[:, 1:] @ (original[1:] - original[:1]))[:, :2] @ matrix.T + origin
            uv = np.linalg.solve((source_cell[1:] - source_cell[:1]).T, (points - source_cell[0]).T).T
            minimum = float(np.c_[1-uv.sum(1), uv].min())
            candidates.append((minimum, index, original, bary))
        minimum, index, original, bary = min(candidates, key=lambda item: item[0])
        rows.append(dict(version=version, mode=mode, accepted=accepted, sourceParent=parent, regionCell=cell,
                         generatedProvenanceRow=int(index), originalNativeTriangle=original.tolist(),
                         sourceBarycentrics=bary.tolist(), projectionMatrix=matrix.tolist(),
                         projectionOrigin=origin.tolist(), sourceCell=source_cell.tolist(),
                         inputHashes=dict(sourcePack=sha(source_path), provenance=sha(folder/'normalized-face-provenance.npz'),
                                          displayWarp=sha(warp_path), bindings=sha(folder/'bindings.json'))))
    target = Path(__file__).with_name('fixtures') / 'precise-region-containment.json'
    target.write_text(json.dumps(rows, indent=2) + '\n')
    print(target)


if __name__ == '__main__':
    main()
