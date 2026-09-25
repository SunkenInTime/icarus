#pragma once

#include <stdint.h>

#ifdef _WIN32
#define ISH_API __declspec(dllexport)
#else
#define ISH_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum ISHStatus {
  ISH_OK = 0,
  ISH_BUSY = 1,
  ISH_INVALID = 2,
  ISH_FAILED = 3,
};

// ABI 1. Edge input is five doubles per edge: ax, ay, bx, by, wall index.
// Coordinates remain doubles from input through the returned point buffer.
typedef struct ISHResult {
  uint32_t structSize;
  uint32_t status;
  const double *points;
  uint32_t pointCount;
  uint32_t rayCount;
  uint64_t edgeTests;
  uint64_t spatialNodes;
  uint32_t candidateEdges;
  uint32_t reserved;
  double preparationMicros;
  double candidateMicros;
  double queryMicros;
} ISHResult;

ISH_API void *ish_open(const double *edgeRecords, uint32_t edgeCount,
                       uint32_t wallCount, char *error,
                       uint32_t errorCapacity);

// Stable per-context scratch buffers for the Dart owner. They remove allocator
// calls from the query path and must not be accessed concurrently with query.
ISH_API uint8_t *ish_active_wall_buffer(void *handle);
ISH_API ISHResult *ish_result_buffer(void *handle);

// activeWalls contains exactly wallCount bytes. Zero disables a wall.
// directionRadians and apertureRadians use the SVG coordinate plane. The
// returned XY pointer belongs to the handle and remains valid until its next
// query or close. The caller must copy it before either operation.
ISH_API int32_t ish_query(void *handle, double originX, double originY,
                          double directionRadians, double range,
                          double apertureRadians, uint32_t arcSteps,
                          const uint8_t *activeWalls, uint32_t activeWallCount,
                          ISHResult *outResult);

ISH_API int32_t ish_last_error(void *handle, char *error,
                               uint32_t errorCapacity);
ISH_API int32_t ish_close(void *handle);

// Dart NativeFinalizer fallback. Explicit owners should call ish_close and
// detach the finalizer first.
ISH_API void ish_close_finalizer(void *handle);

#ifdef __cplusplus
}
#endif
