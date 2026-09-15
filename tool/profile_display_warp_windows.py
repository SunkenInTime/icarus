"""Isolated Windows profile runs using one immutable native scene and display W."""
import argparse,hashlib,json,os,shutil,subprocess,time
from pathlib import Path

def sha(path):
 digest=hashlib.sha256()
 with path.open('rb') as stream:
  for chunk in iter(lambda:stream.read(4*1024*1024),b''):digest.update(chunk)
 return digest.hexdigest()

def main():
 p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--allow-post-report-exit-failure',action='store_true');args=p.parse_args()
 root=Path('E:/IcarusWorldAudit/2026-09-06');rev=root/'tactical-visibility-revision';args.output.mkdir(parents=True,exist_ok=True)
 config=json.loads((rev/'staged-display-split-v1/candidate-config.json').read_text())['maps']['split'];fixture=root/'compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json';fd=json.loads(fixture.read_text());queries=Path(fd['queryFile']);assert sha(queries)==fd['querySha256']
 bundle=args.output/'app'
 if bundle.exists():raise ValueError('Use a new profile output to preserve prior executable evidence')
 shutil.copytree(args.build,bundle)
 binary=bundle/'icarus.exe';native=Path(config['folder']);warp=Path(config['displayWarpFile']);assert sha(warp)==config['displayWarpSha256']
 inputs=[binary,bundle/'data/app.so',fixture,queries,Path(config['library']),*sorted(p for p in native.iterdir()if p.is_file()),Path(config['groundFieldFile']),warp]
 bindings={'scope':'Offline source-floor diagnostic; same source input meshes, production renderer with optional display projection. No Hive or user library is opened.','inputs':[{'path':str(f.resolve()),'sha256':sha(f),'bytes':f.stat().st_size}for f in inputs]}
 bindingsPath=args.output/'input-bindings.json';bindingsPath.write_text(json.dumps(bindings,indent=2))
 env=os.environ.copy();env.update(ICARUS_HEIGHT_FIXTURE=str(fixture),ICARUS_HEIGHT_DIRECTORY=str(native),ICARUS_HEIGHT_DLL=config['library'],ICARUS_DISPLAY_WARP_FILE=str(warp),ICARUS_DISPLAY_WARP_SHA256=config['displayWarpSha256'],ICARUS_TACTICAL_GROUND_FILE=config['groundFieldFile'],ICARUS_FROZEN_REPLAY='1',ICARUS_REPLAY_FRAMES='1440',ICARUS_WARMUP_FRAMES='144',ICARUS_CACHE_IMAGES='1',ICARUS_INPUT_BINDINGS=str(bindingsPath.resolve()))
 # These redirections are defense in depth. The harness itself never opens Hive.
 for name in ['APPDATA','LOCALAPPDATA']:
  folder=args.output/name.lower();folder.mkdir(exist_ok=True);env[name]=str(folder.resolve())
 results=[]
 for i,enabled in enumerate([False,True,True,False]):
  mode='on'if enabled else'off';output=args.output/f'{i+1:02d}-warp-{mode}.json';env.update(ICARUS_DISPLAY_WARP_ENABLED='1'if enabled else'0',ICARUS_AUDIT_OUTPUT=str(output.resolve()))
  started=time.time()
  with output.with_suffix('.process.log').open('w')as log:
   process=subprocess.Popen([str(binary.resolve())],cwd=bundle,env=env,stdout=log,stderr=subprocess.STDOUT)
   code=process.wait(timeout=90)
  report=json.loads(output.read_text())
  output.with_suffix('.exit.json').write_text(json.dumps({'exitCode':code,'exitHex':hex(code),'reportStatus':report['status'],'accepted':code==0 and report['status']=='complete'},indent=2))
  assert report['status']=='complete' and (code==0 or args.allow_post_report_exit_failure),f'Exit{hex(code)}, reportstatus={report["status"]}; full data preserved in{output}'
  report['processExitCode']=code
  assert report['frozenReplay'] and report['displayWarpEnabled']==enabled
  assert report['paintedPoseCount']>100 and report['matchedPaintTimings']>100,'Insufficient actual paint samples'
  assert len(report['sourceMeshSha256'])==10
  if results:
   assert report['sourceMeshSha256']==results[0]['sourceMeshSha256']
   assert report['effectiveQueriesSha256']==results[0]['effectiveQueriesSha256']
  results.append(report)
  print(json.dumps({'run':i+1,'warp':mode,'elapsedSeconds':time.time()-started,'refresh':report['displayRefreshRate'],'requested':report['requestedPoseCount'],'painted':report['paintedPoseCount'],'render':report['renderSummaries'],'cache':report['imageCache']}),flush=True)
 summary={'scope':bindings['scope'],'processesExitedCleanly':all(r['processExitCode']==0 for r in results),'acceptance':'pre-exit timing diagnostic only'if any(r['processExitCode']!=0 for r in results)else'completed isolated renderer profile','sourceMeshHashesIdentical':True,'effectiveQueryHashesIdentical':True,'order':['off','on','on','off'],'runs':[{k:r[k]for k in ['processExitCode','displayWarpEnabled','displayRefreshRate','devicePixelRatio','requestedReplayHz','warmupFrames','fixturePoseCount','requestedPoseCount','paintedPoseCount','steadyDistinctDrawStamps','steadyDrawIntervalsMicros','steadyDrawIntervalsOver144Hz','steadyDrawIntervalsOverTwo144HzFrames','renderSummaries','imageCache','sourceMeshBytes','residentBeforeCloseBytes']}for r in results]}
 (args.output/'comparison.json').write_text(json.dumps(summary,indent=2))
if __name__=='__main__':main()
