"""Reject measured runtime standing aliases absent from their reviewed source.

This is the reverse of a source-to-model floor comparison. It does not certify
physical-top aliases or gameplay accessibility. All thirteen maps require an
independent reviewed domain source.
Manual measured domains retain physical evidence but cannot authorize automatic
runtime standing aliases.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path


DEFAULT_MANIFEST = Path('scripts/data/map-standing-source-manifest.json')
DEFAULT_CERTIFICATE = Path('scripts/data/standing-source-certificate.json')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def text_sha(path):
    return hashlib.sha256(Path(path).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def source_domain_ids(source):
    records = source['domains']
    manual_records = source.get('manualDomains', [])
    automatic = {d['id'] for d in records}
    manual = {d['id'] for d in manual_records}
    assert len(automatic) == len(records), 'Duplicate automatic source identity'
    assert len(manual) == len(manual_records), 'Duplicate manual source identity'
    assert not automatic & manual, 'A source domain cannot be automatic and manual'
    return automatic, manual


def check_measured_aliases(name, model, automatic, manual):
    prefix = f'{name}-measured-'
    aliases = [s for s in model['supports'] if s['id'].startswith(prefix)]
    known = automatic | manual
    return dict(
        measuredAliases=len(aliases),
        unknown=[s['id'] for s in aliases if s['id'][len(prefix):] not in known],
        manualAliases=[s['id'] for s in aliases if s['id'][len(prefix):] in manual],
        automaticManualAliases=[s['id'] for s in aliases
            if s['id'][len(prefix):] in manual and s.get('automaticStandingAllowed')])


def audit(manifest_path, certificate_path):
    manifest = json.loads(manifest_path.read_bytes())
    maps = {p.name.removesuffix('_svg_height_attack.json.gz')
            for p in Path('assets/maps').glob('*_svg_height_attack.json.gz')}
    assert maps == set(manifest['maps']), 'Every map needs an explicit source disposition.'
    rows, failures = [], []
    for name, spec in manifest['maps'].items():
        source = Path(spec['sourcePath'])
        assert sha(source) == spec['sourceSha256'], (name, 'Source bytes changed')
        domains, manual = source_domain_ids(json.loads(source.read_bytes()))
        for side in ['attack', 'defense']:
            path = Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            model = json.loads(gzip.decompress(path.read_bytes()))
            check = check_measured_aliases(name, model, domains, manual)
            failed = bool(check['unknown'] or check['automaticManualAliases'])
            if failed:
                failures.append(dict(map=name, side=side, **check))
            rows.append(dict(map=name, side=side, asset=path.as_posix(), assetSha256=sha(path),
                             **check,
                             status='failed' if failed else 'passed'))
    if failures:
        raise ValueError(json.dumps(failures))
    certificate = dict(status='passed', scope=__doc__.strip(),
                       manifestSha256=text_sha(manifest_path), algorithmSha256=text_sha(Path(__file__)),
                       rows=rows)
    certificate_path.write_text(json.dumps(certificate, indent=2)+'\n')
    print(json.dumps(dict(status='passed', verifiedSides=sum(r['status'] == 'passed' for r in rows))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--certificate', type=Path, default=DEFAULT_CERTIFICATE)
    args = parser.parse_args()
    audit(args.manifest, args.certificate)
