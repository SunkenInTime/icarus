#include "icarus_height.h"
#include "height_pipeline.hpp"
#include <cstring>
#include <limits>
#include <memory>

static_assert(sizeof(IHQuery) == 56);
static_assert(sizeof(IHBatch) == 80);
static_assert(sizeof(IHInfo) == 72);
static_assert(offsetof(IHBatch, positions) == 24);
static_assert(offsetof(IHBatch, computeWallMicros) == 72);
namespace {
constexpr size_t maximumFloats = 1u << 24;
void textCopy(const std::string &text, char *target, uint32_t capacity) {
  if (!target || capacity == 0)
    return;
  size_t n = std::min(text.size(), size_t(capacity - 1));
  std::memcpy(target, text.data(), n);
  target[n] = 0;
}
struct Slot {
  uint64_t lease = 0;
  std::vector<float> positions;
  std::array<uint32_t, 11> offsets{};
};
struct Handle {
  Model model;
  AlphaData alpha;
  PipelinePool pool;
  std::mutex callMutex;
  std::array<Slot, 2> slots;
  uint64_t nextLease = 1;
  uint32_t workers, maxCones;
  double minimumHeight, maximumHeight, loadMillis = 0;
  std::string error;
  Handle(const std::string &folder, uint32_t workerCount, uint32_t cones)
      : model(folder, false), alpha(folder, model),
        pool(model, alpha, int(workerCount)), workers(workerCount),
        maxCones(cones) {
    std::ifstream parameters(
        std::filesystem::u8path(folder + "/parameters.txt"));
    if (!(parameters >> minimumHeight >> maximumHeight) ||
        !std::isfinite(minimumHeight) || !std::isfinite(maximumHeight) ||
        minimumHeight > maximumHeight)
      throw std::runtime_error(
          "missing or invalid height-domain parameters.txt");
  }
};
int failure(Handle &h, IHBatch *out, int status, const std::string &message) {
  h.error = message;
  if (out) {
    *out = {};
    out->structSize = sizeof(IHBatch);
    out->status = uint32_t(status);
  }
  return status;
}
} // namespace

