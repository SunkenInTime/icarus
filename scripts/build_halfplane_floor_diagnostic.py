"""Build an isolated, switchable half-plane cache experiment; no existing DLL edits."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');OUT=ROOT/'native-floor-halfplanes-build';OUT.mkdir(exist_ok=True)
original=Path('scripts/native_tactical_rays/floor_atlas.cpp').resolve();text=original.read_text()
text=text.replace('struct FloorClipCache {','''static thread_local bool ordered_halfplanes=false;
extern "C" EXPORT_ATLAS void set_ordered_floor_halfplanes(int enabled){ordered_halfplanes=enabled!=0;}
struct HalfPlane {double dx,dy,value,rank;};
struct FloorClipCache {
  std::vector<HalfPlane> ordered,ordered_triangles;''')
needle='  floor_clip_cache=std::move(cache);'
assert text.count(needle)==1
text=text.replace(needle,'''  if(ordered_halfplanes) {
    cache->ordered.resize(vertices);cache->ordered_triangles.resize(count*3);
    for(int cell=0;cell<count;cell++) {
      const int first=ranges[cell*2],size=ranges[cell*2+1];
      for(int i=0;i<size;i++) {
        const double* a=polygons+(first+i)*2;const double* b=polygons+(first+(i+1)%size)*2;
        double dx=b[0]-a[0],dy=b[1]-a[1],value=cache->values[first+i],length=std::hypot(dx,dy);
        cache->ordered[first+i]={dx,dy,value,length?value/length:value};
      }
      auto less=[](const HalfPlane& a,const HalfPlane& b){return a.rank<b.rank;};
      std::stable_sort(cache->ordered.begin()+first,cache->ordered.begin()+first+size,less);
      const double* triangle=triangles+cell*6;
      for(int i=0;i<3;i++) {
        const double* a=triangle+i*2;const double* b=triangle+((i+1)%3)*2;
        double dx=b[0]-a[0],dy=b[1]-a[1],value=cache->triangle_values[cell*3+i],length=std::hypot(dx,dy);
        cache->ordered_triangles[cell*3+i]={dx,dy,value,length?value/length:value};
      }
      std::stable_sort(cache->ordered_triangles.begin()+cell*3,cache->ordered_triangles.begin()+cell*3+3,less);
    }
  }
'''+needle)
start=text.index('    for(int i=0;i<size && hi>=lo;++i) {',text.index('  for(int cell:cells)'))
end=text.index('    if(hi-lo<=1e-11)continue;',start)
old=text[start:end]
new='''    if(cache && !cache->ordered.empty()) {
      for(int i=0;i<size && hi>=lo;i++) {
        const auto& edge=cache->ordered[first+i];const double value=edge.value;
        const double slope=sign*cross2(edge.dx,edge.dy,vx,vy);
        if(std::abs(slope)<1e-14) {if(value<0)hi=-1;}
        else if(slope>0)lo=std::max(lo,-value/slope);else hi=std::min(hi,-value/slope);
      }
    } else {
'''+old+'    }\n'
text=text[:start]+new+text[end:]
start=text.index('    for(int edge=0;edge<3 && original_hi>=original_lo;++edge) {')
end=text.index('    if(original_hi-original_lo>=1e-11)',start)
old=text[start:end]
new='''    if(cache && !cache->ordered_triangles.empty()) {
      for(int i=0;i<3 && original_hi>=original_lo;i++) {
        const auto& edge=cache->ordered_triangles[cell*3+i];const double value=edge.value;
        const double slope=orientation*cross2(edge.dx,edge.dy,vx,vy);
        if(std::abs(slope)<1e-14) {if(value<0)original_hi=-1;}
        else if(slope>0)original_lo=std::max(original_lo,-value/slope);else original_hi=std::min(original_hi,-value/slope);
      }
    } else {
'''+old+'    }\n'
text=text[:start]+new+text[end:];(OUT/'floor_atlas.cpp').write_text(text)
cone=Path('scripts/native_tactical_rays/floor_cone.cpp').resolve();ref=Path('scripts/native_tactical_rays/reference_cast.cpp').resolve()
(OUT/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.14)
project(floor_halfplanes LANGUAGES CXX)
add_library(floor_halfplanes SHARED floor_atlas.cpp "{cone.as_posix()}" "{ref.as_posix()}")
target_compile_features(floor_halfplanes PRIVATE cxx_std_17)
target_compile_options(floor_halfplanes PRIVATE /O2 /fp:strict /EHsc)
''')
cmake='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
subprocess.run([cmake,'-S',str(OUT),'-B',str(OUT/'build')],check=True);subprocess.run([cmake,'--build',str(OUT/'build'),'--config','Release'],check=True)
(OUT/'provenance.json').write_text(json.dumps({'sourceHashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [original,cone,ref,Path(__file__)]},'generatedSha256':hashlib.sha256(text.encode()).hexdigest(),'scope':'Origin-local edge delta cache and rejection order only; all original edge values/divisions/thresholds and floor policy retained.'},indent=2))
