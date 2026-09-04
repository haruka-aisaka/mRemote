#include "mremote/rdpsnd.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct audio_test_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdpsnd_device *device;
    uint64_t expected_generation;
    const uint8_t *expected_bytes;
    size_t expected_length;
    mr_rdpsnd_pcm_result pcm_result;
    int block_pcm;
    int release_pcm;
    int pcm_entered;
    int play_done;
    int close_done;
    int attempt_reentrant_free;
    mr_rdp_status reentrant_free_status;
    mr_rdp_status play_status;
    mr_rdp_status close_status;
    atomic_int failures;
    atomic_int pcm_count;
    atomic_int confirm_count;
    atomic_int poison_count;
    mr_rdpsnd_wave_confirmation last_confirmation;
    uint64_t last_pcm_stream_id;
} audio_test_context;

static int audio_context_init(audio_test_context *context)
{
    memset(context, 0, sizeof(*context));
    if (pthread_mutex_init(&context->mutex, NULL) != 0) {
        return 0;
    }
    if (pthread_cond_init(&context->condition, NULL) != 0) {
        (void)pthread_mutex_destroy(&context->mutex);
        return 0;
    }
    context->pcm_result = MR_RDPSND_PCM_ACCEPTED;
    atomic_init(&context->failures, 0);
    atomic_init(&context->pcm_count, 0);
    atomic_init(&context->confirm_count, 0);
    atomic_init(&context->poison_count, 0);
    return 1;
}

static void audio_context_destroy(audio_test_context *context)
{
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
}

static void audio_failure(audio_test_context *context, const char *message)
{
    (void)fprintf(stderr, "audio callback failure: %s\n", message);
    (void)atomic_fetch_add_explicit(&context->failures, 1, memory_order_relaxed);
}

static mr_rdpsnd_pcm_result pcm_callback(
    void *opaque,
    const mr_rdpsnd_pcm_packet *packet)
{
    audio_test_context *context = (audio_test_context *)opaque;
    (void)atomic_fetch_add_explicit(&context->pcm_count, 1, memory_order_relaxed);
    if (packet == NULL || packet->struct_size < sizeof(*packet) ||
        packet->generation != context->expected_generation ||
        packet->format.format_tag != MR_RDPSND_WAVE_FORMAT_PCM) {
        audio_failure(context, "invalid PCM packet metadata");
    }
    if (context->expected_bytes != NULL &&
        (packet->bytes != context->expected_bytes ||
         packet->length != context->expected_length)) {
        audio_failure(context, "PCM view changed");
    }
    context->last_pcm_stream_id = packet->stream_id;
    if (context->attempt_reentrant_free) {
        context->reentrant_free_status = mr_rdpsnd_device_free(&context->device);
    }
    (void)pthread_mutex_lock(&context->mutex);
    context->pcm_entered = 1;
    (void)pthread_cond_broadcast(&context->condition);
    while (context->block_pcm && !context->release_pcm) {
        (void)pthread_cond_wait(&context->condition, &context->mutex);
    }
    (void)pthread_mutex_unlock(&context->mutex);
    return context->pcm_result;
}

static void confirm_callback(
    void *opaque,
    const mr_rdpsnd_wave_confirmation *confirmation)
{
    audio_test_context *context = (audio_test_context *)opaque;
    if (confirmation == NULL || confirmation->struct_size < sizeof(*confirmation) ||
        confirmation->generation != context->expected_generation) {
        audio_failure(context, "invalid confirmation metadata");
        return;
    }
    context->last_confirmation = *confirmation;
    (void)atomic_fetch_add_explicit(&context->confirm_count, 1, memory_order_relaxed);
}

static mr_rdpsnd_pcm_result poison_pcm_callback(
    void *opaque,
    const mr_rdpsnd_pcm_packet *packet)
{
    audio_test_context *context = (audio_test_context *)opaque;
    (void)packet;
    (void)atomic_fetch_add_explicit(&context->poison_count, 1, memory_order_relaxed);
    return MR_RDPSND_PCM_ACCEPTED;
}

static void poison_confirm_callback(
    void *opaque,
    const mr_rdpsnd_wave_confirmation *confirmation)
{
    audio_test_context *context = (audio_test_context *)opaque;
    (void)confirmation;
    (void)atomic_fetch_add_explicit(&context->poison_count, 1, memory_order_relaxed);
}

static struct timespec deadline_after_seconds(unsigned int seconds)
{
    struct timespec deadline;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)seconds;
    return deadline;
}

static int wait_for_field(audio_test_context *context, const int *field)
{
    struct timespec deadline = deadline_after_seconds(3u);
    int result = 1;
    (void)pthread_mutex_lock(&context->mutex);
    while (*field == 0 && result == 1) {
        if (pthread_cond_timedwait(&context->condition, &context->mutex, &deadline) != 0) {
            result = 0;
        }
    }
    (void)pthread_mutex_unlock(&context->mutex);
    return result;
}

