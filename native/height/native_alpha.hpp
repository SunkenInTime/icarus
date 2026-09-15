#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace Alpha {
struct Error : std::runtime_error {
  int code;
  Error(int c, const char *s) : std::runtime_error(s), code(c) {}
};
enum Wrap { Repeat = 0, Clamp = 1, Mirror = 2, Black = 3 };
inline const std::array<double, 256> normalized = [] {
  std::array<double, 256> result{};
  for (int i = 0; i < 256; i++)
    result[i] = static_cast<float>(i / 255.0);
  return result;
}();
struct Texture {
  int width, height, minimum = 255, maximum = 0;
  const uint8_t *bytes;
  Texture(int w, int h, const uint8_t *b) : width(w), height(h), bytes(b) {
    if (w <= 0 || h <= 0)
      throw Error(4, "invalid-alpha-texture-size");
    for (int i = 0; i < w * h; i++) {
      minimum = std::min(minimum, int(b[i]));
      maximum = std::max(maximum, int(b[i]));
    }
  }
  double at(int x, int y) const {
    return x < 0 || y < 0 ? 0.0 : normalized[bytes[y * width + x]];
  }
};
struct Policy {
  int mode = 2;
  double threshold = .333, scale = 1, bias = 0;
  Wrap s = Repeat, t = Repeat;
  bool useRange = true;
};
struct Scratch {
  std::vector<double> breaks;
  std::vector<std::array<double, 2>> intervals;
  uint64_t cells = 0, mixed = 0;
};
inline int pixel(double integer, int neighbor, int size, Wrap wrap) {
  if (wrap == Clamp) {
    if (integer < 0)
      return integer == -1 && neighbor == 1 ? 0 : 0;
    if (integer >= size - 1)
      return size - 1;
    return int(integer) + neighbor;
  }
  if (wrap == Black) {
    if (integer < -1 || integer >= size)
      return -1;
    int i = int(integer) + neighbor;
    return i < 0 || i >= size ? -1 : i;
  }
  int dimension = wrap == Mirror ? size * 2 : size;
  // fmod reduces the exact integral double before adding its neighbor. This
  // preserves adjacent texels even for finite addresses beyond int64/2^53.
  double remainder = std::fmod(integer, double(dimension));
  if (remainder < 0)
    remainder += dimension;
  int i = (int(remainder) + neighbor) % dimension;
  return wrap == Mirror && i >= size ? size * 2 - 1 - i : i;
}
inline double sample(const Texture &a, const Policy &p, double u, double v) {
  if (!std::isfinite(u) || !std::isfinite(v))
    throw Error(1, "invalid-segment-uv");
  if ((p.s == Black && (u < 0 || u > 1)) || (p.t == Black && (v < 0 || v > 1)))
    return p.bias;
  double x = u * a.width - .5, y = v * a.height - .5;
  if (!std::isfinite(x) || !std::isfinite(y))
    throw Error(3, "nonfinite-pixel-coordinate");
  double ix = std::floor(x), iy = std::floor(y), fx = x - ix, fy = y - iy,
         value = 0;
  for (int xx = 0; xx < 2; xx++) {
    int px = pixel(ix, xx, a.width, p.s);
    if (px < 0)
      continue;
    double wx = xx ? fx : 1 - fx;
    for (int yy = 0; yy < 2; yy++) {
      int py = pixel(iy, yy, a.height, p.t);
      if (py >= 0) {
        double wy = yy ? fy : 1 - fy;
        value += a.at(px, py) * wx * wy;
      }
    }
  }
  return value * p.scale + p.bias;
}
inline void clip(const Texture *texture, const Policy &p, double u0, double v0,
                 double u1, double v1, Scratch &work, int maxCells = 100000) {
  auto &out = work.intervals;
  out.clear();
  work.cells = work.mixed = 0;
  if (p.mode == 0)
    return;
  if (p.mode != 2) {
    out.push_back({0, 1});
    return;
  }
  if (!std::isfinite(u0) || !std::isfinite(v0) || !std::isfinite(u1) ||
      !std::isfinite(v1))
    throw Error(1, "invalid-segment-uv");
  if (!texture)
    throw Error(4, "missing-alpha-texture");
  const auto &a = *texture;
  double du = u1 - u0, dv = v1 - v0;
  if (p.useRange) {
    double x = a.minimum / 255.0 * p.scale + p.bias,
           y = a.maximum / 255.0 * p.scale + p.bias, lo = std::min(x, y),
           hi = std::max(x, y);
    if (p.s == Black || p.t == Black) {
      lo = std::min(lo, p.bias);
      hi = std::max(hi, p.bias);
    }
    if (lo >= p.threshold) {
      out.push_back({0, 1});
      return;
    }
    if (hi < p.threshold)
      return;
  }
  auto &breaks = work.breaks;
  breaks.clear();
  breaks.push_back(0);
  breaks.push_back(1);
  auto axis = [&](double origin, double delta, int size, Wrap wrap) {
    if (std::abs(delta) < 1e-15)
      return;
    double a = origin * size - .5, b = (origin + delta) * size - .5;
    if (!std::isfinite(a) || !std::isfinite(b))
      throw Error(3, "nonfinite-pixel-coordinate");
    double lo = std::ceil(std::min(a, b)), hi = std::floor(std::max(a, b));
    if (hi - lo > maxCells)
      throw Error(2, "alpha-segment-cell-budget-exceeded");
    int count = int(hi - lo);
    for (int i = 0; i <= count; i++) {
      double integer = lo + i, t = ((integer + .5) / size - origin) / delta;
      if (t > 0 && t < 1)
        breaks.push_back(t);
    }
    if (wrap == Black)
      for (double edge : {0.0, 1.0}) {
        double t = (edge - origin) / delta;
        if (t > 0 && t < 1)
          breaks.push_back(t);
      }
  };
  axis(u0, du, a.width, p.s);
  axis(v0, dv, a.height, p.t);
  std::sort(breaks.begin(), breaks.end());
  breaks.erase(std::unique(breaks.begin(), breaks.end()), breaks.end());
  if (breaks.size() > size_t(maxCells))
    throw Error(2, "alpha-segment-cell-budget-exceeded");
  auto emit = [&](double lo, double hi) {
    if (!out.empty() && std::abs(out.back()[1] - lo) <= 1e-10)
      out.back()[1] = hi;
    else
      out.push_back({lo, hi});
  };
  auto value = [&](double t) { return sample(a, p, u0 + du * t, v0 + dv * t); };
  for (size_t cell = 0; cell + 1 < breaks.size(); cell++) {
    work.cells++;
    double left = breaks[cell], right = breaks[cell + 1], span = right - left,
           middle = left + span * .5, u = u0 + du * middle,
           v = v0 + dv * middle, lo = INFINITY, hi = -INFINITY;
    if ((p.s == Black && (u < 0 || u > 1)) ||
        (p.t == Black && (v < 0 || v > 1))) {
      lo = hi = 0;
    } else {
      double x = std::floor(u * a.width - .5),
             y = std::floor(v * a.height - .5);
      for (int ix = 0; ix < 2; ix++) {
        int px = pixel(x, ix, a.width, p.s);
        for (int iy = 0; iy < 2; iy++) {
          int py = pixel(y, iy, a.height, p.t);
          double val = a.at(px, py);
          lo = std::min(lo, val);
          hi = std::max(hi, val);
        }
      }
    }
    double x = lo * p.scale + p.bias, y = hi * p.scale + p.bias;
    lo = std::min(x, y);
    hi = std::max(x, y);
    if (lo >= p.threshold) {
      emit(left, right);
      continue;
    }
    if (hi + 1e-12 < p.threshold)
      continue;
    work.mixed++;
    double q1 = value(left + span * .25) - p.threshold,
           q2 = value(left + span * .5) - p.threshold,
           q3 = value(left + span * .75) - p.threshold;
    double qa = 8 * (q1 - 2 * q2 + q3), qb = 2 * (q3 - q1) - qa,
           qc = q2 - .25 * qa - .5 * qb;
    std::array<double, 4> cuts{0, 1, 0, 0};
    int count = 2;
    auto root = [&](double t) {
      if (t > 0 && t < 1)
        cuts[count++] = t;
    };
    if (std::abs(qa) < 1e-12) {
      if (std::abs(qb) > 1e-12)
        root(-qc / qb);
    } else {
      double d = qb * qb - 4 * qa * qc;
      if (d >= 0) {
        double r = std::sqrt(d);
        root((-qb - r) / (2 * qa));
        root((-qb + r) / (2 * qa));
      }
    }
    std::sort(cuts.begin(), cuts.begin() + count);
    count = int(std::unique(cuts.begin(), cuts.begin() + count) - cuts.begin());
    for (int i = 0; i + 1 < count; i++) {
      double low = cuts[i], high = cuts[i + 1];
      if (value(left + span * (low + high) / 2) + 1e-12 < p.threshold)
        continue;
      emit(left + span * low, left + span * high);
    }
  }
}
} // namespace Alpha
