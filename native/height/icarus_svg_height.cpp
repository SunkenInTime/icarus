#include "icarus_svg_height.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

static_assert(sizeof(ISHResult) == 72);
static_assert(offsetof(ISHResult, points) == 8);
static_assert(offsetof(ISHResult, queryMicros) == 64);

namespace {
using Clock = std::chrono::steady_clock;
constexpr double pi = 3.141592653589793238462643383279502884;
constexpr double cornerOffset = 1e-8;
constexpr double slabPadding = 1e-10;
constexpr uint32_t maximumEdges = 1u << 19;
constexpr uint32_t maximumWalls = 1u << 20;
constexpr uint32_t maximumArcSteps = 4096;
constexpr size_t maximumPoints = 1u << 22;

struct Point {
  double x, y;
};

Point operator-(Point a, Point b) { return {a.x - b.x, a.y - b.y}; }
double cross(Point a, Point b) { return a.x * b.y - a.y * b.x; }
double dot(Point a, Point b) { return a.x * b.x + a.y * b.y; }

bool betweenOnSameLine(Point first, Point middle, Point last) {
  const Point span = last - first;
  const Point offset = middle - first;
  const double lengthSquared = dot(span, span);
  const double along = dot(offset, span);
  if (lengthSquared == 0 || along < 0 || along > lengthSquared)
    return false;
  const double length = std::sqrt(lengthSquared);
  const double roundoff = 64 * std::numeric_limits<double>::epsilon() *
                          std::max(1.0, length);
  return std::abs(cross(offset, span)) <= roundoff * length;
}

struct Bounds {
  double left, top, right, bottom;
};

struct Edge {
  Point a, b;
  uint32_t wall;
  uint32_t aVertex = 0, bVertex = 0;

