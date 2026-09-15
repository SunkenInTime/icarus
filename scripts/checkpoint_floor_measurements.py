"""Save complete independent source measurements before accepting another job."""
from concurrent.futures import ProcessPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import traceback


_worker_state = None


def initialize_worker(measure, state):
    global _worker_state
    _worker_state = (measure, state)


def run_worker(obligation):
    measure, state = _worker_state
    return measure(obligation, *state)


def checkpointed_measurements(obligations, measure, state, folder, fingerprint, workers=1):
    """Yield in source order; commit completed worker results immediately."""
    if workers < 1:
        raise ValueError('workers must be positive')
    folder = Path(folder)/fingerprint
    folder.mkdir(parents=True, exist_ok=True)
    keys = [item[0] for item in obligations]
    if len(set(keys)) != len(keys):
        raise ValueError('Duplicate source obligation')
    results, missing, failures = {}, [], []
    for item in obligations:
        path = folder/f'{item[0]}.json'
        if path.exists():
            record = json.loads(path.read_bytes())
            payload = json.dumps(record['result'], separators=(',', ':'), sort_keys=True).encode()
            assert record['fingerprint'] == fingerprint
            assert record['obligation'] == json.loads(json.dumps(item))
            assert record['resultSha256'] == hashlib.sha256(payload).hexdigest()
            results[item[0]] = record['result']
        else:
            missing.append(item)
    print(f'Resuming {len(results)} completed source records; measuring {len(missing)} with {workers} workers.', flush=True)

    def save(item, result):
        payload = json.dumps(result, separators=(',', ':'), sort_keys=True).encode()
        record = dict(fingerprint=fingerprint, obligation=item, result=result,
            resultSha256=hashlib.sha256(payload).hexdigest())
        path = folder/f'{item[0]}.json'
        temporary = path.with_suffix('.tmp')
        with temporary.open('w') as stream:
            json.dump(record, stream, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        results[item[0]] = result
        print(json.dumps(result['row']), flush=True)

    def failed(item, error):
        record = dict(fingerprint=fingerprint, obligation=item,
            error=f'{type(error).__name__}: {error}', traceback=traceback.format_exc())
        (folder/f'{item[0]}.error.json').write_text(json.dumps(record, indent=2)+'\n')
        failures.append(item[0])
        print(json.dumps(record), flush=True)

    if workers == 1:
        for item in missing:
            try:
                result = measure(item, *state)
            except Exception as error:
                failed(item, error)
            else:
                save(item, result)
    elif missing:
        with ProcessPoolExecutor(max_workers=workers, initializer=initialize_worker,
                initargs=(measure, state)) as pool:
            jobs = {pool.submit(run_worker, item): item for item in missing}
            for job in as_completed(jobs):
                try:
                    result = job.result()
                except Exception as error:
                    failed(jobs[job], error)
                else:
                    save(jobs[job], result)
    if failures:
        raise RuntimeError(f'Unfinished source measurements: {failures}. Other completed records were saved.')
    return [results[key] for key in keys]
