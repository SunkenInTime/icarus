"""Build a test-only outward-rounded BVH traversal; triangle policy is unchanged."""
from pathlib import Path
import subprocess,json,hashlib
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');out=REV/'native-rounded-profile-oracle-build';out.mkdir(exist_ok=True);source=Path('scripts/native_tactical_rays/reference_cast.cpp').resolve();s=source.read_text();s=s.replace('#include <cstdint>','#include <cstdint>\n#include <limits>')
needle='extern "C" EXPORT_CAST int nearest_triangle('
helper='''// Each stored input is enclosed by its adjacent representable values.
// Subtraction and division are rounded outward once more. This broadens only
// traversal candidates; the original triangle predicate still decides hits.
static double down(double x){return std::nextafter(x,-std::numeric_limits<double>::infinity());}
static double up(double x){return std::nextafter(x,std::numeric_limits<double>::infinity());}
extern "C" EXPORT_CAST int reference_slab_interval(double bmin,double bmax,double origin,double direction,double* result){
  const double dl=down(down(bmin)-up(origin)),dh=up(up(bmax)-down(origin));
  const double vl=down(direction),vh=up(direction);
  if(vl<=0 && vh>=0){result[0]=-INFINITY;result[1]=INFINITY;return 0;}
  const double q[]{dl/vl,dl/vh,dh/vl,dh/vh};
  result[0]=down(*std::min_element(q,q+4));result[1]=up(*std::max_element(q,q+4));return 1;
}
'''
s=s.replace(needle,helper+needle)
old='''      if(std::abs(direction[axis])<1e-15) {
        if(origin[axis]<box[axis] || origin[axis]>box[axis+3]){valid=false;break;}
      } else {
        double a=(box[axis]-origin[axis])/direction[axis],b=(box[axis+3]-origin[axis])/direction[axis];
        low=std::max(low,std::min(a,b));high=std::min(high,std::max(a,b));
        if(high<low){valid=false;break;}
      }'''
new='''      if(std::abs(direction[axis])<1e-15) {
        if(up(origin[axis])<down(box[axis]) || down(origin[axis])>up(box[axis+3])){valid=false;break;}
      } else {
        double interval[2];reference_slab_interval(box[axis],box[axis+3],origin[axis],direction[axis],interval);
        low=std::max(low,interval[0]);high=std::min(high,interval[1]);
        if(high<low){valid=false;break;}
      }'''
assert s.count(old)==1;s=s.replace(old,new);(out/'reference_cast.cpp').write_text(s);profiles=Path('scripts/native_wall_profiles/profiles.cpp').resolve();(out/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.14)
project(rounded_profile_oracle LANGUAGES CXX)
add_library(rounded_profile_oracle SHARED reference_cast.cpp "{profiles.as_posix()}")
target_compile_features(rounded_profile_oracle PRIVATE cxx_std_17)
target_compile_options(rounded_profile_oracle PRIVATE /O2 /fp:strict /EHsc)
''');cmake='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe';subprocess.run([cmake,'-S',str(out),'-B',str(out/'build')],check=True);subprocess.run([cmake,'--build',str(out/'build'),'--config','Release'],check=True);(out/'provenance.json').write_text(json.dumps({'originalReferenceSha256':hashlib.sha256(source.read_bytes()).hexdigest(),'profilesSha256':hashlib.sha256(profiles.read_bytes()).hexdigest(),'generatedReferenceSha256':hashlib.sha256(s.encode()).hexdigest(),'builderSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'trianglePredicateChanged':False,'scope':'Outward interval arithmetic around adjacent representable input coordinates for BVH slabs only.'},indent=2))
