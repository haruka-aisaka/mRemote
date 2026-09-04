#include "bridge_internal.h"
#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct channel_test_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    pthread_t run_thread;
    uint64_t generation;
    uint64_t last_sequence;
    int connected;
    int run_done;
    int probe_done;
    int resize_done;
    mr_rdp_status run_status;
    unsigned int channel_counts[6][2];
    unsigned int probe_counts[5];
    unsigned int resize_count;
    const uint8_t *source_probe_pointer;
    uint8_t expected_probe[32];
    size_t expected_probe_length;
    uint8_t expected_probe_sha256[MR_RDP_SHA256_BYTES];
    atomic_int failures;
    atomic_int poison_callbacks;
} channel_test_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void record_failure(channel_test_context *context, const char *message)
{
    (void)fprintf(stderr, "callback failure: %s\n", message);
    (void)atomic_fetch_add_explicit(&context->failures, 1, memory_order_relaxed);
}

static int channel_test_context_init(channel_test_context *context)
{
    memset(context, 0, sizeof(*context));
    if (pthread_mutex_init(&context->mutex, NULL) != 0) {
        return 0;
    }
    if (pthread_cond_init(&context->condition, NULL) != 0) {
        (void)pthread_mutex_destroy(&context->mutex);
        return 0;
    }
    atomic_init(&context->failures, 0);
    atomic_init(&context->poison_callbacks, 0);
    return 1;
}

static void channel_test_context_destroy(channel_test_context *context)
{
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
}

static struct timespec deadline_after_seconds(unsigned int seconds)
{
    struct timespec deadline;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)seconds;
    return deadline;
}

static int wait_for_flag(channel_test_context *context, const int *flag)
{
    const struct timespec deadline = deadline_after_seconds(3u);
    int result = 1;
    (void)pthread_mutex_lock(&context->mutex);
    while (*flag == 0 && result != 0) {
        result = pthread_cond_timedwait(
            &context->condition, &context->mutex, &deadline) == 0;
    }
    (void)pthread_mutex_unlock(&context->mutex);
    return result;
}

static void initialize_config(
    mr_rdp_config *config,
    uint64_t generation)
{
    static const char hostname[] = "channels.example.test";
    static const char username[] = "phase0-user";
    static const char password[] = "phase0-password";
    mr_rdp_config_init(config);
    config->generation = generation;
    config->hostname = hostname;
    config->username = username;
    config->username_length = sizeof(username) - 1u;
    config->password = password;
    config->password_length = sizeof(password) - 1u;
}

static int record_sequence(
    channel_test_context *context,
    uint64_t generation,
    uint64_t sequence)
{
    int valid = 1;
    (void)pthread_mutex_lock(&context->mutex);
    if (generation != context->generation || sequence == 0u ||
        sequence <= context->last_sequence) {
        valid = 0;
    } else {
        context->last_sequence = sequence;
    }
    (void)pthread_mutex_unlock(&context->mutex);
    if (!valid) {
        record_failure(context, "non-monotonic telemetry identity");
    }
    return valid;
}

static void state_callback(void *opaque, const mr_rdp_state_event *event)
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->generation != context->generation) {
        record_failure(context, "invalid state event");
        return;
    }
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        (void)pthread_cond_broadcast(&context->condition);
        (void)pthread_mutex_unlock(&context->mutex);
    }
}

static void channel_callback(void *opaque, const mr_rdp_channel_event *event)
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->reserved != 0u || event->channel < MR_RDP_CHANNEL_CLIPRDR ||
        event->channel > MR_RDP_CHANNEL_RDPGFX ||
        event->transition > MR_RDP_CHANNEL_CONNECTED) {
        record_failure(context, "invalid channel event");
        return;
    }
    (void)record_sequence(context, event->generation, event->sequence);
    (void)pthread_mutex_lock(&context->mutex);
    ++context->channel_counts[event->channel][event->transition];
    (void)pthread_mutex_unlock(&context->mutex);
}

