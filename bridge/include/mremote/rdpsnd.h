#ifndef MREMOTE_RDPSND_H
#define MREMOTE_RDPSND_H

#include "mremote/rdp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MR_RDPSND_ABI_VERSION 1u
#define MR_RDPSND_WAVE_FORMAT_PCM 1u
#define MR_RDPSND_DEFAULT_MAX_WAVE_BYTES (1024u * 1024u)

typedef struct mr_rdpsnd_device mr_rdpsnd_device;

/* Version-independent WAVEFORMATEX subset used at the FreeRDP boundary. */
typedef struct mr_rdpsnd_format {
    uint32_t struct_size;
    uint16_t format_tag;
    uint16_t channels;
    uint32_t samples_per_second;
    uint32_t average_bytes_per_second;
    uint16_t block_align;
    uint16_t bits_per_sample;
    uint16_t extra_size;
    uint16_t reserved;
} mr_rdpsnd_format;

typedef struct mr_rdpsnd_config {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t generation;
    size_t max_wave_bytes;
    uint8_t initially_focused;
    uint8_t reserved[7];
} mr_rdpsnd_config;

typedef uint8_t mr_rdpsnd_pcm_result;
enum {
    MR_RDPSND_PCM_ACCEPTED = 0,
    MR_RDPSND_PCM_DROP_BACKPRESSURE = 1
};

typedef uint8_t mr_rdpsnd_confirm_disposition;
enum {
    MR_RDPSND_CONFIRM_DELIVERED = 0,
    MR_RDPSND_CONFIRM_DROPPED_NOT_FOCUSED = 1,
    MR_RDPSND_CONFIRM_DROPPED_NO_CONSUMER = 2,
    MR_RDPSND_CONFIRM_DROPPED_BACKPRESSURE = 3,
    MR_RDPSND_CONFIRM_DROPPED_MALFORMED = 4,
    MR_RDPSND_CONFIRM_DROPPED_CLOSED = 5,
    MR_RDPSND_CONFIRM_DROPPED_CONSUMER_ERROR = 6
};

typedef struct mr_rdpsnd_pcm_packet {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    uint64_t stream_id;
    mr_rdpsnd_format format;
    uint8_t block_number;
    uint8_t reserved2;
    uint16_t server_timestamp;
    const uint8_t *bytes;
    size_t length;
} mr_rdpsnd_pcm_packet;

typedef struct mr_rdpsnd_wave_confirmation {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    uint64_t stream_id;
    uint8_t block_number;
    mr_rdpsnd_confirm_disposition disposition;
    uint16_t server_timestamp;
} mr_rdpsnd_wave_confirmation;

typedef mr_rdpsnd_pcm_result (*mr_rdpsnd_pcm_callback)(
    void *context,
    const mr_rdpsnd_pcm_packet *packet);
typedef void (*mr_rdpsnd_wave_confirm_callback)(
    void *context,
    const mr_rdpsnd_wave_confirmation *confirmation);

typedef struct mr_rdpsnd_callbacks {
    uint32_t struct_size;
    uint32_t abi_version;
    mr_rdpsnd_pcm_callback on_pcm;
    mr_rdpsnd_wave_confirm_callback on_wave_confirm;
} mr_rdpsnd_callbacks;

void mr_rdpsnd_format_init(mr_rdpsnd_format *format);
void mr_rdpsnd_config_init(mr_rdpsnd_config *config);
void mr_rdpsnd_callbacks_init(mr_rdpsnd_callbacks *callbacks);

/* PCM-only FormatSupported equivalent. Unsupported but structurally valid
 * formats return OK with out_supported=0; malformed input returns an error. */
mr_rdp_status mr_rdpsnd_format_supported(
    const mr_rdpsnd_format *format,
    uint8_t *out_supported);

/* Copies config and callback table. generation zero is reserved and rejected;
 * on_wave_confirm is mandatory. The context is borrowed through free
 * returning. */
mr_rdp_status mr_rdpsnd_device_create(
    const mr_rdpsnd_config *config,
    const mr_rdpsnd_callbacks *callbacks,
    void *context,
    mr_rdpsnd_device **out_device);

/* FormatSupported/Open/SetFormat/Play/Close equivalents. Open and SetFormat
 * reject every non-PCM format. Close is thread-safe, drains active callbacks,
 * and is idempotent. */
mr_rdp_status mr_rdpsnd_device_open(
    mr_rdpsnd_device *device,
    const mr_rdpsnd_format *format);
mr_rdp_status mr_rdpsnd_device_set_format(
    mr_rdpsnd_device *device,
    const mr_rdpsnd_format *format);
mr_rdp_status mr_rdpsnd_device_set_focused(
    mr_rdpsnd_device *device,
    uint8_t focused);

/* Every non-reentrant call with a non-NULL live device invokes on_wave_confirm
 * exactly once, including malformed, non-focused, backpressure, and closed-
 * stream drops. PCM bytes are a borrowed callback-duration view; on_pcm must
 * synchronously copy accepted data into its bounded ring. Callbacks are
 * serialized. Audio callbacks must not call play/close/free; such reentrancy
 * is rejected to avoid teardown deadlock. set_focused remains safe. */
mr_rdp_status mr_rdpsnd_device_play(
    mr_rdpsnd_device *device,
    uint8_t block_number,
    uint16_t server_timestamp,
    const uint8_t *bytes,
    size_t length);

mr_rdp_status mr_rdpsnd_device_close(mr_rdpsnd_device *device);

/* Free equivalent. It closes and drains registered callbacks, clears
 * *inout_device, and accepts an already-NULL handle. Raw-pointer lifetime
 * belongs to the owner: an external gate must prevent new invocations before
 * free starts and must not leave a call racing between invocation and its
 * internal registration. Calling through a stale handle is never safe.
 * Calling from an audio callback is rejected. */
mr_rdp_status mr_rdpsnd_device_free(mr_rdpsnd_device **inout_device);

#ifdef __cplusplus
}
#endif

#endif
