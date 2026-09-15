// Test-only BVH traversal. Python retains alpha policy and floor selection.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

using V3 = std::array<double, 3>;
static V3 subtract(const double* a, const double* b) { return {a[0]-b[0], a[1]-b[1], a[2]-b[2]}; }
static V3 cross(const V3& a, const V3& b) { return {a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]}; }
static double dot(const V3& a, const V3& b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }

#ifdef _WIN32
#define EXPORT_CAST __declspec(dllexport)
#else
#define EXPORT_CAST __attribute__((visibility("default")))
#endif
extern "C" EXPORT_CAST int nearest_triangle(
    const double* vertices, const uint32_t* faces, const double* bounds,
    const int32_t* nodes, const double* origin, const double* target,
    double minimum, double padding, int end_inclusive, const int32_t* excluded, int excluded_count,
    double* output) {
  V3 direction=subtract(target,origin);
  const double length=std::sqrt(dot(direction,direction));
  if(length<1e-6)return -1;
  for(double& value:direction)value/=length;
  const double end=length-padding;
  double best=length;
  int best_face=-1;
  std::array<int,128> stack{};int used=1;
  while(used) {
    const int node=stack[--used];const double* box=bounds+node*6;
    double low=0,high=best;bool valid=true;
    for(int axis=0;axis<3;++axis) {
      if(std::abs(direction[axis])<1e-15) {
        if(origin[axis]<box[axis] || origin[axis]>box[axis+3]){valid=false;break;}
      } else {
        double a=(box[axis]-origin[axis])/direction[axis],b=(box[axis+3]-origin[axis])/direction[axis];
        low=std::max(low,std::min(a,b));high=std::min(high,std::max(a,b));
        if(high<low){valid=false;break;}
      }
    }
    if(!valid)continue;
    const int32_t* info=nodes+node*4;
    if(info[1]==0) {
      if(used+2>128)return -2;
      stack[used++]=info[2];stack[used++]=info[3];continue;
    }
    for(int face=info[0];face<info[0]+info[1];++face) {
      if(std::find(excluded,excluded+excluded_count,face)!=excluded+excluded_count)continue;
      const double* a=vertices+faces[face*3]*3;
      const double* b=vertices+faces[face*3+1]*3;
      const double* c=vertices+faces[face*3+2]*3;
      const V3 ab=subtract(b,a),ac=subtract(c,a),p=cross(direction,ac);
      const double determinant=dot(ab,p);
      if(std::abs(determinant)<1e-12)continue;
      const V3 relative=subtract(origin,a),q=cross(relative,ab);
      const double u=dot(relative,p)/determinant,v=dot(direction,q)/determinant,t=dot(ac,q)/determinant;
      if(t<0 || u< -1e-7 || v< -1e-7 || u+v>1+1e-7 || t<minimum || t>end ||
         (padding>0 && !end_inclusive && t==end) || (best_face>=0 && t>=best))continue;
      best=t;best_face=face;output[0]=t;output[1]=u;output[2]=v;
    }
  }
  return best_face;
}
