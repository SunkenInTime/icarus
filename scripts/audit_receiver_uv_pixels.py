"""Native-scale pixel grids for source UVs versus Float32 coefficients.

This isolates coefficient quantization on actual2x/8x authored SVG grids. It is
not a GPU shader emulation or a claim that extrapolated material planes are floors.
"""
import argparse
from fractions import Fraction as F
import gzip
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
import shapely
from scipy.ndimage import binary_erosion, distance_transform_edt

from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import IndexedTriangles
from finite_receiver_shadows import Receiver
from probe_real_receiver_room_controls import sha


def alpha_batch(texture, uv, policy):
    h, w = texture.shape
    position = uv*np.array([w,h])-.5
    integer = np.floor(position).astype(np.int64); frac = position-integer
    value = np.zeros(len(uv))
    def wrap(index, size, mode):
        if mode == 'repeat': return index % size, np.ones(len(index),bool)
        if mode == 'mirror':
            v=index%(2*size); return np.where(v<size,v,2*size-1-v), np.ones(len(index),bool)
        if mode == 'clamp': return np.clip(index,0,size-1), np.ones(len(index),bool)
        if mode == 'black': return np.clip(index,0,size-1), (index>=0)&(index<size)
        raise ValueError(mode)
    for dx in [0,1]:
        x, valid_x=wrap(integer[:,0]+dx,w,policy['wrapS'])
        wx=frac[:,0] if dx else 1-frac[:,0]
        for dy in [0,1]:
            y, valid_y=wrap(integer[:,1]+dy,h,policy['wrapT'])
            wy=frac[:,1] if dy else 1-frac[:,1]
            value+=texture[y,x]*wx*wy*(valid_x&valid_y)
    value=value*policy.get('alphaScale',1)+policy.get('alphaBias',0)
    outside=((policy['wrapS']=='black')&((uv[:,0]<0)|(uv[:,0]>1)))|((policy['wrapT']=='black')&((uv[:,1]<0)|(uv[:,1]>1)))
    value[outside]=policy.get('alphaBias',0)
    return value


class Warp:
    def __init__(self,data):
        self.source=np.array(data['sourceNativeMeters']).reshape(-1,2)
        self.target=np.array(data['targetAttackSvg']).reshape(-1,2)
        self.faces=np.array(data['triangles']).reshape(-1,3)
        self.source_index=IndexedTriangles(self.source,self.faces)
        self.target_index=IndexedTriangles(self.target,self.faces)
        self.cells=shapely.polygons(self.source[self.faces]); self.tree=shapely.STRtree(self.cells)
    def inverse(self,xy):
        cells=self.target_index.find_simplex(xy)
        if np.any(cells<0): raise ValueError('Pixel left display-warp domain')
        t=self.target_index.transform[cells];uv=np.einsum('nij,nj->ni',t[:,:2],xy-t[:,2])
        return np.einsum('ni,nij->nj',np.c_[uv,1-uv.sum(1)],self.source[self.faces[cells]])
    def shape(self,polygon):
        shape=shapely.Polygon(polygon);pieces=[]
        for cell in self.tree.query(shape,predicate='intersects'):
            part=shapely.intersection(shape,self.cells[cell])
            if part.geom_type!='Polygon' or part.area==0: continue
            xy=np.array(part.exterior.coords[:-1]);t=self.source_index.transform[cell]
            uv=np.einsum('ij,nj->ni',t[:2],xy-t[2]);bary=np.c_[uv,1-uv.sum(1)]
            pieces.append(shapely.Polygon(bary@self.target[self.faces[cell]]))
        return shapely.union_all(pieces)


def boundary_shift(a,b):
    if np.array_equal(a,b): return 0.
    ea=a&~binary_erosion(a);eb=b&~binary_erosion(b)
    if not ea.any() or not eb.any(): return None
    return float(max(distance_transform_edt(~ea)[eb].max(),distance_transform_edt(~eb)[ea].max()))


