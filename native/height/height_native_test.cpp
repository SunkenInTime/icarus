#include "icarus_height.h"
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace fs = std::filesystem;

void check(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}

int main() {
  const auto folder =
      fs::temp_directory_path() /
      fs::u8path(
          "icarus-height-\xc3\xa9-" +
          std::to_string(
              std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(folder);
  try {
    std::vector<char> raw(8);
    std::ofstream arrays(folder / "arrays.txt");
    auto append = [&](const char *name, const auto &values) {
      using Value = typename std::decay_t<decltype(values)>::value_type;
      raw.resize((raw.size() + 7) / 8 * 8);
      arrays << name << ' ' << raw.size() << ' ' << values.size() << '\n';
      const auto offset = raw.size();
      raw.resize(offset + values.size() * sizeof(Value));
      if (!values.empty())
        std::memcpy(raw.data() + offset, values.data(),
                    values.size() * sizeof(Value));
    };
    append("vertices", std::vector<double>{1, -1, 0, 1, 1, 0, 1, 0, 3});
    append("faces", std::vector<uint32_t>{0, 1, 2});
    append("bounds", std::vector<double>{1, -1, 0, 1, 1, 3});
    append("nodes", std::vector<int32_t>{0, 1, -1, -1});
    append("faceMasks", std::vector<int32_t>{-1});
    append("maskedUvs", std::vector<double>{});
    append("maskedMaterials", std::vector<uint32_t>{});
    arrays.close();
    std::ofstream(folder / "height-source.raw", std::ios::binary)
        .write(raw.data(), raw.size());
    std::ofstream(folder / "alpha-textures.txt");
    std::ofstream(folder / "alpha-materials.txt");
    std::ofstream(folder / "parameters.txt") << "0 3";

    std::array<char, 4096> error{};
    auto *handle =
        ih_open(folder.u8string().c_str(), 4, 10, error.data(), error.size());
    check(handle != nullptr, error.data());
    IHInfo info{};
    info.structSize = sizeof(info);
    check(ih_info(handle, &info) == IH_OK && info.abiVersion == 1, "ABI info");
    for (uint32_t size : {0u, 1u, 71u, 73u}) {
      info.structSize = size;
      const auto before = info;
      check(ih_info(handle, &info) == IH_INVALID &&
                std::memcmp(&before, &info, sizeof(info)) == 0,
            "info size guard");
    }
    IHQuery query{0, 0, 1.75, 1, 0, 5, 1.8};
    IHBatch first{}, second{}, third{};
    first.structSize = second.structSize = third.structSize = sizeof(IHBatch);
    for (uint32_t size : {0u, 1u, 79u, 81u}) {
      first.structSize = size;
      const auto before = first;
      check(ih_compute(handle, &query, 1, 0, &first) == IH_INVALID &&
                std::memcmp(&before, &first, sizeof(first)) == 0,
            "batch size guard");
    }
    first.structSize = sizeof(first);
    check(ih_compute(handle, &query, 1, 7, &first) == IH_OK, "first frame");
    check(first.poseStamp == 7 && first.floatCount > 0 &&
              first.floatCount % 6 == 0,
          "triangle output");
    const std::vector<float> saved(first.positions,
                                   first.positions + first.floatCount);
    check(ih_compute(handle, &query, 1, 8, &second) == IH_OK, "second lease");
    check(ih_compute(handle, &query, 1, 9, &third) == IH_BUSY,
          "bounded leases");
    check(ih_close(handle) == IH_BUSY, "close with leased data");
    check(std::memcmp(saved.data(), first.positions, saved.size() * 4) == 0,
          "lease stability");
    const auto oldLease = first.leaseId;
    check(ih_release(handle, oldLease) == IH_OK, "release first");
    check(ih_compute(handle, &query, 1, 9, &third) == IH_OK, "reuse slot");
    check(ih_release(handle, oldLease) == IH_STALE_LEASE, "stale release");
    check(ih_release(handle, second.leaseId) == IH_OK, "release second");
    check(ih_release(handle, third.leaseId) == IH_OK, "release third");
    query.z = 4;
    check(ih_compute(handle, &query, 1, 10, &first) == IH_INVALID,
          "height domain");
    query.z = 1.75;
    check(ih_compute(handle, &query, 1, 11, &first) == IH_OK, "recovery");
    check(ih_release(handle, first.leaseId) == IH_OK, "release recovered");
    check(ih_close(handle) == IH_OK, "joined close");

    std::ofstream(folder / "arrays.txt", std::ios::app)
        << "vertices 99999999 9\n";
    check(ih_open(folder.u8string().c_str(), 4, 10, error.data(),
                  error.size()) == nullptr,
          "malformed metadata rejection");
    fs::remove_all(folder);
    std::cout
        << "ABI sizes, leases, recovery, UTF-8 paths and shutdown passed\n";
    return 0;
  } catch (const std::exception &error) {
    fs::remove_all(folder);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