static void clipboard_probe_callback(
    void *opaque,
    const mr_rdp_clipboard_probe_event *event)
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->stage < MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT ||
        event->stage > MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT ||
        event->probe_id != 7u || event->status != MR_RDP_STATUS_OK ||
        event->payload_byte_count != context->expected_probe_length ||
        memcmp(event->payload_sha256, context->expected_probe_sha256,
               MR_RDP_SHA256_BYTES) != 0) {
        record_failure(context, "invalid clipboard probe telemetry");
        return;
    }
    (void)record_sequence(context, event->generation, event->sequence);
    (void)pthread_mutex_lock(&context->mutex);
    ++context->probe_counts[event->stage];
    if (event->stage == MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT) {
        context->probe_done = 1;
        (void)pthread_cond_broadcast(&context->condition);
    }
    (void)pthread_mutex_unlock(&context->mutex);
}

static void display_resize_callback(
    void *opaque,
    const mr_rdp_display_resize_event *event)
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->generation != context->generation || event->request_id != 9u ||
        event->width != 1920u || event->height != 1080u ||
        event->status != MR_RDP_STATUS_OK) {
        record_failure(context, "invalid display resize telemetry");
        return;
    }
    (void)record_sequence(context, event->generation, event->sequence);
    (void)pthread_mutex_lock(&context->mutex);
    ++context->resize_count;
    context->resize_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static void poison_channel_callback(
    void *opaque,
    const mr_rdp_channel_event *event)
{
    channel_test_context *context = (channel_test_context *)opaque;
    (void)event;
    (void)atomic_fetch_add_explicit(
        &context->poison_callbacks, 1, memory_order_relaxed);
}

static void clipboard_probe_observer(
    void *opaque,
    uint64_t probe_id,
    const uint8_t *bytes,
    size_t byte_count,
    const uint8_t sha256[MR_RDP_SHA256_BYTES])
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (pthread_equal(context->run_thread, pthread_self()) == 0 ||
        probe_id != 7u || bytes == NULL || bytes == context->source_probe_pointer ||
        byte_count != context->expected_probe_length ||
        memcmp(bytes, context->expected_probe, byte_count) != 0 ||
        memcmp(sha256, context->expected_probe_sha256, MR_RDP_SHA256_BYTES) != 0) {
        record_failure(context, "mock did not own the clipboard probe snapshot");
    }
}

static void display_resize_observer(
    void *opaque,
    const mr_rdp_display_resize_request *request)
{
    channel_test_context *context = (channel_test_context *)opaque;
    if (pthread_equal(context->run_thread, pthread_self()) == 0 || request == NULL ||
        request->request_id != 9u || request->width != 1920u ||
        request->height != 1080u) {
        record_failure(context, "invalid mock display request");
    }
}

