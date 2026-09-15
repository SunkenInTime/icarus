"""Freeze continuous paper contact proof and original-height source previews."""
import gzip
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
from native_compact_wall_profiles import sha
from propose_split_generator_region import curve_y,bezier
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    folder=REV/'split-generator-paper1640-scoped-proposal-v3';review=REV/'split-generator-paper1640-scoped-finite-review-v3'
    path=folder/'region-declaration.json';f=json.loads(path.read_text());packet=review/'source-and-mapped-fragments.npz';d=np.load(packet)
    src=np.array(f['sourceVerticesSvg']);target=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles']);regions=np.unique(d['regionCells'])
    ranks={row['cell']:declaration for declaration in f['declaredRankOneMappings'] for row in declaration['cells']}
    maximum=0.;endpoint_error=0.;points=0;lines=0
    for region in regions:
        tri=target[cells[region]];mapped=d['mappedSvg'][d['regionCells']==region]
        if np.array_equal(tri,np.broadcast_to(tri[0],tri.shape)):
            points+=1;assert np.max(abs(mapped-tri[0]))<1e-10;ends=tri[:1]
        else:
            lines+=1;assert region in ranks;ends=np.array(ranks[region]['targetEndpointsSvg']);direction=ends[1]-ends[0]
            values=(mapped-ends[0])@direction/(direction@direction);assert values.min()>-1e-10 and values.max()<1+1e-10
            error=float(np.max(np.linalg.norm(mapped-(ends[0]+values[...,None]*direction),axis=-1)));maximum=max(maximum,error);assert error<1e-10
        endpoint_error=max(endpoint_error,max(abs(y-curve_y(x)) for x,y in ends))
    assert endpoint_error<1e-10
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    topology=verify_region_topology(f,explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3)))
    prior=REV/'split-generator-connected-profile-proposal-v4/region-declaration.json';old=json.loads(prior.read_text())
    assert old['generatorReview']['cubic204']==f['generatorReview']['cubic204'];assert old['targetVerticesSvg']==f['targetVerticesSvg'];assert old['triangles']==f['triangles']
    bindings=REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json';families=json.loads(bindings.read_text())['families']
    assert not any(set(f['reviewedSourceFaces'])&set(row.get('reviewedSourceFaces',[])) for row in families)
    assert not any(1640 in row['objects'] for row in families)
    field=explicit_warp(src,target-src,cells);raw=d['paperTriangles'].copy();raw[:,:,:2]=raw[:,:,:2]@matrix.T+offset
    curve=bezier(np.linspace(0,1,2001));fig,axes=plt.subplots(2,2,figsize=(13,9))
    for ax,z in zip(axes.flat,[3.9,4.75,5.01,5.5]):
        lines_at_z,_=sections(raw,z)
        ax.add_collection(LineCollection(lines_at_z,colors='#4584b8',linewidths=1.3,label='Original paper section'))
        paths=lines_at_z[:,:1]+np.linspace(0,1,301)[None,:,None]*(lines_at_z[:,1:]-lines_at_z[:,:1])
        mapped=field.apply(paths.reshape(-1,2)).reshape(paths.shape)
        ax.add_collection(LineCollection(mapped,colors='#d58718',linewidths=2,label='Proposed paper section'))
        ax.plot(*curve.T,color='#6e2031',linestyle='--',linewidth=.8,label='Authored cubic204')
        ax.set(xlim=(47.7,60.3),ylim=(187.42,186.64),title=f'Original source height {z:g}m',xlabel='Attack SVG X',ylabel='Attack SVG Y')
        ax.grid(alpha=.15);ax.legend(fontsize=8)
    fig.suptitle('Attached paper follows the authored generator curve at every retained height\nSection previews exaggerate depth. Finite fragment proof is separate; no product render yet.');fig.tight_layout(rect=[0,0,1,.92]);fig.savefig(folder/'original-height-contact-sections.png',dpi=150);plt.close(fig)
    report=dict(declarationSha256=sha(path),finitePacketSha256=sha(packet),finiteReportSha256=sha(review/'report.json'),
        unchangedGeneratorDeclarationSha256=sha(prior),candidateBindingsSha256=sha(bindings),scriptSha256=sha(Path(__file__)),
        occupiedRegions=len(regions),pointCells=points,lineCells=lines,maximumFragmentDistanceFromDeclaredLineSvg=maximum,
        maximumLineEndpointDistanceFromAuthoredCubicSvg=endpoint_error,
        exactCubicHullBoundSvg=max(row['controlHullDistanceBoundSvg'] for row in f['generatorReview']['cubic204']['segments']),
        sourceTopology=topology,allPaperFacesScopedExclusively=True,allExistingCandidateFamiliesUnchanged=True,
        completeSourceZRangeMeters=[float(d['paperTriangles'][:,:,2].min()),float(d['paperTriangles'][:,:,2].max())],
        claim='Every finite paper fragment projects to a certified cubic segment or point, preserving finite source heights. Full source partition includes collapsed fragments. Existing generator/cover declarations remain unchanged. This proves continuous paper contact within the existing cubic tessellation bound, not game floor policy or raster behavior.')
    (folder/'continuous-contact-review.json').write_text(json.dumps(report,indent=2)+'\n')
    files=[path,folder/'continuous-contact-review.json',folder/'original-height-contact-sections.png',packet,review/'report.json',
           REV/'split-generator-paper1640-attachment-proposal-v1/original-paper-attachment.png',prior]
    (folder/'frozen-review-index.json').write_text(json.dumps(dict(files=[dict(path=str(p),sha256=sha(p)) for p in files],
        status='Awaiting root source and preview review, then cumulative bake and both-side pixels.',productionMutation=False),indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='sourceTopology'},indent=2))


if __name__=='__main__':main()
