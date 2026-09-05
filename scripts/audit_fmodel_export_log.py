"""Catch parse errors hidden behind a successful FModel export queue.

Writes an evidence report and exits 1 when the selected log interval has errors.
Use the export start time, not the start of an unrelated earlier session.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def audit(path, since, until=None):
    raw = Path(path).read_bytes()
    errors, warnings = [], []
    timestamp = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[(ERR|WRN)\] (.*)$')
    for line in raw.decode('utf-8-sig').splitlines():
        match = timestamp.match(line)
        if not match or match[1] < since or (until and match[1] > until):
            continue
        # Only severity headers are retained, not settings, keys or log payloads.
        (errors if match[2] == 'ERR' else warnings).append(match[3])
    classes = Counter()
    for error in errors:
        match = re.search(r'Could not read (\w+)(?: named| correctly)', error)
        classes[match[1] if match else 'other'] += 1
    return {'schemaVersion': 1, 'sourceLogSha256': hashlib.sha256(raw).hexdigest(),
            'sinceLocalTime': since, 'untilLocalTime': until,
            'status': 'parse-errors' if errors else 'no-error-headers-found',
            'certified': False, 'errorHeaders': len(errors),
            'warningHeaders': len(warnings), 'errorsByClass': dict(classes),
            'uniqueErrorHeaders': sorted(set(errors)),
            'limitations': ['An error-free log does not prove completeness or gameplay visibility.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log')
    parser.add_argument('--since', required=True, help='YYYY-MM-DD HH:MM:SS in log local time')
    parser.add_argument('--until')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    result = audit(args.log, args.since, args.until)
    Path(args.output).write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({k: result[k] for k in ['status', 'errorHeaders', 'warningHeaders', 'errorsByClass']}))
    raise SystemExit(1 if result['errorHeaders'] else 0)
