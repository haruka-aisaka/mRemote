#include "mr_pcm_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct mr_pcm_ring {
    _Atomic size_t write_count;
    _Atomic size_t read_count;
    size_t capacity;
    uint8_t *bytes;
};

mr_pcm_ring *mr_pcm_ring_create(size_t capacity)
{
    mr_pcm_ring *ring;
    if (capacity == 0u) {
        return NULL;
    }
    ring = (mr_pcm_ring *)calloc(1u, sizeof(*ring));
    if (ring == NULL) {
        return NULL;
    }
    ring->bytes = (uint8_t *)calloc(capacity, 1u);
    if (ring->bytes == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    atomic_init(&ring->write_count, 0u);
    atomic_init(&ring->read_count, 0u);
    return ring;
}

void mr_pcm_ring_destroy(mr_pcm_ring *ring)
{
    if (ring == NULL) {
        return;
    }
    free(ring->bytes);
    free(ring);
}

int mr_pcm_ring_write(mr_pcm_ring *ring, const uint8_t *bytes, size_t length)
{
    size_t written;
    size_t read;
    size_t offset;
    size_t first;
    if (ring == NULL || bytes == NULL || length == 0u) {
        return 0;
    }
    written = atomic_load_explicit(&ring->write_count, memory_order_relaxed);
    read = atomic_load_explicit(&ring->read_count, memory_order_acquire);
    if (length > ring->capacity - (written - read)) {
        return 0;
    }
    offset = written % ring->capacity;
    first = ring->capacity - offset < length ? ring->capacity - offset : length;
    memcpy(ring->bytes + offset, bytes, first);
    memcpy(ring->bytes, bytes + first, length - first);
    atomic_store_explicit(&ring->write_count, written + length, memory_order_release);
    return 1;
}

size_t mr_pcm_ring_read(mr_pcm_ring *ring, uint8_t *destination, size_t length)
{
    size_t written;
    size_t read;
    size_t available;
    size_t offset;
    size_t first;
    if (ring == NULL || destination == NULL || length == 0u) {
        return 0u;
    }
    read = atomic_load_explicit(&ring->read_count, memory_order_relaxed);
    written = atomic_load_explicit(&ring->write_count, memory_order_acquire);
    available = written - read;
    if (length > available) {
        length = available;
    }
    offset = read % ring->capacity;
    first = ring->capacity - offset < length ? ring->capacity - offset : length;
    memcpy(destination, ring->bytes + offset, first);
    memcpy(destination + first, ring->bytes, length - first);
    atomic_store_explicit(&ring->read_count, read + length, memory_order_release);
    return length;
}

size_t mr_pcm_ring_readable(const mr_pcm_ring *ring)
{
    if (ring == NULL) {
        return 0u;
    }
    return atomic_load_explicit(&ring->write_count, memory_order_acquire) -
        atomic_load_explicit(&ring->read_count, memory_order_relaxed);
}

void mr_pcm_ring_discard(mr_pcm_ring *ring)
{
    if (ring == NULL) {
        return;
    }
    atomic_store_explicit(
        &ring->read_count,
        atomic_load_explicit(&ring->write_count, memory_order_acquire),
        memory_order_release);
}
