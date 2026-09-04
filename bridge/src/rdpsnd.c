#include "mremote/rdpsnd.h"

#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define MR_RDPSND_MAX_CONFIGURED_WAVE_BYTES (64u * 1024u * 1024u)

struct mr_rdpsnd_device {
    pthread_mutex_t mutex;
    pthread_mutex_t callback_mutex;
    pthread_cond_t condition;
    mr_rdpsnd_callbacks callbacks;
    void *callback_context;
    uint64_t generation;
    uint64_t stream_id;
    size_t max_wave_bytes;
    unsigned int callbacks_in_flight;
    unsigned int close_calls_in_flight;
    mr_rdpsnd_format format;
    int open;
    int closing;
    int focused;
    int freeing;
    int callback_active;
    pthread_t callback_thread;
};

static uint64_t mr_rdpsnd_next_stream_id(uint64_t current)
{
    ++current;
    if (current == 0u) {
        ++current;
    }
    return current;
}

static int mr_rdpsnd_reserved_is_zero(const uint8_t *reserved, size_t length)
{
    size_t index;
    for (index = 0u; index < length; ++index) {
        if (reserved[index] != 0u) {
            return 0;
        }
    }
    return 1;
}

static mr_rdp_status mr_rdpsnd_inspect_format(
    const mr_rdpsnd_format *format,
    uint8_t *out_supported)
{
    uint32_t bytes_per_sample;
    uint32_t expected_block_align;
    uint64_t expected_average;

    if (format == NULL || out_supported == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_supported = 0u;
    if (format->struct_size < sizeof(*format)) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (format->reserved != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (format->format_tag != MR_RDPSND_WAVE_FORMAT_PCM) {
        return MR_RDP_STATUS_OK;
    }
    if (format->channels == 0u || format->samples_per_second == 0u ||
        format->bits_per_sample == 0u ||
        (format->bits_per_sample % 8u) != 0u || format->extra_size != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    bytes_per_sample = (uint32_t)format->bits_per_sample / 8u;
    expected_block_align = (uint32_t)format->channels * bytes_per_sample;
    if (expected_block_align == 0u || expected_block_align > UINT16_MAX ||
        format->block_align != expected_block_align) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    expected_average = (uint64_t)format->samples_per_second * expected_block_align;
    if (expected_average > UINT32_MAX ||
        format->average_bytes_per_second != (uint32_t)expected_average) {
        return MR_RDP_ERROR_INVALID_DATA;
    }

    if (format->channels <= 2u &&
        format->samples_per_second >= 8000u &&
        format->samples_per_second <= 192000u &&
        (format->bits_per_sample == 8u || format->bits_per_sample == 16u)) {
        *out_supported = 1u;
    }
    return MR_RDP_STATUS_OK;
}

void mr_rdpsnd_format_init(mr_rdpsnd_format *format)
{
    if (format == NULL) {
        return;
    }
    memset(format, 0, sizeof(*format));
    format->struct_size = (uint32_t)sizeof(*format);
    format->format_tag = MR_RDPSND_WAVE_FORMAT_PCM;
    format->channels = 2u;
    format->samples_per_second = 48000u;
    format->bits_per_sample = 16u;
    format->block_align = 4u;
    format->average_bytes_per_second = 192000u;
}

void mr_rdpsnd_config_init(mr_rdpsnd_config *config)
{
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->struct_size = (uint32_t)sizeof(*config);
    config->abi_version = MR_RDPSND_ABI_VERSION;
    config->max_wave_bytes = MR_RDPSND_DEFAULT_MAX_WAVE_BYTES;
}

void mr_rdpsnd_callbacks_init(mr_rdpsnd_callbacks *callbacks)
{
    if (callbacks == NULL) {
        return;
    }
    memset(callbacks, 0, sizeof(*callbacks));
    callbacks->struct_size = (uint32_t)sizeof(*callbacks);
    callbacks->abi_version = MR_RDPSND_ABI_VERSION;
}

mr_rdp_status mr_rdpsnd_format_supported(
    const mr_rdpsnd_format *format,
    uint8_t *out_supported)
{
    return mr_rdpsnd_inspect_format(format, out_supported);
}

mr_rdp_status mr_rdpsnd_device_create(
    const mr_rdpsnd_config *config,
    const mr_rdpsnd_callbacks *callbacks,
    void *context,
    mr_rdpsnd_device **out_device)
{
    mr_rdpsnd_device *device;
    size_t maximum;
    int mutex_initialized = 0;
    int callback_mutex_initialized = 0;

    if (out_device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_device = NULL;
    if (config == NULL || callbacks == NULL ||
        config->struct_size < sizeof(*config) ||
        config->abi_version != MR_RDPSND_ABI_VERSION ||
        config->generation == 0u ||
        config->initially_focused > 1u ||
        !mr_rdpsnd_reserved_is_zero(config->reserved, sizeof(config->reserved)) ||
        callbacks->struct_size < sizeof(*callbacks) ||
        callbacks->abi_version != MR_RDPSND_ABI_VERSION ||
        callbacks->on_wave_confirm == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    maximum = config->max_wave_bytes == 0u
        ? MR_RDPSND_DEFAULT_MAX_WAVE_BYTES
        : config->max_wave_bytes;
    if (maximum > MR_RDPSND_MAX_CONFIGURED_WAVE_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }

    device = (mr_rdpsnd_device *)calloc(1u, sizeof(*device));
    if (device == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    if (pthread_mutex_init(&device->mutex, NULL) != 0) {
        free(device);
        return MR_RDP_ERROR_BACKEND;
    }
    mutex_initialized = 1;
    if (pthread_mutex_init(&device->callback_mutex, NULL) != 0) {
        (void)pthread_mutex_destroy(&device->mutex);
        free(device);
        return MR_RDP_ERROR_BACKEND;
    }
    callback_mutex_initialized = 1;
    if (pthread_cond_init(&device->condition, NULL) != 0) {
        if (callback_mutex_initialized) {
            (void)pthread_mutex_destroy(&device->callback_mutex);
        }
        if (mutex_initialized) {
            (void)pthread_mutex_destroy(&device->mutex);
        }
        free(device);
        return MR_RDP_ERROR_BACKEND;
    }
    device->callbacks = *callbacks;
    device->callbacks.struct_size = (uint32_t)sizeof(device->callbacks);
    device->callbacks.abi_version = MR_RDPSND_ABI_VERSION;
    device->callback_context = context;
    device->generation = config->generation;
    device->max_wave_bytes = maximum;
    device->focused = config->initially_focused != 0u;
    *out_device = device;
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_rdpsnd_require_supported_format(
    const mr_rdpsnd_format *format)
{
    uint8_t supported = 0u;
    mr_rdp_status status = mr_rdpsnd_inspect_format(format, &supported);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    return supported != 0u ? MR_RDP_STATUS_OK : MR_RDP_ERROR_UNSUPPORTED;
}

static int mr_rdpsnd_is_callback_thread(mr_rdpsnd_device *device)
{
    return device->callback_active &&
        pthread_equal(device->callback_thread, pthread_self()) != 0;
}

mr_rdp_status mr_rdpsnd_device_open(
    mr_rdpsnd_device *device,
    const mr_rdpsnd_format *format)
{
    mr_rdp_status status;
    if (device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    status = mr_rdpsnd_require_supported_format(format);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (device->freeing || device->closing || device->open ||
        mr_rdpsnd_is_callback_thread(device)) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    device->format = *format;
    device->format.struct_size = (uint32_t)sizeof(device->format);
    device->stream_id = mr_rdpsnd_next_stream_id(device->stream_id);
    device->open = 1;
    (void)pthread_mutex_unlock(&device->mutex);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdpsnd_device_set_format(
    mr_rdpsnd_device *device,
    const mr_rdpsnd_format *format)
{
    mr_rdp_status status;
    if (device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    status = mr_rdpsnd_require_supported_format(format);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (device->freeing || !device->open || mr_rdpsnd_is_callback_thread(device)) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    device->format = *format;
    device->format.struct_size = (uint32_t)sizeof(device->format);
    device->stream_id = mr_rdpsnd_next_stream_id(device->stream_id);
    (void)pthread_mutex_unlock(&device->mutex);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdpsnd_device_set_focused(
    mr_rdpsnd_device *device,
    uint8_t focused)
{
    if (device == NULL || focused > 1u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (device->freeing) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    device->focused = focused != 0u;
    (void)pthread_mutex_unlock(&device->mutex);
    return MR_RDP_STATUS_OK;
}

static void mr_rdpsnd_callback_finished(mr_rdpsnd_device *device)
{
    (void)pthread_mutex_lock(&device->mutex);
    device->callback_active = 0;
    if (device->callbacks_in_flight > 0u) {
        --device->callbacks_in_flight;
    }
    (void)pthread_cond_broadcast(&device->condition);
    (void)pthread_mutex_unlock(&device->mutex);
    (void)pthread_mutex_unlock(&device->callback_mutex);
}

mr_rdp_status mr_rdpsnd_device_play(
    mr_rdpsnd_device *device,
    uint8_t block_number,
    uint16_t server_timestamp,
    const uint8_t *bytes,
    size_t length)
{
    mr_rdpsnd_pcm_callback pcm_callback;
    mr_rdpsnd_wave_confirm_callback confirm_callback;
    mr_rdpsnd_pcm_packet packet;
    mr_rdpsnd_wave_confirmation confirmation;
    mr_rdpsnd_pcm_result pcm_result = MR_RDPSND_PCM_ACCEPTED;
    mr_rdpsnd_confirm_disposition disposition;
    mr_rdp_status status;
    int open;
    int focused;
    int freeing;

    if (device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (mr_rdpsnd_is_callback_thread(device)) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    ++device->callbacks_in_flight;
    (void)pthread_mutex_unlock(&device->mutex);

    (void)pthread_mutex_lock(&device->callback_mutex);
    (void)pthread_mutex_lock(&device->mutex);
    device->callback_active = 1;
    device->callback_thread = pthread_self();
    open = device->open;
    focused = device->focused;
    freeing = device->freeing;
    pcm_callback = device->callbacks.on_pcm;
    confirm_callback = device->callbacks.on_wave_confirm;

    memset(&packet, 0, sizeof(packet));
    packet.struct_size = (uint32_t)sizeof(packet);
    packet.generation = device->generation;
    packet.stream_id = device->stream_id;
    packet.format = device->format;
    packet.block_number = block_number;
    packet.server_timestamp = server_timestamp;
    packet.bytes = bytes;
    packet.length = length;

    memset(&confirmation, 0, sizeof(confirmation));
    confirmation.struct_size = (uint32_t)sizeof(confirmation);
    confirmation.generation = device->generation;
    confirmation.stream_id = device->stream_id;
    confirmation.block_number = block_number;
    confirmation.server_timestamp = server_timestamp;
    (void)pthread_mutex_unlock(&device->mutex);

    if (!open || freeing) {
        disposition = MR_RDPSND_CONFIRM_DROPPED_CLOSED;
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (bytes == NULL || length == 0u ||
               (packet.format.block_align != 0u &&
                (length % packet.format.block_align) != 0u)) {
        disposition = MR_RDPSND_CONFIRM_DROPPED_MALFORMED;
        status = MR_RDP_ERROR_INVALID_DATA;
    } else if (length > device->max_wave_bytes) {
        disposition = MR_RDPSND_CONFIRM_DROPPED_MALFORMED;
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!focused) {
        disposition = MR_RDPSND_CONFIRM_DROPPED_NOT_FOCUSED;
        status = MR_RDP_STATUS_OK;
    } else if (pcm_callback == NULL) {
        disposition = MR_RDPSND_CONFIRM_DROPPED_NO_CONSUMER;
        status = MR_RDP_STATUS_OK;
    } else {
        pcm_result = pcm_callback(device->callback_context, &packet);
        if (pcm_result == MR_RDPSND_PCM_ACCEPTED) {
            disposition = MR_RDPSND_CONFIRM_DELIVERED;
            status = MR_RDP_STATUS_OK;
        } else if (pcm_result == MR_RDPSND_PCM_DROP_BACKPRESSURE) {
            disposition = MR_RDPSND_CONFIRM_DROPPED_BACKPRESSURE;
            status = MR_RDP_STATUS_OK;
        } else {
            disposition = MR_RDPSND_CONFIRM_DROPPED_CONSUMER_ERROR;
            status = MR_RDP_ERROR_BACKEND;
        }
    }

    confirmation.disposition = disposition;
    confirm_callback(device->callback_context, &confirmation);
    mr_rdpsnd_callback_finished(device);
    return status;
}

mr_rdp_status mr_rdpsnd_device_close(mr_rdpsnd_device *device)
{
    if (device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (mr_rdpsnd_is_callback_thread(device)) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    if (device->freeing) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    ++device->close_calls_in_flight;
    device->closing = 1;
    device->open = 0;
    memset(&device->format, 0, sizeof(device->format));
    device->stream_id = mr_rdpsnd_next_stream_id(device->stream_id);
    while (device->callbacks_in_flight != 0u) {
        (void)pthread_cond_wait(&device->condition, &device->mutex);
    }
    --device->close_calls_in_flight;
    if (device->close_calls_in_flight == 0u) {
        device->closing = 0;
    }
    (void)pthread_cond_broadcast(&device->condition);
    (void)pthread_mutex_unlock(&device->mutex);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdpsnd_device_free(mr_rdpsnd_device **inout_device)
{
    mr_rdpsnd_device *device;
    if (inout_device == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    device = *inout_device;
    if (device == NULL) {
        return MR_RDP_STATUS_OK;
    }
    (void)pthread_mutex_lock(&device->mutex);
    if (mr_rdpsnd_is_callback_thread(device)) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    if (device->freeing) {
        (void)pthread_mutex_unlock(&device->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    device->freeing = 1;
    device->open = 0;
    memset(&device->format, 0, sizeof(device->format));
    device->stream_id = mr_rdpsnd_next_stream_id(device->stream_id);
    while (device->callbacks_in_flight != 0u ||
           device->close_calls_in_flight != 0u) {
        (void)pthread_cond_wait(&device->condition, &device->mutex);
    }
    (void)pthread_mutex_unlock(&device->mutex);

    *inout_device = NULL;
    (void)pthread_cond_destroy(&device->condition);
    (void)pthread_mutex_destroy(&device->callback_mutex);
    (void)pthread_mutex_destroy(&device->mutex);
    memset(device, 0, sizeof(*device));
    free(device);
    return MR_RDP_STATUS_OK;
}
