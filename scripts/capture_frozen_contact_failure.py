"""Replay a frozen bake and preserve failing frame inputs without changing it."""
import argparse
import json
from pathlib import Path
import sys
import numpy as np


def main(stage,output):
    output.mkdir(exist_ok=False)
    sys.path.insert(0,str(stage/'compiler'))
    from run_frozen_contact_stage import main as run
    try:run(stage)
    except Exception as error:
        trace=error.__traceback__;frames=[];arrays={};exact={}
        while trace:
            frame=trace.tb_frame;local=frame.f_locals;record=dict(file=frame.f_code.co_filename,function=frame.f_code.co_name,line=trace.tb_lineno)
            for key in ['face_id','obj','region_cell','cell']:
                if key in local and isinstance(local[key],(int,np.integer)):record[key]=int(local[key])
            if 'family' in local:record['familyEdge']=local['family'].get('edge')
            for key in ['xyz','projected','data','part','weights','points','triangles','coords','bounds_data']:
                if key in local and isinstance(local[key],np.ndarray):arrays[f'{len(frames)}_{key}']=local[key]
            for key in ['initial','exact_part','rational_weights','source_construction']:
                if local.get(key) is not None:exact[f'{len(frames)}_{key}']=[[str(v) for v in row] for row in local[key]]
            frames.append(record);trace=trace.tb_next
        np.savez_compressed(output/'failure-arrays.npz',**arrays)
        (output/'failure-exact.json').write_text(json.dumps(exact,indent=2)+'\n')
        report=dict(error=repr(error),frames=frames,stage=str(stage),compilerModified=False)
        (output/'failure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2),flush=True)
        raise


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('stage',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();main(args.stage,args.output)
