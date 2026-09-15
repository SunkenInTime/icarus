"""Rebuild and independently check every physical standing candidate.

Navigation, source names and connected-component labels never gate this pass.
Installation remains a separate command after production cone verification.
"""
import argparse
import subprocess
import sys
from pathlib import Path
from audit_all_map_gameplay_levels import MAPS


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    p.add_argument('--verify-only',action='store_true');args=p.parse_args()
    scripts=Path(__file__).parent
    for name in args.maps:
        if not args.verify_only:
            subprocess.run([sys.executable,str(scripts/'build_all_physical_standing_surfaces.py'),name],check=True)
        subprocess.run([sys.executable,str(scripts/'remove_degenerate_standing_rings.py'),name],check=True)
        checked=subprocess.run([sys.executable,str(scripts/'verify_all_physical_standing_surfaces.py'),name])
        if checked.returncode:
            subprocess.run([sys.executable,str(scripts/'refine_physical_standing_edges.py'),name],check=True)
            subprocess.run([sys.executable,str(scripts/'verify_all_physical_standing_surfaces.py'),name],check=True)
