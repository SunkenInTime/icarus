"""Source/candidate section preview of the shared courtyard field."""
import argparse,gzip,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections
from prepare_ascent_connected_corners import REV


def main(folder):
    folder=Path(folder);proof=json.loads((folder/'bindings.json').read_text());f=proof['families'][0];w=json.loads(gzip.decompress((REV/'display-warps-v1/ascent.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(s,t-s,np.array(w['triangles']).reshape(-1,3));_,source=pack(Path(proof['sourceBackup']));before=source['vertices'][source['faces'][proof['removedControlFaces']]];_,candidate=pack(folder/'ascent.height.bin.gz');pr=np.load(folder/'normalized-face-provenance.npz');after=candidate['vertices'][candidate['faces'][pr['generatedFaceIds']]];fig,axes=plt.subplots(2,2,figsize=(15,12));cells=np.array(f['triangles']);source_grid=np.array(f['sourceVerticesSvg']);target_grid=np.array(f['targetVerticesSvg'])
    for ax,p,title in zip(axes[0],[source_grid,target_grid],['One connected source field','Shared authored field, including caps and roofs']):
        ax.triplot(*p.T,cells,color='#64748b',lw=.35);ax.set_aspect('equal');ax.invert_yaxis();ax.set_title(title)
    for ax,z in zip(axes[1],[1.75,2.75]):
        for label,tri,color in [('Original control',before,'#d95f02'),('Connected candidate',after,'#1b9e77')]:
            lines,_=sections(tri,z);xy=lines.reshape(-1,2)@m.T+o;display=forward.apply(xy).reshape(-1,2,2);ax.add_collection(LineCollection(display,color=color,lw=.9,label=label))
        for span in f['reviewedAuthoredSpans']:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='black',lw=1.2)
        box=f['box'];ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.legend(fontsize=8);ax.set_title(f'Preserved source profiles at control Z={z} m; black SVG')
    spans=f['completeSpans'];fig.suptitle(f'Ascent connected spans {min(spans)}–{max(spans)}: geometry preview, not acceptance',fontsize=13);fig.tight_layout();fig.savefig(folder/'connected-region-preview.png',dpi=180);plt.close(fig)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');main(p.parse_args().candidate)
