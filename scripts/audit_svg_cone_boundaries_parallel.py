"""Run the existing GEOS contact audit in bounded, resumable batches."""
import argparse
from concurrent.futures import ProcessPoolExecutor, wait, FIRST_COMPLETED
import gzip
import hashlib
import json
import os
from pathlib import Path
import re

import numpy as np
import shapely

from audit_svg_cone_boundaries import audit
from compile_reviewed_svg_height_map import polygon


_models = {}
BATCH_SIZE = 64


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def initialize(models):
    global _models
    _models = {}
    for key, path, expected in models:
        path = Path(path)
        assert sha(path) == expected, path
        data = json.loads(gzip.decompress(path.read_bytes()))
        shapes = np.array([polygon(w) for w in data['walls']], dtype=object)
        _models[tuple(key)] = (data['walls'], shapely.STRtree(shapes), shapes)


def measure(lines):
    intervals, issues = 0, []
    for line in lines:
        row = json.loads(line)
        count, found = audit(row, *_models[(row['map'], row['side'])])
        intervals += count
        if found:
            issues.append(dict(row, issues=found,
                maximumErrorSvg=max(abs(item['errorSvg']) for item in found)))
    return dict(cones=len(lines), intervals=intervals, issues=issues)


def batches(path):
    with path.open() as source:
        lines = []
        for line in source:
            lines.append(line)
            if len(lines) == BATCH_SIZE:
                yield lines
                lines = []
        if lines:
            yield lines


def result_hash(result):
    return hashlib.sha256(json.dumps(result, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def run(output, models=None, workers=6):
    if workers < 1:
        raise ValueError('workers must be positive')
    export_path = output/'export-summary.json'
    export_hash = sha(export_path)
    exported = json.loads(export_path.read_bytes())
    cones_path = output/'cones.jsonl'
    cone_hash = sha(cones_path)
    assert cone_hash == exported['conesSha256']
    paths = []
    for asset, expected in sorted(exported['assetSha256'].items()):
        match = re.fullmatch(r'assets/maps/(.+)_svg_height_(attack|defense)\.json\.gz', asset)
        if match:
            key = match.groups()
            path = models/key[0]/f'candidate-{key[1]}.json.gz' if models else Path(asset)
            assert sha(path) == expected, path
            paths.append((key, str(path), expected))
    assert paths
    algorithms = {name: sha(Path(__file__).with_name(name)) for name in
        ['audit_svg_cone_boundaries_parallel.py', 'audit_svg_cone_boundaries.py', 'compile_reviewed_svg_height_map.py']}
    inputs = dict(conesSha256=cone_hash, assets=paths, algorithms=algorithms, batchSize=BATCH_SIZE)
    fingerprint = result_hash(inputs)
    checkpoint = output/'contact-checkpoints'/fingerprint
    checkpoint.mkdir(parents=True, exist_ok=True)
    results = {}
    resumed = 0

    def commit(index, result):
        record = dict(fingerprint=fingerprint, index=index, result=result, resultSha256=result_hash(result))
        path = checkpoint/f'{index}.json'
        temporary = path.with_suffix('.tmp')
        with temporary.open('w') as stream:
            json.dump(record, stream, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        results[index] = result
        if len(results) % 20 == 0:
            print(f'Saved {len(results)} cone batches.', flush=True)

    with ProcessPoolExecutor(max_workers=workers, initializer=initialize, initargs=(paths,)) as pool:
        pending = {}

        def collect():
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            for job in done:
                commit(pending.pop(job), job.result())

        for index, lines in enumerate(batches(cones_path)):
            path = checkpoint/f'{index}.json'
            if path.exists():
                record = json.loads(path.read_bytes())
                assert record['fingerprint'] == fingerprint and record['index'] == index
                assert record['resultSha256'] == result_hash(record['result'])
                assert record['result']['cones'] == len(lines)
                results[index] = record['result']
                resumed += 1
                continue
            pending[pool.submit(measure, lines)] = index
            if len(pending) >= workers * 2:
                collect()
        while pending:
            collect()
    assert sha(cones_path) == cone_hash
    assert sha(export_path) == export_hash
    for _, path, expected in paths:
        assert sha(Path(path)) == expected, path
    ordered = [results[index] for index in sorted(results)]
    issues = [item for result in ordered for item in result['issues']]
    issues.sort(key=lambda row: -row['maximumErrorSvg'])
    report = dict(cones=sum(r['cones'] for r in ordered), checkedIntervals=sum(r['intervals'] for r in ordered),
        flaggedCones=len(issues), flaggedIntervals=sum(len(row['issues']) for row in issues),
        conesSha256=cone_hash, assetSha256=exported['assetSha256'], thresholdSvg=.002,
        algorithmSha256=algorithms, checkpointFingerprint=fingerprint, resumedBatches=resumed,
        scope='Independent GEOS ray intersections against active painted footprints. Height semantics require separate source/gameplay review.',
        cases=issues)
    assert report['cones'] == exported['emitted']
    (output/'boundary-audit.json').write_text(json.dumps(report, separators=(',', ':'))+'\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'cases'}))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--models', type=Path)
    parser.add_argument('--workers', type=int, default=6)
    args = parser.parse_args()
    run(args.output, args.models, args.workers)
