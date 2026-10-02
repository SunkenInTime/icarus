/*
 * icarus_replay: decodes a Valorant .vrf replay into the buffer described in
 * docs/replay-format.md. Every buffer the probe and decode return is owned
 * by the library until passed to icarus_replay_free, exactly once.
 *
 * When is_error is nonzero, ptr holds a UTF-8 JSON error object instead:
 *   { "code": "...", "message": "...", "build"?: "..." }
 * with code one of notAReplay, unsupportedBuild, unsupportedCompression,
 * transformCheckFailed, corrupt, io, cancelled.
 *
 * Paths are NUL-terminated UTF-8. The functions are safe to call from any
 * thread; nothing is shared between calls.
 */
#ifndef ICARUS_REPLAY_H
#define ICARUS_REPLAY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint8_t* ptr;
  size_t len;
  uint32_t is_error;
} IcarusReplayBuffer;

/*
 * Header-only probe for a replay list: JSON
 *   { "id", "mapPath", "build", "durationMs", "recordedAt"?, "supported",
 *     "decoderVersion", "players": [{ "subject", "agentId" }] }
 * Reads the replay info and Header chunk only; never decompresses.
 */
IcarusReplayBuffer icarus_replay_probe(const char* path_utf8);

/*
 * A decode's progress and cancel request. The library owns its memory and
 * makes every access atomic, so other threads may poll and cancel through
 * these functions while icarus_replay_decode runs.
 */
typedef struct IcarusReplayControl IcarusReplayControl;

/* A new control: progress 0, not cancelled. */
IcarusReplayControl* icarus_replay_control_new(void);

/* The decode's progress, 0..10000 (hundredths of a percent); 0 for NULL. */
uint32_t icarus_replay_control_progress(const IcarusReplayControl* control);

/* Stops the decode using the control with the `cancelled` error at its next
 * frame or packet. NULL is ignored. */
void icarus_replay_control_cancel(const IcarusReplayControl* control);

/* Releases a control, once, after any decode using it has returned. NULL is
 * ignored. */
void icarus_replay_control_free(IcarusReplayControl* control);

/*
 * Full decode: the .icrp buffer, or an error object. No callbacks: progress
 * and cancel go through `control`, which may be NULL and must not be freed
 * until the call returns.
 */
IcarusReplayBuffer icarus_replay_decode(const char* path_utf8,
                                        const IcarusReplayControl* control);

/* Releases a buffer from either function. A NULL ptr is ignored. */
void icarus_replay_free(IcarusReplayBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif /* ICARUS_REPLAY_H */
