// Independent full-source 3D casts along an offline piecewise floor reference.
#include "height_pipeline.hpp"
#include <limits>
#include <set>

using V3 = std::array<double, 3>;
V3 sub(const V3& a, const V3& b) { return {a[0]-b[0], a[1]-b[1], a[2]-b[2]}; }
double dot(const V3& a, const V3& b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
V3 cross(const V3& a, const V3& b) { return {a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]}; }

double cast(const Model& m, const AlphaData& alpha, const V3& origin, const V3& target, double minimumT) {
  const V3 direction = sub(target, origin);
  double best = 1 + 1e-10;
  std::array<int,128> stack; int used=1; stack[0]=0;
  while(used) {
    const int node=stack[--used];
    const double* box=m.bounds+node*6;
    double low=minimumT, high=std::min(1.0,best);
    bool admitted=true;
    for(int axis=0;axis<3;++axis) {
      if(std::abs(direction[axis])<1e-15) {
        if(origin[axis]<box[axis]-1e-10 || origin[axis]>box[axis+3]+1e-10) { admitted=false; break; }
      } else {
        double a=(box[axis]-origin[axis])/direction[axis], b=(box[axis+3]-origin[axis])/direction[axis];
        if(a>b)std::swap(a,b); low=std::max(low,a); high=std::min(high,b);
        if(low>high+1e-10) { admitted=false; break; }
      }
    }
    if(!admitted)continue;
    const int* info=m.nodes+node*4;
    if(!info[1]) { if(used+2>128)throw std::runtime_error("BVH stack overflow"); stack[used++]=info[2];stack[used++]=info[3];continue; }
    for(int face=info[0];face<info[0]+info[1];++face) {
      V3 a,b,c;
      for(int k=0;k<3;++k) { a[k]=m.vertices[m.faces[face*3]*3+k];b[k]=m.vertices[m.faces[face*3+1]*3+k];c[k]=m.vertices[m.faces[face*3+2]*3+k]; }
      auto e1=sub(b,a), e2=sub(c,a), p=cross(direction,e2);
      double det=dot(e1,p);if(std::abs(det)<1e-14)continue;
      auto difference=sub(origin,a);double u=dot(difference,p)/det;
      auto q=cross(difference,e1);double v=dot(direction,q)/det, t=dot(e2,q)/det;
      if(u< -1e-10 || v< -1e-10 || u+v>1+1e-10 || t<minimumT-1e-10 || t>1+1e-10 || t>=best)continue;
      const int mask=m.masks[face];
      if(mask>=0) {
        const auto& mat=alpha.materials.at(alpha.materialIds[mask]);
        const double* uv=alpha.uvs+mask*6;
        double s=(1-u-v)*uv[0]+u*uv[2]+v*uv[4], r=(1-u-v)*uv[1]+u*uv[3]+v*uv[5];
        if(Alpha::sample(alpha.textures.at(mat.texture),mat.policy,s,r)<mat.policy.threshold)continue;
      }
      best=std::clamp(t,0.0,1.0);
    }
  }
  return best<=1 ? best : std::numeric_limits<double>::infinity();
}