static void *run_thread_main(void *opaque)
{
    channel_test_context *context = (channel_test_context *)opaque;
    context->run_thread = pthread_self();
    context->run_status = mr_rdp_session_run(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->run_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
    return NULL;
}

static int test_sha256_vectors_and_limit(void)
{
    static const uint8_t empty_digest[MR_RDP_SHA256_BYTES] = {
        0xe3u, 0xb0u, 0xc4u, 0x42u, 0x98u, 0xfcu, 0x1cu, 0x14u,
        0x9au, 0xfbu, 0xf4u, 0xc8u, 0x99u, 0x6fu, 0xb9u, 0x24u,
        0x27u, 0xaeu, 0x41u, 0xe4u, 0x64u, 0x9bu, 0x93u, 0x4cu,
        0xa4u, 0x95u, 0x99u, 0x1bu, 0x78u, 0x52u, 0xb8u, 0x55u
    };
    static const uint8_t abc_digest[MR_RDP_SHA256_BYTES] = {
        0xbau, 0x78u, 0x16u, 0xbfu, 0x8fu, 0x01u, 0xcfu, 0xeau,
        0x41u, 0x41u, 0x40u, 0xdeu, 0x5du, 0xaeu, 0x22u, 0x23u,
        0xb0u, 0x03u, 0x61u, 0xa3u, 0x96u, 0x17u, 0x7au, 0x9cu,
        0xb4u, 0x10u, 0xffu, 0x61u, 0xf2u, 0x00u, 0x15u, 0xadu
    };
    static const uint8_t probe[] = {
        0x70u, 0x00u, 0x72u, 0x00u, 0x6fu, 0x00u,
        0x62u, 0x00u, 0x65u, 0x00u, 0x00u, 0x00u
    };
    static const uint8_t probe_digest[MR_RDP_SHA256_BYTES] = {
        0xf7u, 0x68u, 0xbbu, 0x08u, 0x7fu, 0xa0u, 0x07u, 0x20u,
        0x3cu, 0xdbu, 0x97u, 0x1cu, 0xaeu, 0xd0u, 0x4cu, 0x73u,
        0x88u, 0xf1u, 0xe8u, 0x59u, 0xacu, 0xcau, 0x38u, 0x6du,
        0x51u, 0xaau, 0x67u, 0x7cu, 0x2bu, 0x0eu, 0xc5u, 0xc2u
    };
    uint8_t digest[MR_RDP_SHA256_BYTES];
    uint8_t sentinel[MR_RDP_SHA256_BYTES];
    uint8_t one = 1u;
    memset(digest, 0, sizeof(digest));
    REQUIRE(mr_rdp_sha256(NULL, 0u, digest) == MR_RDP_STATUS_OK);
    REQUIRE(memcmp(digest, empty_digest, sizeof(digest)) == 0);
    REQUIRE(mr_rdp_sha256((const uint8_t *)"abc", 3u, digest) == MR_RDP_STATUS_OK);
    REQUIRE(memcmp(digest, abc_digest, sizeof(digest)) == 0);
    REQUIRE(mr_rdp_sha256(probe, sizeof(probe), digest) == MR_RDP_STATUS_OK);
    REQUIRE(memcmp(digest, probe_digest, sizeof(digest)) == 0);
    memset(sentinel, 0xa5, sizeof(sentinel));
    REQUIRE(mr_rdp_sha256(NULL, 1u, sentinel) == MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(sentinel[0] == 0xa5u && sentinel[MR_RDP_SHA256_BYTES - 1u] == 0xa5u);
    REQUIRE(mr_rdp_sha256(
                &one, (size_t)(UINT64_MAX / 8u + 1u), sentinel) ==
            MR_RDP_ERROR_LIMIT_EXCEEDED);
    REQUIRE(sentinel[0] == 0xa5u && sentinel[MR_RDP_SHA256_BYTES - 1u] == 0xa5u);
    return 1;
}

static int test_probe_and_resize_validation(void)
{
    channel_test_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_clipboard_probe probe;
    mr_rdp_display_resize_request resize;
    static const uint8_t valid[] = { 0x41u, 0x00u, 0x00u, 0x00u };
    static const uint8_t missing_nul[] = { 0x41u, 0x00u, 0x42u, 0x00u };
    static const uint8_t embedded_nul[] = {
        0x41u, 0x00u, 0x00u, 0x00u, 0x42u, 0x00u, 0x00u, 0x00u
    };
    static const uint8_t high_only[] = { 0x00u, 0xd8u, 0x00u, 0x00u };
    static const uint8_t low_only[] = { 0x00u, 0xdcu, 0x00u, 0x00u };
    static const uint8_t surrogate_pair[] = {
        0x3du, 0xd8u, 0x00u, 0xdeu, 0x00u, 0x00u
    };

    REQUIRE(channel_test_context_init(&context));
    context.generation = 11u;
    initialize_config(&config, context.generation);
    mr_rdp_mock_script_init(&script);
    REQUIRE(mr_rdp_session_create_mock(
                &config, NULL, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);

    mr_rdp_clipboard_probe_init(&probe);
    probe.probe_id = 1u;
    probe.utf16le_bytes = valid;
    probe.utf16le_byte_count = sizeof(valid);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_STATE);
    probe.struct_size -= 1u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    mr_rdp_clipboard_probe_init(&probe);
    probe.probe_id = 1u;
    probe.utf16le_bytes = valid;
    probe.utf16le_byte_count = sizeof(valid);
    probe.reserved = 1u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.reserved = 0u;
    probe.probe_id = 0u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.probe_id = 1u;
    probe.utf16le_bytes = NULL;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.utf16le_bytes = valid;
    probe.utf16le_byte_count = 2u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.utf16le_byte_count = 3u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.utf16le_byte_count = MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES + 2u;
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    probe.utf16le_bytes = missing_nul;
    probe.utf16le_byte_count = sizeof(missing_nul);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_DATA);
    probe.utf16le_bytes = embedded_nul;
    probe.utf16le_byte_count = sizeof(embedded_nul);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_DATA);
    probe.utf16le_bytes = high_only;
    probe.utf16le_byte_count = sizeof(high_only);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_DATA);
    probe.utf16le_bytes = low_only;
    probe.utf16le_byte_count = sizeof(low_only);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_DATA);
    probe.utf16le_bytes = surrogate_pair;
    probe.utf16le_byte_count = sizeof(surrogate_pair);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_ERROR_INVALID_STATE);

    mr_rdp_display_resize_request_init(&resize);
    resize.request_id = 1u;
    resize.width = 1920u;
    resize.height = 1080u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_STATE);
    resize.struct_size -= 1u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    mr_rdp_display_resize_request_init(&resize);
    resize.request_id = 1u;
    resize.width = 1920u;
    resize.height = 1080u;
    resize.reserved = 1u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    resize.reserved = 0u;
    resize.request_id = 0u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    resize.request_id = 1u;
    resize.width = 1919u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    resize.width = MR_RDP_MIN_DESKTOP_DIMENSION - 2u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    resize.width = 1920u;
    resize.height = MR_RDP_MAX_DESKTOP_DIMENSION + 1u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);

    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    channel_test_context_destroy(&context);
    return 1;
}