  bool intersection(Point origin, Point direction, double range,
                    double &distance) const {
    const Point segment = b - a;
    const Point relative = a - origin;
    const double determinant = cross(direction, segment);
    if (determinant == 0) {
      if (cross(relative, direction) != 0)
        return false;
      const double first = dot(relative, direction);
      const double last = dot(b - origin, direction);
      const double entry = std::max(0.0, std::min(first, last));
      if (std::max(first, last) >= 0 && entry <= range) {
        distance = entry;
        return true;
      }
      return false;
    }
    const double rayDistance = cross(relative, segment) / determinant;
    const double along = cross(relative, direction) / determinant;
    // Admit floating-point endpoint roundoff, matching the Dart oracle. The
    // supporting line and reported intersection distance remain unchanged.
    constexpr double endpointRoundoff = 1e-12;
    if (rayDistance >= 0 && rayDistance <= range &&
        along >= -endpointRoundoff && along <= 1 + endpointRoundoff) {
      distance = rayDistance;
      return true;
    }
    return false;
  }
};

struct Node {
  Bounds bounds{};
  std::vector<uint32_t> ids;
  std::unique_ptr<Node> left, right;
};

Bounds edgeBounds(const Edge &edge) {
  return {std::min(edge.a.x, edge.b.x), std::min(edge.a.y, edge.b.y),
          std::max(edge.a.x, edge.b.x), std::max(edge.a.y, edge.b.y)};
}

void include(Bounds &target, const Bounds &value) {
  target.left = std::min(target.left, value.left);
  target.top = std::min(target.top, value.top);
  target.right = std::max(target.right, value.right);
  target.bottom = std::max(target.bottom, value.bottom);
}

std::unique_ptr<Node> buildNode(const std::vector<Edge> &edges,
                                std::vector<uint32_t> ids) {
  auto node = std::make_unique<Node>();
  node->bounds = edgeBounds(edges[ids.front()]);
  for (size_t i = 1; i < ids.size(); ++i)
    include(node->bounds, edgeBounds(edges[ids[i]]));
  if (ids.size() <= 8) {
    node->ids = std::move(ids);
    return node;
  }
  const bool horizontal = node->bounds.right - node->bounds.left >=
                          node->bounds.bottom - node->bounds.top;
  std::stable_sort(ids.begin(), ids.end(), [&](uint32_t first, uint32_t second) {
    const Edge &a = edges[first];
    const Edge &b = edges[second];
    const double ac = horizontal ? a.a.x + a.b.x : a.a.y + a.b.y;
    const double bc = horizontal ? b.a.x + b.b.x : b.a.y + b.b.y;
    return ac < bc;
  });
  const auto middle = ids.begin() + ids.size() / 2;
  node->left = buildNode(edges, std::vector<uint32_t>(ids.begin(), middle));
  node->right = buildNode(edges, std::vector<uint32_t>(middle, ids.end()));
  return node;
}

bool overlaps(const Bounds &a, const Bounds &b) {
  return !(a.left > b.right || a.right < b.left || a.top > b.bottom ||
           a.bottom < b.top);
}

struct PreparedRay {
  Point origin, direction;
  double inverseX, inverseY;
};

bool entry(const Bounds &bounds, const PreparedRay &ray, double range,
           double &result) {
  double lo = 0.0, hi = range;
  if (ray.direction.x == 0) {
    if (ray.origin.x < bounds.left - slabPadding ||
        ray.origin.x > bounds.right + slabPadding)
      return false;
  } else {
    const double a =
        (bounds.left - slabPadding - ray.origin.x) * ray.inverseX;
    const double b =
        (bounds.right + slabPadding - ray.origin.x) * ray.inverseX;
    lo = std::max(lo, std::min(a, b));
    hi = std::min(hi, std::max(a, b));
    if (lo > hi)
      return false;
  }
  if (ray.direction.y == 0) {
    if (ray.origin.y < bounds.top - slabPadding ||
        ray.origin.y > bounds.bottom + slabPadding)
      return false;
  } else {
    const double a =
        (bounds.top - slabPadding - ray.origin.y) * ray.inverseY;
    const double b =
        (bounds.bottom + slabPadding - ray.origin.y) * ray.inverseY;
    lo = std::max(lo, std::min(a, b));
    hi = std::min(hi, std::max(a, b));
    if (lo > hi)
      return false;
  }
  result = lo;
  return true;
}

struct Hit {
  bool found = false;
  double distance = 0;
  uint32_t edge = 0;
};

struct Counters {
  uint64_t edgeTests = 0, nodes = 0;
};

void collectCandidates(const Node *node, const Bounds &area,
                       std::vector<uint32_t> &output);
struct Crossing { Point point; uint32_t first, second; };

struct Handle {
  std::vector<Edge> edges;
  std::vector<Crossing> crossings;
  uint32_t wallCount;
  std::unique_ptr<Node> tree;
  std::vector<double> output;
  std::vector<uint8_t> activeScratch;
  ISHResult resultScratch{};
  std::vector<double> angles, arcAngles, vertexAngles;
  std::vector<Hit> arcHits;
  std::vector<uint32_t> candidates, vertexStamps;
  uint32_t nextVertexStamp = 1;
  std::mutex mutex;
  std::string error;

