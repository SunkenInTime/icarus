"""Build and verify review candidates without replacing bundled map assets."""
import json
import argparse
import subprocess
import sys
import time
from pathlib import Path
from audit_all_map_gameplay_levels import OUT


def main():
 steps=[
  ('standing-clearance','audit_all_map_standing_clearance.py'),
  ('finite-wall-review','review_all_map_prop_wall_caps.py'),
  ('named-opening-review','review_all_map_named_openings.py'),
  ('physical-ground-build','refine_all_map_physical_ground.py'),
  ('split-vent-ground','review_split_vent_ground.py'),
  ('flat-support-build','build_all_map_gameplay_supports.py'),
  ('inclined-support-build','add_inclined_gameplay_supports.py'),
  ('tube-landing-review','review_icebox_tube_landing.py'),
  ('floor-classification','classify_all_map_floor_findings.py'),
  ('support-verification','verify_all_map_gameplay_supports.py'),
 ]
 parser=argparse.ArgumentParser();parser.add_argument('--from-step',choices=[label for label,_ in steps],default=steps[0][0]);args=parser.parse_args()
 start_index=next(i for i,(label,_) in enumerate(steps) if label==args.from_step)
 records=json.loads((OUT/'build-stages.json').read_text())[:start_index] if start_index else []
 steps=steps[start_index:]
 for label,script in steps:
  start=time.monotonic();log=OUT/f'{label}-final.log'
  print(label,'started',flush=True)
  with log.open('w') as output:result=subprocess.run([sys.executable,str(Path(__file__).parent/script)],stdout=output,stderr=subprocess.STDOUT)
  records.append(dict(step=label,exitCode=result.returncode,seconds=time.monotonic()-start,log=str(log)))
  (OUT/'build-stages.json').write_text(json.dumps(records,indent=2))
  print(label,'finished',result.returncode,flush=True)
  if result.returncode:raise SystemExit(result.returncode)


if __name__=='__main__':main()
