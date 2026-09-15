// Testing CLI: complete horizontal sections and exact source alpha intervals.
#include "height_pipeline.hpp"
#include <cstring>

int main(int argc, char** argv) {
  try {
    if (argc != 6 && argc != 7) throw std::runtime_error("folder input.xyz.f64 output.rays.f64 directions range [excluded-faces.u8]");
    const int directions = std::stoi(argv[4]);
    const double range = std::stod(argv[5]);
    if (directions < 1 || directions > 4096 || !(range > 0 && range <= 65))
      throw std::runtime_error("invalid ray parameters");
    Model model(argv[1], false);
    AlphaData alpha(argv[1], model);
    std::vector<uint8_t> excluded(model.faceCount, 0);
    if (argc == 7) {
      std::ifstream flags(std::filesystem::u8path(argv[6]), std::ios::binary | std::ios::ate);
      if (!flags || flags.tellg() != std::streamoff(model.faceCount)) throw std::runtime_error("invalid excluded face mask");
      flags.seekg(0); flags.read(reinterpret_cast<char*>(excluded.data()), std::streamsize(excluded.size()));
      if (!flags) throw std::runtime_error("incomplete excluded face mask");
    }
    std::ifstream input(std::filesystem::u8path(argv[2]), std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("cannot open query input");
    const auto bytes = input.tellg();
    if (bytes < 0 || bytes % 24 != 0) throw std::runtime_error("invalid XYZ input");
    input.seekg(0);
    std::ofstream output(std::filesystem::u8path(argv[3]), std::ios::binary);
    if (!output) throw std::runtime_error("cannot open result output");
    std::vector<Section> sections, solid;
    std::vector<double> distances(directions), dx(directions), dy(directions);
    for (int i = 0; i < directions; ++i) {
      const double angle = 2 * 3.14159265358979323846 * i / directions;
      dx[i] = std::cos(angle); dy[i] = std::sin(angle);
    }
    Alpha::Scratch scratch;
    const auto started = Clock::now();
    const auto count = size_t(bytes / 24);
    for (size_t index = 0; index < count; ++index) {
      double xyz[3]; input.read(reinterpret_cast<char*>(xyz), sizeof xyz);
      if (!input || !std::isfinite(xyz[0]) || !std::isfinite(xyz[1]) || !std::isfinite(xyz[2]))
        throw std::runtime_error("invalid query value");
      Query q; q.x = xyz[0]; q.y = xyz[1]; q.z = xyz[2]; q.dx = 1; q.dy = 0; q.range = range;
      Counts counts;
      model.query(q, false, true, sections, counts, false);
      solid.clear();
      for (const auto& s : sections) {
        if (excluded[s.face]) continue;
        if (s.mask < 0) { solid.push_back(s); continue; }
        auto uv = alpha.sectionUvs(model, s, q.z);
        const auto& material = alpha.materials.at(alpha.materialIds[s.mask]);
        Alpha::clip(&alpha.textures.at(material.texture), material.policy, uv[0], uv[1], uv[2], uv[3], scratch);
        for (const auto& interval : scratch.intervals) {
          const double x = s.bx - s.ax, y = s.by - s.ay;
          solid.push_back({s.face, s.mask, s.ax + x * interval[0], s.ay + y * interval[0],
                           s.ax + x * interval[1], s.ay + y * interval[1]});
        }
      }
      std::fill(distances.begin(), distances.end(), range);
      for (const auto& s : solid) {
        const double ax = s.ax - q.x, ay = s.ay - q.y, sx = s.bx - s.ax, sy = s.by - s.ay;
        for (int i = 0; i < directions; ++i) {
          const double determinant = dx[i] * sy - dy[i] * sx;
          if (std::abs(determinant) < 1e-14) continue;
          const double t = (ax * sy - ay * sx) / determinant;
          const double u = (ax * dy[i] - ay * dx[i]) / determinant;
          if (t > 1e-8 && t < distances[i] && u >= -1e-10 && u <= 1 + 1e-10) distances[i] = t;
        }
      }
      output.write(reinterpret_cast<const char*>(distances.data()), std::streamsize(distances.size() * sizeof(double)));
    }
    if (!output) throw std::runtime_error("incomplete result write");
    std::cout << "queries=" << count << " directions=" << directions << " seconds="
              << std::chrono::duration<double>(Clock::now() - started).count() << std::endl;
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
