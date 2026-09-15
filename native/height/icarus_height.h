#pragma once
#include <stdint.h>
#ifdef _WIN32
#define IH_API __declspec(dllexport)
#else
#define IH_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif

// ABI 1. Natural alignment, 64-bit pointers. All timings are doubles.
// A handle owns one model and a persistent pool.
enum IHStatus {
  IH_OK = 0,
  IH_BUSY = 1,
  IH_INVALID = 2,
  IH_STALE_LEASE = 3,
  IH_FAILED = 4
};
typedef struct IHQuery {
  double x, y, z, dx, dy, range, coneRadians;
} IHQuery;
typedef struct IHBatch {
  uint32_t structSize, status;
  uint64_t poseStamp, leaseId;
  const float *positions;
  const uint32_t *coneOffsets;
  uint32_t floatCount, coneCount;
  double queryCpuMicros, alphaCpuMicros, meshCpuMicros, computeWallMicros;
} IHBatch;
typedef struct IHInfo {
  uint32_t structSize, abiVersion, workers, maxCones;
  uint64_t rawModelBytes, zBoundsBytes, intermediateCapacityBytes,
      resultCapacityBytes;
  double loadMillis, minimumHeight, maximumHeight;
} IHInfo;

// folder contains prepared immutable height-source.raw and metadata sidecars.
// maxCones is 1..10. workers is 1..16. Pack load and pool creation happen here.
IH_API void *ih_open(const char *folder, uint32_t workers, uint32_t maxCones,
                     char *error, uint32_t errorCapacity);
IH_API int32_t ih_info(void *handle, IHInfo *outInfo);
// Synchronous, intended for a persistent Dart worker isolate. Valid range is
// (0,65]m, cone angle is (0,pi], and dx/dy must be normalized within 1e-9.
// The whole batch succeeds or returns an error without publishing any output.
// Output is relative to each input origin. coneOffsets has coneCount+1 entries
// in FLOATS, starts at 0, ends at floatCount, and each difference is divisible
// by 6. There are at most two leased result buffers, each capped at 2^24
// floats. poseStamp is returned unchanged, including zero. Inputs are copied on
// call.
IH_API int32_t ih_compute(void *handle, const IHQuery *queries, uint32_t count,
                          uint64_t poseStamp, IHBatch *outBatch);
// Pointers remain valid until this exact lease is released. Old lease ids can
// never release a newer result. Copy to TransferableTypedData before release.
IH_API int32_t ih_release(void *handle, uint64_t leaseId);
IH_API int32_t ih_last_error(void *handle, char *error, uint32_t errorCapacity);
// Caller must stop submitting first and must not race close with any API call.
// Returns BUSY while a result is leased. Success joins all native pool threads.
IH_API int32_t ih_close(void *handle);
#ifdef __cplusplus
}
#endif
