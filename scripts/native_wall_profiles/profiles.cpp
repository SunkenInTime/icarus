// Diagnostic only: exact stored polygon rings; no dilation or quantization.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>
#define API extern "C" __declspec(dllexport)
struct P { double x,y; };
struct Ring { int family,polygon,hole; std::vector<P> points; };
struct Piece { int family; double x,y,dx,dy,a,da; };
struct Mask { int family; P p[3]; };
struct Model { std::vector<Ring> rings; std::vector<Piece> pieces; std::vector<Mask> masks; };
static double cross(P a,P b){return a.x*b.y-a.y*b.x;}
// -1 outside, 0 exact boundary, 1 inside. A near boundary only sets a flag.
static int ring_state(const std::vector<P>& points,P q,bool& near) {
  bool inside=false;
  for(size_t i=0,j=points.size()-1;i<points.size();j=i++) {
    P a=points[j],b=points[i],d{b.x-a.x,b.y-a.y},v{q.x-a.x,q.y-a.y};
    double c=cross(d,v),l2=d.x*d.x+d.y*d.y;
    if(l2>0){double t=std::clamp((v.x*d.x+v.y*d.y)/l2,0.0,1.0);
      if(std::hypot(v.x-t*d.x,v.y-t*d.y)<=1e-10)near=true;}
    if(c==0 && q.x>=std::min(a.x,b.x)&&q.x<=std::max(a.x,b.x)&&q.y>=std::min(a.y,b.y)&&q.y<=std::max(a.y,b.y))return 0;
    if((a.y>q.y)!=(b.y>q.y) && q.x<a.x+(b.x-a.x)*(q.y-a.y)/(b.y-a.y))inside=!inside;
  }
  return inside?1:-1;
}
static bool covered(const Model& m,int family,P q,bool& near) {
  bool outer=false,hole=false;int polygon=-1;
  for(const auto& ring:m.rings) {
    if(ring.family!=family)continue;
    if(ring.polygon!=polygon){if(outer&&!hole)return true;outer=false;hole=false;polygon=ring.polygon;}
    int state=ring_state(ring.points,q,near);
    if(!ring.hole)outer=state>=0;else if(state==1)hole=true;
  }
  return outer&&!hole;
}
API void* profile_create(const double* points,const int32_t* rings,int nr,const double* pieces,const int32_t* families,int np,const double* masks,const int32_t* mf,int nm) {
  auto* m=new Model;
  for(int i=0;i<nr;i++){const auto* r=rings+5*i;Ring ring{r[0],r[1],r[2],{}};for(int j=0;j<r[4];j++)ring.points.push_back({points[2*(r[3]+j)],points[2*(r[3]+j)+1]});m->rings.push_back(std::move(ring));}
  for(int i=0;i<np;i++){const auto* p=pieces+6*i;m->pieces.push_back({families[i],p[0],p[1],p[2]-p[0],p[3]-p[1],p[4],p[5]-p[4]});}
  for(int i=0;i<nm;i++){Mask mask;mask.family=mf[i];for(int j=0;j<3;j++)mask.p[j]={masks[6*i+2*j],masks[6*i+2*j+1]};m->masks.push_back(mask);}return m;
}
API void profile_destroy(void* p){delete static_cast<Model*>(p);}
// queries: [originXYZ,targetXYZ]. out: [opaque distance,family,near boundary,parallel contact].
// maskedOut retains a distance for EACH original masked profile, infinity if absent.
API void profile_batch(void* ptr,const double* queries,int count,double minimum,double padding,double* out,double* maskedOut){
  const auto& m=*static_cast<Model*>(ptr);const double inf=std::numeric_limits<double>::infinity();
  for(int i=0;i<count;i++){const double* q=queries+6*i;double* o=out+4*i;o[0]=inf;o[1]=-1;o[2]=0;o[3]=0;
    std::fill(maskedOut+i*m.masks.size(),maskedOut+(i+1)*m.masks.size(),inf);
    P d{q[3]-q[0],q[4]-q[1]};double dz=q[5]-q[2],length=std::sqrt(d.x*d.x+d.y*d.y+dz*dz);
    for(const auto& piece:m.pieces){P e{piece.dx,piece.dy},v{piece.x-q[0],piece.y-q[1]};double det=cross(d,e);
      if(det==0){if(cross(v,d)==0)o[3]=1;continue;}
      double t=cross(v,e)/det,u=cross(v,d)/det,distance=t*length;
      if(u<0||u>1||distance<minimum||distance>=length-padding)continue;
      P point{piece.a+u*piece.da,q[2]+t*dz};bool near=(u<=1e-12||u>=1-1e-12);
      bool hit=covered(m,piece.family,point,near);if(near)o[2]=1;
      if(hit&&distance<o[0]){o[0]=distance;o[1]=piece.family;}
      for(size_t k=0;k<m.masks.size();k++){const auto& mask=m.masks[k];if(mask.family!=piece.family)continue;
        bool maskNear=false;std::vector<P> triangle(mask.p,mask.p+3);
        if(ring_state(triangle,point,maskNear)>=0)maskedOut[i*m.masks.size()+k]=std::min(maskedOut[i*m.masks.size()+k],distance);
        if(maskNear)o[2]=1;
      }
    }
  }
}
extern "C" int nearest_triangle(const double*,const uint32_t*,const double*,const int32_t*,const double*,const double*,double,double,int,const int32_t*,int,double*);
API void profile_bvh_batch(const double* vertices,const uint32_t* faces,const double* bounds,const int32_t* nodes,const double* queries,int count,double minimum,double padding,double* out){
  for(int i=0;i<count;i++){double hit[3]={};int face=nearest_triangle(vertices,faces,bounds,nodes,queries+6*i,queries+6*i+3,minimum,padding,0,nullptr,0,hit);
    out[4*i]=face;out[4*i+1]=face<0?std::numeric_limits<double>::infinity():hit[0];out[4*i+2]=hit[1];out[4*i+3]=hit[2];}
}
