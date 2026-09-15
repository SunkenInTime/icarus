// Experimental local floor atlas. Native source coordinates throughout.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>
#include <memory>
#include <chrono>
#include <vector>
#ifdef _WIN32
#define EXPORT_ATLAS __declspec(dllexport)
#else
#define EXPORT_ATLAS __attribute__((visibility("default")))
#endif
struct Interval { double lo, hi; int cell; double original_lo, original_hi; };
static double cross2(double ax,double ay,double bx,double by) { return ax*by-ay*bx; }
using ProfileClock=std::chrono::steady_clock;
static thread_local bool floor_profiling=false;
static thread_local double floor_profile[12]{};
extern "C" EXPORT_ATLAS void reset_floor_profile(int enabled){floor_profiling=enabled!=0;std::fill(floor_profile,floor_profile+12,0.);}
extern "C" EXPORT_ATLAS void get_floor_profile(double* output){std::copy(floor_profile,floor_profile+12,output);}
extern "C" int floor_profile_enabled(){return floor_profiling;}
struct AngularVector {double x,y,ex,ey;};
struct AngularWedge {AngularVector first,last;bool certified=false;};
// Measured control: exact rejection reduced offered edges but increased cone
// time. Retain the diagnostic switch; the normal path leaves it disabled.
static thread_local bool angular_rejection=false;
static thread_local double angular_counts[3]{};
extern "C" EXPORT_ATLAS void set_floor_angular_rejection(int enabled){angular_rejection=enabled!=0;}
extern "C" EXPORT_ATLAS void get_floor_angular_counts(double* output){std::copy(angular_counts,angular_counts+3,output);}
static AngularVector angular_vector(double x,double y,double ox,double oy) {
  const double vx=x-ox,vy=y-oy;
  // One outward representable step bounds each rounded subtraction. This
  // includes cancellation and subnormal results without a geometric epsilon.
  return {vx,vy,std::max(vx-std::nextafter(vx,-INFINITY),std::nextafter(vx,INFINITY)-vx),
                std::max(vy-std::nextafter(vy,-INFINITY),std::nextafter(vy,INFINITY)-vy)};
}
static std::array<double,2> angular_cross(const AngularVector& a,const AngularVector& b) {
  const double left=a.x*b.y,right=a.y*b.x,value=left-right;
  // Conservative forward-error bound for the determinant and uncertain
  // vertex-origin subtraction. Uncertain signs retain ordinary clipping.
  const double error=8*std::numeric_limits<double>::epsilon()*(std::abs(left)+std::abs(right))+
    4*(a.ex*std::abs(b.y)+a.ey*std::abs(b.x)+b.ex*std::abs(a.y)+b.ey*std::abs(a.x)+a.ex*b.ey+a.ey*b.ex);
  return {value,error};
}
struct FloorClipCache {
  const double *polygons,*triangles;double x,y;
  std::vector<double> signs,values,triangle_signs,triangle_values;
  std::vector<AngularWedge> wedges;
};
static thread_local std::unique_ptr<FloorClipCache> floor_clip_cache;
extern "C" void begin_floor_clip_cache(int count,const double* polygons,const int32_t* ranges,const double* triangles,const double* origin) {
  auto cache=std::make_unique<FloorClipCache>();cache->polygons=polygons;cache->triangles=triangles;cache->x=origin[0];cache->y=origin[1];
  cache->signs.resize(count);cache->triangle_signs.resize(count);cache->triangle_values.resize(count*3);
  if(angular_rejection)cache->wedges.resize(count);std::fill(angular_counts,angular_counts+3,0.);
  int vertices=0;for(int cell=0;cell<count;++cell)vertices=std::max(vertices,ranges[cell*2]+ranges[cell*2+1]);cache->values.resize(vertices);
  for(int cell=0;cell<count;++cell) {
    const int first=ranges[cell*2],size=ranges[cell*2+1];double area=0;
    for(int i=0;i<size;++i){const double* a=polygons+(first+i)*2;const double* b=polygons+(first+(i+1)%size)*2;area+=cross2(a[0],a[1],b[0],b[1]);}
    const double sign=area>=0?1:-1;cache->signs[cell]=sign;
    for(int i=0;i<size;++i){const double* a=polygons+(first+i)*2;const double* b=polygons+(first+(i+1)%size)*2;cache->values[first+i]=sign*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);}
    const double* triangle=triangles+cell*6;
    const double orientation=cross2(triangle[2]-triangle[0],triangle[3]-triangle[1],triangle[4]-triangle[0],triangle[5]-triangle[1])>=0?1:-1;cache->triangle_signs[cell]=orientation;
    for(int edge=0;edge<3;++edge){const double* a=triangle+edge*2;const double* b=triangle+((edge+1)%3)*2;cache->triangle_values[cell*3+edge]=orientation*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);}
    if(angular_rejection && size>=3) {
      bool inside=true;for(int i=0;i<size;++i)if(cache->values[first+i]<0)inside=false;
      if(inside)continue;
      std::vector<AngularVector> vectors;vectors.reserve(size);
      for(int i=0;i<size;++i)vectors.push_back(angular_vector(polygons[(first+i)*2],polygons[(first+i)*2+1],origin[0],origin[1]));
      int lower=0,upper=0;
      for(int i=1;i<size;++i) {
        if(cross2(vectors[lower].x,vectors[lower].y,vectors[i].x,vectors[i].y)<0)lower=i;
        if(cross2(vectors[i].x,vectors[i].y,vectors[upper].x,vectors[upper].y)<0)upper=i;
      }
      const auto width=angular_cross(vectors[lower],vectors[upper]);
      bool certified=std::isfinite(width[0]) && std::isfinite(width[1]) && width[0]>width[1];
      for(int i=0;i<size && certified;++i) {
        if(i!=lower){const auto d=angular_cross(vectors[lower],vectors[i]);if(!(d[0]>d[1]))certified=false;}
        if(i!=upper){const auto d=angular_cross(vectors[i],vectors[upper]);if(!(d[0]>d[1]))certified=false;}
      }
      if(certified){cache->wedges[cell]={vectors[lower],vectors[upper],true};++angular_counts[2];}
    }
  }
  floor_clip_cache=std::move(cache);
}
extern "C" void end_floor_clip_cache(){floor_clip_cache.reset();}
extern "C" EXPORT_ATLAS int cast_floor_atlas(
    int count, int transit_count, const double* polygons, const int32_t* polygon_ranges,
    const double* planes, const double* original_triangles, const int64_t* source_faces, const uint8_t* terrain,
    const double* segments, const int32_t* segment_ranges, const int32_t* segment_faces,
    const uint8_t* endpoint_closed, const double* endpoint_tolerance,
    const uint8_t* fallback, const double* bvh_bounds, const int32_t* bvh_nodes,
    const int32_t* bvh_cells, const double* transit_polygons, const int32_t* transit_ranges,
    const int32_t* transit_groups, const int32_t* transit_sheets, const int32_t* transit_cell_groups,
    const uint8_t* transit_adjacency, const double* origin, const double* direction,
    double distance, double step, double* output, int capacity) {
  const auto profile_begin=floor_profiling?ProfileClock::now():ProfileClock::time_point{};
  const double vx=direction[0]*distance, vy=direction[1]*distance;
  const auto* cache=floor_clip_cache.get();
  if(cache && (cache->polygons!=polygons || cache->triangles!=original_triangles || cache->x!=origin[0] || cache->y!=origin[1]))cache=nullptr;
  std::vector<Interval> intervals; std::vector<double> events{0,1};
  struct Transit {double lo,hi;int group,sheet,parent;};
  std::vector<Transit> transit,merged_transit;
  for(int parent=0;parent<transit_count;++parent) {
    const int first=transit_ranges[parent*2],size=transit_ranges[parent*2+1];double area=0,lo=0,hi=1;
    for(int i=0;i<size;++i) {const double* a=transit_polygons+(first+i)*2;const double* b=transit_polygons+(first+(i+1)%size)*2;area+=cross2(a[0],a[1],b[0],b[1]);}
    const double sign=area>=0?1:-1;
    for(int i=0;i<size && hi>=lo;++i) {
      const double* a=transit_polygons+(first+i)*2;const double* b=transit_polygons+(first+(i+1)%size)*2;
      const double value=sign*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);
      const double slope=sign*cross2(b[0]-a[0],b[1]-a[1],vx,vy);
      if(std::abs(slope)<1e-14) {if(value<0)hi=-1;}
      else if(slope>0)lo=std::max(lo,-value/slope);else hi=std::min(hi,-value/slope);
    }
    if(hi-lo>1e-11)transit.push_back({lo,hi,transit_groups[parent],transit_sheets[parent],parent});
  }
  std::sort(transit.begin(),transit.end(),[](const Transit& a,const Transit& b){return a.sheet==b.sheet?a.lo<b.lo:a.sheet<b.sheet;});
  for(const auto& value:transit) {
    if(!merged_transit.empty()) {
      auto& previous=merged_transit.back();
      if(previous.sheet==value.sheet && previous.group==value.group && value.lo<=previous.hi+1e-13 && transit_adjacency[previous.parent*transit_count+value.parent]) {
        if(value.hi>previous.hi) {previous.hi=value.hi;previous.parent=value.parent;}continue;
      }
    }
    merged_transit.push_back(value);
  }
  for(auto& value:merged_transit) {value.lo=std::round(value.lo*1e13)/1e13;value.hi=std::round(value.hi*1e13)/1e13;events.push_back(value.lo);events.push_back(value.hi);}
  std::vector<int> pending{0},cells;
  while(!pending.empty()) {
    if(floor_profiling)++floor_profile[9];
    const int index=pending.back();pending.pop_back();const double* box=bvh_bounds+index*4;
    double lo=0,hi=1;bool valid=true;
    for(int axis=0;axis<2;++axis) {
      const double v=direction[axis]*distance;
      if(std::abs(v)<1e-15) {if(origin[axis]<box[axis] || origin[axis]>box[axis+2])valid=false;}
      else {double a=(box[axis]-origin[axis])/v,b=(box[axis+2]-origin[axis])/v;
        lo=std::max(lo,std::min(a,b));hi=std::min(hi,std::max(a,b));if(hi<lo)valid=false;}
    }
    if(!valid)continue;const int32_t* node=bvh_nodes+index*4;
    if(node[1])for(int i=0;i<node[1];++i)cells.push_back(bvh_cells[node[0]+i]);
    else {pending.push_back(node[2]);pending.push_back(node[3]);}
  }
  std::sort(cells.begin(),cells.end());
  for(int cell:cells) {
    if(cache && !cache->wedges.empty() && cache->wedges[cell].certified) {
      ++angular_counts[0];const AngularVector ray{vx,vy,0,0};const auto& wedge=cache->wedges[cell];
      const auto left=angular_cross(wedge.first,ray),right=angular_cross(ray,wedge.last);
      if(left[0]<-left[1] || right[0]<-right[1]){++angular_counts[1];continue;}
    }
    const int first=polygon_ranges[cell*2], size=polygon_ranges[cell*2+1];
    if(floor_profiling)floor_profile[10]+=size+3;
    double area=0;
    if(!cache)for(int i=0;i<size;++i) {
      const double* a=polygons+(first+i)*2; const double* b=polygons+(first+(i+1)%size)*2;
      area+=cross2(a[0],a[1],b[0],b[1]);
    }
    const double sign=cache?cache->signs[cell]:(area>=0?1:-1); double lo=0,hi=1;
    for(int i=0;i<size && hi>=lo;++i) {
      const double* a=polygons+(first+i)*2; const double* b=polygons+(first+(i+1)%size)*2;
      const double value=cache?cache->values[first+i]:sign*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);
      const double slope=sign*cross2(b[0]-a[0],b[1]-a[1],vx,vy);
      if(std::abs(slope)<1e-14) { if(value<0)hi=-1; }
      else if(slope>0)lo=std::max(lo,-value/slope);
      else hi=std::min(hi,-value/slope);
    }
    if(hi-lo<=1e-11)continue;
    const double* triangle=original_triangles+cell*6;
    const double orientation=cache?cache->triangle_signs[cell]:(cross2(triangle[2]-triangle[0],triangle[3]-triangle[1],triangle[4]-triangle[0],triangle[5]-triangle[1])>=0?1:-1);
    double original_lo=0,original_hi=1;
    for(int edge=0;edge<3 && original_hi>=original_lo;++edge) {
      const double* a=triangle+edge*2;const double* b=triangle+((edge+1)%3)*2;
      const double value=cache?cache->triangle_values[cell*3+edge]:orientation*cross2(b[0]-a[0],b[1]-a[1],origin[0]-a[0],origin[1]-a[1]);
      const double slope=orientation*cross2(b[0]-a[0],b[1]-a[1],vx,vy);
      if(std::abs(slope)<1e-14) {if(value<0)original_hi=-1;}
      else if(slope>0)original_lo=std::max(original_lo,-value/slope);
      else original_hi=std::min(original_hi,-value/slope);
    }
    if(original_hi-original_lo>=1e-11) {
      events.push_back(std::round(original_lo*1e13)/1e13);events.push_back(std::round(original_hi*1e13)/1e13);
    } else {original_lo=1;original_hi=0;}
    intervals.push_back({lo,hi,cell,original_lo,original_hi});
    events.push_back(std::round(lo*1e13)/1e13);events.push_back(std::round(hi*1e13)/1e13);
  }
  const auto profile_intervals=floor_profiling?ProfileClock::now():ProfileClock::time_point{};
  std::sort(events.begin(),events.end());events.erase(std::unique(events.begin(),events.end()),events.end());
  // Sweep the same exact intervals in their original cell order. Most floor
  // patches overlap only a few neighbors; scanning every intersected patch at
  // every event is unnecessary. No events or candidate ties are removed.
  std::vector<int> interval_order(intervals.size()),active_intervals;
  std::iota(interval_order.begin(),interval_order.end(),0);
  std::sort(interval_order.begin(),interval_order.end(),[&](int a,int b){return intervals[a].lo==intervals[b].lo?a<b:intervals[a].lo<intervals[b].lo;});
  size_t interval_cursor=0;
  const auto profile_sorted=floor_profiling?ProfileClock::now():ProfileClock::time_point{};
  double profile_section_seconds=0;
  double previous=origin[2]-1.75,unsupported=0; bool supported=false,detached=false,raised_origin=false; int written=0;
  struct Candidate {int cell;double begin,end,error,miderror;bool original;};
  for(size_t index=1;index<events.size();++index) {
    // A tiny event interval may contain an exact wall contact. Skipping it
    // leaves a real hole between the two adjacent closed intervals.
    double lo=events[index-1],hi=events[index];if(hi<=lo)continue;
    const double mid=(lo+hi)/2;std::vector<Candidate> candidates;
    while(interval_cursor<interval_order.size() && intervals[interval_order[interval_cursor]].lo<=mid)active_intervals.push_back(interval_order[interval_cursor++]);
    active_intervals.erase(std::remove_if(active_intervals.begin(),active_intervals.end(),[&](int index){return intervals[index].hi<mid;}),active_intervals.end());
    std::sort(active_intervals.begin(),active_intervals.end());
    if(floor_profiling)floor_profile[11]+=active_intervals.size();
    if(!detached)for(int active_index:active_intervals) {
      const auto& interval=intervals[active_index];
      const int cell=interval.cell;const double* plane=planes+cell*3;
      const double a=plane[0]*(origin[0]+lo*vx)+plane[1]*(origin[1]+lo*vy)+plane[2];
      const double b=plane[0]*(origin[0]+hi*vx)+plane[1]*(origin[1]+hi*vy)+plane[2];
      if(lo!=0 && source_faces[cell]>=0 &&
         (raised_origin ? (terrain[cell]!=2 || std::abs(a-previous)>1e-5) : terrain[cell]==2))continue;
      candidates.push_back({cell,a,b,std::abs(a-previous),0,interval.original_lo<=mid && mid<=interval.original_hi});
    }
    const bool original_source=std::any_of(candidates.begin(),candidates.end(),[&](const Candidate& c){return c.original && source_faces[c.cell]>=0 && c.error<=step+1e-6;});
    if(original_source)candidates.erase(std::remove_if(candidates.begin(),candidates.end(),[&](const Candidate& c){return !c.original && source_faces[c.cell]>=0;}),candidates.end());
    int nav=-1;std::vector<int> close;
    for(int i=0;i<(int)candidates.size();++i) {
      if(candidates[i].error<=.35 && source_faces[candidates[i].cell]>=0)close.push_back(i);
      if(source_faces[candidates[i].cell]<0 && (nav<0 || candidates[i].error<candidates[nav].error))nav=i;
    }
    if(nav>=0) {
      const double hint=candidates[nav].begin;
      std::vector<int> real;double best=std::numeric_limits<double>::infinity();
      for(int i=0;i<(int)candidates.size();++i) {
        auto& value=candidates[i];value.miderror=std::abs(value.begin-hint);
        if(source_faces[value.cell]>=0 && value.miderror<=.35 && value.error<=step+1e-6) {
          real.push_back(i);best=std::min(best,value.miderror);
        }
      }
      if(!real.empty()) {close.clear();for(int i:real)if(candidates[i].miderror<=best+1e-5)close.push_back(i);}
      if(!real.empty() && close.size()>1) {
        const double* nav_plane=planes+candidates[nav].cell*3;
        double slope_best=std::numeric_limits<double>::infinity();
        std::vector<double> slope_errors;
        for(int i:close) {const double* p=planes+candidates[i].cell*3;
          const double error=std::hypot(p[0]-nav_plane[0],p[1]-nav_plane[1]);
          slope_errors.push_back(error);slope_best=std::min(slope_best,error);}
        std::vector<int> tied;for(int i=0;i<(int)close.size();++i)if(slope_errors[i]<=slope_best+1e-8)tied.push_back(close[i]);
        close=std::move(tied);
      }
    }
    if(lo!=0) {
      std::vector<int> real;double highest=-std::numeric_limits<double>::infinity();
      for(int i=0;i<(int)candidates.size();++i)if(terrain[candidates[i].cell]==1 && candidates[i].error<=step+1e-6) {
        real.push_back(i);highest=std::max(highest,candidates[i].begin);
      }
      if(!real.empty()) {close.clear();for(int i:real)if(candidates[i].begin>=highest-1e-5)close.push_back(i);}
    }
    if(close.empty() && lo!=0)for(int i=0;i<(int)candidates.size();++i)if(source_faces[candidates[i].cell]>=0)close.push_back(i);
    double best=std::numeric_limits<double>::infinity();
    for(int i:close)if(candidates[i].error<=step+1e-6)best=std::min(best,candidates[i].error);
    int pick=-1;double change=std::numeric_limits<double>::infinity();
    for(int i:close)if(candidates[i].error<=step+1e-6 && candidates[i].error<=best+1e-5) {
      const double value=std::abs(candidates[i].end-candidates[i].begin);
      if(value<change) {change=value;pick=i;}
    }
    int cell=-1;double ground0=previous,ground1=previous;
    if(pick>=0) {cell=candidates[pick].cell;ground0=candidates[pick].begin;ground1=candidates[pick].end;supported=true;unsupported=0;
      if(lo==0)raised_origin=terrain[cell]==2;}
    else if(supported) {unsupported+=(hi-lo)*distance;if(unsupported>1e-4)detached=true;}
    if(detached)hi=1; // Holding incoming height makes the remaining source fallback one straight ray.
    bool transit_skip=false;
    if(cell>=0 && !raised_origin && transit_cell_groups[cell]>=0)for(const auto& value:merged_transit) {
      if(value.group==transit_cell_groups[cell] && value.lo<=lo && value.hi>hi) {
        hi=value.hi;const double* plane=planes+cell*3;
        ground1=plane[0]*(origin[0]+hi*vx)+plane[1]*(origin[1]+hi*vy)+plane[2];transit_skip=true;
      }
    }
    double hit=std::numeric_limits<double>::infinity();int hitface=-1;bool ambiguous=false;
    const auto profile_section_begin=floor_profiling?ProfileClock::now():ProfileClock::time_point{};
    if(cell>=0 && !fallback[cell] && !transit_skip) {
      const double dz=ground1-ground0,length=std::sqrt(std::pow((hi-lo)*distance,2)+dz*dz);
      for(int j=0;j<segment_ranges[cell*2+1];++j) {
        if(floor_profiling)++floor_profile[8];
        const int segment=segment_ranges[cell*2]+j; const double* line=segments+segment*4;
        const double ex=line[2]-line[0],ey=line[3]-line[1],ax=line[0]-origin[0],ay=line[1]-origin[1];
        bool near_endpoint=false;
        for(int endpoint=0;endpoint<2;++endpoint) {
          const double px=line[endpoint*2]-origin[0],py=line[endpoint*2+1]-origin[1];
          const double t=(px*vx+py*vy)/(distance*distance);
          const double separation=std::abs(cross2(px,py,vx,vy))/distance;
          if(separation<=endpoint_tolerance[segment] && t>=lo-endpoint_tolerance[segment]/distance && t<=hi+endpoint_tolerance[segment]/distance)near_endpoint=true;
        }
        if(near_endpoint) {ambiguous=true;continue;}
        const double determinant=cross2(vx,vy,ex,ey);if(std::abs(determinant)<1e-12)continue;
        const double t=cross2(ax,ay,ex,ey)/determinant,u=cross2(ax,ay,vx,vy)/determinant;
        const double local=(t-lo)/(hi-lo)*length;
        if(t<lo || t>hi || u<0 || u>1 || (u==0 && !endpoint_closed[segment*2]) || (u==1 && !endpoint_closed[segment*2+1]) ||
           local<(lo==0?1e-5:0) || local>length-(hi==1?1e-5:0))continue;
        if(t<hit) {hit=t;hitface=segment_faces[segment];}
      }
    }
    if(floor_profiling)profile_section_seconds+=std::chrono::duration<double>(ProfileClock::now()-profile_section_begin).count();
    if(written>=capacity)return -1;double* row=output+written++*8;
    row[0]=lo*distance;row[1]=hi*distance;row[2]=ground0;row[3]=ground1;
    row[4]=cell;row[5]=hit*distance;row[6]=transit_skip?-2:hitface;row[7]=!transit_skip && (cell<0 || fallback[cell] || ambiguous);
    previous=ground1;
    if(transit_skip)while(index<events.size() && events[index]<hi)++index;
    if(hitface>=0 || detached)break;
  }
  if(floor_profiling){
    floor_profile[0]+=std::chrono::duration<double>(profile_intervals-profile_begin).count();
    floor_profile[1]+=std::chrono::duration<double>(profile_sorted-profile_intervals).count();
    floor_profile[2]+=std::chrono::duration<double>(ProfileClock::now()-profile_sorted).count()-profile_section_seconds;
    floor_profile[3]+=profile_section_seconds;floor_profile[4]+=1;floor_profile[5]+=intervals.size();floor_profile[6]+=events.size();floor_profile[7]+=written;
  }
  return written;
}