static void *play_thread_main(void *opaque)
{
    audio_test_context *context = (audio_test_context *)opaque;
    context->play_status = mr_rdpsnd_device_play(
        context->device, 21u, 456u, context->expected_bytes, context->expected_length);
    (void)pthread_mutex_lock(&context->mutex);
    context->play_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
    return NULL;
}

static void *close_thread_main(void *opaque)
{
    audio_test_context *context = (audio_test_context *)opaque;
    context->close_status = mr_rdpsnd_device_close(context->device);
    (void)pthread_mutex_lock(&context->mutex);
    context->close_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
    return NULL;
}

static int wait_until_close_has_closed_stream(
    mr_rdpsnd_device *device,
    const mr_rdpsnd_format *format)
{
    unsigned int attempt;
    for (attempt = 0u; attempt < 1000000u; ++attempt) {
        const mr_rdp_status status = mr_rdpsnd_device_set_format(device, format);
        if (status == MR_RDP_ERROR_INVALID_STATE) {
            return 1;
        }
        if (status != MR_RDP_STATUS_OK) {
            return 0;
        }
        (void)sched_yield();
    }
    return 0;
}

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void initialize_callbacks(mr_rdpsnd_callbacks *callbacks)
{
    mr_rdpsnd_callbacks_init(callbacks);
    callbacks->on_pcm = pcm_callback;
    callbacks->on_wave_confirm = confirm_callback;
}

static int create_device(
    audio_test_context *context,
    uint8_t focused,
    size_t max_wave_bytes,
    mr_rdpsnd_callbacks *callbacks)
{
    mr_rdpsnd_config config;
    mr_rdpsnd_config_init(&config);
    config.generation = context->expected_generation;
    config.initially_focused = focused;
    config.max_wave_bytes = max_wave_bytes;
    return mr_rdpsnd_device_create(
        &config, callbacks, context, &context->device) == MR_RDP_STATUS_OK;
}

static int test_pcm_only_format_negotiation(void)
{
    mr_rdpsnd_format format;
    uint8_t supported = 9u;
    mr_rdpsnd_format_init(&format);
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) == MR_RDP_STATUS_OK);
    REQUIRE(supported == 1u);

    format.channels = 1u;
    format.samples_per_second = 44100u;
    format.block_align = 2u;
    format.average_bytes_per_second = 88200u;
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) == MR_RDP_STATUS_OK);
    REQUIRE(supported == 1u);

    format.format_tag = 2u;
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) == MR_RDP_STATUS_OK);
    REQUIRE(supported == 0u);

    mr_rdpsnd_format_init(&format);
    format.bits_per_sample = 24u;
    format.block_align = 6u;
    format.average_bytes_per_second = 288000u;
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) == MR_RDP_STATUS_OK);
    REQUIRE(supported == 0u);

    mr_rdpsnd_format_init(&format);
    format.block_align = 3u;
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) ==
            MR_RDP_ERROR_INVALID_DATA);
    REQUIRE(supported == 0u);
    mr_rdpsnd_format_init(&format);
    format.reserved = 1u;
    REQUIRE(mr_rdpsnd_format_supported(&format, &supported) ==
            MR_RDP_ERROR_INVALID_DATA);
    return 1;
}