def denominator_bounds(row):
    coeff=[F(float(x))for x in row['homography'][2]];eye=[F(float(x))for x in row['eyeXY']]
    values=[sum((coeff[i]*(F(float(p[i]))-eye[i])for i in range(2)),coeff[2])for p in row['candidatePolygon']]
    low,high=min(values),max(values)
    return dict(minimum=float(np.nextafter(float(low),-np.inf)),maximum=float(np.nextafter(float(high),np.inf)),
                exactMinimum=[str(low.numerator),str(low.denominator)],exactMaximum=[str(high.numerator),str(high.denominator)],
                constantNonzeroSign=low>0 or high<0)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('revision',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();r=args.revision;out=args.output;out.mkdir(parents=True,exist_ok=False)
    actual_path=r/'finite-receiver-masked-uv-v2/report.json';stress_path=r/'finite-receiver-masked-uv-stress-v1/report.json'
    actual=json.loads(actual_path.read_bytes());stress=json.loads(stress_path.read_bytes())
    actual_rows=[x for x in actual['records']if x['status']=='projective-candidate']
    stress_rows=[x for x in stress['records']if x['status']=='projective-candidate']
    mixed=[x for x in stress_rows if min(y['expectedAlpha']for y in x['samples'])<x['policy']['threshold']<=max(y['expectedAlpha']for y in x['samples'])]
    chosen=[('actual-floor',actual_rows[0]),('stress-worst-uv',max(stress_rows,key=lambda x:x['maximumFloat32CoefficientUVError'])),
            ('stress-threshold-material',max(mixed,key=lambda x:x['maximumFloat32CoefficientAlphaError']))]
    pack=r/'split-complete-control-original-height-v29-v2/split.height.bin.gz';assert sha(pack)==actual['completePackSha256']==stress['completePackSha256']
    model=NativeReferenceModel(pack,r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    warp_path=r/'staged-display-split-v1/split.display-warp.json.gz';wdata=json.loads(gzip.decompress(warp_path.read_bytes()));warp=Warp(wdata)
    # The largest coefficient error can occur on a subpixel-width source face.
    # Retain that diagnostic, plus the worst case with at least one2x pixel of
    # projected area so it is not mistaken for a sampled visible-mask test.
    visible_stress=[x for x in stress_rows if warp.shape(x['candidatePolygon']).area*4 >= 1]
    chosen.append(('stress-visible-worst-uv',max(visible_stress,key=lambda x:x['maximumFloat32CoefficientUVError'])))
    reports=[]
    for label,row in chosen:
        fixture_path=r/'source-refined-nav-standing-controls-v2'/(row['fixture']+'.npz')
        with np.load(fixture_path)as d:eye=d['observer'];receiver=Receiver(d['receiverFootprint'],d['receiverPlane'])
        display_shape=warp.shape(row['candidatePolygon']);bounds=display_shape.bounds
        source_triangle=model.arrays['vertices'][model.arrays['faces'][row['sourceFace']]]
        source_uv=model.arrays['maskedUvs'][row['mask']];texture=model.textures[row['texture']];policy=row['policy']
        matrix=np.array(row['homography']);qmatrix=matrix.astype(np.float32).astype(float)
        edge_a,edge_b=source_triangle[1]-source_triangle[0],source_triangle[2]-source_triangle[0]
        relative=eye-source_triangle[0];cross_q=np.cross(relative,edge_a)
        for scale in [2,8]:
            left,top=np.floor(np.array(bounds[:2])*scale).astype(int)-2;right,bottom=np.ceil(np.array(bounds[2:])*scale).astype(int)+2
            width,height=int(right-left),int(bottom-top)
            arrays={key:np.zeros((height,width),bool)for key in ['domain','reference','candidate','sceneReference','sceneCandidate']}
            uv_error=texel_error=alpha_error=0.;tested=0;reference_hit_failures=0
            for start in range(0,height,32):
                finish=min(height,start+32);xx,yy=np.meshgrid((np.arange(left,right)+.5)/scale,(np.arange(top+start,top+finish)+.5)/scale)
                points=np.c_[xx.ravel(),yy.ravel()];inside=shapely.covers(display_shape,shapely.points(points));selected=np.flatnonzero(inside)
                if not len(selected):continue
                physical=warp.inverse(points[inside]);target=receiver.lift(physical);directions=target-eye
                # Independent direct triangle barycentrics at every pixel center.
                p=np.cross(directions,edge_b);det=p@edge_a;u=(p@relative)/det;v=(directions@cross_q)/det
                fraction=(edge_b@cross_q)/det
                valid=(u>=-1e-7)&(v>=-1e-7)&(u+v<=1+1e-7)&(fraction>=0)&(fraction<=1+1e-7)
                reference_hit_failures+=int((~valid).sum())
                expected_uv=np.c_[1-u-v,u,v]@source_uv
                local=np.c_[physical-eye[:2],np.ones(len(physical))];projected=local@qmatrix.T;candidate_uv=projected[:,:2]/projected[:,2,None]
                a=alpha_batch(texture,expected_uv,policy);b=alpha_batch(texture,candidate_uv,policy)
                expected=a>=policy['threshold'];observed=b>=policy['threshold']
                uv_error=max(uv_error,float(np.max(abs(expected_uv-candidate_uv))));texel_error=max(texel_error,float(np.max(abs(expected_uv-candidate_uv)*np.array(texture.shape[::-1]))));alpha_error=max(alpha_error,float(np.max(abs(a-b))));tested+=len(a)
                sub={key:arrays[key][start:finish].reshape(-1)for key in arrays}
                sub['domain'][selected]=True;sub['reference'][selected]=expected;sub['candidate'][selected]=observed
                if label=='actual-floor':
                    # Every actual sample is transparent in both mappings. Keep
                    # the real opaque backing instead of treating it as clear.
                    for j,index in enumerate(selected):
                        hit=model.cast(eye,target[j]);blocked=hit is not None
                        if expected[j]!=observed[j]:raise AssertionError('Actual face classification differs; needs explicit per-face replacement replay')
                        sub['sceneReference'][index]=blocked;sub['sceneCandidate'][index]=blocked
            difference=arrays['reference']^arrays['candidate']
            base=np.zeros((height,width,3),np.uint8);base[:]=[15,17,22];base[arrays['domain']]=[72,75,82]
            images=[]
            for key in ['reference','candidate']:
                pixels=base.copy();pixels[arrays[key]]=[214,176,104]
                image=Image.fromarray(pixels);image.save(out/f'{label}-{scale}x-{key}.png');images.append(image)
            pixels=base.copy();pixels[difference]=[255,40,90];Image.fromarray(pixels).save(out/f'{label}-{scale}x-difference.png')
            lane=max(width,310);sheet=Image.new('RGB',(lane*2+12,max(height,70)+44),(20,22,28));draw=ImageDraw.Draw(sheet)
            draw.text((4,4),f'{label} {scale}x source Float64',(230,230,230));draw.text((lane+16,4),'Float32 coefficients; unscaled pixels',(230,230,230));sheet.paste(images[0],((lane-width)//2,38));sheet.paste(images[1],(lane+12+(lane-width)//2,38));sheet.save(out/f'{label}-{scale}x-comparison.png')
            if label=='actual-floor':
                for key in ['sceneReference','sceneCandidate']:
                    pixels=base.copy();pixels[arrays[key]&arrays['domain']]=[214,176,104];Image.fromarray(pixels).save(out/f'{label}-{scale}x-{key}.png')
            reports.append(dict(label=label,fixture=row['fixture'],sourceFace=row['sourceFace'],material=row['material'],scale=scale,
                                pixelRect=[int(left),int(top),int(right),int(bottom)],testedPixelCenters=tested,referenceHitFailures=reference_hit_failures,
                                opaqueReferencePixels=int(arrays['reference'].sum()),opaqueCandidatePixels=int(arrays['candidate'].sum()),
                                differingPixelCenters=int(difference.sum()),maximumRasterBoundaryShiftPixels=boundary_shift(arrays['reference'],arrays['candidate'])if tested else None,
                                projectedDomainAreaPixels=float(display_shape.area*scale*scale),
                                pixelSampleStatus='sampled'if tested else 'no-covered-pixel-centers-no-raster-agreement-claim',
                                sceneOpaqueReferencePixels=int(arrays['sceneReference'].sum())if label=='actual-floor'else None,
                                sceneDifferences=int((arrays['sceneReference']^arrays['sceneCandidate']).sum())if label=='actual-floor'else None,
                                maximumUVError=uv_error,maximumTextureTexelError=texel_error,maximumAlphaError=alpha_error,
                                denominatorDomain=denominator_bounds(row),comparisonImage=str(out/f'{label}-{scale}x-comparison.png')))
            print(label,scale,'tested',tested,'different',int(difference.sum()),'texelError',texel_error,flush=True)
    report=dict(scope=__doc__,records=reports,actualInputSha256=sha(actual_path),stressInputSha256=sha(stress_path),
                packSha256=sha(pack),displayWarpSha256=sha(warp_path),scriptSha256=sha(Path(__file__)),
                limitations=['Each2x/8x image is evaluated directly at its own original SVG pixel centers; no resized lower-resolution image is used.',
                             'Point-sampled coverage isolates coefficient quantization; it is not Flutter antialiasing or a GPU Float32 arithmetic emulation.',
                             'The stress cases extrapolate a receiver plane and deliberately do not clip to authored floor fill or frozen FOV/range.',
                             'Zero raster boundary shift means no difference at these pixel centers, not an infinitesimal contour-equality proof.',
                             'No new visual tolerance or production masking policy is chosen by this diagnostic.'])
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
