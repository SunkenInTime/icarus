#include "native_alpha.hpp"
#include "query_model.hpp"
#include <atomic>
#include <condition_variable>
#include <exception>
#include <mutex>
#include <thread>

struct AlphaData {
  struct Material {
    int texture = -1;
    Alpha::Policy policy;
  };
  std::vector<Alpha::Texture> textures;
  std::vector<Material> materials;
  const double *uvs = nullptr;
  const uint32_t *materialIds = nullptr;
  AlphaData(const std::string &folder, const Model &m) {
    uvs = reinterpret_cast<const double *>(m.raw.data() +
                                           m.arrays.at("maskedUvs").first);
    materialIds = reinterpret_cast<const uint32_t *>(
        m.raw.data() + m.arrays.at("maskedMaterials").first);
    size_t offset;
    std::ifstream tex(std::filesystem::u8path(folder + "/alpha-textures.txt"));
    int id, w, h;
    while (tex >> id >> w >> h >> offset) {
      if (id != int(textures.size()) || w <= 0 || h <= 0 ||
          size_t(w) * size_t(h) > size_t(INT32_MAX) || offset > m.raw.size() ||
          size_t(w) * size_t(h) > m.raw.size() - offset)
        throw std::runtime_error("invalid texture metadata");
      textures.emplace_back(
          w, h, reinterpret_cast<const uint8_t *>(m.raw.data() + offset));
    }
    if (!tex.eof())
      throw std::runtime_error("invalid texture metadata stream");
    std::ifstream mat(std::filesystem::u8path(folder + "/alpha-materials.txt"));
    Material value;
    int ws, wt;
    while (mat >> id >> value.texture >> value.policy.threshold >>
           value.policy.scale >> value.policy.bias >> ws >> wt) {
      if (id < 0 || id > 100000 || value.texture < 0 ||
          size_t(value.texture) >= textures.size() || ws < 0 || ws > 3 ||
          wt < 0 || wt > 3 || !std::isfinite(value.policy.threshold) ||
          !std::isfinite(value.policy.scale) ||
          !std::isfinite(value.policy.bias))
        throw std::runtime_error("invalid alpha material");
      value.policy.s = static_cast<Alpha::Wrap>(ws);
      value.policy.t = static_cast<Alpha::Wrap>(wt);
      if (id >= int(materials.size()))
        materials.resize(id + 1);
      materials[id] = value;
    }
    if (!mat.eof())
      throw std::runtime_error("invalid material metadata stream");
    for (size_t i = 0; i < m.arrays.at("maskedMaterials").second; i++)
      if (materialIds[i] >= materials.size() ||
          materials[materialIds[i]].texture < 0)
        throw std::runtime_error("missing alpha material");
    for (size_t i = 0; i < m.arrays.at("maskedUvs").second; i++)
      if (!std::isfinite(uvs[i]))
        throw std::runtime_error("non-finite alpha UV");
  }
  std::array<double, 4> sectionUvs(const Model &m, const Section &s,
                                   double z) const {
    std::array<double, 4> result{};
    int count = 0;
    for (int edge = 0; edge < 3; edge++) {
      int next = (edge + 1) % 3;
      auto a = m.vertices + m.faces[s.face * 3 + edge] * 3,
           b = m.vertices + m.faces[s.face * 3 + next] * 3;
      double za = a[2] - z, zb = b[2] - z;
      if ((za <= 0) == (zb <= 0))
        continue;
      double t = -za / (zb - za);
      const double *ua = uvs + s.mask * 6 + edge * 2,
                   *ub = uvs + s.mask * 6 + next * 2;
      result[count * 2] = ua[0] + (ub[0] - ua[0]) * t;
      result[count * 2 + 1] = ua[1] + (ub[1] - ua[1]) * t;
      count++;
    }
    if (count == 0) {
      for (int k = 0; k < 3; k++) {
        auto v = m.vertices + m.faces[s.face * 3 + k] * 3;
        if (v[2] != z)
          continue;
        if (count < 2) {
          result[count * 2] = uvs[s.mask * 6 + k * 2];
          result[count * 2 + 1] = uvs[s.mask * 6 + k * 2 + 1];
        }
        count++;
      }
    }
    if (count != 2)
      throw std::runtime_error("section UV topology differs");
    return result;
  }
};