struct Field {
  struct Cell { std::array<double,9> value; };
  std::vector<Cell> cells;
  double xmin=1e100,ymin=1e100,xmax=-1e100,ymax=-1e100;
  int width,height; const double gridSize=4;
  std::vector<std::vector<int>> grid;
  Field(const char* path) {
    std::ifstream f(std::filesystem::u8path(path),std::ios::binary);uint32_t count;
    f.read(reinterpret_cast<char*>(&count),4);if(!f || !count || count>1000000)throw std::runtime_error("Invalid field");
    cells.resize(count);f.read(reinterpret_cast<char*>(cells.data()),std::streamsize(count)*72);if(!f)throw std::runtime_error("Incomplete field");
    for(auto& cell:cells)for(int i=0;i<3;++i){xmin=std::min(xmin,cell.value[i*2]);xmax=std::max(xmax,cell.value[i*2]);ymin=std::min(ymin,cell.value[i*2+1]);ymax=std::max(ymax,cell.value[i*2+1]);}
    width=int(std::floor((xmax-xmin)/gridSize))+1;height=int(std::floor((ymax-ymin)/gridSize))+1;grid.resize(size_t(width)*height);
    for(int id=0;id<int(cells.size());++id){auto&v=cells[id].value;double x0=std::min({v[0],v[2],v[4]}),x1=std::max({v[0],v[2],v[4]}),y0=std::min({v[1],v[3],v[5]}),y1=std::max({v[1],v[3],v[5]});
      for(int y=int((y0-ymin)/gridSize);y<=int((y1-ymin)/gridSize);++y)for(int x=int((x0-xmin)/gridSize);x<=int((x1-xmin)/gridSize);++x)grid[size_t(y)*width+x].push_back(id);
    }
  }
  double z(int cell,double x,double y) const {const auto&v=cells[cell].value;return v[6]*x+v[7]*y+v[8];}
  bool interval(int cell,double x,double y,double dx,double dy,double range,double&low,double&high)const{
    const auto&v=cells[cell].value;low=0;high=range;
    double area=(v[2]-v[0])*(v[5]-v[1])-(v[3]-v[1])*(v[4]-v[0]);double sign=area>0?1:-1;
    for(int i=0;i<3;++i){int j=(i+1)%3;double ex=v[j*2]-v[i*2],ey=v[j*2+1]-v[i*2+1];double a=sign*(ex*(y-v[i*2+1])-ey*(x-v[i*2])),b=sign*(ex*dy-ey*dx);
      if(std::abs(b)<1e-14){if(a< -1e-10)return false;}else if(b>0)low=std::max(low,-a/b);else high=std::min(high,-a/b);if(low>high+1e-10)return false;
    }return high-low>1e-10;
  }
  std::vector<std::array<double,3>> pieces(double x,double y,double dx,double dy,double range)const{
    int gx=int(std::floor((x-xmin)/gridSize)),gy=int(std::floor((y-ymin)/gridSize));
    const int sx=dx>=0?1:-1,sy=dy>=0?1:-1;
    double tx=std::abs(dx)<1e-15?1e100:(xmin+(gx+(sx>0?1:0))*gridSize-x)/dx;
    double ty=std::abs(dy)<1e-15?1e100:(ymin+(gy+(sy>0?1:0))*gridSize-y)/dy;
    const double stepX=std::abs(dx)<1e-15?1e100:gridSize/std::abs(dx),stepY=std::abs(dy)<1e-15?1e100:gridSize/std::abs(dy);
    std::vector<uint8_t> seen(cells.size());std::vector<std::array<double,3>> output;
    double t=0;
    while(t<=range && gx>=0&&gy>=0&&gx<width&&gy<height){
      for(int id:grid[size_t(gy)*width+gx])if(!seen[id]){seen[id]=1;double lo,hi;if(interval(id,x,y,dx,dy,range,lo,hi))output.push_back({lo,hi,double(id)});}
      if(tx<ty){t=tx;tx+=stepX;gx+=sx;}else{t=ty;ty+=stepY;gy+=sy;}
    }
    std::sort(output.begin(),output.end());return output;
  }
};

int main(int argc,char**argv){try{
  if(argc!=7)throw std::runtime_error("source-folder field.bin world-xyz.f64 output.f64 directions range");
  Model model(argv[1],false);AlphaData alpha(argv[1],model);Field field(argv[2]);int directions=std::stoi(argv[5]);double range=std::stod(argv[6]);
  if(directions<1||directions>4096||!(range>0&&range<=65))throw std::runtime_error("Invalid rays");
  std::ifstream input(std::filesystem::u8path(argv[3]),std::ios::binary|std::ios::ate);auto size=input.tellg();if(size<0||size%24)throw std::runtime_error("Invalid XYZ");input.seekg(0);
  std::ofstream output(std::filesystem::u8path(argv[4]),std::ios::binary);auto started=Clock::now();
  for(size_t i=0;i<size_t(size/24);++i){V3 origin;input.read(reinterpret_cast<char*>(origin.data()),24);std::vector<double> results(directions,range);
    auto containing=field.pieces(origin[0],origin[1],1,0,1e-6);if(containing.empty())throw std::runtime_error("Origin outside field");double relative=origin[2]-field.z(int(containing.front()[2]),origin[0],origin[1]);
    for(int ray=0;ray<directions;++ray){double angle=2*3.14159265358979323846*ray/directions,dx=std::cos(angle),dy=std::sin(angle);
      for(auto interval:field.pieces(origin[0],origin[1],dx,dy,range)){double lo=interval[0],hi=interval[1];if(lo>results[ray])break;int cell=int(interval[2]);V3 a={origin[0]+lo*dx,origin[1]+lo*dy,0},b={origin[0]+hi*dx,origin[1]+hi*dy,0};a[2]=field.z(cell,a[0],a[1])+relative;b[2]=field.z(cell,b[0],b[1])+relative;
        double hit=cast(model,alpha,a,b,lo<1e-8?1e-8/std::max(hi-lo,1e-12):0);if(std::isfinite(hit)){results[ray]=std::min(results[ray],lo+(hi-lo)*hit);}
      }
    }output.write(reinterpret_cast<const char*>(results.data()),std::streamsize(results.size()*8));
  }if(!input||!output)throw std::runtime_error("Incomplete IO");std::cout<<"source queries="<<size_t(size/24)<<" directions="<<directions<<" seconds="<<std::chrono::duration<double>(Clock::now()-started).count()<<std::endl;return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