static int test_channel_probe_and_resize_round_trip(void)
{
    channel_test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    uint8_t probe_bytes[] = {
        0x70u, 0x00u, 0x72u, 0x00u, 0x6fu, 0x00u,
        0x62u, 0x00u, 0x65u, 0x00u, 0x00u, 0x00u
    };
    const mr_rdp_mock_channel_transition transitions[] = {
        { MR_RDP_CHANNEL_CLIPRDR, MR_RDP_CHANNEL_CONNECTED, { 0u } },
        { MR_RDP_CHANNEL_RDPSND, MR_RDP_CHANNEL_CONNECTED, { 0u } },
        { MR_RDP_CHANNEL_DRDYNVC, MR_RDP_CHANNEL_CONNECTED, { 0u } },
        { MR_RDP_CHANNEL_DISP, MR_RDP_CHANNEL_CONNECTED, { 0u } },
        { MR_RDP_CHANNEL_RDPGFX, MR_RDP_CHANNEL_CONNECTED, { 0u } },
        { MR_RDP_CHANNEL_RDPGFX, MR_RDP_CHANNEL_DISCONNECTED, { 0u } },
        { MR_RDP_CHANNEL_DISP, MR_RDP_CHANNEL_DISCONNECTED, { 0u } },
        { MR_RDP_CHANNEL_DRDYNVC, MR_RDP_CHANNEL_DISCONNECTED, { 0u } },
        { MR_RDP_CHANNEL_RDPSND, MR_RDP_CHANNEL_DISCONNECTED, { 0u } },
        { MR_RDP_CHANNEL_CLIPRDR, MR_RDP_CHANNEL_DISCONNECTED, { 0u } }
    };
    static const uint8_t probe_digest[MR_RDP_SHA256_BYTES] = {
        0xf7u, 0x68u, 0xbbu, 0x08u, 0x7fu, 0xa0u, 0x07u, 0x20u,
        0x3cu, 0xdbu, 0x97u, 0x1cu, 0xaeu, 0xd0u, 0x4cu, 0x73u,
        0x88u, 0xf1u, 0xe8u, 0x59u, 0xacu, 0xcau, 0x38u, 0x6du,
        0x51u, 0xaau, 0x67u, 0x7cu, 0x2bu, 0x0eu, 0xc5u, 0xc2u
    };
    mr_rdp_clipboard_probe probe;
    mr_rdp_display_resize_request resize;
    size_t index;

    REQUIRE(channel_test_context_init(&context));
    context.generation = 22u;
    context.source_probe_pointer = probe_bytes;
    context.expected_probe_length = sizeof(probe_bytes);
    memcpy(context.expected_probe, probe_bytes, sizeof(probe_bytes));
    memcpy(context.expected_probe_sha256, probe_digest, sizeof(probe_digest));
    initialize_config(&config, context.generation);
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = state_callback;
    callbacks.on_channel_event = channel_callback;
    callbacks.on_clipboard_probe_event = clipboard_probe_callback;
    callbacks.on_display_resize_event = display_resize_callback;
    mr_rdp_mock_script_init(&script);
    script.observer_context = &context;
    script.channel_transitions = transitions;
    script.channel_transition_count = sizeof(transitions) / sizeof(transitions[0]);
    script.on_start_clipboard_probe = clipboard_probe_observer;
    script.on_request_display_resize = display_resize_observer;
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_flag(&context, &context.connected));

    mr_rdp_clipboard_probe_init(&probe);
    probe.probe_id = 7u;
    probe.utf16le_bytes = probe_bytes;
    probe.utf16le_byte_count = sizeof(probe_bytes);
    REQUIRE(mr_rdp_session_start_clipboard_probe(context.session, &probe) ==
            MR_RDP_STATUS_OK);
    memset(probe_bytes, 0xa5, sizeof(probe_bytes));

    mr_rdp_display_resize_request_init(&resize);
    resize.request_id = 9u;
    resize.width = 1920u;
    resize.height = 1080u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &resize) ==
            MR_RDP_STATUS_OK);
    resize.width = 200u;
    resize.height = 200u;

    REQUIRE(wait_for_flag(&context, &context.probe_done));
    REQUIRE(wait_for_flag(&context, &context.resize_done));
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for_flag(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(context.last_sequence == 15u);
    for (index = MR_RDP_CHANNEL_CLIPRDR; index <= MR_RDP_CHANNEL_RDPGFX; ++index) {
        REQUIRE(context.channel_counts[index][MR_RDP_CHANNEL_CONNECTED] == 1u);
        REQUIRE(context.channel_counts[index][MR_RDP_CHANNEL_DISCONNECTED] == 1u);
    }
    for (index = MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT;
         index <= MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT; ++index) {
        REQUIRE(context.probe_counts[index] == 1u);
    }
    REQUIRE(context.resize_count == 1u);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    channel_test_context_destroy(&context);
    return 1;
}