struct ShadowMesh {
  std::vector<float> positions;
  std::array<double, 32> first{}, second{};
  int count = 0;
  uint64_t shadows = 0, collinear = 0;
  void reset() {
    positions.clear();
    shadows = collinear = 0;
  }
  void clip(double nx, double ny, double constant) {
    if (count == 0)
      return;
    int output = 0;
    double px = first[(count - 1) * 2], py = first[(count - 1) * 2 + 1],
           pd = nx * px + ny * py + constant;
    for (int i = 0; i < count; i++) {
      double x = first[i * 2], y = first[i * 2 + 1],
             d = nx * x + ny * y + constant;
      if ((d >= 0) != (pd >= 0)) {
        double fraction = pd / (pd - d);
        second[output++] = px + (x - px) * fraction;
        second[output++] = py + (y - py) * fraction;
      }
      if (d >= 0) {
        second[output++] = x;
        second[output++] = y;
      }
      px = x;
      py = y;
      pd = d;
    }
    first.swap(second);
    count = output / 2;
  }
  void shadow(double ax, double ay, double bx, double by, double range) {
    double cross = ax * by - ay * bx, sign = cross > 0 ? 1.0 : -1.0;
    first[0] = -range;
    first[1] = -range;
    first[2] = range;
    first[3] = -range;
    first[4] = range;
    first[5] = range;
    first[6] = -range;
    first[7] = range;
    count = 4;
    clip(-sign * ay, sign * ax, 0);
    clip(sign * by, -sign * bx, 0);
    clip(sign * (by - ay), -sign * (bx - ax), -std::abs(cross));
    if (count < 3)
      return;
    shadows++;
    for (int v = 1; v + 1 < count; v++)
      for (int point : {0, v, v + 1}) {
        positions.push_back(float(first[point * 2]));
        positions.push_back(float(first[point * 2 + 1]));
      }
  }
  void add(const Section &s, const Query &q, double range = 65) {
    double ax = s.ax - q.x, ay = s.ay - q.y, bx = s.bx - q.x, by = s.by - q.y,
           cross = ax * by - ay * bx;
    if (cross == 0) {
      collinear++;
      return;
    }
    double dx = bx - ax, dy = by - ay, lengthSquared = dx * dx + dy * dy;
    constexpr double epsilonSquared = 1e-18;
    if (cross * cross <= epsilonSquared * lengthSquared) {
      double length = std::sqrt(lengthSquared), ux = dx / length,
             uy = dy / length, distance = cross / length;
      double halfGap =
          std::sqrt(std::max(0.0, epsilonSquared - distance * distance));
      double aAlong = ax * ux + ay * uy, bAlong = bx * ux + by * uy;
      if (aAlong <= halfGap && bAlong >= -halfGap) {
        double cx = uy * distance, cy = -ux * distance;
        if (aAlong < -halfGap)
          shadow(ax, ay, cx - ux * halfGap, cy - uy * halfGap, range);
        if (bAlong > halfGap)
          shadow(cx + ux * halfGap, cy + uy * halfGap, bx, by, range);
        return;
      }
    }
    shadow(ax, ay, bx, by, range);
  }
};