extern "C" {
void *ih_open(const char *folder, uint32_t workers, uint32_t maxCones,
              char *error, uint32_t capacity) {
  try {
    if (!folder || !*folder || workers < 1 || workers > 16 || maxCones < 1 ||
        maxCones > 10)
      throw std::runtime_error("invalid folder, workers or maxCones");
    auto start = Clock::now();
    auto handle = std::make_unique<Handle>(folder, workers, maxCones);
    handle->loadMillis =
        std::chrono::duration<double, std::milli>(Clock::now() - start).count();
    textCopy("", error, capacity);
    return handle.release();
  } catch (const std::exception &e) {
    textCopy(e.what(), error, capacity);
    return nullptr;
  } catch (...) {
    textCopy("unknown native initialization error", error, capacity);
    return nullptr;
  }
}
int32_t ih_info(void *opaque, IHInfo *out) {
  if (!opaque || !out || out->structSize != sizeof(IHInfo))
    return IH_INVALID;
  auto &h = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(h.callMutex, std::try_to_lock);
  if (!lock)
    return IH_BUSY;
  *out = {};
  out->structSize = sizeof(IHInfo);
  out->abiVersion = 1;
  out->workers = h.workers;
  out->maxCones = h.maxCones;
  out->rawModelBytes = h.model.raw.size();
  out->zBoundsBytes = h.model.zmin.size() * 16;
  for (auto &o : h.pool.outputs)
    out->intermediateCapacityBytes +=
        (o.sections.capacity() + o.clipped.capacity()) * sizeof(Section) +
        o.mesh.positions.capacity() * 4;
  for (auto &s : h.slots)
    out->resultCapacityBytes += s.positions.capacity() * 4;
  out->loadMillis = h.loadMillis;
  out->minimumHeight = h.minimumHeight;
  out->maximumHeight = h.maximumHeight;
  return IH_OK;
}
int32_t ih_compute(void *opaque, const IHQuery *input, uint32_t count,
                   uint64_t stamp, IHBatch *out) {
  if (!opaque || !out || out->structSize != sizeof(IHBatch))
    return IH_INVALID;
  auto &h = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(h.callMutex, std::try_to_lock);
  if (!lock) {
    *out = {};
    out->structSize = sizeof(IHBatch);
    out->status = IH_BUSY;
    return IH_BUSY;
  }
  auto start = Clock::now();
  try {
    if (!input || count == 0 || count > h.maxCones)
      return failure(h, out, IH_INVALID,
                     "query count is outside configured limit");
    std::array<Query, 10> queries{};
    for (uint32_t i = 0; i < count; i++) {
      const auto &q = input[i];
      const double values[] = {q.x,  q.y,     q.z,          q.dx,
                               q.dy, q.range, q.coneRadians};
      for (double value : values)
        if (!std::isfinite(value))
          return failure(h, out, IH_INVALID, "non-finite query value");
      if (q.z < h.minimumHeight || q.z > h.maximumHeight)
        return failure(h, out, IH_INVALID,
                       "observer height outside packed domain");
      if (q.range <= 0 || q.range > 65 || q.coneRadians <= 0 ||
          q.coneRadians > 3.14159265358979323846)
        return failure(h, out, IH_INVALID,
                       "range must be (0,65] and cone angle (0,pi]");
      if (std::abs(q.dx * q.dx + q.dy * q.dy - 1) > 1e-9)
        return failure(h, out, IH_INVALID, "direction must be normalized");
      queries[i] = {q.x, q.y, q.z, q.dx, q.dy, q.range, q.coneRadians};
    }
    Slot *slot = nullptr;
    for (auto &candidate : h.slots)
      if (candidate.lease == 0) {
        slot = &candidate;
        break;
      }
    if (!slot)
      return failure(h, out, IH_BUSY, "both native result buffers are leased");
    if (h.nextLease == 0)
      return failure(h, out, IH_FAILED, "native lease id space exhausted");
    h.pool.run(queries, Stage::Full, int(count));
    size_t size = 0;
    for (uint32_t i = 0; i < count; i++) {
      auto length = h.pool.outputs[i].mesh.positions.size();
      if (length % 6)
        return failure(h, out, IH_FAILED, "unaligned native triangles");
      size += length;
    }
    if (size > maximumFloats)
      return failure(h, out, IH_FAILED,
                     "native result exceeds bounded float capacity");
    slot->positions.resize(size);
    slot->offsets[0] = 0;
    size_t used = 0;
    double query = 0, alpha = 0, mesh = 0;
    for (uint32_t i = 0; i < count; i++) {
      auto &o = h.pool.outputs[i];
      for (float value : o.mesh.positions)
        if (!std::isfinite(value))
          return failure(h, out, IH_FAILED, "non-finite emitted triangle");
      if (!o.mesh.positions.empty())
        std::memcpy(slot->positions.data() + used, o.mesh.positions.data(),
                    o.mesh.positions.size() * 4);
      used += o.mesh.positions.size();
      slot->offsets[i + 1] = uint32_t(used);
      query += o.queryMicros;
      alpha += o.alphaMicros;
      mesh += o.meshMicros;
    }
    slot->lease = h.nextLease++;
    *out = {};
    out->structSize = sizeof(IHBatch);
    out->status = IH_OK;
    out->poseStamp = stamp;
    out->leaseId = slot->lease;
    out->positions = slot->positions.data();
    out->coneOffsets = slot->offsets.data();
    out->floatCount = uint32_t(used);
    out->coneCount = count;
    out->queryCpuMicros = query;
    out->alphaCpuMicros = alpha;
    out->meshCpuMicros = mesh;
    out->computeWallMicros =
        std::chrono::duration<double, std::micro>(Clock::now() - start).count();
    h.error.clear();
    return IH_OK;
  } catch (const std::exception &e) {
    return failure(h, out, IH_FAILED, e.what());
  } catch (...) {
    return failure(h, out, IH_FAILED, "unknown native compute error");
  }
}
int32_t ih_release(void *opaque, uint64_t lease) {
  if (!opaque || lease == 0)
    return IH_INVALID;
  auto &h = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(h.callMutex, std::try_to_lock);
  if (!lock)
    return IH_BUSY;
  for (auto &slot : h.slots)
    if (slot.lease == lease) {
      slot.lease = 0;
      return IH_OK;
    }
  h.error = "stale or foreign native lease";
  return IH_STALE_LEASE;
}
int32_t ih_last_error(void *opaque, char *error, uint32_t capacity) {
  if (!opaque || !error || capacity == 0)
    return IH_INVALID;
  auto &h = *static_cast<Handle *>(opaque);
  std::unique_lock<std::mutex> lock(h.callMutex, std::try_to_lock);
  if (!lock)
    return IH_BUSY;
  textCopy(h.error, error, capacity);
  return IH_OK;
}
int32_t ih_close(void *opaque) {
  if (!opaque)
    return IH_INVALID;
  auto *h = static_cast<Handle *>(opaque);
  {
    std::unique_lock<std::mutex> lock(h->callMutex, std::try_to_lock);
    if (!lock)
      return IH_BUSY;
    for (auto &slot : h->slots)
      if (slot.lease)
        return IH_BUSY;
  }
  delete h;
  return IH_OK;
}
}