static int test_generation_zero_is_rejected(void)
{
    mr_rdpsnd_config config;
    mr_rdpsnd_callbacks callbacks;
    mr_rdpsnd_device *device = (mr_rdpsnd_device *)(uintptr_t)1u;
    mr_rdpsnd_config_init(&config);
    mr_rdpsnd_callbacks_init(&callbacks);
    callbacks.on_wave_confirm = poison_confirm_callback;
    REQUIRE(config.generation == 0u);
    REQUIRE(mr_rdpsnd_device_create(
                &config, &callbacks, NULL, &device) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(device == NULL);
    return 1;
}

static int test_open_set_play_close_free_and_callback_copy(void)
{
    audio_test_context context;
    mr_rdpsnd_callbacks callbacks;
    mr_rdpsnd_format format;
    const uint8_t stereo_frame[] = { 1u, 2u, 3u, 4u };
    uint64_t first_stream_id;

    REQUIRE(audio_context_init(&context));
    context.expected_generation = 91u;
    context.expected_bytes = stereo_frame;
    context.expected_length = sizeof(stereo_frame);
    context.attempt_reentrant_free = 1;
    context.reentrant_free_status = MR_RDP_STATUS_OK;
    initialize_callbacks(&callbacks);
    REQUIRE(create_device(&context, 1u, 0u, &callbacks));
    callbacks.on_pcm = poison_pcm_callback;
    callbacks.on_wave_confirm = poison_confirm_callback;

    mr_rdpsnd_format_init(&format);
    format.format_tag = 3u;
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) ==
            MR_RDP_ERROR_UNSUPPORTED);
    mr_rdpsnd_format_init(&format);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdpsnd_device_play(
                context.device, 7u, 123u, stereo_frame, sizeof(stereo_frame)) ==
            MR_RDP_STATUS_OK);
    REQUIRE(context.reentrant_free_status == MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(context.device != NULL);
    REQUIRE(atomic_load_explicit(&context.pcm_count, memory_order_relaxed) == 1);
    REQUIRE(atomic_load_explicit(&context.confirm_count, memory_order_relaxed) == 1);
    REQUIRE(context.last_confirmation.disposition == MR_RDPSND_CONFIRM_DELIVERED);
    REQUIRE(context.last_confirmation.block_number == 7u);
    REQUIRE(context.last_confirmation.server_timestamp == 123u);
    REQUIRE(context.last_confirmation.stream_id == context.last_pcm_stream_id);
    first_stream_id = context.last_confirmation.stream_id;

    format.channels = 1u;
    format.samples_per_second = 44100u;
    format.block_align = 2u;
    format.average_bytes_per_second = 88200u;
    REQUIRE(mr_rdpsnd_device_set_format(context.device, &format) == MR_RDP_STATUS_OK);
    context.expected_length = 2u;
    REQUIRE(mr_rdpsnd_device_play(context.device, 8u, 124u, stereo_frame, 2u) ==
            MR_RDP_STATUS_OK);
    REQUIRE(context.last_confirmation.stream_id != first_stream_id);

    REQUIRE(mr_rdpsnd_device_close(context.device) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_close(context.device) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_play(
                context.device, 9u, 125u, stereo_frame, sizeof(stereo_frame)) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(context.last_confirmation.disposition == MR_RDPSND_CONFIRM_DROPPED_CLOSED);
    REQUIRE(atomic_load_explicit(&context.confirm_count, memory_order_relaxed) == 3);
    REQUIRE(atomic_load_explicit(&context.poison_count, memory_order_relaxed) == 0);
    REQUIRE(mr_rdpsnd_device_free(&context.device) == MR_RDP_STATUS_OK);
    REQUIRE(context.device == NULL);
    REQUIRE(mr_rdpsnd_device_free(&context.device) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    audio_context_destroy(&context);
    return 1;
}

static int test_malformed_nonfocused_and_backpressure_always_confirm(void)
{
    audio_test_context context;
    mr_rdpsnd_callbacks callbacks;
    mr_rdpsnd_format format;
    const uint8_t samples[8] = { 0u };
    int expected_confirms = 0;

    REQUIRE(audio_context_init(&context));
    context.expected_generation = 92u;
    initialize_callbacks(&callbacks);
    REQUIRE(create_device(&context, 0u, 4u, &callbacks));
    mr_rdpsnd_format_init(&format);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) == MR_RDP_STATUS_OK);

    REQUIRE(mr_rdpsnd_device_play(context.device, 1u, 1u, samples, 4u) ==
            MR_RDP_STATUS_OK);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition ==
            MR_RDPSND_CONFIRM_DROPPED_NOT_FOCUSED);
    REQUIRE(atomic_load_explicit(&context.pcm_count, memory_order_relaxed) == 0);

    REQUIRE(mr_rdpsnd_device_play(context.device, 2u, 2u, NULL, 4u) ==
            MR_RDP_ERROR_INVALID_DATA);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition == MR_RDPSND_CONFIRM_DROPPED_MALFORMED);
    REQUIRE(mr_rdpsnd_device_play(context.device, 3u, 3u, samples, 3u) ==
            MR_RDP_ERROR_INVALID_DATA);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition == MR_RDPSND_CONFIRM_DROPPED_MALFORMED);
    REQUIRE(mr_rdpsnd_device_play(context.device, 4u, 4u, samples, sizeof(samples)) ==
            MR_RDP_ERROR_LIMIT_EXCEEDED);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition == MR_RDPSND_CONFIRM_DROPPED_MALFORMED);

    REQUIRE(mr_rdpsnd_device_set_focused(context.device, 1u) == MR_RDP_STATUS_OK);
    context.expected_bytes = samples;
    context.expected_length = 4u;
    context.pcm_result = MR_RDPSND_PCM_DROP_BACKPRESSURE;
    REQUIRE(mr_rdpsnd_device_play(context.device, 5u, 5u, samples, 4u) ==
            MR_RDP_STATUS_OK);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition ==
            MR_RDPSND_CONFIRM_DROPPED_BACKPRESSURE);
    context.pcm_result = (mr_rdpsnd_pcm_result)99u;
    REQUIRE(mr_rdpsnd_device_play(context.device, 6u, 6u, samples, 4u) ==
            MR_RDP_ERROR_BACKEND);
    ++expected_confirms;
    REQUIRE(context.last_confirmation.disposition ==
            MR_RDPSND_CONFIRM_DROPPED_CONSUMER_ERROR);
    REQUIRE(atomic_load_explicit(&context.confirm_count, memory_order_relaxed) ==
            expected_confirms);
    REQUIRE(mr_rdpsnd_device_free(&context.device) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    audio_context_destroy(&context);
    return 1;
}