struct Output {
  std::vector<Section> sections, clipped;
  ShadowMesh mesh;
  Counts counts;
  uint64_t alphaCalls = 0, alphaCells = 0, alphaMixed = 0;
  double queryMicros = 0, alphaMicros = 0, meshMicros = 0;
  Output() {
    sections.reserve(32768);
    clipped.reserve(32768);
    mesh.positions.reserve(262144);
  }
};
enum class Stage { Query, Alpha, Mesh, Full };
class PipelinePool {
  const Model &model;
  const AlphaData &alpha;
  std::vector<std::thread> workers;
  std::mutex mutex;
  std::condition_variable ready, done;
  bool stopping = false;
  uint64_t generation = 0;
  size_t completed = 0;
  std::atomic<int> next{0};
  std::array<Query, 10> queries;
  Stage stage = Stage::Full;
  std::exception_ptr error;
  int jobCount = 10;
  void doAlpha(Output &o, const Query &q, Alpha::Scratch &scratch) {
    o.clipped.clear();
    o.alphaCalls = o.alphaCells = o.alphaMixed = 0;
    const double half = q.coneRadians / 2;
    double c = std::cos(half), s = std::sin(half), lx = q.dx * c + q.dy * s,
           ly = q.dy * c - q.dx * s, ux = q.dx * c - q.dy * s,
           uy = q.dy * c + q.dx * s;
    for (const auto &section : o.sections) {
      if (section.mask < 0) {
        o.clipped.push_back(section);
        continue;
      }
      auto uv = alpha.sectionUvs(model, section, q.z);
      const auto &mat = alpha.materials.at(alpha.materialIds[section.mask]);
      Alpha::clip(&alpha.textures.at(mat.texture), mat.policy, uv[0], uv[1],
                  uv[2], uv[3], scratch);
      o.alphaCalls++;
      o.alphaCells += scratch.cells;
      o.alphaMixed += scratch.mixed;
      for (auto interval : scratch.intervals) {
        double dx = section.bx - section.ax, dy = section.by - section.ay;
        Section part{section.face,
                     section.mask,
                     section.ax + dx * interval[0],
                     section.ay + dy * interval[0],
                     section.ax + dx * interval[1],
                     section.ay + dy * interval[1]};
        if (Model::intersectsCone(part, q, lx, ly, ux, uy))
          o.clipped.push_back(part);
      }
    }
  }

public:
  std::array<Output, 10> outputs;
  PipelinePool(const Model &m, const AlphaData &a, int size)
      : model(m), alpha(a) {
    try {
      for (int i = 0; i < size; i++)
        workers.emplace_back([this] {
          uint64_t observed = 0;
          Alpha::Scratch scratch;
          while (true) {
            {
              std::unique_lock<std::mutex> lock(mutex);
              ready.wait(lock,
                         [&] { return stopping || generation != observed; });
              if (stopping)
                return;
              observed = generation;
            }
            try {
              for (int index = next.fetch_add(1); index < jobCount;
                   index = next.fetch_add(1)) {
                auto &o = outputs[index];
                auto &q = queries[index];
                if (stage == Stage::Query || stage == Stage::Full) {
                  auto t = Clock::now();
                  o.counts = {};
                  model.query(q, true, true, o.sections, o.counts, true);
                  o.queryMicros = std::chrono::duration<double, std::micro>(
                                      Clock::now() - t)
                                      .count();
                }
                if (stage == Stage::Alpha || stage == Stage::Full) {
                  auto t = Clock::now();
                  doAlpha(o, q, scratch);
                  o.alphaMicros = std::chrono::duration<double, std::micro>(
                                      Clock::now() - t)
                                      .count();
                }
                if (stage == Stage::Mesh || stage == Stage::Full) {
                  auto t = Clock::now();
                  o.mesh.reset();
                  for (auto &s : o.clipped)
                    o.mesh.add(s, q, q.range);
                  o.meshMicros = std::chrono::duration<double, std::micro>(
                                     Clock::now() - t)
                                     .count();
                }
              }
            } catch (...) {
              std::lock_guard<std::mutex> lock(mutex);
              if (!error)
                error = std::current_exception();
            }
            {
              std::lock_guard<std::mutex> lock(mutex);
              if (++completed == workers.size())
                done.notify_one();
            }
          }
        });
    } catch (...) {
      {
        std::lock_guard<std::mutex> lock(mutex);
        stopping = true;
      }
      ready.notify_all();
      for (auto &t : workers)
        t.join();
      throw;
    }
  }
  ~PipelinePool() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
    }
    ready.notify_all();
    for (auto &t : workers)
      t.join();
  }
  void run(const std::array<Query, 10> &batch, Stage requested = Stage::Full,
           int count = 10) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      queries = batch;
      stage = requested;
      jobCount = count;
      next.store(0);
      completed = 0;
      error = nullptr;
      generation++;
    }
    ready.notify_all();
    std::unique_lock<std::mutex> lock(mutex);
    done.wait(lock, [&] { return completed == workers.size(); });
    if (error)
      std::rethrow_exception(error);
  }
};
