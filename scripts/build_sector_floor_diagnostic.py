"""Build isolated observer-local convex edge sectors; no production DLL changes."""
from pathlib import Path
import hashlib,json,subprocess,sys
lazy='--lazy' in sys.argv
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');out=REV/('native-floor-sectors-lazy-build' if lazy else 'native-floor-sectors-build');out.mkdir(exist_ok=True)
original=Path('scripts/native_tactical_rays/floor_atlas.cpp').resolve();s=original.read_text().replace('#include <vector>','#include <vector>\n#include <set>')
helper=r'''
static thread_local bool sector_index_enabled=false;
static thread_local double sector_counts[5]{};
extern "C" EXPORT_ATLAS void set_floor_sector_index(int value){sector_index_enabled=value!=0;}
extern "C" EXPORT_ATLAS void get_floor_sector_counts(double* output){std::copy(sector_counts,sector_counts+5,output);}
struct FloorSector {double angle;AngularVector ray;int first=-1,second=-1;};
struct FloorSectors {std::vector<FloorSector> sectors;};
static double positive_angle(double y,double x){double a=std::atan2(y,x);return a<0?a+2*std::acos(-1.):a;}
static FloorSectors build_floor_sectors(const double* polygon,int n,const double* values,double sign,const double* origin) {
  FloorSectors result;if(n<8)return result;
  const double tau=2*std::acos(-1.);double scale=std::max({1.,std::abs(origin[0]),std::abs(origin[1])});
  for(int i=0;i<n*2;i++)scale=std::max(scale,std::abs(polygon[i]));
  const double uncertainty=128*std::numeric_limits<double>::epsilon()*scale*scale;
  std::vector<AngularVector> rays;std::vector<double> angles;std::vector<int> order(n);
  for(int i=0;i<n;i++) {
    if(std::abs(values[i])<=uncertainty)return result;
    const double* a=polygon+i*2;const double* b=polygon+((i+1)%n)*2;const double* c=polygon+((i+2)%n)*2;
    if(sign*cross2(b[0]-a[0],b[1]-a[1],c[0]-b[0],c[1]-b[1]) < -uncertainty)return result;
    rays.push_back(angular_vector(a[0],a[1],origin[0],origin[1]));angles.push_back(positive_angle(rays.back().y,rays.back().x));order[i]=i;
  }
  std::sort(order.begin(),order.end(),[&](int a,int b){return angles[a]<angles[b];});
  std::vector<int> ranks(n);std::vector<std::vector<int>> starts(n),ends(n);std::vector<std::array<int,2>> arcs(n);
  for(int i=0;i<n;i++){if(i && angles[order[i]]==angles[order[i-1]])return result;ranks[order[i]]=i;}
  for(int i=0;i<n;i++) {
    int a=i,b=(i+1)%n;const auto determinant=angular_cross(rays[a],rays[b]);
    if(std::abs(determinant[0])<=determinant[1])return result;
    if(determinant[0]<0)std::swap(a,b);
    starts[ranks[a]].push_back(i);ends[ranks[b]].push_back(i);arcs[i]={a,b};
  }
  double mid=(angles[order[0]]+angles[order[1]])*.5;
  auto wrap=[&](double x){return x<0?x+tau:x;};std::set<int> active;
  for(int i=0;i<n;i++){const auto arc=arcs[i];if(wrap(mid-angles[arc[0]])<wrap(angles[arc[1]]-angles[arc[0]]))active.insert(i);}
  for(int i=0;i<n;i++) {
    if(i){for(int edge:ends[i])active.erase(edge);for(int edge:starts[i])active.insert(edge);}
    if(active.size()>2)return FloorSectors{};
    FloorSector sector{angles[order[i]],rays[order[i]]};auto it=active.begin();
    if(it!=active.end())sector.first=*it++;if(it!=active.end())sector.second=*it;
    result.sectors.push_back(sector);
  }
  return result;
}
static const FloorSector* select_floor_sector(const FloorSectors& index,double angle,double vx,double vy) {
  const auto& table=index.sectors;if(table.empty())return nullptr;
  auto it=std::upper_bound(table.begin(),table.end(),angle,[](double a,const FloorSector& b){return a<b.angle;});
  const int i=it==table.begin()?int(table.size())-1:int(it-table.begin())-1;const int j=(i+1)%table.size();
  const double tau=2*std::acos(-1.);double left=angle-table[i].angle,right=table[j].angle-angle;if(left<0)left+=tau;if(right<0)right+=tau;
  // atan2 identifies a candidate sector only. Vertex uncertainty returns to
  // the unchanged full clip. Cross-product error bounds also cover rounded
  // vertex-minus-origin subtraction. The extra angular guard is fallback,
  // never a geometric expansion or distance acceptance tolerance.
  if(std::min(left,right)<=1e-12)return nullptr;
  const AngularVector ray{vx,vy,0,0};const auto a=angular_cross(table[i].ray,ray),b=angular_cross(ray,table[j].ray);
  if(std::abs(a[0])<=a[1] || std::abs(b[0])<=b[1])return nullptr;
  return &table[i];
}
extern "C" EXPORT_ATLAS void probe_floor_sector_clip(const double* polygon,int n,const double* origin,const double* rays,int count,int enabled,double* output) {
  double area=0;for(int i=0;i<n;i++){const double* a=polygon+i*2;const double* b=polygon+((i+1)%n)*2;area+=cross2(a[0],a[1],b[0],b[1]);}
  const double sign=area>=0?1:-1;std::vector<double> values(n);
  for(int i=0;i<n;i++){const double* a=polygon+i*2;const double* b=polygon+((i+1)%n)*2;values[i]=sign*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);}
  auto index=enabled?build_floor_sectors(polygon,n,values.data(),sign,origin):FloorSectors{};
  for(int q=0;q<count;q++) {
    const double vx=rays[q*2],vy=rays[q*2+1];const auto* sector=enabled?select_floor_sector(index,positive_angle(vy,vx),vx,vy):nullptr;
    double lo=0,hi=1;int tested=0;const int selected[]{sector?sector->first:-1,sector?sector->second:-1};
    if(sector && selected[0]<0)hi=-1;
    for(int j=0;j<(sector?2:n) && hi>=lo;j++) {
      const int i=sector?selected[j]:j;if(i<0)break;++tested;
      const double* a=polygon+i*2;const double* b=polygon+((i+1)%n)*2;const double slope=sign*cross2(b[0]-a[0],b[1]-a[1],vx,vy);
      if(std::abs(slope)<1e-14){if(values[i]<0)hi=-1;}
      else if(slope>0)lo=std::max(lo,-values[i]/slope);else hi=std::min(hi,-values[i]/slope);
    }
    output[q*4]=lo;output[q*4+1]=hi;output[q*4+2]=sector?1:0;output[q*4+3]=tested;
  }
}
'''
s=s.replace('struct FloorClipCache {',helper+'\nstruct FloorClipCache {\n  std::vector<FloorSectors> sectors;')
needle='  floor_clip_cache=std::move(cache);';assert s.count(needle)==1
s=s.replace(needle,'''  std::fill(sector_counts,sector_counts+5,0.);
  if(sector_index_enabled) {
    cache->sectors.resize(count);
    for(int cell=0;cell<count;cell++) {
      const int first=ranges[cell*2],size=ranges[cell*2+1];
      cache->sectors[cell]=build_floor_sectors(polygons+first*2,size,cache->values.data()+first,cache->signs[cell],origin);
      if(!cache->sectors[cell].sectors.empty()){++sector_counts[0];sector_counts[1]+=cache->sectors[cell].sectors.size();}
    }
  }
'''+needle)
s=s.replace('  for(int cell:cells) {','  const double sector_angle=positive_angle(vy,vx);\n  for(int cell:cells) {')
start=s.index('    for(int i=0;i<size && hi>=lo;++i) {',s.index('  for(int cell:cells)'));end=s.index('    if(hi-lo<=1e-11)continue;',start);old=s[start:end]
s=s[:start]+'''    const auto* sector=cache && !cache->sectors.empty()?select_floor_sector(cache->sectors[cell],sector_angle,vx,vy):nullptr;
    if(sector) {
      ++sector_counts[2];const int chosen[]{sector->first,sector->second};
      if(chosen[0]<0){++sector_counts[3];continue;}
      for(int i:chosen) {
        if(i<0 || hi<lo)break;++sector_counts[4];
        const double* a=polygons+(first+i)*2;const double* b=polygons+(first+(i+1)%size)*2;
        const double value=cache->values[first+i];const double slope=sign*cross2(b[0]-a[0],b[1]-a[1],vx,vy);
        if(std::abs(slope)<1e-14){if(value<0)hi=-1;}
        else if(slope>0)lo=std::max(lo,-value/slope);else hi=std::min(hi,-value/slope);
      }
    } else {
'''+old+'    }\n'+s[end:]
if lazy:
    s=s.replace('std::vector<FloorSectors> sectors;', 'mutable std::vector<FloorSectors> sectors;\n  mutable std::vector<uint8_t> sectors_ready;')
    begin=s.index('    for(int cell=0;cell<count;cell++) {',s.index('  if(sector_index_enabled) {'))
    end=s.index('\n  }\n  floor_clip_cache=',begin)
    s=s[:begin]+'    cache->sectors_ready.resize(count,0);'+s[end:]
    needle='    const auto* sector=cache && !cache->sectors.empty()?'
    s=s.replace(needle,'''    if(cache && !cache->sectors.empty() && !cache->sectors_ready[cell]) {
      cache->sectors[cell]=build_floor_sectors(polygons+first*2,size,cache->values.data()+first,sign,origin);
      cache->sectors_ready[cell]=1;
      if(!cache->sectors[cell].sectors.empty()){++sector_counts[0];sector_counts[1]+=cache->sectors[cell].sectors.size();}
    }
'''+needle)
(out/'floor_atlas.cpp').write_text(s);cone=Path('scripts/native_tactical_rays/floor_cone.cpp').resolve();ref=Path('scripts/native_tactical_rays/reference_cast.cpp').resolve()
(out/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.14)
project(floor_sectors LANGUAGES CXX)
add_library(floor_sectors SHARED floor_atlas.cpp "{cone.as_posix()}" "{ref.as_posix()}")
target_compile_features(floor_sectors PRIVATE cxx_std_17)
target_compile_options(floor_sectors PRIVATE /O2 /fp:strict /EHsc)
''')
cmake='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
subprocess.run([cmake,'-S',str(out),'-B',str(out/'build')],check=True);subprocess.run([cmake,'--build',str(out/'build'),'--config','Release'],check=True)
(out/'provenance.json').write_text(json.dumps(dict(sourceHashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [original,cone,ref,Path(__file__)]},generatedSha256=hashlib.sha256(s.encode()).hexdigest(),scope=__doc__),indent=2))
