// Offline reuse of eye-dependent shadow planes across receiver patches.
// The existing entry point is included for literal output comparisons.
// Neither this library nor its temporary plane tables are bundled in Icarus.
#include "../native_finite_shadows/projection.cpp"

EXPORT int finite_shadow_prepare(const double* eye_values,const double* triangles,
    int count,double* planes,uint8_t* states) {
  if(!eye_values || !triangles || !planes || !states || count<0) return -1;
  for(int i=0;i<3;++i) if(!std::isfinite(eye_values[i])) return -1;
  const auto eye=point(eye_values);
  for(int f=0;f<count;++f) {
    states[f]=0;
    const double* raw=triangles+f*9;
    bool finite=true;
    for(int i=0;i<9;++i) finite=finite && std::isfinite(raw[i]);
    if(!finite) { states[f]=6;continue; }
    V3 t[3]={point(raw),point(raw+3),point(raw+6)};
    auto e1=minus(t[1],t[0]),e2=minus(t[2],t[0]);
    auto normal=cross(e1,e2);
    double norm=std::sqrt(dot(normal,normal));
    if(norm==0) { states[f]=2;continue; }
    double distance=dot(normal,minus(eye,t[0]));
    if(std::abs(distance)<=1e-10*norm) { states[f]=1;continue; }
    auto a=absolute(e1),b=absolute(e2);
    V3 permanent={a.y*b.z+a.z*b.y,a.z*b.x+a.x*b.z,a.x*b.y+a.y*b.x};
    double bound=32*std::numeric_limits<double>::epsilon()*dot(permanent,absolute(minus(eye,t[0])));
    if(std::abs(distance)<=bound) { states[f]=3;continue; }
    for(int p=0;p<4;++p) {
      V3 n;double offset=0;
      if(p<3) n=cross(minus(t[p],eye),minus(t[(p+1)%3],t[p]));
      else { n=normal;offset=-std::abs(distance); }
      if(distance>0) n=scale(n,-1);
      auto target=planes+f*16+p*4;
      target[0]=n.x;target[1]=n.y;target[2]=n.z;target[3]=offset;
    }
  }
  return 0;
}

EXPORT int finite_receiver_project_prepared(const double* eye_values,
    const double* planes,const uint8_t* states,int prepared_count,
    const int32_t* ids,int count,const double* plane,double standing_height,
    const double* footprint,int footprint_count,float* output,int capacity,uint8_t* fallback) {
  if(!eye_values || !planes || !states || !ids || !plane || !footprint || !output || !fallback ||
      prepared_count<0 || count<0 || footprint_count<3 || capacity<0) return -1;
  for(int i=0;i<3;++i) if(!std::isfinite(eye_values[i]) || !std::isfinite(plane[i])) return -1;
  if(!std::isfinite(standing_height)) return -1;
  for(int i=0;i<footprint_count*2;++i) if(!std::isfinite(footprint[i])) return -1;
  for(int f=0;f<count;++f) if(ids[f]<0 || ids[f]>=prepared_count) return -1;
  const auto eye=point(eye_values);
  const double height_offset=plane[0]*eye.x+plane[1]*eye.y+plane[2]+standing_height-eye.z;
  std::vector<V2> polygon,next;
  polygon.reserve(footprint_count+8);next.reserve(footprint_count+8);
  int written=0;
  for(int f=0;f<count;++f) {
    fallback[f]=states[ids[f]];
    if(fallback[f]) continue;
    polygon.clear();
    for(int i=0;i<footprint_count;++i) polygon.push_back({footprint[i*2]-eye.x,footprint[i*2+1]-eye.y});
    for(int p=0;p<4 && !polygon.empty();++p) {
      const double* raw=planes+ids[f]*16+p*4;
      V3 n={raw[0],raw[1],raw[2]};double offset=raw[3];
      V3 c={n.x+n.z*plane[0],n.y+n.z*plane[1],offset+n.z*height_offset};
      if(!std::isfinite(c.x)||!std::isfinite(c.y)||!std::isfinite(c.z)) { fallback[f]=6;polygon.clear();break; }
      clip(polygon,next,c);
    }
    if(polygon.empty()) continue;
    if(polygon.size()<3) { fallback[f]=4;continue; }
    double area2=0;auto anchor=polygon[0];
    for(size_t i=0;i<polygon.size();++i) {
      auto a=polygon[i],b=polygon[(i+1)%polygon.size()];
      area2+=(a.x-anchor.x)*(b.y-anchor.y)-(a.y-anchor.y)*(b.x-anchor.x);
    }
    if(!std::isfinite(area2)) { fallback[f]=6;continue; }
    if(std::abs(area2)<=1e-16) { fallback[f]=5;continue; }
    bool loss=false;
    for(size_t i=1;i+1<polygon.size();++i) {
      auto a=polygon[0],b=polygon[i],c=polygon[i+1];
      double before=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
      V2 af={static_cast<float>(a.x),static_cast<float>(a.y)};
      V2 bf={static_cast<float>(b.x),static_cast<float>(b.y)};
      V2 cf={static_cast<float>(c.x),static_cast<float>(c.y)};
      double after=(bf.x-af.x)*(cf.y-af.y)-(bf.y-af.y)*(cf.x-af.x);
      if(!std::isfinite(after)||(before!=0&&(after==0||(before>0)!=(after>0)))) loss=true;
    }
    if(loss) { fallback[f]=7;continue; }
    if(static_cast<int>((polygon.size()-2)*6)>capacity-written) return -2;
    for(size_t i=1;i+1<polygon.size();++i) for(auto p:{polygon[0],polygon[i],polygon[i+1]}) {
      output[written++]=static_cast<float>(p.x);output[written++]=static_cast<float>(p.y);
    }
  }
  return written;
}
