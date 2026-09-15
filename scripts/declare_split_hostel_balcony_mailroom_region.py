"""Connected two-contour field, including shared balcony and local U frontage."""
import gzip,json
import numpy as np
from build_split_connected_tower import REV
from declare_split_component7_catwalk_region import declaration as catwalk
from declare_split_mailroom_region import declaration as mailroom
from declare_split_component2_cover_region import grid


def declaration():
    family=catwalk();u=mailroom();bands=family['sourceProfileBands']
    def set_band(span,source):
        entry=next(b for b in bands['x'] if span in b['spans']);entry['source']=source
    set_band(190,[91.4351119795615,92.76231042151966])
    set_band(196,[172.6895480475297,173.94621064241244])
    set_band(192,[103.35788113844188,104.08883206370102])
    set_band(198,[146.40285999690823,147.22792023859125])
    next(b for b in bands['y'] if b['spans']==[191])['source']=[110.36283204769245,111.67908360060244]
    next(b for b in bands['y'] if b['spans']==[201])['source']=[135.1632328966043,136.7274449090715]
    bands['x'].extend(u['sourceProfileBands']['x'])
    next(b for b in bands['x'] if b['spans']==[164])['source'][0]=161.9240526048152
    bands['x'].extend([dict(spans=[166],source=[187.32079604728955,188.57745491366785],target=188.697),dict(spans=[168],source=[205.00804560165957,205.00806051567736],target=204.646)])
    bands['y'].extend(u['sourceProfileBands']['y'])
    bands['y'].append(dict(spans=[165],source=[167.50076073741712,167.50076073741712],target=167.282))
    def knots(entries,outer,guards):
        points={v:v for v in [*outer,*guards]}
        for b in entries:
            for value in b['source']:points[value]=b['target']
        values=sorted(points);return values,[points[v] for v in values]
    xs,tx=knots(bands['x'],[88.,207.],[206.])
    ys,ty=knots(bands['y'],[100.,232.],[228.])
    family.update(grid(xs,ys,lambda x,y:[float(np.interp(x,xs,tx)),float(np.interp(y,ys,ty))]))
    packets=[REV/'split-component7-source-review-v1/full-source-context.npz',REV/'split-component7-catwalk-join-review-v1/hostel-catwalk-join-full-source.npz',REV/'split-original-scene-connected-source-review-v1/clove-mailroom-recess-full-source.npz']
    packets.extend(REV/'split-component7-remaining-assembly-review-v1'/f'{name}-full-source.npz' for name in ['hostel-attached-frames','tower-attached-doorframe','balcony-connected-other-unit'])
    ids=set();objects=set()
    for path in packets:
        raw=np.load(path);ids.update(raw['sourceFaceIds'].tolist());objects.update(raw['sourceObjectIds'].tolist())
    family['reviewedSourceFaces']=sorted(ids);family['objects']=sorted(objects)
    family['reviewedAuthoredSpans'].extend(u['reviewedAuthoredSpans'])
    p=json.loads(gzip.decompress((REV/'split-connected-contour-proposals-v2/component-6.json.gz').read_bytes()))
    family['reviewedAuthoredSpans'].extend(dict(completeSpan=s['completeSpan'],legacyStraightEdgeIndex=s['legacyStraightEdgeIndex'],startSvg=s['authoredEndpoints'][0],endSvg=s['authoredEndpoints'][1]) for s in p['spans'] if s['completeSpan'] in [164,165,166,167])
    family['status']='Connected source proposal pending topology, exact boundary joins and original-height gates.'
    family['role']='One field for the connected hostel, both balcony units, attached frames and finite mailroom U. Preserve every original Z/UV profile. Other props and pipe roles remain outside this declaration.'
    family['sourcePacketFiles']=[str(p) for p in packets]
    family['unresolvedFrontiers']=['U to retained7609/7612 header at184/185 requires shared endpoint proof before bake.','Right continuation168/169 is finite; unchanged far fragments are not claimed to match authored contour.']
    return family


if __name__=='__main__':
    family=declaration();out=REV/'split-hostel-balcony-mailroom-region-proposal-v1';out.mkdir(exist_ok=True);(out/'region-declaration.json').write_text(json.dumps(family,indent=2));print(out)
