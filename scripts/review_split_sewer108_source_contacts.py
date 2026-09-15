"""Freeze original-height wall-normal rays and identify every first source face."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np

from declare_split_legacy105_connected_region import ROOT, REV, sha
from native_reference_cast import NativeReferenceModel
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp


def main(declaration, output):
    output.mkdir(exist_ok=False)
    family = json.loads(declaration.read_text())
    wp = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(wp.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    offset = np.array(w['projection']['origin'])
    inverse = np.linalg.inv(matrix)
    s = np.array(family['sourceVerticesSvg']); t = np.array(family['targetVerticesSvg'])
    mapping = explicit_warp(s,t-s,np.array(family['triangles']))
    constraints = family['sourceConstraints']
    def c(oid,axis,approx):
        values = [r['coordinate'] for r in constraints if r.get('object')==oid and r['axis']==axis]
        found = min(values,key=lambda v:abs(v-approx))
        assert abs(found-approx)<2e-5
        return found
    xleft = c(6162,0,394.62465136)
    xright = c(6169,0,396.59028908)
    north = 288.6989892960074
    south = 304.33747040034166
    refs = {
        108:[[c(6163,0,369.21211957),north],[xleft,north]],
        109:[[xleft,north],[xleft,290.715797006]],
        110:[[394.40034454,291.31824],[396.56220653,291.31824]],
        111:[[396.59019959,280.86399954],[396.59019959,290.74345446]],
        112:[[396.59019959,280.86399954],[404.40944015,280.86399954]],
        113:[[404.40944015,257.40812722],[404.40944015,280.86399954]],
        114:[[xright,c(6169,1,257.40812722)],[404.40944015,c(6169,1,257.40812722)]],
        115:[[c(6169,0,380.95180797),c(6169,1,273.04475899)],[xright,c(6169,1,257.40812722)]],
        116:[[c(6169,0,357.47721856),c(6169,1,273.04475899)],[c(6169,0,380.95180797),c(6169,1,273.04475899)]],
        142:[[380.084,south],[xleft,south]],
        143:[[xleft,302.352690544],[xleft,south]],
        144:[[394.40034454,301.73172603],[396.56229522,301.73172603]],
        145:[[396.59019959,302.30024540],[396.59019959,311.68115862]],
        146:[[388.77095904,312.14096175],[396.59019959,312.14096175]],
    }
    path = REV/'full-height-input-v1/split/split.height.bin.gz'
    original = NativeReferenceModel(path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    raw_ids = np.load(path.parent/'source-correspondence.npz')['sourceFaces']
    meta_path = ROOT/'supplemented-v2/world/split/geometry.json'
    objects = json.loads(meta_path.read_text())['objects']
    starts = np.array([o['firstFace'] for o in objects])
    authored = vector_lines(Path('assets/maps/split_map.svg'))
    rows = []
    for edge, line in refs.items():
        a,b = np.array(line)
        tangent = (b-a)/np.linalg.norm(b-a)
        normal = np.array([-tangent[1],tangent[0]])
        svg_a,svg_b = authored[edge]
        svg_d = svg_b-svg_a
        for z in [2.75,3.25,4.85,5.75,6.75,8.25]:
            for fraction in [.2,.5,.8]:
                point = a+fraction*(b-a)
                for side in [-1,1]:
                    start = np.r_[((point+side*.75*normal)-offset)@inverse.T,z]
                    end = np.r_[((point-side*.75*normal)-offset)@inverse.T,z]
                    hit = original.cast(start,end)
                    row = dict(id=f'wall{edge}-z{z:g}-t{fraction:g}-side{side}',
                        edge=edge,originalZ=z,fraction=fraction,side=side,
                        originalStart=start.tolist(),originalEnd=end.tolist(),hit=hit)
                    if hit:
                        raw = int(raw_ids[hit['face']])
                        owner = int(np.searchsorted(starts,raw,side='right')-1)
                        source_svg = np.array(hit['point'][:2])@matrix.T+offset
                        admitted = raw in family['reviewedSourceFaces']
                        mapped = mapping.apply(source_svg[None])[0] if admitted else source_svg
                        delta = mapped-svg_a
                        distance = abs(svg_d[0]*delta[1]-svg_d[1]*delta[0])/np.linalg.norm(svg_d)
                        along = float((mapped-svg_a)@svg_d/(svg_d@svg_d))
                        row.update(rawSourceFace=raw,sourceObject=owner,sourcePath=objects[owner]['path'],
                            sourceSvg=source_svg.tolist(),proposedSvg=mapped.tolist(),
                            includedInProposal=admitted,authoredLineDistanceSvg=float(distance),
                            authoredAlongParameter=along)
                    rows.append(row)
    standing = [r for r in rows if r['originalZ']==4.85 and r['hit']]
    foreign = [r for r in standing if not r['includedInProposal']]
    expected = [r for r in standing if r['includedInProposal']]
    summary = dict(rays=len(rows),sourceHits=sum(r['hit'] is not None for r in rows),
        standingOriginalHeightHits=len(standing),standingForeignFirstContacts=len(foreign),
        standingIncludedMaximumAuthoredLineErrorSvg=max((r['authoredLineDistanceSvg'] for r in expected),default=0),
        foreignFirstContactObjects=sorted({r['sourceObject'] for r in rows if r['hit'] and not r['includedInProposal']}))
    report = dict(summary=summary,records=rows,declarationSha256=sha(declaration),
        scriptSha256=sha(Path(__file__)),originalSourcePackSha256=sha(path),
        sourceCorrespondenceSha256=sha(path.parent/'source-correspondence.npz'),
        sourceMetadataSha256=sha(meta_path),referenceSegmentsSourceSvg=refs,
        semantics='Horizontal original-Z, two-sided wall-normal source controls. They attribute actual first faces in the complete optical source scene. Source Z 4.85 is the reviewed entrance standing-height control. These are not final standing-target visibility queries; arch/header transitions at other heights must remain distinct from authored contact errors.',
        productionMutation=False)
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
    for r in foreign:
        print(r['id'],r['sourceObject'],r['rawSourceFace'],r['authoredLineDistanceSvg'])


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--declaration',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    main(a.declaration,a.output)
