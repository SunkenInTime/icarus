/*
 * icarus_replay: decodes a Valorant .vrf replay into the buffer described in
 * docs/replay-format.md. Three functions; every buffer they return is owned
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
 * Full decode: the .icrp buffer, or an error object. No callbacks; the
 * caller owns two cells it polls/sets from another thread:
 *   progress  written by the decoder with 0..10000 (hundredths of a percent),
 *             relaxed atomic stores;
 *   cancel    read between chunks and packets; nonzero stops the decode with
 *             the `cancelled` error.
 * Either pointer may be NULL. Both must be 4-byte aligned, stay valid until
 * the call returns, and be accessed atomically by other threads.
 */
IcarusReplayBuffer icarus_replay_decode(const char* path_utf8, uint32_t* progress,
                                        const uint32_t* cancel);

/* Releases a buffer from either function. A NULL ptr is ignored. */
void icarus_replay_free(IcarusReplayBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif /* ICARUS_REPLAY_H */
