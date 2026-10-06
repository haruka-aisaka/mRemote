#ifndef MREMOTE_PCM_RING_H
#define MREMOTE_PCM_RING_H

#include <stddef.h>
#include <stdint.h>

/*
 * A single-producer, single-consumer byte ring for PCM.
 *
 * The producer is the session's rdpsnd callback; the consumer is the
 * AVAudioEngine render callback, which must not lock, allocate or wait. Both
 * indices are monotonic counters published with release/acquire ordering, so
 * neither side ever blocks the other. Exactly one thread may write and one
 * may read at a time; discard is a consumer-side operation.
 */
typedef struct mr_pcm_ring mr_pcm_ring;

mr_pcm_ring *mr_pcm_ring_create(size_t capacity);
void mr_pcm_ring_destroy(mr_pcm_ring *ring);

/* Writes all of length or nothing, so a frame is never split by a full
 * ring. Returns 1 when written, 0 when there was not room. */
int mr_pcm_ring_write(mr_pcm_ring *ring, const uint8_t *bytes, size_t length);

/* Reads up to length bytes and returns how many were read. */
size_t mr_pcm_ring_read(mr_pcm_ring *ring, uint8_t *destination, size_t length);

size_t mr_pcm_ring_readable(const mr_pcm_ring *ring);

/* Consumer side: drops everything written so far, e.g. on a focus switch so
 * the backlog of a session that was in the background is never played. */
void mr_pcm_ring_discard(mr_pcm_ring *ring);

#endif
