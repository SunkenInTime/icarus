"""Distinguish relocated opaque frame contacts from the excluded glass sheet."""
import hashlib,json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import ROOT,REV
from authored_region_cells import barycentric
from render_split_remaining_corner_families import sections


def main():
    candidate=REV/'split-wall-family-normalized-candidate-v25';out=REV/'split-182-frame-glass-profile-review-v1';out.mkdir(exist_ok=True)
    family=next(f for f in json.loads((candidate/'bindings.json').read_text())['families'] if f['edge']==200190)
    packet=np.load(REV/'split-original-scene-connected-source-review-v1/clove-upward-notch-full-source.npz');choose=packet['sourceObjectIds']==7797;faces=packet['sourceFaceIds'][choose];triangles=packet['trianglesSvgSourceZ'][choose]
    full_original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];retained=np.isin(faces,full_original)
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles']);polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons)
    rank={row['cell']:(d,row) for d in family.get('declaredRankOneMappings',[]) for row in d['cells']}
    def mapping(lines):
        result=[]
        for endpoints in lines:
            line=shapely.LineString(endpoints)
            for i in tree.query(line,predicate='intersects'):
                for part in shapely.get_parts(shapely.intersection(line,polygons[i])):
                    if not isinstance(part,shapely.LineString):continue
                    points=shapely.get_coordinates(part);weights=barycentric(points,source[cells[i]])
                    if i in rank:
                        declaration,row=rank[i];a,b=np.array(declaration['targetEndpointsSvg']);mapped=a+(weights@np.array(row['vertexParameters']))[:,None]*(b-a)
                    else:mapped=weights@target[cells[i]]
                    result.extend(np.stack((mapped[:-1],mapped[1:]),axis=1))
        return result
    ray=next(r for r in json.loads((candidate/'independent-junction-rays.json').read_text())['records'] if r.get('completeSpan')==182 and r['status']=='passed-authored-wall')
    fig,axes=plt.subplots(1,3,figsize=(18,8))
    for ax,z in zip(axes,[6.75,8.25,11.75]):
        opaque,_=sections(triangles[retained],z);excluded,_=sections(triangles[~retained],z)
        ax.add_collection(LineCollection(opaque,colors='#dc2626',lw=1.5,label='Original retained source'))
        ax.add_collection(LineCollection(mapping(opaque),colors='#16a34a',lw=2,label='Mapped retained source'))
        ax.add_collection(LineCollection(mapping(excluded),colors='#2563eb',lw=2,linestyles='dashed',label='Mapped excluded material sheets'))
        ax.plot(*np.array([ray['startSvg'],ray['finishSvg']]).T,color='#a855f7',lw=1,label='Frozen probe XY')
        ax.scatter(*ray['expectedContactSvg'],marker='x',color='black',s=60,label='Authored-line intersection')
        ax.set_xlim(212,217);ax.set_ylim(199,193.5);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Original raw Z {z:g} m');ax.legend(fontsize=7)
    fig.suptitle('182 near-upper diagonal: opaque frame moves; excluded glass sheet remains excluded.\nRaw height sections identify the source assembly. The frozen probe uses separate provisional relative heights0.75/1.75/2.75. No new opacity claim or infill.');fig.tight_layout(rect=[0,0,1,.92]);fig.savefig(out/'frame-versus-excluded-sheet.png',dpi=170);plt.close(fig)
    metadata=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');materials=raw['material_indices'][faces]
    evidence=[]
    for material in np.unique(materials[~retained]):
        row=metadata['materials'][int(material)];path=__import__('pathlib').Path(row['source'])
        evidence.append(dict(materialIndex=int(material),metadata=row,sourceMaterialSha256=hashlib.sha256(path.read_bytes()).hexdigest(),excludedOriginalFaces=faces[(materials==material)&~retained].tolist()))
    trace=json.loads((candidate/'late182-original-source-trace.json').read_text())
    report=dict(sourceObject=7797,originalBlockingFrameFace=2825769,originalBlockingFrameMaterial=metadata['materials'][5346],excludedSheetAtNewCrossing=2825969,excludedMaterialEvidence=evidence,originalRayTrace=trace,frozenProbe=ray,
        finding='All three original probes struck the opaque frame cap. The new authored-line crossing lies on a material sheet absent from both frozen full-height and control visibility packs. Its exported material declares BlendMode2. The normalized frame retains its own profile; this does not justify filling the excluded sheet.',
        limitation='Material-dependent transmittance is not simulated or inferred here. Raw source height plots are assembly evidence, not proof that the three relative test heights are valid live standing positions.',productionMutation=False)
    (out/'source-material-profile-evidence.json').write_text(json.dumps(report,indent=2));print(out)


if __name__=='__main__':main()