static int test_old_callback_prefix_is_accepted(void)
{
    channel_test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    const mr_rdp_mock_channel_transition transition = {
        MR_RDP_CHANNEL_CLIPRDR, MR_RDP_CHANNEL_CONNECTED, { 0u }
    };
    REQUIRE(channel_test_context_init(&context));
    context.generation = 33u;
    initialize_config(&config, context.generation);
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = state_callback;
    callbacks.on_channel_event = poison_channel_callback;
    callbacks.struct_size = (uint32_t)offsetof(mr_rdp_callbacks, on_channel_event);
    mr_rdp_mock_script_init(&script);
    script.channel_transitions = &transition;
    script.channel_transition_count = 1u;
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_flag(&context, &context.connected));
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for_flag(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.poison_callbacks, memory_order_relaxed) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    channel_test_context_destroy(&context);
    return 1;
}

typedef struct invalid_backend {
    mr_rdp_backend base;
} invalid_backend;

static atomic_int invalid_backend_destroyed;

static mr_rdp_status invalid_run(mr_rdp_backend *backend)
{
    (void)backend;
    return MR_RDP_STATUS_OK;
}

static void invalid_request_stop(mr_rdp_backend *backend)
{
    (void)backend;
}

static mr_rdp_status invalid_send_key(
    mr_rdp_backend *backend,
    const mr_rdp_key_event *event)
{
    (void)backend;
    (void)event;
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status invalid_send_pointer(
    mr_rdp_backend *backend,
    const mr_rdp_pointer_event *event)
{
    (void)backend;
    (void)event;
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status invalid_start_probe(
    mr_rdp_backend *backend,
    const mr_rdp_backend_clipboard_probe *probe)
{
    (void)backend;
    (void)probe;
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status invalid_request_resize(
    mr_rdp_backend *backend,
    const mr_rdp_display_resize_request *request)
{
    (void)backend;
    (void)request;
    return MR_RDP_STATUS_OK;
}

static void invalid_destroy(mr_rdp_backend *backend)
{
    (void)atomic_fetch_add_explicit(
        &invalid_backend_destroyed, 1, memory_order_relaxed);
    free(backend);
}

static mr_rdp_status invalid_factory(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend)
{
    invalid_backend *backend;
    (void)config;
    (void)host;
    backend = (invalid_backend *)calloc(1u, sizeof(*backend));
    if (backend == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    backend->base.vtable = (const mr_rdp_backend_vtable *)factory_context;
    *out_backend = &backend->base;
    return MR_RDP_STATUS_OK;
}

static int test_missing_extended_vtable_methods_are_rejected(void)
{
    static const mr_rdp_backend_vtable missing_probe = {
        .run = invalid_run,
        .request_stop = invalid_request_stop,
        .send_key = invalid_send_key,
        .send_pointer = invalid_send_pointer,
        .start_clipboard_probe = NULL,
        .request_display_resize = invalid_request_resize,
        .destroy = invalid_destroy
    };
    static const mr_rdp_backend_vtable missing_resize = {
        .run = invalid_run,
        .request_stop = invalid_request_stop,
        .send_key = invalid_send_key,
        .send_pointer = invalid_send_pointer,
        .start_clipboard_probe = invalid_start_probe,
        .request_display_resize = NULL,
        .destroy = invalid_destroy
    };
    mr_rdp_config config;
    mr_rdp_session *session = (mr_rdp_session *)(uintptr_t)1u;
    atomic_init(&invalid_backend_destroyed, 0);
    initialize_config(&config, 44u);
    REQUIRE(mr_rdp_session_create_internal(
                &config, NULL, NULL, invalid_factory, &missing_probe, &session) ==
            MR_RDP_ERROR_BACKEND);
    REQUIRE(session == NULL);
    REQUIRE(atomic_load_explicit(
                &invalid_backend_destroyed, memory_order_relaxed) == 1);
    session = (mr_rdp_session *)(uintptr_t)1u;
    REQUIRE(mr_rdp_session_create_internal(
                &config, NULL, NULL, invalid_factory, &missing_resize, &session) ==
            MR_RDP_ERROR_BACKEND);
    REQUIRE(session == NULL);
    REQUIRE(atomic_load_explicit(
                &invalid_backend_destroyed, memory_order_relaxed) == 2);
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
        { "SHA-256 vectors and limit", test_sha256_vectors_and_limit },
        { "probe and resize validation", test_probe_and_resize_validation },
        { "channel/probe/resize round trip", test_channel_probe_and_resize_round_trip },
        { "old callback prefix", test_old_callback_prefix_is_accepted },
        { "extended vtable validation", test_missing_extended_vtable_methods_are_rejected }
    };
    size_t index;
    for (index = 0u; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        const int passed = tests[index].function();
        (void)printf("%s %s\n", passed ? "PASS" : "FAIL", tests[index].name);
        if (!passed) {
            return EXIT_FAILURE;
        }
    }
    (void)printf("%zu channel contract tests passed\n",
                 sizeof(tests) / sizeof(tests[0]));
    return EXIT_SUCCESS;
}