static int test_no_consumer_still_confirms(void)
{
    audio_test_context context;
    mr_rdpsnd_callbacks callbacks;
    mr_rdpsnd_format format;
    const uint8_t samples[4] = { 0u };
    REQUIRE(audio_context_init(&context));
    context.expected_generation = 93u;
    mr_rdpsnd_callbacks_init(&callbacks);
    callbacks.on_wave_confirm = confirm_callback;
    REQUIRE(create_device(&context, 1u, 0u, &callbacks));
    mr_rdpsnd_format_init(&format);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_play(context.device, 1u, 1u, samples, sizeof(samples)) ==
            MR_RDP_STATUS_OK);
    REQUIRE(context.last_confirmation.disposition ==
            MR_RDPSND_CONFIRM_DROPPED_NO_CONSUMER);
    REQUIRE(atomic_load_explicit(&context.confirm_count, memory_order_relaxed) == 1);
    REQUIRE(mr_rdpsnd_device_free(&context.device) == MR_RDP_STATUS_OK);
    audio_context_destroy(&context);
    return 1;
}

static int test_close_drains_pcm_and_confirmation(void)
{
    audio_test_context context;
    mr_rdpsnd_callbacks callbacks;
    mr_rdpsnd_format format;
    const uint8_t samples[4] = { 1u, 2u, 3u, 4u };
    pthread_t play_thread;
    pthread_t close_thread;

    REQUIRE(audio_context_init(&context));
    context.expected_generation = 94u;
    context.expected_bytes = samples;
    context.expected_length = sizeof(samples);
    context.block_pcm = 1;
    initialize_callbacks(&callbacks);
    REQUIRE(create_device(&context, 1u, 0u, &callbacks));
    mr_rdpsnd_format_init(&format);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&play_thread, NULL, play_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.pcm_entered));
    REQUIRE(pthread_create(&close_thread, NULL, close_thread_main, &context) == 0);
    REQUIRE(wait_until_close_has_closed_stream(context.device, &format));
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) ==
            MR_RDP_ERROR_INVALID_STATE);

    (void)pthread_mutex_lock(&context.mutex);
    REQUIRE(context.close_done == 0);
    context.release_pcm = 1;
    (void)pthread_cond_broadcast(&context.condition);
    (void)pthread_mutex_unlock(&context.mutex);

    REQUIRE(wait_for_field(&context, &context.play_done));
    REQUIRE(wait_for_field(&context, &context.close_done));
    REQUIRE(pthread_join(play_thread, NULL) == 0);
    REQUIRE(pthread_join(close_thread, NULL) == 0);
    REQUIRE(context.play_status == MR_RDP_STATUS_OK);
    REQUIRE(context.close_status == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.pcm_count, memory_order_relaxed) == 1);
    REQUIRE(atomic_load_explicit(&context.confirm_count, memory_order_relaxed) == 1);
    REQUIRE(mr_rdpsnd_device_open(context.device, &format) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_close(context.device) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdpsnd_device_free(&context.device) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    audio_context_destroy(&context);
    return 1;
}

typedef int (*test_function)(void);
typedef struct test_case {
    const char *name;
    test_function function;
} test_case;

int main(void)
{
    const test_case tests[] = {
        { "PCM-only format negotiation", test_pcm_only_format_negotiation },
        { "generation zero rejection", test_generation_zero_is_rejected },
        { "open/set/play/close/free and callback copy", test_open_set_play_close_free_and_callback_copy },
        { "malformed/nonfocused/backpressure confirm", test_malformed_nonfocused_and_backpressure_always_confirm },
        { "no consumer confirm", test_no_consumer_still_confirms },
        { "close drains callbacks", test_close_drains_pcm_and_confirmation }
    };
    size_t index;
    for (index = 0u; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        const int result = tests[index].function();
        (void)printf("%s %s\n", result ? "PASS" : "FAIL", tests[index].name);
        if (!result) {
            return EXIT_FAILURE;
        }
    }
    (void)printf("%zu rdpsnd contract tests passed\n",
                 sizeof(tests) / sizeof(tests[0]));
    return EXIT_SUCCESS;
}
