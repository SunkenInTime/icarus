"""Close receiver/curve views for the reviewed generator-cover junction."""
import gzip
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.figure import Figure
from matplotlib.backends.backend_agg import FigureCanvasAgg
import numpy as np
import shapely
from svgpathtools import parse_path,Line

from audit_all_map_wall_span_coverage import authored_spans
from native_compact_wall_profiles import sha
from tactical_alignment_receiver import receiver_domain
from verify_split_generator_profile_proposal import parameter_at_x,restrict
from authored_cubic_segments import cubic_segments

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
FOLDER=REV/'split-generator-connected-profile-proposal-v4'


def cubic_y(controls,x):
    t=parameter_at_x(controls,x)
    return restrict(controls,t,t)[0,1] if t else controls[0,1]


def paths(geometry):
    for part in shapely.get_parts(geometry):
        if isinstance(part,shapely.Polygon):
            yield np.asarray(part.exterior.coords),True
            for hole in part.interiors:yield np.asarray(hole.coords),False


def fill(ax,receiver,box,offset=(0,0),scale=1):
    for coords,exterior in paths(shapely.intersection(receiver,shapely.box(*box))):
        points=(coords-np.asarray(offset))*scale
        ax.fill(*points.T,color='#d9e2eb' if exterior else 'white',lw=0,zorder=0)


def boundaries(ax,geometry,box,color,offset=(0,0),scale=1,**kwargs):
    for part in shapely.get_parts(shapely.intersection(geometry.boundary,shapely.box(*box))):
        if isinstance(part,shapely.LineString):
            p=(np.asarray(part.coords)-offset)*scale
            ax.plot(*p.T,color=color,**kwargs)


