// Bounded native port of the frozen adaptive diagnostic. This is not an
// exhaustive angular-event sweep or a production cone implementation.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <map>
#include <stdexcept>
#include <vector>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API __attribute__((visibility("default")))
#endif
extern "C" int cast_floor_atlas(int,int,const double*,const int32_t*,const double*,const double*,const int64_t*,const uint8_t*,const double*,const int32_t*,const int32_t*,const uint8_t*,const double*,const uint8_t*,const double*,const int32_t*,const int32_t*,const double*,const int32_t*,const int32_t*,const int32_t*,const int32_t*,const uint8_t*,const double*,const double*,double,double,double*,int);
extern "C" int nearest_triangle(const double*,const uint32_t*,const double*,const int32_t*,const double*,const double*,double,double,int,const int32_t*,int,double*);
extern "C" void begin_floor_clip_cache(int,const double*,const int32_t*,const double*,const double*);
extern "C" void end_floor_clip_cache();
extern "C" int floor_profile_enabled();
using AlphaCallback=int(*)(int,double,double);
struct ConeContext {
  int cells,transits;std::array<const void*,21> a;std::array<const void*,5> source;AlphaCallback alpha;
  std::vector<double> rows=std::vector<double>(80000);
  int queries=0,source_calls=0,alpha_calls=0,pieces=0;bool limited=false;
  bool profiling=false;double profile[5]{};
  template<class T>const T* p(int i)const{return static_cast<const T*>(a[i]);}
  double ray(const double* origin,double angle,double distance) {
    const double direction[]{std::cos(angle),std::sin(angle)};
    int count=cast_floor_atlas(cells,transits,p<double>(0),p<int32_t>(1),p<double>(2),p<double>(3),p<int64_t>(4),p<uint8_t>(5),p<double>(6),p<int32_t>(7),p<int32_t>(8),p<uint8_t>(9),p<double>(10),p<uint8_t>(11),p<double>(12),p<int32_t>(13),p<int32_t>(14),p<double>(15),p<int32_t>(16),p<int32_t>(17),p<int32_t>(18),p<int32_t>(19),p<uint8_t>(20),origin,direction,distance,.35,rows.data(),10000);
    if(count<0)throw std::runtime_error("piece capacity");
    ++queries;pieces+=count;double best=distance;
    for(int i=0;i<count;++i) {
      const double* row=rows.data()+i*8;const double lo=row[0],hi=row[1];
      best=std::min(best,row[5]);
      if(row[7]) {
        const auto source_begin=profiling?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
        ++source_calls;const int cell=int(row[4]);const double flat[]{0,0,row[2]};const double* plane=cell>=0?p<double>(2)+cell*3:flat;
        const double endxy[]{origin[0]+direction[0]*distance,origin[1]+direction[1]*distance};
        const double start[]{origin[0],origin[1],origin[0]*plane[0]+origin[1]*plane[1]+plane[2]+1.75};
        const double end[]{endxy[0],endxy[1],endxy[0]*plane[0]+endxy[1]*plane[1]+plane[2]+1.75};
        const double dx=end[0]-start[0],dy=end[1]-start[1],dz=end[2]-start[2];
        const double scale=std::sqrt(dx*dx+dy*dy+dz*dz)/distance;
        const double minimum=lo*scale+(lo==0?1e-5:0),padding=(distance-hi)*scale+(hi==distance?1e-5:0);
        std::vector<int32_t> excluded;double hit[3];
        for(;;) {
          const int face=nearest_triangle(static_cast<const double*>(source[0]),static_cast<const uint32_t*>(source[1]),static_cast<const double*>(source[2]),static_cast<const int32_t*>(source[3]),start,end,minimum,padding,hi!=distance,excluded.data(),int(excluded.size()),hit);
          if(face==-2)throw std::runtime_error("source stack capacity");if(face<0)break;
          if(static_cast<const int32_t*>(source[4])[face]>=0) {
            ++alpha_calls;if(!alpha)throw std::runtime_error("missing alpha sampler");
            const int opaque=alpha(face,hit[1],hit[2]);if(opaque<0)throw std::runtime_error("alpha callback failure");
            if(!opaque) {excluded.push_back(face);continue;}
          }
          // Project the same full affine-line hit back into source XY.
          const double length=scale*distance;
          const double hx=start[0]+dx/length*hit[0],hy=start[1]+dy/length*hit[0];
          best=std::min(best,(hx-origin[0])*direction[0]+(hy-origin[1])*direction[1]);break;
        }
        if(profiling)profile[3]+=std::chrono::duration<double>(std::chrono::steady_clock::now()-source_begin).count();
      }
      if(best<hi)break;
    }
    return best;
  }
};
extern "C" API void* create_floor_cone(int cells,int transits,const void*const* arrays,const void*const* source,AlphaCallback alpha) {
  try {auto* context=new ConeContext;context->cells=cells;context->transits=transits;std::copy(arrays,arrays+21,context->a.begin());std::copy(source,source+5,context->source.begin());context->alpha=alpha;return context;}catch(...){return nullptr;}
}
extern "C" API void destroy_floor_cone(void* handle){delete static_cast<ConeContext*>(handle);}
extern "C" API void get_cone_profile(void* handle,double* output){const auto& c=*static_cast<ConeContext*>(handle);std::copy(c.profile,c.profile+5,output);}
static double chord(double left,double lr,double right,double rr,double angle) {
  const double ax=lr*std::cos(left),ay=lr*std::sin(left),bx=rr*std::cos(right),by=rr*std::sin(right),dx=std::cos(angle),dy=std::sin(angle);
  const double ex=bx-ax,ey=by-ay,det=dx*ey-dy*ex;
  return std::abs(det)<1e-15?(lr+rr)/2:(ax*ey-ay*ex)/det;
}
extern "C" API int build_floor_cone(void* handle,const double* origin,double distance,const double* seeds,int seed_count,double tolerance,int maximum_queries,double* output,int capacity,double* stats) {
  try {
    auto& c=*static_cast<ConeContext*>(handle);c.queries=c.source_calls=c.alpha_calls=c.pieces=0;c.limited=false;
    c.profiling=floor_profile_enabled()!=0;std::fill(c.profile,c.profile+5,0.);
    const auto begin=std::chrono::steady_clock::now();std::map<double,double> cache;
    struct CacheScope{~CacheScope(){end_floor_clip_cache();}} cache_scope;
    begin_floor_clip_cache(c.cells,c.p<double>(0),c.p<int32_t>(1),c.p<double>(3),origin);
    if(c.profiling)c.profile[1]=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
    auto query=[&](double angle){auto it=cache.find(angle);if(it!=cache.end())return it->second;const auto ray_begin=c.profiling?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};double value=c.ray(origin,angle,distance);if(c.profiling)c.profile[2]+=std::chrono::duration<double>(std::chrono::steady_clock::now()-ray_begin).count();cache.emplace(angle,value);return value;};
    std::function<std::vector<double>(double,double,int)> refine;
    refine=[&](double left,double right,int depth) {
      double a=query(left),b=query(right);const double probes[]{left+(right-left)*.25,left+(right-left)*.5,left+(right-left)*.75};
      if(int(cache.size())+3>maximum_queries){c.limited=true;return std::vector<double>{left,right};}
      double error=0;for(double t:probes)error=std::max(error,std::abs(query(t)-chord(left,a,right,b,t)));
      if(error<=tolerance || right-left<1e-9)return std::vector<double>{left,right};
      if(depth>=24){c.limited=true;return std::vector<double>{left,right};}
      auto first=refine(left,probes[1],depth+1);auto second=refine(probes[1],right,depth+1);first.pop_back();first.insert(first.end(),second.begin(),second.end());return first;
    };
    std::vector<double> angles;
    for(int i=1;i<seed_count;++i){auto part=refine(seeds[i-1],seeds[i],0);part.pop_back();angles.insert(angles.end(),part.begin(),part.end());}
    angles.push_back(seeds[seed_count-1]);if(int(angles.size())>capacity)return -2;
    for(size_t i=0;i<angles.size();++i){output[i*2]=angles[i];output[i*2+1]=query(angles[i]);}
    end_floor_clip_cache();
    stats[0]=c.queries;stats[1]=c.source_calls;stats[2]=c.alpha_calls;stats[3]=c.pieces;stats[4]=c.limited;stats[5]=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
    if(c.profiling){c.profile[0]=stats[5];c.profile[4]=c.profile[0]-c.profile[1]-c.profile[2];}
    return int(angles.size());
  }catch(...){return -1;}
}
