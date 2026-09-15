"""Pack reviewed map models without rounding any geometry or height."""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path

from bundle_split_svg_height import fields


def support_label(label):
    """Keep source instance names in evidence, not in the elevation menu."""
    label = label.split(';')[0].removeprefix('Summit ')
    locations = {'AtkPathA': 'A approach', 'AtkPathB': 'B approach',
                 'DefPathA': 'A defense approach', 'DefPathB': 'B defense approach',
                 'AtkSpawn': 'Attacker spawn', 'DefSpawn': 'Defender spawn',
                 'TopMid': 'Upper Mid', 'BSite': 'B Site', 'Bsite': 'B Site',
                 'ASite': 'A Site', 'CSite': 'C Site', 'BLink': 'B Link'}
    if '_' not in label:
        for source, readable in locations.items():
            label = label.replace(source, readable)
        return re.sub(r'\bCrate 6 Kingdom\b', 'Kingdom crate', label)
    location = next((readable for source, readable in locations.items()
                     if source in label), '')
    kinds = [('Shipping', 'Shipping container'), ('Container', 'Container'),
             ('Fountain', 'Fountain'), ('Scaffolding', 'Scaffolding'),
             ('Barrel', 'Barrel'), ('DyeVat', 'Vat'), ('Bench', 'Bench'),
             ('Pallet', 'Pallet'), ('Planter', 'Planter'), ('TarpCrate', 'Covered crate'),
             ('TempleCrate', 'Temple crate'), ('CardboardBox', 'Cardboard box'),
             ('Wood', 'Wooden crate'), ('Crate', 'Crate'), ('Box', 'Box'),
             ('Pillar', 'Pillar'), ('Generator', 'Generator'), ('Shelf', 'Shelf'),
             ('Monitor', 'Monitor'), ('VendingMachine', 'Vending machine'),
             ('APC', 'Vehicle'), ('Hay', 'Hay bale'), ('Wall', 'Wall'),
             ('Brick', 'Brick cover'), ('BathHouse', 'Bathhouse'),
             ('Corrugated', 'Metal cover'), ('Cover', 'Cover')]
    kind = next((readable for source, readable in kinds if source in label), 'Cover')
    return f'{location} {kind.lower()}' if location else kind


def pack(name,source_dir,output_dir):
    reports=[];pending=[]
    for side in ('attack','defense'):
        source=source_dir/f'{name}-{side}.json';source_bytes=source.read_bytes();model=json.loads(source_bytes)
        if model.get('map')!=name or model.get('side')!=side or model.get('version') not in [2,3]:
            raise ValueError('Map/side/schema mismatch')
        if model['version']==3 and not isinstance(model.get('ground',{}).get('standingTriangles'),list):
            raise ValueError('Physical ground eligibility must be explicit')
        if model.get('reviewStatus')!='reviewed' or model.get('pendingWallIds') or any(
                w['unknownHeight'] or any(high is None for _, high in w['bands'])
                for w in model['walls']):
            raise ValueError('Unreviewed model cannot be bundled')
        artwork=Path(model['sourceSvg']['path'])
        if hashlib.sha256(artwork.read_bytes()).hexdigest()!=model['sourceSvg']['sha256']:
            raise ValueError('Model artwork changed since extraction')
        packed=fields(model,('version','map','side','coordinateSpace','verticalSpace','viewBox','defaultCameraHeightMeters','ground'))
        packed['sourceSvg']=fields(model['sourceSvg'],('sha256',))
        packed['walls']=[fields(row,('id','rings','fillRule','bands','unknownHeight','floorElevationMeters')) for row in model['walls']]
        packed['supports']=[fields(row,('id','label','rings','fillRule','heightAboveFloorMeters','floorElevationMeters','surfaceElevationMeters','surfacePlane','automaticStandingAllowed')) for row in model['supports']]
        for support in packed['supports']:
            support['label']=support_label(support['label'])
        packed['receiver']=[fields(row,('rings','fillRule')) for row in model['receiver']]
        raw=json.dumps(packed,separators=(',',':'),allow_nan=False).encode();compressed=gzip.compress(raw,compresslevel=9,mtime=0)
        assert json.loads(gzip.decompress(compressed))==packed
        output=output_dir/f'{name}_svg_height_{side}.json.gz';pending.append((output,compressed))
        reports.append(dict(map=name,side=side,source=str(source),output=str(output),sourceSha256=hashlib.sha256(source_bytes).hexdigest(),
            sourceArtworkSha256=model['sourceSvg']['sha256'],bundledSha256=hashlib.sha256(compressed).hexdigest(),
            rawBytes=len(raw),bundledBytes=len(compressed),walls=len(packed['walls']),supports=len(packed['supports']),coordinatesRounded=False))
    # Validate the entire pair before writing either side.
    output_dir.mkdir(parents=True,exist_ok=True)
    for path,compressed in pending:path.write_bytes(compressed)
    return reports


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--maps',nargs='+',required=True);p.add_argument('--input',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--report',type=Path,required=True);a=p.parse_args();records=[]
    for name in a.maps:records.extend(pack(name,a.input,a.output))
    a.report.write_text(json.dumps(dict(records=records,totalBytes=sum(r['bundledBytes'] for r in records)),indent=2)+'\n')
    print(json.dumps(dict(maps=len(a.maps),totalBytes=sum(r['bundledBytes'] for r in records))))
