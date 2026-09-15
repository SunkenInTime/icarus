#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

struct Query {
  double x, y, z, dx, dy, range = 65,
                          coneRadians = 103.0 * 3.14159265358979323846 / 180.0;
};
struct Section {
  uint32_t face;
  int32_t mask;
  double ax, ay, bx, by;
};
static_assert(sizeof(Section) == 40);
using Clock = std::chrono::steady_clock;
struct Counts {
  uint64_t nodes = 0, faces = 0, sections = 0, masks = 0, shadowNodes = 0;
};
std::vector<char> read(const std::string &path) {
  std::ifstream f(std::filesystem::u8path(path),
                  std::ios::binary | std::ios::ate);
  if (!f)
    throw std::runtime_error("missing input");
  auto size = f.tellg();
  if (size < 8 || size > std::streamoff(2ull << 30))
    throw std::runtime_error("invalid model size");
  std::vector<char> data(static_cast<size_t>(size));
  f.seekg(0);
  if (!f.read(data.data(), size))
    throw std::runtime_error("incomplete model read");
  return data;
}
struct Model {
  std::vector<char> raw;
  const double *vertices, *bounds;
  const uint32_t *faces;
  const int32_t *nodes, *masks;
  std::vector<double> zmin, zmax;
  size_t faceCount;
  std::map<std::string, std::pair<size_t, size_t>> arrays;
  std::vector<std::array<double, 9>> triangles;
  Model(const std::string &folder, bool buildAos = true) {
    raw = read(folder + "/height-source.raw");
    std::ifstream f(std::filesystem::u8path(folder + "/arrays.txt"));
    std::string name;
    size_t offset, count;
    while (f >> name >> offset >> count) {
      size_t width =
          (name == "vertices" || name == "bounds" || name == "maskedUvs") ? 8
                                                                          : 4;
      if (offset % width || offset > raw.size() ||
          count > (raw.size() - offset) / width ||
          !arrays.emplace(name, std::make_pair(offset, count)).second)
        throw std::runtime_error("invalid model array extent");
    }
    if (!f.eof() || arrays.size() != 7)
      throw std::runtime_error("invalid model arrays");
    auto ptr = [&](std::string n) { return raw.data() + arrays.at(n).first; };
    vertices = reinterpret_cast<const double *>(ptr("vertices"));
    bounds = reinterpret_cast<const double *>(ptr("bounds"));
    faces = reinterpret_cast<const uint32_t *>(ptr("faces"));
    nodes = reinterpret_cast<const int32_t *>(ptr("nodes"));
    masks = reinterpret_cast<const int32_t *>(ptr("faceMasks"));
    faceCount = arrays.at("faces").second / 3;
    size_t vertexCount = arrays.at("vertices").second / 3,
           nodeCount = arrays.at("nodes").second / 4,
           maskCount = arrays.at("maskedMaterials").second;
    if (!faceCount || !vertexCount || !nodeCount ||
        arrays.at("faces").second % 3 || arrays.at("vertices").second % 3 ||
        arrays.at("nodes").second % 4 ||
        arrays.at("bounds").second != nodeCount * 6 ||
        arrays.at("faceMasks").second != faceCount ||
        arrays.at("maskedUvs").second != maskCount * 6)
      throw std::runtime_error("invalid model array shape");
    for (size_t i = 0; i < vertexCount * 3; i++)
      if (!std::isfinite(vertices[i]))
        throw std::runtime_error("non-finite model vertex");
    for (size_t i = 0; i < faceCount * 3; i++)
      if (faces[i] >= vertexCount)
        throw std::runtime_error("invalid model vertex index");
    for (size_t i = 0; i < faceCount; i++)
      if (masks[i] < -1 || (masks[i] >= 0 && size_t(masks[i]) >= maskCount))
        throw std::runtime_error("invalid face mask index");
    // Requiring a forward, singly-parented tree bounds both traversal stacks.
    std::vector<int> depths(nodeCount, 0);
    depths[0] = 1;
    for (size_t i = 0; i < nodeCount; i++) {
      if (!depths[i] || depths[i] > 64)
        throw std::runtime_error("invalid model tree depth");
      for (int axis = 0; axis < 3; axis++)
        if (!std::isfinite(bounds[i * 6 + axis]) ||
            !std::isfinite(bounds[i * 6 + axis + 3]) ||
            bounds[i * 6 + axis] > bounds[i * 6 + axis + 3])
          throw std::runtime_error("invalid model bounds");
      int start = nodes[i * 4], length = nodes[i * 4 + 1];
      if (length < 0 || start < 0 || size_t(start) > faceCount ||
          size_t(length) > faceCount - size_t(start))
        throw std::runtime_error("invalid leaf range");
      if (length == 0)
        for (int side = 2; side < 4; side++) {
          int child = nodes[i * 4 + side];
          if (child <= int(i) || size_t(child) >= nodeCount || depths[child])
            throw std::runtime_error("invalid model child");
          depths[child] = depths[i] + 1;
        }
    }
    zmin.resize(faceCount);
    zmax.resize(faceCount);
    if (buildAos)
      triangles.resize(faceCount);
    for (size_t i = 0; i < faceCount; i++) {
      auto a = vertices[faces[i * 3] * 3 + 2],
           b = vertices[faces[i * 3 + 1] * 3 + 2],
           c = vertices[faces[i * 3 + 2] * 3 + 2];
      zmin[i] = std::min({a, b, c});
      zmax[i] = std::max({a, b, c});
      if (buildAos)
        for (size_t v = 0; v < 3; v++)
          for (size_t axis = 0; axis < 3; axis++)
            triangles[i][v * 3 + axis] = vertices[faces[i * 3 + v] * 3 + axis];
    }
  }
  bool section(uint32_t face, double z, Section &out, bool aos = false) const {
    int count = 0;
    double xy[4];
    const double *v[3];
    for (int k = 0; k < 3; k++)
      v[k] = aos ? triangles[face].data() + k * 3
                 : vertices + faces[face * 3 + k] * 3;
    for (int edge = 0; edge < 3; edge++) {
      int next = (edge + 1) % 3;
      auto a = v[edge], b = v[next];
      double za = a[2] - z, zb = b[2] - z;
      if ((za <= 0) == (zb <= 0))
        continue;
      double t = -za / (zb - za);
      xy[count * 2] = a[0] + (b[0] - a[0]) * t;
      xy[count * 2 + 1] = a[1] + (b[1] - a[1]) * t;
      count++;
    }
    if (count == 0) {
      int zero = 0;
      bool above = false;
      for (int k = 0; k < 3; k++) {
        auto point = v[k];
        if (point[2] > z)
          above = true;
        if (point[2] != z)
          continue;
        if (zero < 2) {
          xy[zero * 2] = point[0];
          xy[zero * 2 + 1] = point[1];
        }
        zero++;
      }
      if (zero != 2 || above)
        return false;
      count = 2;
    }
    if (count != 2 || (xy[0] == xy[2] && xy[1] == xy[3]))
      return false;
    out = {face, masks[face], xy[0], xy[1], xy[2], xy[3]};
    return true;
  }
  static bool halfClip(double a, double b, double &lo, double &hi) {
    if (a >= 0 && b >= 0)
      return true;
    if (a < 0 && b < 0)
      return false;
    double t = a / (a - b);
    if (a < 0)
      lo = std::max(lo, t);
    else
      hi = std::min(hi, t);
    return lo <= hi;
  }
  static bool intersectsCone(const Section &s, const Query &q, double lx,
                             double ly, double ux, double uy) {
    double ax = s.ax - q.x, ay = s.ay - q.y, bx = s.bx - q.x, by = s.by - q.y,
           lo = 0, hi = 1;
    if (!halfClip(lx * ay - ly * ax, lx * by - ly * bx, lo, hi))
      return false;
    if (!halfClip(uy * ax - ux * ay, uy * bx - ux * by, lo, hi))
      return false;
    double dx = bx - ax, dy = by - ay, den = dx * dx + dy * dy;
    double t = den == 0 ? lo : std::clamp(-(ax * dx + ay * dy) / den, lo, hi);
    double x = ax + dx * t, y = ay + dy * t;
    return x * x + y * y <= q.range * q.range;
  }
  double rayBox(int node, const Query &q, double dx, double dy,
                double limit) const {
    int b = node * 6;
    if (q.z < bounds[b + 2] || q.z > bounds[b + 5])
      return INFINITY;
    double lo = 0, hi = limit;
    for (int axis = 0; axis < 2; axis++) {
      double p = axis ? q.y : q.x, d = axis ? dy : dx;
      if (d == 0) {
        if (p < bounds[b + axis] || p > bounds[b + axis + 3])
          return INFINITY;
      } else {
        double a = (bounds[b + axis] - p) / d,
               c = (bounds[b + axis + 3] - p) / d;
        if (a > c)
          std::swap(a, c);
        lo = std::max(lo, a);
        hi = std::min(hi, c);
        if (hi < lo)
          return INFINITY;
      }
    }
    return lo;
  }
  int seedRay(const Query &q, double dx, double dy) const {
    double nearest = q.range;
    int last = -1, used = 1;
    std::array<int32_t, 128> stack;
    stack[0] = 0;
    while (used) {
      int node = stack[--used], n = node * 4;
      if (rayBox(node, q, dx, dy, nearest) > nearest)
        continue;
      if (nodes[n + 1] == 0) {
        int l = nodes[n + 2], r = nodes[n + 3];
        double dl = rayBox(l, q, dx, dy, nearest),
               dr = rayBox(r, q, dx, dy, nearest);
        if (dl < dr) {
          if (dr <= nearest)
            stack[used++] = r;
          if (dl <= nearest)
            stack[used++] = l;
        } else {
          if (dl <= nearest)
            stack[used++] = l;
          if (dr <= nearest)
            stack[used++] = r;
        }
        continue;
      }
      for (int face = nodes[n]; face < nodes[n] + nodes[n + 1]; face++) {
        if (masks[face] >= 0 || q.z < zmin[face] || q.z > zmax[face])
          continue;
        Section s;
        if (!section(face, q.z, s))
          continue;
        double sx = s.bx - s.ax, sy = s.by - s.ay, den = dx * sy - dy * sx;
        if (den == 0)
          continue;
        double qx = s.ax - q.x, qy = s.ay - q.y, t = (qx * sy - qy * sx) / den;
        if (t <= 1e-9 || t > nearest)
          continue;
        double u = (qx * dy - qy * dx) / den;
        if (u < -1e-12 || u > 1 + 1e-12)
          continue;
        nearest = t;
        last = face;
      }
    }
    return last;
  }
  void query(const Query &q, bool cone, bool zfilter,
             std::vector<Section> &output, Counts &stats, bool seed = false,
             std::vector<uint32_t> *seedIds = nullptr, bool aos = false) const {
    output.clear();
    std::array<int32_t, 128> stack;
    int used = 1;
    stack[0] = 0;
    const double h = q.coneRadians / 2;
    const double c = std::cos(h), s = std::sin(h), lx = q.dx * c + q.dy * s,
                 ly = q.dy * c - q.dx * s, ux = q.dx * c - q.dy * s,
                 uy = q.dy * c + q.dx * s;
    std::array<std::array<double, 9>, 8> shadows;
    std::array<int, 8> seedFaces;
    int shadowCount = 0;
    if (seed) {
      double facing = std::atan2(q.dy, q.dx);
      for (int i = 0; i < 8; i++) {
        double direction = facing - h + 2 * h * (i + .5) / 8;
        int face = seedRay(q, std::cos(direction), std::sin(direction));
        if (face < 0 ||
            std::find(seedFaces.begin(), seedFaces.begin() + shadowCount,
                      face) != seedFaces.begin() + shadowCount)
          continue;
        Section section;
        if (!this->section(face, q.z, section))
          continue;
        double ax = section.ax - q.x, ay = section.ay - q.y,
               bx = section.bx - q.x, by = section.by - q.y,
               cross = ax * by - ay * bx;
        if (cross == 0)
          continue;
        double sign = cross > 0 ? 1.0 : -1.0;
        shadows[shadowCount] = {
            -sign * ay,       sign * ax,         0,
            sign * by,        -sign * bx,        0,
            sign * (by - ay), -sign * (bx - ax), -std::abs(cross)};
        seedFaces[shadowCount++] = face;
        output.push_back(section);
        stats.sections++;
        if (seedIds)
          seedIds->push_back(static_cast<uint32_t>(face));
      }
    }
    while (used) {
      auto node = stack[--used], b = node * 6, n = node * 4;
      stats.nodes++;
      if (q.z < bounds[b + 2] || q.z > bounds[b + 5] ||
          q.x + q.range < bounds[b] || q.x - q.range > bounds[b + 3] ||
          q.y + q.range < bounds[b + 1] || q.y - q.range > bounds[b + 4])
        continue;
      if (cone) {
        double nx = std::clamp(q.x, bounds[b], bounds[b + 3]) - q.x,
               ny = std::clamp(q.y, bounds[b + 1], bounds[b + 4]) - q.y;
        if (nx * nx + ny * ny > q.range * q.range)
          continue;
        double lowx = bounds[b] - q.x, highx = bounds[b + 3] - q.x,
               lowy = bounds[b + 1] - q.y, highy = bounds[b + 4] - q.y;
        auto maximum = [&](double a, double d) {
          return a * (a >= 0 ? highx : lowx) + d * (d >= 0 ? highy : lowy);
        };
        if (maximum(-ly, lx) < 0 || maximum(uy, -ux) < 0)
          continue;
        bool hidden = false;
        for (int i = 0; i < shadowCount; i++) {
          bool inside = true;
          for (int p = 0; p < 9; p += 3) {
            double sx = shadows[i][p], sy = shadows[i][p + 1];
            double value = sx * (sx >= 0 ? lowx : highx) +
                           sy * (sy >= 0 ? lowy : highy) + shadows[i][p + 2];
            if (value <= 1e-9 * (1 + std::abs(sx) + std::abs(sy))) {
              inside = false;
              break;
            }
          }
          if (inside) {
            hidden = true;
            break;
          }
        }
        if (hidden) {
          stats.shadowNodes++;
          continue;
        }
      }
      int count = nodes[n + 1];
      if (count == 0) {
        stack[used++] = nodes[n + 2];
        stack[used++] = nodes[n + 3];
        continue;
      }
      for (int face = nodes[n]; face < nodes[n] + count; face++) {
        if (std::find(seedFaces.begin(), seedFaces.begin() + shadowCount,
                      face) != seedFaces.begin() + shadowCount)
          continue;
        stats.faces++;
        if (zfilter && (q.z < zmin[face] || q.z > zmax[face]))
          continue;
        Section section;
        if (!this->section(face, q.z, section, aos))
          continue;
        if (cone && !intersectsCone(section, q, lx, ly, ux, uy))
          continue;
        output.push_back(section);
        stats.sections++;
        stats.masks += section.mask >= 0;
      }
    }
  }
};