def main():
    declaration=FOLDER/'region-declaration.json';family=json.loads(declaration.read_text())
    previous=FOLDER/'independent-cubic-cover-contact-review.json';proof=json.loads(previous.read_text())
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(warp_path.read_bytes()));reflection=np.array(w['attackToDefenseSvg']['origin'])
    art=[Path('assets/maps/split_map.svg'),Path('assets/maps/split_map_defense.svg')]
    controls=[];receivers=[];covers=[]
    for side,path in enumerate(art):
        segment=next(s for r,s in authored_spans(path) if r['span']==204)
        c=np.array([[v.real,v.imag] for v in [segment.start,segment.control1,segment.control2,segment.end]])
        shape=receiver_domain(path)
        if side:c=reflection-c;shape=shapely.transform(shape,lambda xy:reflection-xy)
        if c[0,0]>c[-1,0]:c=c[::-1]
        controls.append(c);receivers.append(shape)
        strokes=[]
        for element in ET.parse(path).getroot().iter():
            if not element.tag.endswith('path') or 'stroke' not in element.attrib:continue
            for s in parse_path(element.get('d','')):
                if not isinstance(s,Line):continue
                p=np.array([[v.real,v.imag] for v in [s.start,s.end]])
                if side:p=reflection-p
                if p[:,0].min()>69 and p[:,0].max()<78 and p[:,1].min()>186 and p[:,1].max()<195:strokes.append(p)
        assert len(strokes)==3
        covers.append(strokes)
    left=proof['coverRearJoinChecks'][0];join=np.asarray(left['mappedPoints'][0]);start=np.array([join[0],186.527])
    rows=[]
    for side,(c,receiver) in enumerate(zip(controls,receivers)):
        exact_y=float(cubic_y(c,join[0]))
        stroke=shapely.LineString([start,join]);intersection=shapely.intersection(stroke,receiver)
        # Receiver intersection ends at the attack-authored join. Split its
        # length into exact side artwork drift and local flattening residue.
        points=shapely.get_coordinates(intersection)
        receiver_y=float(points[:,1].min()) if len(points) else float(join[1])
        rows.append(dict(side=['attack','registered-defense'][side],exactAuthoredCubicControls=c.tolist(),
            exactCubicYAtAttackCoverX=exact_y,receiverBoundaryYAtAttackCoverX=receiver_y,
            exactAuthoredSideDriftSvg=float(join[1]-exact_y),receiverFlatteningVerticalResidueSvg=float(exact_y-receiver_y),
            literalRearStubReceiverIntersectionSvg=float(intersection.length),
            literalRearStubReceiverIntersectionAt8xPixels=float(intersection.length*8),
            actualCoverStrokeCoordinates=[p.tolist() for p in covers[side]],
            maximumReceiverCubicControlHullBoundSvg=max(v['controlHullDistanceBoundSvg'] for v in cubic_segments(c,1e-5)),
            receiverCurveControlHullToleranceSvg=1e-5))
    delta=controls[1]-controls[0]
    coefficients=np.array([delta[0],3*(delta[1]-delta[0]),3*(delta[0]-2*delta[1]+delta[2]),
                           -delta[0]+3*delta[1]-3*delta[2]+delta[3]])
    square=sum(np.polynomial.polynomial.polymul(coefficients[:,axis],coefficients[:,axis]) for axis in range(2))
    roots=np.polynomial.polynomial.polyroots(np.polynomial.polynomial.polyder(square))
    parameters=[0.,1.]+[float(t.real) for t in roots if abs(t.imag)<1e-10 and 0<t.real<1]
    distances=[float(np.linalg.norm(np.polynomial.polynomial.polyval(t,coefficients))) for t in parameters]
    best=int(np.argmax(distances))
    fig=plt.figure(figsize=(16,12));grid=fig.add_gridspec(3,2,height_ratios=[1.15,1.05,.65],hspace=.55,wspace=.3)
    box=[69.3,186.42,77.82,187.15]
    colors=['#2563eb','#16a34a']
    for side in range(2):
        ax=fig.add_subplot(grid[0,side]);fill(ax,receivers[side],box)
        xs=np.linspace(69.3,min(77.82,controls[side][-1,0]),1001)
        ax.plot(xs,[cubic_y(controls[side],x) for x in xs],color='black',lw=1.6,label='Exact side-authored cubic')
        boundaries(ax,receivers[side],box,colors[side],lw=.9,ls='--',label='Flattened receiver')
        for stroke in covers[side]:ax.plot(*stroke.T,color='#64748b',lw=1.2)
        ax.plot(*np.array([start,join]).T,color='#be185d',lw=2.2,label='Authored rear stub inside generator')
        ax.plot(*join,'o',color='#ea580c',ms=4,label='Mapped cover/cubic join')
        ax.set(xlim=box[::2],ylim=box[3:0:-2],title=['Attack','Registered defense'][side]+' receiver overlay',xlabel='Canonical SVG X',ylabel='Canonical SVG Y')
        ax.legend(loc='upper center',fontsize=8);ax.grid(alpha=.15)
    # Microscopic left endpoint view. Coordinates are offsets so plotting
    # does not hide the literal small differences in axis-number formatting.
    ax=fig.add_subplot(grid[1,0]);micro=[join[0]-2e-5,join[1]-9e-6,join[0]+2e-5,join[1]+3e-6]
    fill(ax,receivers[0],micro,join,1e6)
    xx=np.linspace(micro[0],micro[2],301)
    for side,color in enumerate(colors):
        yy=np.array([cubic_y(controls[side],x) for x in xx])
        ax.plot((xx-join[0])*1e6,(yy-join[1])*1e6,color=color,lw=1.6,label=['Exact attack curve','Exact registered defense curve'][side])
        boundaries(ax,receivers[side],micro,color,join,1e6,lw=1,ls='--',label=['Attack receiver','Defense receiver'][side])
    ax.plot([0,0],[-9,0],color='#be185d',lw=2);ax.plot(0,0,'o',color='#ea580c',ms=4)
    ax.set(xlim=(-20,20),ylim=(3,-9),title='Left join: actual endpoint differences',xlabel='X offset from join, millionths of SVG',ylabel='Y offset from join, millionths of SVG')
    ax.legend(fontsize=8,loc='lower right');ax.grid(alpha=.25)
    # Separate right coordinates are visible only at microscopic scale.
    ax=fig.add_subplot(grid[1,1]);right=np.array([77.5863,186.527]);micro=[77.5861,186.5268,77.5865,186.52735]
    fill(ax,receivers[0],micro,right,1e6)
    for side,color in enumerate(colors):boundaries(ax,receivers[side],micro,color,right,1e6,lw=1,ls='--')
    ax.plot([0,0],[-200,0],color='#ea580c',lw=2,label='Attack generator X=77.5863')
    ax.plot([100,100],[0,350],color='#9333ea',lw=2,label='Attack cover X=77.5864')
    ax.plot([-100,-100],[-200,350],color='#16a34a',lw=1,ls=':',label='Defense generator/cover X=77.5862')
    ax.set(xlim=(-200,200),ylim=(350,-200),title='Right join: no silent coordinate unification',xlabel='X offset from attack generator, millionths of SVG',ylabel='Y offset from corner, millionths of SVG')
    ax.legend(fontsize=8,loc='upper left');ax.grid(alpha=.25)
    native_box=[68.5,185.75,78.5,188.75];width,height=80,24
    native_paths=[]
    for side in range(2):
        small=Figure(figsize=(width/100,height/100),dpi=100);canvas=FigureCanvasAgg(small);ax=small.add_axes([0,0,1,1])
        fill(ax,receivers[side],native_box)
        boundaries(ax,receivers[side],native_box,'#111827',lw=.45)
        for stroke in covers[side]:ax.plot(*stroke.T,color='#64748b',lw=.45)
        ax.plot(*np.array([start,join]).T,color='#be185d',lw=.6)
        ax.set(xlim=(native_box[0],native_box[2]),ylim=(native_box[3],native_box[1]));ax.axis('off')
        canvas.draw();pixels=np.array(canvas.buffer_rgba())
        native=FOLDER/f'generator-join-{["attack","defense"][side]}-8px-per-svg.png';small.savefig(native,dpi=100);native_paths.append(native)
        ax=fig.add_subplot(grid[2,side]);ax.imshow(pixels,interpolation='nearest');ax.set_xticks(np.arange(0,width+1,8));ax.set_yticks(np.arange(0,height+1,8));ax.grid(alpha=.18)
        ax.set(title=['Attack','Defense'][side]+' geometry raster: 8 pixels per SVG, enlarged with nearest sampling',xlabel='Native raster pixels. This is a scale diagram, not an app screenshot.',ylabel='Pixels')
    fig.suptitle('Generator / lower-cover rear join. Gray is the painted receiver; white is the generator hole.\n'
                 'The rear stub is buried. Tiny endpoint residues include curve tessellation and existing attack/defense artwork differences.',fontsize=13)
    image=FOLDER/'rear-stub-receiver-close-review.png';fig.savefig(image,dpi=160,bbox_inches='tight');plt.close(fig)
    report=dict(scope=__doc__,declarationSha256=sha(declaration),priorContactProofSha256=sha(previous),
        svgInputs=[dict(path=str(p),sha256=sha(p)) for p in art],displayWarpSha256=sha(warp_path),scriptSha256=sha(Path(__file__)),
        mappedJoinSvg=join.tolist(),authoredRearStubStartSvg=start.tolist(),authoredRearStubLengthSvg=float(np.linalg.norm(join-start)),
        sideRecords=rows,maximumControlDifferenceSvg=float(np.linalg.norm(controls[0]-controls[1],axis=1).max()),
        maximumControlDifferenceAt8xPixels=float(np.linalg.norm(controls[0]-controls[1],axis=1).max()*8),
        sameParameterCurveDifference=dict(maximumSvg=distances[best],atParameter=parameters[best],
            maximumAt8xPixels=distances[best]*8,method='All real stationary roots of squared cubic difference, plus endpoints.',
            conservativeControlHullBoundSvg=float(np.linalg.norm(delta,axis=1).max())),
        geometryScaleRaster=dict(pixelsPerSvg=8,widthPixels=width,heightPixels=height,svgBounds=native_box,appRenderer=False),
        reviewImage=dict(path=image.name,sha256=sha(image)),nativeScaleImages=[dict(path=p.name,sha256=sha(p)) for p in native_paths],
        conclusion='The rear stub ends on the exact attack cubic. Receiver endpoint slivers include both tessellation and separately rounded defense artwork. No SVG or source geometry was edited.',
        productionMutation=False)
    (FOLDER/'rear-stub-receiver-close-review.json').write_text(json.dumps(report,indent=2)+'\n')
    frozen=['frozen-review-index.json','region-declaration.json','rear-stub-receiver-close-review.json',
            image.name,*[p.name for p in native_paths]]
    (FOLDER/'approval-review-index.json').write_text(json.dumps(dict(
        status='Close source/receiver packet frozen for parent review. No bake authorized by this artifact.',
        files=[dict(path=name,sha256=sha(FOLDER/name)) for name in frozen],productionMutation=False),indent=2)+'\n')
    print(json.dumps(dict(sideRecords=rows,maximumControlDifferenceSvg=report['maximumControlDifferenceSvg']),indent=2))


if __name__=='__main__':main()
