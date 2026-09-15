"""Run the release widget probe and retain exit status and input fingerprints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--moving-index', type=int, default=4)
args = parser.parse_args()
assert 0 <= args.moving_index < 10
fixture = json.loads(args.fixture.read_text())
query_file = Path(fixture['queryFile'])
query_sha = hashlib.sha256(query_file.read_bytes()).hexdigest()
assert query_sha == fixture['querySha256'], 'Walking fixture bytes changed'
args.output.parent.mkdir(parents=True, exist_ok=True)
environment = os.environ.copy()
environment.update(ICARUS_AUDIT_OUTPUT=str(args.output.resolve()),
                   ICARUS_HEIGHT_FIXTURE=str(args.fixture.resolve()),
                   ICARUS_MOVING_INDEX=str(args.moving_index))
fingerprints = {}
for file in [args.binary, args.binary.parent / 'icarus_height.dll',
             args.binary.parent / 'data' / 'app.so', args.fixture, query_file]:
    fingerprints[str(file.resolve())] = hashlib.sha256(file.read_bytes()).hexdigest()
log_path = Path(str(args.output) + '.process.log')
with log_path.open('w') as log:
    process = subprocess.Popen([str(args.binary.resolve())], env=environment,
                               stdout=log, stderr=subprocess.STDOUT)
    try:
        code = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        code = None
record = {'pid': process.pid, 'exitCode': code, 'fingerprints': fingerprints,
          'movingIndex': args.moving_index}
Path(str(args.output) + '.inputs.json').write_text(json.dumps(record, indent=2))
print(json.dumps(record))
if code is None:
    raise RuntimeError('Probe did not close within 60 seconds; process left available for inspection.')
if code != 0:
    raise RuntimeError(f'Probe exited abnormally: {code}')
if json.loads(args.output.read_text())['status'] != 'passed':
    raise RuntimeError('Probe reported a failure')