  Handle(std::vector<Edge> input, uint32_t walls)
      : edges(std::move(input)), wallCount(walls),
        activeScratch(std::max(uint32_t(1), walls)) {
    std::map<std::pair<double, double>, uint32_t> vertices;
    for (Edge &edge : edges) {
      auto id = [&](Point point) {
        const auto key = std::make_pair(point.x, point.y);
        const auto found = vertices.find(key);
        if (found != vertices.end())
          return found->second;
        const uint32_t value = uint32_t(vertices.size());
        vertices.emplace(key, value);
        return value;
      };
      edge.aVertex = id(edge.a);
      edge.bVertex = id(edge.b);
    }
    vertexStamps.resize(vertices.size());
    candidates.reserve(edges.size());
    angles.reserve(std::min(maximumPoints, size_t(4097) + vertices.size() * 3));
    arcAngles.reserve(maximumArcSteps + 1);
    vertexAngles.reserve(vertices.size());
    arcHits.reserve(maximumArcSteps + 1);
    if (!edges.empty()) {
      std::vector<uint32_t> ids(edges.size());
      for (uint32_t i = 0; i < ids.size(); ++i)
        ids[i] = i;
      tree = buildNode(edges, std::move(ids));
      // Compute the static crossing topology once, never during a frame query.
      std::vector<uint32_t> nearby;
      for (uint32_t i = 0; i < edges.size(); ++i) {
        const Edge &a = edges[i];
        const Point delta = a.b - a.a;
        nearby.clear();
        collectCandidates(tree.get(), edgeBounds(a), nearby);
        for (uint32_t j : nearby) {
          if (j <= i) continue;
          const Edge &b = edges[j];
          const Point other = b.b - b.a;
          const double determinant = cross(delta, other);
          if (determinant == 0) continue;
          const Point relative = b.a - a.a;
          const double t = cross(relative, other) / determinant;
          const double u = cross(relative, delta) / determinant;
          if (t > 0 && t < 1 && u > 0 && u < 1) {
            crossings.push_back({{a.a.x + delta.x * t, a.a.y + delta.y * t}, a.wall, b.wall});
            if (crossings.size() > maximumPoints)
              throw std::runtime_error("SVG crossing topology exceeds bounded capacity");
          }
        }
      }
    }
  }
};

Hit castRay(const Handle &handle, Point origin, Point direction, double range,
            const uint8_t *active, Counters &counters) {
  Hit result;
  if (!handle.tree || range == 0)
    return result;
  double best = range;
  const PreparedRay ray{origin, direction,
                        direction.x == 0 ? 0 : 1 / direction.x,
                        direction.y == 0 ? 0 : 1 / direction.y};
  // A balanced binary tree with at most 2^19 leaves needs fewer than 64
  // pending siblings. Keep ray traversal off the allocator hot path.
  struct Pending {
    const Node *node;
    double entryDistance;
  };
  std::array<Pending, 64> stack{};
  size_t stackSize = 0;
  double rootEntry;
  if (entry(handle.tree->bounds, ray, best, rootEntry))
    stack[stackSize++] = {handle.tree.get(), rootEntry};
  else
    ++counters.nodes;
  while (stackSize) {
    const Pending pending = stack[--stackSize];
    const Node *node = pending.node;
    ++counters.nodes;
    if (pending.entryDistance > best)
      continue;
    if (!node->ids.empty()) {
      for (uint32_t id : node->ids) {
        const Edge &edge = handle.edges[id];
        if (!active[edge.wall])
          continue;
        ++counters.edgeTests;
        double distance;
        if (edge.intersection(origin, direction, best, distance) &&
            (distance < best || !result.found)) {
          best = distance;
          result = {true, distance, id};
        }
      }
      continue;
    }
    double leftEntry, rightEntry;
    const bool hasLeft = entry(node->left->bounds, ray, best, leftEntry);
    const bool hasRight = entry(node->right->bounds, ray, best, rightEntry);
    if (hasLeft && hasRight) {
      if (leftEntry <= rightEntry) {
        stack[stackSize++] = {node->right.get(), rightEntry};
        stack[stackSize++] = {node->left.get(), leftEntry};
      } else {
        stack[stackSize++] = {node->left.get(), leftEntry};
        stack[stackSize++] = {node->right.get(), rightEntry};
      }
    } else if (hasLeft) {
      stack[stackSize++] = {node->left.get(), leftEntry};
    } else if (hasRight) {
      stack[stackSize++] = {node->right.get(), rightEntry};
    }
  }
  return result;
}

void collectCandidates(const Node *node, const Bounds &area,
                       std::vector<uint32_t> &output) {
  if (!overlaps(node->bounds, area))
    return;
  if (!node->ids.empty()) {
    output.insert(output.end(), node->ids.begin(), node->ids.end());
  } else {
    collectCandidates(node->left.get(), area, output);
    collectCandidates(node->right.get(), area, output);
  }
}

void copyText(const std::string &text, char *target, uint32_t capacity) {
  if (!target || capacity == 0)
    return;
  const size_t count = std::min(text.size(), size_t(capacity - 1));
  std::memcpy(target, text.data(), count);
  target[count] = 0;
}

int failure(Handle &handle, ISHResult *out, int status,
            const std::string &message) {
  handle.error = message;
  if (out) {
    *out = {};
    out->structSize = sizeof(ISHResult);
    out->status = uint32_t(status);
  }
  return status;
}
} // namespace

