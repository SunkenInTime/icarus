#include "icarus_svg_height.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

static_assert(sizeof(ISHResult) == 72);
static_assert(offsetof(ISHResult, points) == 8);
static_assert(offsetof(ISHResult, queryMicros) == 64);

namespace {
using Clock = std::chrono::steady_clock;
constexpr double pi = 3.141592653589793238462643383279502884;
constexpr double infinity = std::numeric_limits<double>::infinity();
constexpr double cornerOffset = 1e-8;
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
  // See the Dart _Edge: corner roundoff admitted along the wall.
  double inverseLength = 0;
  // The side its own wall lies on, going a to b: 0 right, 1 left, 2 unknown.
  uint8_t interior = 2;

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
    const double slack = (1e-13 + rayDistance * 1e-10) * inverseLength;
    if (rayDistance >= 0 && rayDistance <= range &&
        along >= -slack && along <= 1 + slack) {
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

struct Hit {
  bool found = false;
  double distance = 0;
  uint32_t edge = 0;
};

struct Crossing { Point point; uint32_t first, second; };

// Moves a per-query stamp on, clearing its marks the one time in 2^32 it
// wraps, so a stale mark never matches.
void advance(uint32_t &stamp, std::vector<uint32_t> &marks) {
  if (++stamp == 0) {
    std::fill(marks.begin(), marks.end(), 0u);
    stamp = 1;
  }
}

// Margins on the proofs: rounding in the angles and distances here is some
// 1e-15, far inside these.
constexpr double angleMargin = 1e-9;
constexpr double relativeMargin = 1e-9, absoluteMargin = 1e-9;
// Rays beside a corner leave this far from its angle.
constexpr double cornerSlack = cornerOffset + angleMargin;
// The narrowest bin; a cone's bins are about this wide.
constexpr double binWidth = 2 * pi / 2048;

bool beyond(double distance, double depth) {
  return distance > depth * (1 + relativeMargin) + absoluteMargin;
}

double distanceTo(const Bounds &bounds, double x, double y) {
  const double dx = std::max(0.0, std::max(bounds.left - x, x - bounds.right));
  const double dy = std::max(0.0, std::max(bounds.top - y, y - bounds.bottom));
  return std::sqrt(dx * dx + dy * dy);
}

// The active edges a cone's eye may see, filed by the angles they cover. This
// is the Dart _ConeBins in lib/view_cone/svg_height_visibility.dart, which
// carries the proofs.
//
// Every ray of a cone leaves the same eye. So rather than walk the edge tree
// once per ray, a query files the edges it may meet once: each gets its
// nearest distance to the eye and the span of angles it covers, and goes into
// every bin of that span. A ray then tests only its bin's edges.
//
// Each bin also gets a depth, the farthest any ray in it can travel. A run of
// consecutive ring edges that crosses a bin from one boundary to the next is
// an unbroken wall across it, so every ray in the bin stops no farther than
// the run's farthest point there. Whatever begins beyond the depths it spans
// is hidden: an edge there is not filed, and a corner there needs no rays.
//
// The edge tree is walked nearest node first, and a node whose bounds begin
// beyond the depths of every bin they span is skipped whole. Depths are only
// ever used with a margin, and whatever they let through is tested exactly,
// so the outline is the one every edge would give.
struct ConeBins {
  const std::vector<Edge> *edges = nullptr;
  const std::vector<Point> *points = nullptr;
  const uint8_t *active = nullptr;

  // Filed edges, by slot: edge id, nearest distance to the eye, and the span
  // of angles from the cone's direction they cover, which may run past pi.
  std::vector<uint32_t> edgeIds;
  std::vector<double> near, from, to;

  // Bins split [lowest, lowest + binCount * width] evenly. Bin k's filed
  // slots are items[offsets[k]] up to items[offsets[k + 1]], nearest first.
  uint32_t binCount = 0;
  double lowest = 0, width = 1;
  std::vector<uint32_t> offsets, items;

  // The farthest any ray in a bin can travel; infinite when unproven.
  std::vector<double> depth;
  // The largest depth over ranges of bins: a segment tree whose leaves, from
  // index leaves on, are the depths.
  std::vector<double> peaks;
  size_t leaves = 0;
  // The world direction of each bin boundary.
  std::vector<double> boundaryX, boundaryY;

  double cosine = 1, sine = 0, ox = 0, oy = 0;
  bool whole = false;

  // Per vertex this query, where vertexMark is vertexStamp: its angle from
  // the cone's direction and its distance from the eye.
  std::vector<double> vertexAngle, vertexDistance;
  std::vector<uint32_t> vertexMark;
  uint32_t vertexStamp = 0;

  // Edges filed this query that a run can pass through: slotMark is mark.
  // An edge through the eye stops nothing reliably beside it.
  std::vector<uint32_t> slotMark;
  uint32_t mark = 0;
  // The runs to walk this wave: dirty is dirtyStamp on their edges.
  std::vector<uint32_t> dirty;
  uint32_t dirtyStamp = 0;
  std::vector<uint32_t> heads;

  // Tree nodes waiting to be visited, nearest first: a binary heap.
  std::vector<const Node *> heapNodes;
  std::vector<double> heapKeys;

  uint64_t nodes = 0;

  void reserve(size_t vertexCount, size_t edgeCount) {
    vertexAngle.resize(vertexCount);
    vertexDistance.resize(vertexCount);
    vertexMark.assign(vertexCount, 0);
    slotMark.assign(edgeCount, 0);
    dirty.assign(edgeCount, 0);
  }

  size_t count() const { return edgeIds.size(); }

  // The angle of dx, dy from the cone's direction, in [-pi, pi].
  double angleOf(double dx, double dy) const {
    return std::atan2(-dx * sine + dy * cosine, dx * cosine + dy * sine);
  }

  uint32_t binOf(double angle) const {
    const double k = std::floor((angle - lowest) / width);
    return k < 0 ? 0 : (k >= binCount ? binCount - 1 : uint32_t(k));
  }

  // Whether every ray within a corner offset of angle provably stops before
  // distance.
  bool hides(double angle, double distance) const {
    const uint32_t last = binOf(angle + cornerSlack);
    for (uint32_t k = binOf(angle - cornerSlack); k <= last; ++k)
      if (!beyond(distance, depth[k]))
        return false;
    // Behind a full circle, rays beside an angle at the seam wrap round.
    if (whole) {
      if (angle - cornerSlack < lowest &&
          !beyond(distance, depth[binCount - 1]))
        return false;
      if (angle + cornerSlack > lowest + binCount * width &&
          !beyond(distance, depth[0]))
        return false;
    }
    return true;
  }

  void file(const std::vector<Edge> &edgeList,
            const std::vector<Point> &vertexPoints, const Node *root,
            Point origin, double direction, double range,
            const uint8_t *activeWalls, double lowestAngle, double span) {
    edges = &edgeList;
    points = &vertexPoints;
    active = activeWalls;
    cosine = std::cos(direction);
    sine = std::sin(direction);
    lowest = lowestAngle;
    ox = origin.x;
    oy = origin.y;
    advance(vertexStamp, vertexMark);
    advance(mark, slotMark);
    const uint32_t bins =
        std::max(64u, uint32_t(std::ceil(span / binWidth)));
    binCount = bins;
    width = span / bins;
    whole = span >= 2 * pi;
    boundaryX.resize(bins + 1);
    boundaryY.resize(bins + 1);
    for (uint32_t j = 0; j <= bins; ++j) {
      const double world = direction + lowest + j * width;
      boundaryX[j] = std::cos(world);
      boundaryY[j] = std::sin(world);
    }
    depth.assign(bins, infinity);
    leaves = 1;
    while (leaves < bins)
      leaves *= 2;
    peaks.assign(2 * leaves, infinity);
    edgeIds.clear();
    near.clear();
    from.clear();
    to.clear();
    nodes = 0;
    if (root)
      walk(root, range);

    // File each edge in the bins it may be seen in: count, then place.
    offsets.assign(bins + 1, 0);
    place(false);
    for (uint32_t k = 0; k < bins; ++k)
      offsets[k + 1] += offsets[k];
    if (items.size() < offsets[bins])
      items.resize(std::max<size_t>(offsets[bins], items.size() * 2));
    place(true);
    // Placing advanced each bin's offset to the next bin's start.
    for (uint32_t k = bins; k > 0; --k)
      offsets[k] = offsets[k - 1];
    offsets[0] = 0;
    // Nearest first within each bin, so a ray stops at the first edge that
    // begins beyond its hit. The walk filed them nearly in this order.
    for (uint32_t k = 0; k < bins; ++k) {
      const uint32_t begin = offsets[k], end = offsets[k + 1];
      for (uint32_t i = begin + 1; i < end; ++i) {
        const uint32_t slot = items[i];
        const double key = near[slot];
        uint32_t j = i;
        while (j > begin && near[items[j - 1]] > key) {
          items[j] = items[j - 1];
          --j;
        }
        items[j] = slot;
      }
    }
  }

  // The nearest hit along direction, angle from the cone's direction, within
  // range; ties go to the lowest edge id.
  Hit cast(Point origin, Point direction, double angle, double range,
           uint64_t &edgeTests) const {
    const uint32_t k = binOf(angle);
    double best = range;
    bool found = false;
    uint32_t bestId = 0;
    for (uint32_t i = offsets[k]; i < offsets[k + 1]; ++i) {
      const uint32_t slot = items[i];
      if (near[slot] > best)
        break;
      const uint32_t id = edgeIds[slot];
      ++edgeTests;
      double distance;
      if (!(*edges)[id].intersection(origin, direction, best, distance))
        continue;
      if (!found || distance < best || (distance == best && id < bestId)) {
        best = distance;
        bestId = id;
        found = true;
      }
    }
    return found ? Hit{true, best, bestId} : Hit{};
  }

private:
  void see(uint32_t vertex) {
    if (vertexMark[vertex] == vertexStamp)
      return;
    vertexMark[vertex] = vertexStamp;
    const Point point = (*points)[vertex];
    const double dx = point.x - ox, dy = point.y - oy;
    vertexAngle[vertex] = angleOf(dx, dy);
    vertexDistance[vertex] = std::sqrt(dx * dx + dy * dy);
  }

  void push(const Node *node, double key) {
    size_t i = heapNodes.size();
    heapNodes.push_back(node);
    heapKeys.push_back(key);
    while (i > 0) {
      const size_t parent = (i - 1) >> 1;
      if (heapKeys[parent] <= key)
        break;
      heapNodes[i] = heapNodes[parent];
      heapKeys[i] = heapKeys[parent];
      i = parent;
    }
    heapNodes[i] = node;
    heapKeys[i] = key;
  }

  // Removes the nearest node and its key.
  const Node *pop(double &popped) {
    const Node *top = heapNodes[0];
    popped = heapKeys[0];
    const Node *node = heapNodes.back();
    const double key = heapKeys.back();
    heapNodes.pop_back();
    heapKeys.pop_back();
    const size_t n = heapNodes.size();
    if (n > 0) {
      size_t i = 0;
      for (;;) {
        size_t child = 2 * i + 1;
        if (child >= n)
          break;
        if (child + 1 < n && heapKeys[child + 1] < heapKeys[child])
          ++child;
        if (heapKeys[child] >= key)
          break;
        heapNodes[i] = heapNodes[child];
        heapKeys[i] = heapKeys[child];
        i = child;
      }
      heapNodes[i] = node;
      heapKeys[i] = key;
    }
    return top;
  }

  void walk(const Node *root, double range) {
    heapNodes.clear();
    heapKeys.clear();
    push(root, distanceTo(root->bounds, ox, oy));
    // Depths are proven from the edges filed so far, again each time the
    // walk passes four times as far from the eye.
    double wave = std::max(range / 16, 1e-3);
    size_t proven = 0;
    while (!heapNodes.empty()) {
      double distance;
      const Node *node = pop(distance);
      if (distance > range)
        break;
      if (distance > wave) {
        if (count() > proven) {
          walkChains(proven);
          raisePeaks();
          proven = count();
        }
        while (wave < distance)
          wave *= 4;
      }
      ++nodes;
      if (!boundsMayShow(node->bounds, distance))
        continue;
      if (!node->ids.empty()) {
        for (uint32_t id : node->ids)
          fileEdge(id, range);
      } else {
        const Node *left = node->left.get(), *right = node->right.get();
        const double leftKey = distanceTo(left->bounds, ox, oy);
        if (leftKey <= range)
          push(left, leftKey);
        const double rightKey = distanceTo(right->bounds, ox, oy);
        if (rightKey <= range)
          push(right, rightKey);
      }
    }
    if (count() > proven)
      walkChains(proven);
  }

  // Whether anything in bounds, distance from the eye at its nearest, could
  // show in the cone.
  bool boundsMayShow(const Bounds &bounds, double distance) const {
    const int column = ox < bounds.left ? 0 : (ox > bounds.right ? 2 : 1);
    const int row = oy < bounds.top ? 0 : (oy > bounds.bottom ? 2 : 1);
    if (distance < absoluteMargin || (column == 1 && row == 1))
      return true;
    // Seen from outside, a box spans less than half a turn, between the two
    // corners that bound its silhouette. Which two depends only on where the
    // eye is around the box: per region, each corner as (right?, bottom?).
    static constexpr bool silhouette[3][3][4] = {
        {{1, 0, 0, 1}, {0, 0, 1, 0}, {0, 0, 1, 1}},
        {{0, 0, 0, 1}, {0, 0, 0, 0}, {1, 0, 1, 1}},
        {{0, 0, 1, 1}, {0, 1, 1, 1}, {1, 0, 0, 1}}};
    const bool *corners = silhouette[row][column];
    const double ax = (corners[0] ? bounds.right : bounds.left) - ox;
    const double ay = (corners[1] ? bounds.bottom : bounds.top) - oy;
    const double bx = (corners[2] ? bounds.right : bounds.left) - ox;
    const double by = (corners[3] ? bounds.bottom : bounds.top) - oy;
    const auto [first, last] =
        span(ax, ay, bx, by, angleOf(ax, ay), angleOf(bx, by));
    return mayShow(first - cornerSlack, last + cornerSlack, distance);
  }

  // The angles the eye sees between points a and b, at angles ta and tb:
  // first to last, last unwrapped past first.
  static std::pair<double, double> span(double ax, double ay, double bx,
                                        double by, double ta, double tb) {
    const double turn = ax * by - ay * bx;
    double first, last;
    if (turn > 0) {
      first = ta;
      last = tb;
    } else if (turn < 0) {
      first = tb;
      last = ta;
    } else {
      first = std::min(ta, tb);
      last = std::max(ta, tb);
    }
    if (last < first)
      last += 2 * pi;
    return {first, last};
  }

  // Whether something distance from the eye, spanning angles first to last
  // (which may run past pi), falls in the cone and is not provably behind
  // the depths there.
  bool mayShow(double first, double last, double distance) const {
    constexpr double margin = 1e-6;
    const double highest = lowest + binCount * width;
    for (double shift = 2 * pi; shift > -4 * pi; shift -= 2 * pi) {
      const double start = first + shift, end = last + shift;
      if (end < lowest - margin || start > highest + margin)
        continue;
      if (!beyond(distance, peak(binOf(start), binOf(end))))
        return true;
    }
    return false;
  }

  // The largest depth over bins first to last.
  double peak(uint32_t first, uint32_t last) const {
    double result = 0;
    size_t low = first + leaves, high = last + leaves + 1;
    while (low < high) {
      if (low & 1)
        result = std::max(result, peaks[low++]);
      if (high & 1)
        result = std::max(result, peaks[--high]);
      low >>= 1;
      high >>= 1;
    }
    return result;
  }

  void raisePeaks() {
    std::copy(depth.begin(), depth.begin() + binCount,
              peaks.begin() + leaves);
    for (size_t i = leaves - 1; i > 0; --i)
      peaks[i] = std::max(peaks[2 * i], peaks[2 * i + 1]);
  }

  void fileEdge(uint32_t id, double range) {
    const Edge &edge = (*edges)[id];
    if (!active[edge.wall])
      return;
    const double ax = edge.a.x - ox, ay = edge.a.y - oy;
    const double bx = edge.b.x - ox, by = edge.b.y - oy;
    const double ex = edge.b.x - edge.a.x, ey = edge.b.y - edge.a.y;
    const double lengthSquared = ex * ex + ey * ey;
    double t = lengthSquared == 0 ? 0.0 : -(ax * ex + ay * ey) / lengthSquared;
    t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    const double cx = ax + ex * t, cy = ay + ey * t;
    const double distance = std::sqrt(cx * cx + cy * cy);
    if (distance > range)
      return;
    see(edge.aVertex);
    see(edge.bVertex);
    double first = -pi, last = pi;
    if (distance >= absoluteMargin) {
      std::tie(first, last) = span(ax, ay, bx, by, vertexAngle[edge.aVertex],
                                   vertexAngle[edge.bVertex]);
      if (!mayShow(first - cornerSlack, last + cornerSlack, distance))
        return;
      slotMark[id] = mark;
    }
    edgeIds.push_back(id);
    near.push_back(distance);
    from.push_back(first);
    to.push_back(last);
  }

  // A boundary index of a whole turn's bins, brought into [0, binCount):
  // a run's unwrapped angle stays within a few turns.
  int64_t wrap(int64_t j) const {
    while (j < 0)
      j += binCount;
    while (j >= binCount)
      j -= binCount;
    return j;
  }

  bool chained(int64_t id) const {
    return id >= 0 && id < int64_t(edges->size()) && slotMark[size_t(id)] == mark;
  }

  // Lowers each bin's depth to the farthest point of any run of consecutive
  // ring edges that crosses the bin from one boundary to the next. Such a run
  // is an unbroken wall across the bin, so it stops every ray in it. Single
  // edges rarely span a bin: Riot's outlines are many short strokes.
  void walkChains(size_t firstNew) {
    const std::vector<Edge> &list = *edges;
    // Runs already walked have proven all they can; walk again only those
    // with an edge filed since, each from its first edge.
    advance(dirtyStamp, dirty);
    const uint32_t stamp = dirtyStamp;
    heads.clear();
    for (size_t slot = firstNew; slot < count(); ++slot) {
      uint32_t id = edgeIds[slot];
      if (slotMark[id] != mark)
        continue;
      while (dirty[id] != stamp) {
        dirty[id] = stamp;
        if (!chained(int64_t(id) - 1) || list[id - 1].bVertex != list[id].aVertex) {
          heads.push_back(id);
          break;
        }
        --id;
      }
    }
    const int64_t bins = binCount;
    for (uint32_t head : heads) {
      uint32_t id = head;
      double raw = vertexAngle[list[id].aVertex];
      // The run's angle, unwrapped so it never jumps by a turn.
      double angle = raw;
      // The last boundary crossed, and since then: the farthest point and the
      // angles the run has reached.
      bool hasLast = false;
      int64_t last = 0;
      double farthest = 0, lowAngle = 0, highAngle = 0;
      for (;;) {
        const Edge &edge = list[id];
        const uint32_t next = edge.bVertex;
        const double nextRaw = vertexAngle[next];
        double turn = nextRaw - raw;
        if (turn > pi)
          turn -= 2 * pi;
        else if (turn <= -pi)
          turn += 2 * pi;
        const double end = angle + turn;
        const double ex = edge.b.x - edge.a.x, ey = edge.b.y - edge.a.y;
        const double along = (edge.a.x - ox) * ey - (edge.a.y - oy) * ex;
        // Boundaries the edge plainly crosses, in the order it crosses them.
        const int64_t step = end > angle ? 1 : -1;
        double start = step > 0
                           ? std::ceil((angle + angleMargin - lowest) / width)
                           : std::floor((angle - angleMargin - lowest) / width);
        double finish = step > 0
                            ? std::floor((end - angleMargin - lowest) / width)
                            : std::ceil((end + angleMargin - lowest) / width);
        if (!whole) {
          // Boundaries outside the cone are skipped below and leave the run
          // alone, so only those just outside need walking. A narrow cone's
          // bins are so fine the others can lie past any integer.
          start = std::min(std::max(start, -1.0), bins + 1.0);
          finish = std::min(std::max(finish, -1.0), bins + 1.0);
        }
        const int64_t stop = int64_t(finish);
        for (int64_t j = int64_t(start); step > 0 ? j <= stop : j >= stop;
             j += step) {
          if (!whole && (j < 0 || j > bins))
            continue;
          const int64_t boundary = whole ? wrap(j) : j;
          const double distance =
              along / (boundaryX[size_t(boundary)] * ey -
                       boundaryY[size_t(boundary)] * ex);
          const double at = lowest + double(j) * width;
          if (!(distance >= 0 && distance < infinity)) {
            hasLast = false;
            continue;
          }
          if (hasLast && std::abs(j - last) == 1) {
            const double previous = lowest + double(last) * width;
            // Between the two crossings the run stayed inside the bin.
            if (lowAngle >= std::min(at, previous) - 1e-8 &&
                highAngle <= std::max(at, previous) + 1e-8) {
              const int64_t low = std::min(j, last);
              const size_t k = size_t(whole ? wrap(low) : low);
              const double bound = std::max(farthest, distance);
              if (bound < depth[k])
                depth[k] = bound;
            }
          }
          hasLast = true;
          last = j;
          farthest = distance;
          lowAngle = highAngle = at;
        }
        farthest = std::max(farthest, vertexDistance[next]);
        lowAngle = std::min(lowAngle, end);
        highAngle = std::max(highAngle, end);
        if (!chained(int64_t(id) + 1) || list[id + 1].aVertex != next)
          break;
        ++id;
        raw = nextRaw;
        angle = end;
      }
    }
  }

  // Counts each slot into offsets[k + 1] for every bin k it is filed in, or,
  // with fill, writes it at offsets[k] and advances that.
  void place(bool fill) {
    const double highest = lowest + binCount * width;
    const uint32_t slots = uint32_t(count());
    for (uint32_t slot = 0; slot < slots; ++slot) {
      const double distance = near[slot];
      if (distance < absoluteMargin) {
        // An edge through the eye can stop a ray in any direction.
        for (uint32_t k = 0; k < binCount; ++k) {
          if (fill)
            items[offsets[k]++] = slot;
          else
            ++offsets[k + 1];
        }
        continue;
      }
      // Rays are admitted a sliver past an edge's ends; see Edge::intersection.
      const double pad = angleMargin + 1e-12 / distance;
      // A span starting just below -pi also covers the bins just below pi.
      for (double shift = 2 * pi; shift > -4 * pi; shift -= 2 * pi) {
        const double start = from[slot] + shift - pad;
        const double end = to[slot] + shift + pad;
        if (end < lowest)
          break;
        if (start > highest)
          continue;
        const uint32_t first = binOf(start), last = binOf(end);
        for (uint32_t k = first; k <= last; ++k) {
          if (beyond(distance, depth[k]))
            continue;
          if (fill)
            items[offsets[k]++] = slot;
          else
            ++offsets[k + 1];
        }
      }
    }
  }
};

struct Handle {
  std::vector<Edge> edges;
  std::vector<Crossing> crossings;
  uint32_t wallCount;
  std::unique_ptr<Node> tree;
  std::vector<double> output;
  std::vector<uint8_t> activeScratch;
  ISHResult resultScratch{};
  std::vector<double> angles, vertexAngles;
  // The edges meeting at each vertex, to tell a corner from a seam.
  std::vector<std::vector<uint32_t>> vertexEdges;
  std::vector<Point> vertexPoints;
  ConeBins bins;
  // Vertices already turned into events this query: eventMark is eventStamp.
  std::vector<uint32_t> eventMark;
  uint32_t eventStamp = 0;
  bool interiorSides = false;
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
      const Point delta = edge.b - edge.a;
      edge.inverseLength = 1 / std::sqrt(dot(delta, delta));
    }
    vertexEdges.resize(vertices.size());
    vertexPoints.resize(vertices.size());
    for (const auto &[key, value] : vertices)
      vertexPoints[value] = {key.first, key.second};
    for (uint32_t i = 0; i < edges.size(); ++i) {
      vertexEdges[edges[i].aVertex].push_back(i);
      vertexEdges[edges[i].bVertex].push_back(i);
    }
    bins.reserve(vertices.size(), edges.size());
    eventMark.assign(vertices.size(), 0);
    angles.reserve(std::min(maximumPoints, size_t(4097) + vertices.size() * 3));
    vertexAngles.reserve(vertices.size());
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

// Whether no active boundary turns at a vertex: the edges two touching pieces
// share cancel, and what remains runs straight through it, or nothing does.
// A ray there meets the wall the rays beside it meet, so it is not an event.
// Pieces cut along one stroke leave such seams every metre or so.
bool seam(const Handle &handle, uint32_t vertex, const uint8_t *active) {
  if (!handle.interiorSides) return false;
  std::array<uint32_t, 8> live{};
  size_t count = 0;
  for (uint32_t id : handle.vertexEdges[vertex]) {
    if (!active[handle.edges[id].wall]) continue;
    if (count == live.size()) return false;
    live[count++] = id;
  }
  std::array<bool, 8> cancelled{};
  for (size_t i = 0; i < count; ++i) {
    const Edge &first = handle.edges[live[i]];
    for (size_t j = i + 1; j < count && !cancelled[i]; ++j) {
      if (cancelled[j]) continue;
      const Edge &second = handle.edges[live[j]];
      // A shared side only when the two walls lie on either side of it.
      const bool same = first.aVertex == second.aVertex && first.bVertex == second.bVertex;
      const bool reversed = first.aVertex == second.bVertex && first.bVertex == second.aVertex;
      if (first.interior > 1 || second.interior > 1) continue;
      if ((same && first.interior != second.interior) ||
          (reversed && first.interior == second.interior))
        cancelled[i] = cancelled[j] = true;
    }
  }
  std::array<Point, 2> away{};
  size_t remaining = 0;
  const Point at = handle.vertexPoints[vertex];
  for (size_t i = 0; i < count; ++i) {
    if (cancelled[i]) continue;
    if (remaining == 2) return false;
    const Edge &edge = handle.edges[live[i]];
    away[remaining++] = (edge.aVertex == vertex ? edge.b : edge.a) - at;
  }
  if (remaining == 0) return true;
  if (remaining == 1) return false;
  const double lengths = std::sqrt(dot(away[0], away[0]) * dot(away[1], away[1]));
  return dot(away[0], away[1]) < 0 &&
         std::abs(cross(away[0], away[1])) <= 1e-12 * lengths;
}

// Whether the wall runs straight across the ray at a vertex: its two active
// edges there leave to either side of the ray's line. Rays just beside such
// a vertex meet those two edges, so only the vertex ray adds a corner. Rays
// beside the vertex matter where the wall turns back (a silhouette) and
// something further can show past it.
bool passThrough(const Handle &handle, uint32_t vertex, Point delta,
                 const uint8_t *active) {
  std::array<double, 2> sides{};
  size_t count = 0;
  const Point at = handle.vertexPoints[vertex];
  for (uint32_t id : handle.vertexEdges[vertex]) {
    const Edge &edge = handle.edges[id];
    if (!active[edge.wall]) continue;
    if (count == sides.size()) return false;
    sides[count++] = cross(delta, (edge.aVertex == vertex ? edge.b : edge.a) - at);
  }
  return count == 2 && sides[0] * sides[1] < 0;
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

int32_t ish_set_interior_sides(void *opaque, const uint8_t *sides,
                               uint32_t edgeCount) {
  if (!opaque || !sides) return ISH_INVALID;
  auto &handle = *static_cast<Handle *>(opaque);
  std::lock_guard<std::mutex> lock(handle.mutex);
  if (edgeCount != handle.edges.size()) return ISH_INVALID;
  for (uint32_t i = 0; i < edgeCount; ++i)
    if (sides[i] > 2) return ISH_INVALID;
  for (uint32_t i = 0; i < edgeCount; ++i)
    handle.edges[i].interior = sides[i];
  handle.interiorSides = true;
  return ISH_OK;
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

    // Every ray starts at the eye, so the walls near it are filed by the
    // angle they cover (see ConeBins): a ray tests only the few edges in its
    // bin, and a corner that a nearer wall provably hides casts no rays.
    const Point origin{originX, originY};
    const double half = apertureRadians / 2;
    const bool whole = half + 1e-6 >= pi;
    ConeBins &bins = handle.bins;
    bins.file(handle.edges, handle.vertexPoints, handle.tree.get(), origin,
              directionRadians, range, active, whole ? -pi : -half,
              whole ? 2 * pi : apertureRadians);

    auto &angles = handle.angles;
    auto &vertexAngles = handle.vertexAngles;
    angles.clear();
    vertexAngles.clear();
    for (uint32_t i = 0; i <= arcSteps; ++i)
      angles.push_back(-half + apertureRadians * i / arcSteps);
    // Rays aimed at a vertex or at a wall's crossing of the range circle stay
    // in the outline even when their neighbours meet the same edge.
    auto add = [&](double event, bool vertex) {
      // Behind a full circle, a ray beside the seam wraps round to the other
      // end: -pi and pi are the same direction.
      if (whole && event < -half) event += 2 * pi;
      if (whole && event > half) event -= 2 * pi;
      if (event < -half || event > half) return;
      angles.push_back(event);
      if (vertex) vertexAngles.push_back(event);
    };
    auto emit = [&](double angle, bool beside) {
      if (beside) add(angle - cornerOffset, false);
      add(angle, true);
      if (beside) add(angle + cornerOffset, false);
    };
    // Whether an event at angle could start a ray in the aperture and is not
    // provably behind a nearer wall.
    auto open = [&](double angle, double distance) {
      if (!whole && (angle < -half - 1e-6 || angle > half + 1e-6))
        return false;
      return !bins.hides(angle, distance);
    };

    const double rangeSquared = range * range;
    // Overlapping painted strokes create visibility corners at their crossing.
    for (const Crossing &crossing : handle.crossings) {
      if (!active[crossing.first] || !active[crossing.second]) continue;
      const Point delta = crossing.point - origin;
      const double distanceSquared = dot(delta, delta);
      if (distanceSquared > rangeSquared || (delta.x == 0 && delta.y == 0))
        continue;
      const double angle = bins.angleOf(delta.x, delta.y);
      if (!open(angle, std::sqrt(distanceSquared))) continue;
      emit(angle, true);
    }
    const auto prepared = Clock::now();

    advance(handle.eventStamp, handle.eventMark);
    const uint32_t stamp = handle.eventStamp;
    for (size_t slot = 0; slot < bins.count(); ++slot) {
      const uint32_t id = bins.edgeIds[slot];
      const Edge &edge = handle.edges[id];
      // A long wall can cross the range circle without either endpoint being
      // in range. Seed that exact transition so the polygon follows the wall
      // all the way to the circle instead of cutting diagonally short of it.
      const Point segment = edge.b - edge.a;
      const Point relative = edge.a - origin;
      const double lengthSquared = dot(segment, segment);
      const double projection = -dot(relative, segment) / lengthSquared;
      const Point closest{relative.x + segment.x * projection,
                          relative.y + segment.y * projection};
      const double remaining = rangeSquared - dot(closest, closest);
      if (remaining >= 0) {
        const double offset = std::sqrt(remaining / lengthSquared);
        for (double t : {projection - offset, projection + offset}) {
          if (t < 0 || t > 1) continue;
          const double angle = bins.angleOf(relative.x + segment.x * t,
                                            relative.y + segment.y * t);
          if (!open(angle, range)) continue;
          if (angle >= -half && angle <= half) {
            angles.push_back(angle);
            vertexAngles.push_back(angle);
          }
        }
      }
      for (uint32_t vertex : {edge.aVertex, edge.bVertex}) {
        if (handle.eventMark[vertex] == stamp) continue;
        handle.eventMark[vertex] = stamp;
        const double distance = bins.vertexDistance[vertex];
        if (distance > range || distance == 0) continue;
        const double angle = bins.vertexAngle[vertex];
        if (!open(angle, distance)) continue;
        if (seam(handle, vertex, active)) continue;
        // Rays just beside a vertex the wall runs straight across meet its
        // two edges, so only the vertex ray adds a corner.
        emit(angle, !passThrough(handle, vertex,
                                 handle.vertexPoints[vertex] - origin, active));
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
    uint64_t edgeTests = 0;
    Hit previousHit;
    size_t sameEdgeRun = 0;
    Point runAnchor{};
    for (const double angle : angles) {
      const double world = directionRadians + angle;
      const Point direction{std::cos(world), std::sin(world)};
      const Hit hit = bins.cast(origin, direction, angle, range, edgeTests);
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
    out->edgeTests = edgeTests;
    // Tree nodes the filing walk visited, and one bin per ray.
    out->spatialNodes = bins.nodes + angles.size();
    out->candidateEdges = uint32_t(bins.count());
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
