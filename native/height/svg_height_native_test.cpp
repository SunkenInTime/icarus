#include "icarus_svg_height.h"

#include <cmath>
#include <cstdint>
#include <limits>

int main() {
  static_assert(sizeof(ISHResult) == 72);
#define CHECK(expression)                                                       \
  do {                                                                          \
    if (!(expression))                                                          \
      return __LINE__;                                                          \
  } while (false)
  const double edge[] = {5.0, -10.0, 5.0, 10.0, 0.0};
  char error[256]{};
  const double badWall[] = {0, 0, 1, 0, 1};
  const double zeroEdge[] = {0, 0, 0, 0, 0};
  const double infiniteEdge[] = {
      0, 0, std::numeric_limits<double>::infinity(), 1, 0};
  CHECK(ish_open(edge, (1u << 19) + 1, 1, error, sizeof(error)) == nullptr);
  CHECK(ish_open(nullptr, 0, (1u << 20) + 1, error, sizeof(error)) ==
        nullptr);
  CHECK(ish_open(badWall, 1, 1, error, sizeof(error)) == nullptr);
  CHECK(ish_open(zeroEdge, 1, 1, error, sizeof(error)) == nullptr);
  CHECK(ish_open(infiniteEdge, 1, 1, error, sizeof(error)) == nullptr);
  void *handle = ish_open(edge, 1, 1, error, sizeof(error));
  CHECK(handle != nullptr);

  uint8_t *active = ish_active_wall_buffer(handle);
  ISHResult *result = ish_result_buffer(handle);
  CHECK(active != nullptr && result != nullptr);
  active[0] = 1;
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 10, 1.5707963267948966, 2, active,
                  1, result) == ISH_OK);
  CHECK(result->status == ISH_OK);
  // Three rays hit one straight edge. The returned polygon keeps the run's
  // endpoints while rayCount continues to report the work performed.
  CHECK(result->pointCount == 3);
  CHECK(result->rayCount == 3);
  CHECK(result->points != nullptr);
  CHECK(result->points[0] == 0 && result->points[1] == 0);
  CHECK(std::abs(result->points[2] - 5) < 1e-12);
  CHECK(std::abs(result->points[3] + 5) < 1e-12);
  CHECK(std::abs(result->points[4] - 5) < 1e-12);
  CHECK(std::abs(result->points[5] - 5) < 1e-12);

  active[0] = 0;
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 10, 1.5707963267948966, 2, active,
                  1, result) == ISH_OK);
  CHECK(result->pointCount == 4);
  CHECK(result->rayCount == 3);
  CHECK(std::abs(result->points[4] - 10) < 1e-12);

  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, -1, 1, 2, active, 1, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 1, 0, 2, active, 1, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 1, 7, 2, active, 1, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 1, 1, 0, active, 1, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 1, 1, 4097, active, 1, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, 0, 1, 1, 2, active, 0, result) ==
        ISH_INVALID);
  result->structSize = sizeof(*result);
  CHECK(ish_query(handle, 0, 0, std::numeric_limits<double>::quiet_NaN(), 1,
                  1, 2, active, 1, result) == ISH_INVALID);
  CHECK(ish_close(handle) == ISH_OK);
  const double cx = 133.863451727991, cy = 16.93786025368884;
  const double ox = 124.9415684595047, oy = 11.111504460225415;
  const double cornerEdges[] = {
      cx-5,cy,cx,cy,0, cx,cy,cx,cy+5,0,
      cx,cy+5,cx-5,cy+5,0, cx-5,cy+5,cx-5,cy,0};
  handle = ish_open(cornerEdges,4,1,error,sizeof(error));
  CHECK(handle != nullptr);
  active = ish_active_wall_buffer(handle);
  active[0] = 1;
  result = ish_result_buffer(handle);
  result->structSize = sizeof(*result);
  const double direction = std::atan2(cy-oy,cx-ox);
  CHECK(ish_query(handle,ox,oy,direction,70,1.0,2,active,1,result)==ISH_OK);
  bool foundCorner = false;
  for (uint32_t i=1;i<result->pointCount;i++) {
    const double px=result->points[i*2],py=result->points[i*2+1];
    if (std::abs(std::atan2(py-oy,px-ox)-direction)<1e-13) {
      CHECK(std::hypot(px-cx,py-cy)<1e-10);
      foundCorner = true;
    }
  }
  CHECK(foundCorner);
  CHECK(ish_close(handle)==ISH_OK);
  return 0;
}