extern "C" {
void *ish_open(const double *records, uint32_t edgeCount, uint32_t wallCount,
               char *error, uint32_t errorCapacity) {
  try {
    if (edgeCount > maximumEdges || wallCount > maximumWalls ||
        (edgeCount && (!records || wallCount == 0)))
      throw std::runtime_error("invalid SVG edge or wall count");
    std::vector<Edge> edges;
    edges.reserve(edgeCount);
    for (uint32_t i = 0; i < edgeCount; ++i) {
      const double *row = records + size_t(i) * 5;
      for (int j = 0; j < 5; ++j)
        if (!std::isfinite(row[j]))
          throw std::runtime_error("non-finite SVG edge record");
      const double wall = row[4];
      if (wall < 0 || wall >= wallCount || std::floor(wall) != wall)
        throw std::runtime_error("SVG edge has invalid wall index");
      if (row[0] == row[2] && row[1] == row[3])
        throw std::runtime_error("zero-length SVG edge");
      edges.push_back({{row[0], row[1]}, {row[2], row[3]}, uint32_t(wall)});
    }
    auto handle = std::make_unique<Handle>(std::move(edges), wallCount);
    copyText("", error, errorCapacity);
    return handle.release();
  } catch (const std::exception &exception) {
    copyText(exception.what(), error, errorCapacity);
    return nullptr;
  } catch (...) {
    copyText("unknown SVG native initialization error", error, errorCapacity);
    return nullptr;
  }
}

uint8_t *ish_active_wall_buffer(void *opaque) {
  return opaque ? static_cast<Handle *>(opaque)->activeScratch.data() : nullptr;
}

ISHResult *ish_result_buffer(void *opaque) {
  return opaque ? &static_cast<Handle *>(opaque)->resultScratch : nullptr;
}

int32_t ish_query(void *opaque, double originX, double originY,
                  double directionRadians, double range,
                  double apertureRadians, uint32_t arcSteps,
                  const uint8_t *active, uint32_t activeWallCount,
                  ISHResult *out) {
  if (!opaque || !out || out->structSize != sizeof(ISHResult))
    return ISH_INVALID;
  auto &handle = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(handle.mutex, std::try_to_lock);
  if (!lock) {
    *out = {};
    out->structSize = sizeof(ISHResult);
    out->status = ISH_BUSY;
    return ISH_BUSY;
  }
  const auto started = Clock::now();
  try {
    const double values[] = {originX, originY, directionRadians, range,
                             apertureRadians};
    for (double value : values)
      if (!std::isfinite(value))
        return failure(handle, out, ISH_INVALID, "non-finite SVG query value");
    if (range < 0 || apertureRadians <= 0 || apertureRadians > 2 * pi ||
        arcSteps < 1 || arcSteps > maximumArcSteps || !active ||
        activeWallCount != handle.wallCount)
      return failure(handle, out, ISH_INVALID,
                     "invalid SVG query range, aperture, arc steps or mask");

    const Point origin{originX, originY};
    const double half = apertureRadians / 2;
    auto &angles = handle.angles;
    auto &arcAngles = handle.arcAngles;
    auto &vertexAngles = handle.vertexAngles;
    auto &arcHits = handle.arcHits;
    angles.clear();
    arcAngles.clear();
    vertexAngles.clear();
    arcHits.clear();
    Counters counters;
    for (uint32_t i = 0; i <= arcSteps; ++i) {
      const double angle = -half + apertureRadians * i / arcSteps;
      angles.push_back(angle);
      arcAngles.push_back(angle);
      const double world = directionRadians + angle;
      arcHits.push_back(castRay(handle, origin,
                                {std::cos(world), std::sin(world)}, range,
                                active, counters));
    }
    const auto prepared = Clock::now();

    auto &candidates = handle.candidates;
    candidates.clear();
    if (handle.tree) {
      const Bounds area{origin.x - range, origin.y - range, origin.x + range,
                        origin.y + range};
      collectCandidates(handle.tree.get(), area, candidates);
    }
    uint32_t vertexStamp = handle.nextVertexStamp++;
    if (vertexStamp == 0) {
      std::fill(handle.vertexStamps.begin(), handle.vertexStamps.end(), 0);
      vertexStamp = handle.nextVertexStamp++;
    }
    const double rangeSquared = range * range;
    auto hiddenEvent = [&](double angle, Point delta) {
      if (apertureRadians / arcSteps >= pi || angle <= -half || angle >= half) return false;
      int interval=int(std::floor((angle+half)/apertureRadians*double(arcSteps)));
      interval=std::max(0,std::min(interval,int(arcSteps)-1));
      const Hit &first=arcHits[size_t(interval)], &last=arcHits[size_t(interval)+1];
      if (!first.found || !last.found || first.edge!=last.edge ||
          angle-cornerOffset<arcAngles[size_t(interval)] ||
          angle+cornerOffset>arcAngles[size_t(interval)+1]) return false;
      const double distance=std::sqrt(dot(delta,delta));
      double hitDistance;
      return handle.edges[first.edge].intersection(origin,{delta.x/distance,delta.y/distance},distance,hitDistance)
          && hitDistance<distance-1e-7;
    };
    for (const Crossing &crossing : handle.crossings) {
      if (!active[crossing.first] || !active[crossing.second]) continue;
      const Point delta = crossing.point - origin;
      if (dot(delta, delta) > rangeSquared || (delta.x == 0 && delta.y == 0)) continue;
      const double relative = std::atan2(delta.y, delta.x) - directionRadians;
      const double angle = std::atan2(std::sin(relative), std::cos(relative));
      if (hiddenEvent(angle,delta)) continue;
      for (double event : {angle - cornerOffset, angle, angle + cornerOffset}) {
        if (event >= -half && event <= half) {
          angles.push_back(event);
          if (event == angle) vertexAngles.push_back(event);
        }
      }
    }
    for (uint32_t id : candidates) {
      const Edge &edge = handle.edges[id];
      if (!active[edge.wall])
        continue;
      // Preserve the exact wall/range-circle transition, even when neither
      // endpoint lies in range. Otherwise a polygon chord clips the wall early.
      const Point segment = edge.b - edge.a;
      const Point relativeStart = edge.a - origin;
      const double lengthSquared = dot(segment, segment);
      const double projection = -dot(relativeStart, segment) / lengthSquared;
      const Point closest{relativeStart.x + segment.x * projection,
                          relativeStart.y + segment.y * projection};
      const double remaining = rangeSquared - dot(closest, closest);
      if (remaining >= 0) {
        const double offset = std::sqrt(remaining / lengthSquared);
        for (double t : {projection - offset, projection + offset}) {
          if (t < 0 || t > 1) continue;
          const Point delta{relativeStart.x + segment.x * t,
                            relativeStart.y + segment.y * t};
          const double relative = std::atan2(delta.y, delta.x) - directionRadians;
          const double angle = std::atan2(std::sin(relative), std::cos(relative));
          if (angle >= -half && angle <= half && !hiddenEvent(angle,delta)) {
            angles.push_back(angle);
            vertexAngles.push_back(angle);
          }
        }
      }
      const Point endpoints[] = {edge.a, edge.b};
      const uint32_t vertexIds[] = {edge.aVertex, edge.bVertex};
      for (int endpoint = 0; endpoint < 2; ++endpoint) {
        const Point point = endpoints[endpoint];
        const uint32_t vertexId = vertexIds[endpoint];
        if (handle.vertexStamps[vertexId] == vertexStamp)
          continue;
        handle.vertexStamps[vertexId] = vertexStamp;
        const Point delta = point - origin;
        const double distanceSquared = dot(delta, delta);
        if (distanceSquared > rangeSquared ||
            (delta.x == 0 && delta.y == 0))
          continue;
        const double relative = std::atan2(delta.y, delta.x) - directionRadians;
        const double angle = std::atan2(std::sin(relative), std::cos(relative));
        if (apertureRadians / arcSteps < pi && angle > -half && angle < half) {
          int interval = int(std::floor((angle + half) / apertureRadians *
                                        double(arcSteps)));
          interval = std::max(0, std::min(interval, int(arcSteps) - 1));
          const Hit &first = arcHits[size_t(interval)];
          const Hit &last = arcHits[size_t(interval) + 1];
          if (first.found && last.found && first.edge == last.edge &&
              angle - cornerOffset >= arcAngles[size_t(interval)] &&
              angle + cornerOffset <= arcAngles[size_t(interval) + 1]) {
            const double distance = std::sqrt(distanceSquared);
            double hitDistance;
            const Point ray{delta.x / distance, delta.y / distance};
            if (handle.edges[first.edge].intersection(origin, ray, distance,
                                                       hitDistance) &&
                hitDistance < distance - 1e-7)
              continue;
          }
        }
        const double events[] = {angle - cornerOffset, angle,
                                 angle + cornerOffset};
        for (double event : events) {
          if (event >= -half && event <= half) {
            angles.push_back(event);
            if (event == angle)
              vertexAngles.push_back(event);
          }
        }
      }
    }
    std::sort(angles.begin(), angles.end());
    angles.erase(std::unique(angles.begin(), angles.end()), angles.end());
    std::sort(vertexAngles.begin(), vertexAngles.end());
    vertexAngles.erase(std::unique(vertexAngles.begin(), vertexAngles.end()),
                       vertexAngles.end());
    if (angles.size() + 1 > maximumPoints)
      return failure(handle, out, ISH_FAILED,
                     "SVG native result exceeds bounded point capacity");
    const auto candidatesFinished = Clock::now();

    handle.output.clear();
    handle.output.reserve((angles.size() + 1) * 2);
    handle.output.push_back(origin.x);
    handle.output.push_back(origin.y);
    Hit previousHit;
    size_t sameEdgeRun = 0;
    Point runAnchor{};
    for (double angle : angles) {
      const double world = directionRadians + angle;
      const Point direction{std::cos(world), std::sin(world)};
      Hit hit;
      const auto found = std::lower_bound(arcAngles.begin(), arcAngles.end(), angle);
      if (found != arcAngles.end() && *found == angle)
        hit = arcHits[size_t(found - arcAngles.begin())];
      else
        hit = castRay(handle, origin, direction, range, active, counters);
      const double distance = hit.found ? hit.distance : range;
      const double x = origin.x + direction.x * distance;
      const double y = origin.y + direction.y * distance;
      const bool isVertexAngle =
          std::binary_search(vertexAngles.begin(), vertexAngles.end(), angle);
      if (!isVertexAngle && hit.found && previousHit.found &&
          hit.edge == previousHit.edge) {
        ++sameEdgeRun;
        const Point point{x, y};
        if (sameEdgeRun == 2) {
          handle.output.push_back(x);
          handle.output.push_back(y);
        } else {
          const Point previous{handle.output[handle.output.size() - 2],
                               handle.output[handle.output.size() - 1]};
          if (betweenOnSameLine(runAnchor, previous, point)) {
            handle.output[handle.output.size() - 2] = x;
            handle.output[handle.output.size() - 1] = y;
          } else {
            // Endpoint roundoff can assign an excursion to the same edge as
            // its neighbors. Keep it unless the points themselves prove that
            // the middle point is redundant.
            runAnchor = previous;
            handle.output.push_back(x);
            handle.output.push_back(y);
          }
        }
      } else {
        // Literal vertex rays stay in the returned boundary. In particular,
        // an exact endpoint ray can form a corner excursion even when its hit
        // edge matches both adjacent rays.
        previousHit = hit;
        sameEdgeRun = 1;
        runAnchor = {x, y};
        handle.output.push_back(x);
        handle.output.push_back(y);
      }
    }

    const auto finished = Clock::now();
    *out = {};
    out->structSize = sizeof(ISHResult);
    out->status = ISH_OK;
    out->points = handle.output.data();
    out->pointCount = uint32_t(handle.output.size() / 2);
    out->rayCount = uint32_t(angles.size());
    out->edgeTests = counters.edgeTests;
    out->spatialNodes = counters.nodes;
    out->candidateEdges = uint32_t(candidates.size());
    out->preparationMicros =
        std::chrono::duration<double, std::micro>(prepared - started).count();
    out->candidateMicros = std::chrono::duration<double, std::micro>(
                               candidatesFinished - prepared)
                               .count();
    out->queryMicros =
        std::chrono::duration<double, std::micro>(finished - started).count();
    handle.error.clear();
    return ISH_OK;
  } catch (const std::exception &exception) {
    return failure(handle, out, ISH_FAILED, exception.what());
  } catch (...) {
    return failure(handle, out, ISH_FAILED, "unknown SVG native query error");
  }
}

int32_t ish_last_error(void *opaque, char *error, uint32_t capacity) {
  if (!opaque || !error || capacity == 0)
    return ISH_INVALID;
  auto &handle = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(handle.mutex, std::try_to_lock);
  if (!lock)
    return ISH_BUSY;
  copyText(handle.error, error, capacity);
  return ISH_OK;
}

int32_t ish_close(void *opaque) {
  if (!opaque)
    return ISH_INVALID;
  auto *handle = static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(handle->mutex, std::try_to_lock);
  if (!lock)
    return ISH_BUSY;
  lock.unlock();
  delete handle;
  return ISH_OK;
}

void ish_close_finalizer(void *opaque) { delete static_cast<Handle *>(opaque); }
}
