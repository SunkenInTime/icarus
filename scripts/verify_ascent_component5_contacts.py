"""Exercise root's independent affine seam proof on the courtyard declaration."""
import argparse,json
from pathlib import Path
import numpy as np
from verify_region_contact import verify_contact
from native_compact_wall_profiles import sha


def main(path):
    path=Path(path);r=json.loads(path.read_text());family=r['families'][0];bands=family['sourceCoordinateBands'];knots=[];targets=[]
    for axis in range(2):
        pairs=[(v,float(t)) for t,b in bands[axis].items() for v in sorted(set([b['lower'],b['upper']]))];pairs.sort();knots.append(np.array([x for x,_ in pairs]));targets.append(np.array([t for _,t in pairs]))
    rows=[]
    for span in family['reviewedAuthoredSpans']:
        line=np.array([span['startSvg'],span['endSvg']]);delta=line[1]-line[0]
        if abs(delta).min()>1e-10:continue
        axis=int(np.argmax(abs(delta)));normal_axis=1-axis;band=bands[normal_axis][str(float(line[0,normal_axis]))]
        low,high=sorted(line[:,axis]);first=bands[axis][str(float(low))]['upper'];last=bands[axis][str(float(high))]['lower'];breaks=np.unique(np.r_[first,knots[axis][(knots[axis]>first)&(knots[axis]<last)],last]);checks=[]
        for lo,hi in zip(breaks[:-1],breaks[1:]):
            a=np.zeros((2,2));b=np.zeros((2,2));expected=np.zeros((2,2));a[:,axis]=b[:,axis]=[lo,hi];a[:,normal_axis]=band['lower'];b[:,normal_axis]=band['upper'];expected[:,axis]=np.interp([lo,hi],knots[axis],targets[axis]);expected[:,normal_axis]=line[0,normal_axis]
            checks.append(verify_contact(family,a,family,b,expected))
        rows.append(dict(completeSpan=span['completeSpan'],sourceDepthBand=[band['lower'],band['upper']],affineSections=len(checks),maximumAuthoredErrorSvg=max((c['maximumAuthoredContactErrorSvg'] for c in checks),default=0.),continuousContactVerified=True))
    report=dict(format='icarus-connected-component-contact-control-v1',sourceDeclarationSha256=sha(path),contactVerifierSha256=sha(Path(__file__).with_name('verify_region_contact.py')),scriptSha256=sha(Path(__file__)),rows=rows,scope='Independent affine contact checks for both sides of each axis-aligned reviewed source depth band; all interior along-coordinate events included. Diagonal145 is separately unresolved until its actual sloped source sheet is verified. Original source Z/UV/coverage is checked by the pack verifier.')
    output=path.with_name(path.stem+'-contact-review.json');output.write_text(json.dumps(report,indent=2)+'\n');print('spans',len(rows),'sections',sum(x['affineSections'] for x in rows),'max',max(x['maximumAuthoredErrorSvg'] for x in rows))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('declarations');main(p.parse_args().declarations)
