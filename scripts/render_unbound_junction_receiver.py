"""Show frozen early wall hits against both authored receiver fills.

The selected rays use the candidate's provisional relative-height policy.
Painted origins are not certified standing positions. This is a source-role
review aid, not permission to discard geometry outside the painted receiver.
"""
import argparse
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import shapely

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import vector_lines
from tactical_alignment_receiver import receiver_domain


def render(candidate, edge, output):
    if output.exists():
        raise FileExistsError(output)
    source=candidate/'independent-junction-rays.json'
    report=json.loads(source.read_text())
    rows=[r for r in report['records'] if r['svgEdge']==edge and
          r['relativeEyeHeightMeters']==1.75 and r['status']=='early-unbound-hit']
    if not rows:
        raise ValueError('No frozen standing early-unbound rays for this edge')
    rev=candidate.parent
    warp_path=rev/'display-warps-v1/split.display-warp.json.gz'
    assert sha(warp_path)==report['displayWarpSha256']
    warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    flip=np.asarray(warp['attackToDefenseSvg']['origin'])
    allpoints=np.asarray([r[key] for r in rows for key in
                          ['startSvg','finishSvg','expectedContactSvg','hitSvg']])
    lo=allpoints.min(0)-2;hi=allpoints.max(0)+2
    output.mkdir()
    fig,axes=plt.subplots(1,2,figsize=(14,7))
    results=[]
    for side,ax in zip(['attack','defense'],axes):
        path=Path('assets/maps')/('split_map.svg' if side=='attack' else 'split_map_defense.svg')
        if not path.exists():
            raise FileNotFoundError(path)
        domain=receiver_domain(path)
        transform=lambda p: np.asarray(p) if side=='attack' else flip-np.asarray(p)
        bounds=np.asarray([transform(lo),transform(hi)])
        lower,upper=bounds.min(0),bounds.max(0)
        for polygon in shapely.get_parts(domain.intersection(shapely.box(*lower,*upper))):
            if polygon.geom_type!='Polygon':continue
            ax.fill(*np.asarray(polygon.exterior.coords).T,color='#d9ecd8')
            for ring in polygon.interiors:
                ax.fill(*np.asarray(ring.coords).T,color='white')
        for line in vector_lines(path):
            ax.plot(*line.T,color='#8d5e22',linewidth=1.5)
        checks=[]
        for row in rows:
            start,finish,expected,hit=[transform(row[k]) for k in
                                      ['startSvg','finishSvg','expectedContactSvg','hitSvg']]
            ax.plot(*np.asarray([start,finish]).T,color='#5679a3',alpha=.5,linewidth=.8)
            ax.scatter(*hit,color='#c92730',s=17,zorder=4)
            ax.scatter(*expected,color='#222222',s=13,marker='x',zorder=5)
            ray=shapely.LineString([start,finish])
            crossings=shapely.get_coordinates(ray.intersection(domain.boundary))
            crossing_distances=sorted(set(float(ray.project(shapely.Point(p))) for p in crossings))
            checks.append(dict(startSvg=start.tolist(),hitSvg=hit.tolist(),
                expectedContactSvg=expected.tolist(),
                originInReceiver=bool(domain.covers(shapely.Point(start))),
                earlyHitInReceiver=bool(domain.covers(shapely.Point(hit))),
                expectedInReceiver=bool(domain.covers(shapely.Point(expected))),
                authoredFillBoundaryCrossingsFromOriginSvg=crossing_distances,
                sourceHitDistanceFromOriginSvg=float(np.linalg.norm(hit-start)),
                boundaryScope='Crossings identify artwork transitions only. A separate source-role review decides which transitions are solid.'))
        ax.set_xlim(lower[0],upper[0])
        ax.set_ylim(upper[1],lower[1]);ax.set_aspect('equal');ax.grid(alpha=.2)
        ax.set_title(side+' / green is painted receiver\nred is early hit; black cross is expected wall contact')
        results.append(dict(side=side,svgSha256=sha(path),checks=checks))
    fig.suptitle(f'Split wall {edge}, frozen standing-section endpoint rays\nProvisional floor policy. Source role and valid player positions still require review.')
    fig.tight_layout(rect=[0,0,1,.88]);fig.savefig(output/'receiver-and-first-hits.png',dpi=160);plt.close(fig)
    (output/'report.json').write_text(json.dumps(dict(scope=__doc__,edge=edge,
        candidatePackSha256=report['candidatePackSha256'],junctionReportSha256=sha(source),
        displayWarpSha256=sha(warp_path),scriptSha256=sha(Path(__file__)),
        frozenRays=rows,sides=results),indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate',type=Path)
    parser.add_argument('edge',type=int)
    parser.add_argument('output',type=Path)
    render(**vars(parser.parse_args()))
