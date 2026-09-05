#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct test_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    uint64_t expected_generation;
    const char *expected_hostname;
    size_t expected_chain_count;
    const mr_rdp_der_blob *source_chain;
    size_t expected_chain_lengths[MR_RDP_MAX_CERTIFICATE_CHAIN];
    uint8_t expected_chain_first_bytes[MR_RDP_MAX_CERTIFICATE_CHAIN];
    uint8_t *source_der;
    uint8_t expected_der_first_byte;
    int verify_der_copy;
    int attempt_reentrant_destroy;
    int block_connected_callback;
    int release_connected_callback;
    int block_frame_callback;
    int release_frame_callback;
    int challenge_seen;
    int connected_seen;
    int frame_seen;
    int config_seen;
    int stop_seen;
    int run_done;
    int destroy_done;
    uint64_t challenge_id;
    uint64_t challenge_generation;
    mr_rdp_status run_status;
    mr_rdp_status destroy_status;
    mr_rdp_status reentrant_destroy_status;
    pthread_t run_thread;
    int run_thread_valid;
    atomic_int failures;
    atomic_int state_callbacks;
    atomic_int certificate_callbacks;
    atomic_int error_callbacks;
    atomic_int frame_callbacks;
    atomic_int poison_callbacks;
    atomic_int key_observations;
    atomic_int pointer_observations;
    mr_rdp_status last_error;
    mr_rdp_key_event observed_key;
    mr_rdp_pointer_event observed_pointer;
    const char *expected_username;
    size_t expected_username_length;
    const char *expected_domain;
    size_t expected_domain_length;
    const char *expected_password;
    size_t expected_password_length;
    const char *source_username;
    const char *source_domain;
    const char *source_password;
    uint32_t expected_desktop_width;
    uint32_t expected_desktop_height;
    const mr_rdp_desktop_frame *source_frame;
    uint8_t copied_frame_first_byte;
    mr_rdp_rect copied_dirty_rect;
} test_context;

static void record_failure(test_context *context, const char *message)
{
    (void)fprintf(stderr, "callback failure: %s\n", message);
    (void)atomic_fetch_add_explicit(&context->failures, 1, memory_order_relaxed);
}

static int test_context_init(test_context *context)
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
    atomic_init(&context->state_callbacks, 0);
    atomic_init(&context->certificate_callbacks, 0);
    atomic_init(&context->error_callbacks, 0);
    atomic_init(&context->frame_callbacks, 0);
    atomic_init(&context->poison_callbacks, 0);
    atomic_init(&context->key_observations, 0);
    atomic_init(&context->pointer_observations, 0);
    return 1;
}

static void test_context_destroy(test_context *context)
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

static int wait_for_field(test_context *context, const int *field)
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

static void original_state_callback(void *opaque, const mr_rdp_state_event *event)
{
    test_context *context = (test_context *)opaque;
    (void)atomic_fetch_add_explicit(&context->state_callbacks, 1, memory_order_relaxed);
    if (event == NULL || event->struct_size < sizeof(*event)) {
        record_failure(context, "invalid state event");
        return;
    }
    if (event->generation != context->expected_generation) {
        record_failure(context, "state generation changed");
    }
    if (context->run_thread_valid &&
        pthread_equal(context->run_thread, pthread_self()) == 0) {
        record_failure(context, "state callback was not on run thread");
    }
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected_seen = 1;
        (void)pthread_cond_broadcast(&context->condition);
        while (context->block_connected_callback &&
               !context->release_connected_callback) {
            (void)pthread_cond_wait(&context->condition, &context->mutex);
        }
        (void)pthread_mutex_unlock(&context->mutex);
    }
}

static void original_certificate_callback(
    void *opaque,
    const mr_rdp_certificate_challenge *challenge)
{
    test_context *context = (test_context *)opaque;
    (void)atomic_fetch_add_explicit(
        &context->certificate_callbacks, 1, memory_order_relaxed);
    if (challenge == NULL || challenge->struct_size < sizeof(*challenge)) {
        record_failure(context, "invalid certificate event");
        return;
    }
    if (context->run_thread_valid &&
        pthread_equal(context->run_thread, pthread_self()) == 0) {
        record_failure(context, "certificate callback was not on run thread");
    }
    if (challenge->generation != context->expected_generation ||
        challenge->challenge_id == 0u) {
        record_failure(context, "invalid challenge identity");
    }
    if (context->expected_hostname != NULL &&
        (challenge->hostname_length != strlen(context->expected_hostname) ||
         memcmp(challenge->hostname, context->expected_hostname,
                challenge->hostname_length) != 0)) {
        record_failure(context, "hostname was not copied at create");
    }
    if (challenge->chain_count != context->expected_chain_count) {
        record_failure(context, "certificate chain count changed");
    }
    if (context->verify_der_copy && challenge->chain_count > 0u) {
        size_t index;
        if (challenge->chain == context->source_chain) {
            record_failure(context, "backend chain array escaped bridge");
        }
        for (index = 0u; index < challenge->chain_count; ++index) {
            if (challenge->chain[index].bytes == context->source_chain[index].bytes) {
                record_failure(context, "backend DER pointer escaped bridge");
            }
            if (challenge->chain[index].length != context->expected_chain_lengths[index] ||
                challenge->chain[index].bytes[0] !=
                    context->expected_chain_first_bytes[index]) {
                record_failure(context, "DER blob length or contents changed");
            }
        }
        context->source_der[0] ^= 0xffu;
        if (challenge->chain[0].bytes[0] != context->expected_der_first_byte) {
            record_failure(context, "DER snapshot aliases backend memory");
        }
    }
    if (context->attempt_reentrant_destroy) {
        context->reentrant_destroy_status = mr_rdp_session_destroy(context->session);
    }
    (void)pthread_mutex_lock(&context->mutex);
    context->challenge_id = challenge->challenge_id;
    context->challenge_generation = challenge->generation;
    context->challenge_seen = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static void original_error_callback(void *opaque, const mr_rdp_error_event *event)
{
    test_context *context = (test_context *)opaque;
    (void)atomic_fetch_add_explicit(&context->error_callbacks, 1, memory_order_relaxed);
    if (event == NULL || event->struct_size < sizeof(*event)) {
        record_failure(context, "invalid error event");
        return;
    }
    context->last_error = event->status;
}

static void original_frame_callback(
    void *opaque,
    const mr_rdp_desktop_frame *frame)
{
    test_context *context = (test_context *)opaque;
    (void)atomic_fetch_add_explicit(&context->frame_callbacks, 1, memory_order_relaxed);
    if (frame == NULL || frame->struct_size < sizeof(*frame)) {
        record_failure(context, "invalid frame event");
        return;
    }
    if (context->run_thread_valid &&
        pthread_equal(context->run_thread, pthread_self()) == 0) {
        record_failure(context, "frame callback was not on run thread");
    }
    if (frame == context->source_frame) {
        record_failure(context, "backend frame descriptor escaped bridge");
    }
    if (frame->generation != context->expected_generation ||
        frame->surface_generation == 0u || frame->frame_id == 0u ||
        frame->bytes == NULL || frame->length == 0u ||
        frame->dirty_rects == NULL || frame->dirty_rect_count == 0u) {
        record_failure(context, "invalid forwarded frame fields");
    } else {
        context->copied_frame_first_byte = frame->bytes[0];
        context->copied_dirty_rect = frame->dirty_rects[0];
    }
    if (context->attempt_reentrant_destroy) {
        context->reentrant_destroy_status = mr_rdp_session_destroy(context->session);
    }
    (void)pthread_mutex_lock(&context->mutex);
    context->frame_seen = 1;
    (void)pthread_cond_broadcast(&context->condition);
    while (context->block_frame_callback && !context->release_frame_callback) {
        (void)pthread_cond_wait(&context->condition, &context->mutex);
    }
    (void)pthread_mutex_unlock(&context->mutex);
}

static void mock_config_observer(
    void *opaque,
    const char *username,
    size_t username_length,
    const char *domain,
    size_t domain_length,
    const char *password,
    size_t password_length,
    uint32_t desktop_width,
    uint32_t desktop_height)
{
    test_context *context = (test_context *)opaque;
    if (context->run_thread_valid &&
        pthread_equal(context->run_thread, pthread_self()) == 0) {
        record_failure(context, "config observer was not on run thread");
    }
    if (username == context->source_username || password == context->source_password ||
        (domain != NULL && domain == context->source_domain)) {
        record_failure(context, "credential input was not deep-copied");
    }
    if (username == NULL || username_length != context->expected_username_length ||
        memcmp(username, context->expected_username, username_length) != 0 ||
        username[username_length] != '\0') {
        record_failure(context, "copied username changed");
    }
    if (password == NULL || password_length != context->expected_password_length ||
        memcmp(password, context->expected_password, password_length) != 0 ||
        password[password_length] != '\0') {
        record_failure(context, "copied password changed");
    }
    if (context->expected_domain == NULL) {
        if (domain != NULL || domain_length != 0u) {
            record_failure(context, "absent domain changed");
        }
    } else if (domain == NULL || domain_length != context->expected_domain_length ||
               memcmp(domain, context->expected_domain, domain_length) != 0 ||
               domain[domain_length] != '\0') {
        record_failure(context, "copied domain changed");
    }
    if (desktop_width != context->expected_desktop_width ||
        desktop_height != context->expected_desktop_height) {
        record_failure(context, "desktop dimensions changed");
    }
    (void)pthread_mutex_lock(&context->mutex);
    context->config_seen = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static void poison_state_callback(void *opaque, const mr_rdp_state_event *event)
{
    test_context *context = (test_context *)opaque;
    (void)event;
    (void)atomic_fetch_add_explicit(&context->poison_callbacks, 1, memory_order_relaxed);
}

static void poison_certificate_callback(
    void *opaque,
    const mr_rdp_certificate_challenge *challenge)
{
    test_context *context = (test_context *)opaque;
    (void)challenge;
    (void)atomic_fetch_add_explicit(&context->poison_callbacks, 1, memory_order_relaxed);
}

static void poison_error_callback(void *opaque, const mr_rdp_error_event *event)
{
    test_context *context = (test_context *)opaque;
    (void)event;
    (void)atomic_fetch_add_explicit(&context->poison_callbacks, 1, memory_order_relaxed);
}

static void poison_frame_callback(
    void *opaque,
    const mr_rdp_desktop_frame *frame)
{
    test_context *context = (test_context *)opaque;
    (void)frame;
    (void)atomic_fetch_add_explicit(&context->poison_callbacks, 1, memory_order_relaxed);
}

static void mock_stop_observer(void *opaque)
{
    test_context *context = (test_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->stop_seen;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static void mock_key_observer(void *opaque, const mr_rdp_key_event *event)
{
    test_context *context = (test_context *)opaque;
    context->observed_key = *event;
    (void)atomic_fetch_add_explicit(&context->key_observations, 1, memory_order_relaxed);
}

static void mock_pointer_observer(void *opaque, const mr_rdp_pointer_event *event)
{
    test_context *context = (test_context *)opaque;
    context->observed_pointer = *event;
    (void)atomic_fetch_add_explicit(
        &context->pointer_observations, 1, memory_order_relaxed);
}

static void *run_thread_main(void *opaque)
{
    test_context *context = (test_context *)opaque;
    context->run_thread = pthread_self();
    context->run_thread_valid = 1;
    context->run_status = mr_rdp_session_run(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->run_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
    return NULL;
}

static void *destroy_thread_main(void *opaque)
{
    test_context *context = (test_context *)opaque;
    context->destroy_status = mr_rdp_session_destroy(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->destroy_done = 1;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
    return NULL;
}

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void initialize_callbacks(mr_rdp_callbacks *callbacks)
{
    mr_rdp_callbacks_init(callbacks);
    callbacks->on_state_changed = original_state_callback;
    callbacks->on_certificate_challenge = original_certificate_callback;
    callbacks->on_error = original_error_callback;
    callbacks->on_desktop_frame = original_frame_callback;
}

static void initialize_config(mr_rdp_config *config, const char *hostname)
{
    static const char username[] = "phase0-user";
    static const char password[] = "phase0-password";
    mr_rdp_config_init(config);
    config->generation = 1u;
    config->hostname = hostname;
    config->username = username;
    config->username_length = sizeof(username) - 1u;
    config->password = password;
    config->password_length = sizeof(password) - 1u;
}

static void initialize_mock_script(
    mr_rdp_mock_script *script,
    test_context *context,
    const mr_rdp_der_blob *chain,
    size_t chain_count)
{
    mr_rdp_mock_script_init(script);
    script->certificate_chain = chain;
    script->certificate_chain_count = chain_count;
    script->observer_context = context;
    script->on_request_stop = mock_stop_observer;
    script->on_send_key = mock_key_observer;
    script->on_send_pointer = mock_pointer_observer;
}

static int test_default_backend_is_explicitly_unavailable(void)
{
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_session *session = (mr_rdp_session *)(uintptr_t)1u;
    initialize_config(&config, "rdp.example.test");
    mr_rdp_callbacks_init(&callbacks);
    callbacks.struct_size = (uint32_t)offsetof(mr_rdp_callbacks, on_state_changed) + 1u;
    REQUIRE(mr_rdp_session_create(&config, &callbacks, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(session == NULL);
    mr_rdp_callbacks_init(&callbacks);
    REQUIRE(mr_rdp_session_create(&config, &callbacks, NULL, &session) ==
            MR_RDP_ERROR_BACKEND_UNAVAILABLE);
    REQUIRE(session == NULL);
    REQUIRE(strcmp(mr_rdp_status_name(MR_RDP_ERROR_STALE_CHALLENGE),
                   "stale_challenge") == 0);
    return 1;
}

static int test_config_span_and_dimension_validation(void)
{
    mr_rdp_config config;
    mr_rdp_session *session = (mr_rdp_session *)(uintptr_t)1u;
    const char embedded_nul[] = { 'a', '\0', 'b' };

    initialize_config(&config, "validation.example.test");
    REQUIRE(config.desktop_width == MR_RDP_DEFAULT_DESKTOP_WIDTH);
    REQUIRE(config.desktop_height == MR_RDP_DEFAULT_DESKTOP_HEIGHT);

    config.generation = 0u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(session == NULL);

    initialize_config(&config, "validation.example.test");
    config.struct_size = (uint32_t)sizeof(config) - 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(session == NULL);

    initialize_config(&config, "validation.example.test");
    config.username = NULL;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.username_length = 0u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.username = embedded_nul;
    config.username_length = sizeof(embedded_nul);
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.username_length = MR_RDP_MAX_USERNAME_BYTES + 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);

    initialize_config(&config, "validation.example.test");
    config.domain = "domain";
    config.domain_length = 0u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.domain = NULL;
    config.domain_length = 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.domain = embedded_nul;
    config.domain_length = sizeof(embedded_nul);
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.domain = "domain";
    config.domain_length = MR_RDP_MAX_DOMAIN_BYTES + 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);

    initialize_config(&config, "validation.example.test");
    config.password = NULL;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.password_length = 0u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.password = embedded_nul;
    config.password_length = sizeof(embedded_nul);
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.password_length = MR_RDP_MAX_PASSWORD_BYTES + 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);

    initialize_config(&config, "validation.example.test");
    config.desktop_width = MR_RDP_MIN_DESKTOP_DIMENSION - 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.desktop_width = MR_RDP_MAX_DESKTOP_DIMENSION + 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.desktop_height = MR_RDP_MIN_DESKTOP_DIMENSION - 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    initialize_config(&config, "validation.example.test");
    config.desktop_height = MR_RDP_MAX_DESKTOP_DIMENSION + 1u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    return 1;
}

static int test_credentials_are_deep_copied(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    char username[] = { 'a', 'l', 'i', 'c', 'e' };
    char domain[] = { 'L', 'A', 'B' };
    char password[] = { 's', '3', 'c', 'r', 'e', 't' };

    REQUIRE(test_context_init(&context));
    context.expected_generation = 31u;
    context.expected_hostname = "credentials.example.test";
    context.expected_username = "alice";
    context.expected_username_length = 5u;
    context.expected_domain = "LAB";
    context.expected_domain_length = 3u;
    context.expected_password = "s3cret";
    context.expected_password_length = 6u;
    context.source_username = username;
    context.source_domain = domain;
    context.source_password = password;
    context.expected_desktop_width = 3840u;
    context.expected_desktop_height = 2160u;

    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    config.username = username;
    config.username_length = sizeof(username);
    config.domain = domain;
    config.domain_length = sizeof(domain);
    config.password = password;
    config.password_length = sizeof(password);
    config.desktop_width = context.expected_desktop_width;
    config.desktop_height = context.expected_desktop_height;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, NULL, 0u);
    script.on_config = mock_config_observer;
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);

    memset(username, 'x', sizeof(username));
    memset(domain, 'x', sizeof(domain));
    memset(password, 'x', sizeof(password));
    config.username = NULL;
    config.domain = NULL;
    config.password = NULL;
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.config_seen));
    REQUIRE(wait_for_field(&context, &context.connected_seen));
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for_field(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_certificate_copy_identity_input_and_idempotent_stop(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    uint8_t leaf[] = { 0x30u, 0x03u, 0x02u, 0x01u, 0x01u };
    const uint8_t issuer[] = { 0x30u, 0x01u, 0x00u };
    mr_rdp_der_blob chain[] = {
        { leaf, sizeof(leaf) },
        { issuer, sizeof(issuer) }
    };
    char hostname[] = "rdp.example.test";
    mr_rdp_key_event key;
    mr_rdp_pointer_event pointer;

    REQUIRE(test_context_init(&context));
    context.expected_generation = 77u;
    context.expected_hostname = "rdp.example.test";
    context.expected_chain_count = 2u;
    context.source_chain = chain;
    context.expected_chain_lengths[0] = sizeof(leaf);
    context.expected_chain_lengths[1] = sizeof(issuer);
    context.expected_chain_first_bytes[0] = leaf[0];
    context.expected_chain_first_bytes[1] = issuer[0];
    context.source_der = leaf;
    context.expected_der_first_byte = leaf[0];
    context.verify_der_copy = 1;
    context.attempt_reentrant_destroy = 1;
    context.reentrant_destroy_status = MR_RDP_STATUS_OK;

    initialize_config(&config, hostname);
    config.generation = context.expected_generation;
    config.certificate_timeout_ms = 2000u;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, chain, 2u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);

    hostname[0] = 'X';
    callbacks.on_state_changed = poison_state_callback;
    callbacks.on_certificate_challenge = poison_certificate_callback;
    callbacks.on_error = poison_error_callback;
    callbacks.on_desktop_frame = poison_frame_callback;

    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.challenge_seen));
    REQUIRE(context.reentrant_destroy_status == MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdp_session_respond_certificate(
                context.session,
                context.challenge_generation + 1u,
                context.challenge_id,
                MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST) ==
            MR_RDP_ERROR_STALE_CHALLENGE);
    REQUIRE(mr_rdp_session_respond_certificate(
                context.session,
                context.challenge_generation,
                context.challenge_id + 1u,
                MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST) ==
            MR_RDP_ERROR_STALE_CHALLENGE);
    REQUIRE(mr_rdp_session_respond_certificate(
                context.session,
                context.challenge_generation,
                context.challenge_id,
                MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_respond_certificate(
                context.session,
                context.challenge_generation,
                context.challenge_id,
                MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST) ==
            MR_RDP_ERROR_STALE_CHALLENGE);
    REQUIRE(wait_for_field(&context, &context.connected_seen));

    mr_rdp_key_event_init(&key);
    key.code = 0x7bu;
    key.action = MR_RDP_KEY_DOWN;
    REQUIRE(mr_rdp_session_send_key(context.session, &key) == MR_RDP_STATUS_OK);
    key.code = 0u;
    REQUIRE(mr_rdp_session_send_key(context.session, &key) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    key.code = 0x7bu;
    key.reserved[1] = 1u;
    REQUIRE(mr_rdp_session_send_key(context.session, &key) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    key.reserved[1] = 0u;
    REQUIRE(atomic_load_explicit(&context.key_observations, memory_order_relaxed) == 1);
    REQUIRE(context.observed_key.code == 0x7bu);

    mr_rdp_pointer_event_init(&pointer);
    pointer.kind = MR_RDP_POINTER_BUTTON;
    pointer.button = MR_RDP_POINTER_BUTTON_RIGHT;
    pointer.action = MR_RDP_KEY_DOWN;
    pointer.x = 100u;
    pointer.y = 200u;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) == MR_RDP_STATUS_OK);
    pointer.button = MR_RDP_POINTER_BUTTON_NONE;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    mr_rdp_pointer_event_init(&pointer);
    pointer.kind = MR_RDP_POINTER_MOVE;
    pointer.action = MR_RDP_KEY_UP;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    pointer.action = MR_RDP_KEY_DOWN;
    pointer.reserved = 1u;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    mr_rdp_pointer_event_init(&pointer);
    pointer.kind = MR_RDP_POINTER_WHEEL;
    pointer.wheel_y = 120;
    pointer.action = MR_RDP_KEY_UP;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(atomic_load_explicit(&context.pointer_observations, memory_order_relaxed) == 1);
    REQUIRE(context.observed_pointer.button == MR_RDP_POINTER_BUTTON_RIGHT);
    pointer.action = MR_RDP_KEY_DOWN;
    pointer.wheel_y = MR_RDP_MAX_WHEEL_DELTA;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.pointer_observations, memory_order_relaxed) == 2);
    pointer.wheel_y = MR_RDP_MAX_WHEEL_DELTA + 1;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    pointer.wheel_y = -MR_RDP_MAX_WHEEL_DELTA - 1;
    REQUIRE(mr_rdp_session_send_pointer(context.session, &pointer) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(atomic_load_explicit(&context.pointer_observations, memory_order_relaxed) == 2);

    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for_field(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(context.stop_seen == 1);
    REQUIRE(mr_rdp_session_respond_certificate(
                context.session,
                context.challenge_generation,
                context.challenge_id,
                MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST) ==
            MR_RDP_ERROR_STALE_CHALLENGE);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    REQUIRE(atomic_load_explicit(&context.certificate_callbacks, memory_order_relaxed) == 1);
    REQUIRE(atomic_load_explicit(&context.poison_callbacks, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_explicit_challenge_cancel_wakes_wait(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    const uint8_t leaf[] = { 0x30u, 0x01u, 0x00u };
    const mr_rdp_der_blob chain[] = { { leaf, sizeof(leaf) } };

    REQUIRE(test_context_init(&context));
    context.expected_generation = 9u;
    context.expected_hostname = "cancel.example.test";
    context.expected_chain_count = 1u;
    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    config.certificate_timeout_ms = 10000u;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, chain, 1u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.challenge_seen));
    REQUIRE(mr_rdp_session_cancel_challenge(
                context.session, context.challenge_generation, context.challenge_id) ==
            MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_cancel_challenge(
                context.session, context.challenge_generation, context.challenge_id) ==
            MR_RDP_ERROR_STALE_CHALLENGE);
    REQUIRE(wait_for_field(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_ERROR_CERTIFICATE_REJECTED);
    REQUIRE(context.last_error == MR_RDP_ERROR_CERTIFICATE_REJECTED);
    REQUIRE(atomic_load_explicit(&context.error_callbacks, memory_order_relaxed) == 1);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(context.stop_seen == 1);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_stop_wakes_certificate_wait(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    const uint8_t leaf[] = { 0x30u, 0x01u, 0x00u };
    const mr_rdp_der_blob chain[] = { { leaf, sizeof(leaf) } };

    REQUIRE(test_context_init(&context));
    context.expected_generation = 10u;
    context.expected_hostname = "stop.example.test";
    context.expected_chain_count = 1u;
    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    config.certificate_timeout_ms = 10000u;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, chain, 1u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.challenge_seen));
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for_field(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(context.stop_seen == 1);
    REQUIRE(atomic_load_explicit(&context.error_callbacks, memory_order_relaxed) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_certificate_timeout_and_der_limits(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t thread;
    const uint8_t leaf[] = { 0x30u, 0x01u, 0x00u };
    mr_rdp_der_blob chain[] = { { leaf, sizeof(leaf) } };

    REQUIRE(test_context_init(&context));
    context.expected_generation = 11u;
    context.expected_hostname = "timeout.example.test";
    context.expected_chain_count = 1u;
    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    config.certificate_timeout_ms = 25u;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, chain, 1u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.run_done));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_ERROR_TIMEOUT);
    REQUIRE(context.last_error == MR_RDP_ERROR_TIMEOUT);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);

    REQUIRE(test_context_init(&context));
    context.expected_generation = 12u;
    context.expected_hostname = "limit.example.test";
    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    initialize_callbacks(&callbacks);
    chain[0].length = MR_RDP_MAX_CERTIFICATE_DER_BYTES + 1u;
    initialize_mock_script(&script, &context, chain, 1u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    context.run_thread = pthread_self();
    context.run_thread_valid = 1;
    REQUIRE(mr_rdp_session_run(context.session) == MR_RDP_ERROR_LIMIT_EXCEEDED);
    REQUIRE(context.last_error == MR_RDP_ERROR_LIMIT_EXCEEDED);
    REQUIRE(atomic_load_explicit(&context.certificate_callbacks, memory_order_relaxed) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int run_invalid_frame_case(
    const mr_rdp_desktop_frame *frame,
    uint64_t config_generation,
    mr_rdp_status expected_status)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;

    REQUIRE(test_context_init(&context));
    context.expected_generation = config_generation;
    context.expected_hostname = "frame-invalid.example.test";
    initialize_config(&config, context.expected_hostname);
    config.generation = config_generation;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, NULL, 0u);
    script.desktop_frame = frame;
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    context.run_thread = pthread_self();
    context.run_thread_valid = 1;
    REQUIRE(mr_rdp_session_run(context.session) == expected_status);
    REQUIRE(context.last_error == expected_status);
    REQUIRE(atomic_load_explicit(&context.frame_callbacks, memory_order_relaxed) == 0);
    REQUIRE(atomic_load_explicit(&context.error_callbacks, memory_order_relaxed) == 1);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_frame_validation_rejects_invalid_views(void)
{
    uint8_t pixels[64] = { 0u };
    mr_rdp_rect rect = { 0u, 0u, 4u, 4u };
    mr_rdp_desktop_frame base;
    mr_rdp_desktop_frame frame;

    memset(&base, 0, sizeof(base));
    base.struct_size = (uint32_t)sizeof(base);
    base.generation = 42u;
    base.surface_generation = 1u;
    base.frame_id = 1u;
    base.width = 4u;
    base.height = 4u;
    base.stride = 16u;
    base.bytes = pixels;
    base.length = sizeof(pixels);
    base.dirty_rects = &rect;
    base.dirty_rect_count = 1u;

    frame = base;
    frame.struct_size = (uint32_t)sizeof(frame) - 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.reserved = 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.reserved2 = 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.generation = 43u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.surface_generation = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.frame_id = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.width = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.height = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.width = MR_RDP_MAX_DESKTOP_DIMENSION + 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.bytes = NULL;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.stride = 15u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.length = sizeof(pixels) - 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.length = (size_t)MR_RDP_MAX_DESKTOP_FRAME_BYTES + 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_LIMIT_EXCEEDED));
    frame = base;
    frame.stride = UINT32_MAX;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_LIMIT_EXCEEDED));
    frame = base;
    frame.dirty_rects = NULL;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.dirty_rect_count = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    frame.dirty_rect_count = MR_RDP_MAX_DESKTOP_DIRTY_RECTS + 1u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    rect.width = 0u;
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    rect = (mr_rdp_rect){ 4u, 0u, 1u, 1u };
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    rect = (mr_rdp_rect){ 3u, 0u, 2u, 1u };
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    rect = (mr_rdp_rect){ 0u, 4u, 1u, 1u };
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    frame = base;
    rect = (mr_rdp_rect){ 0u, 3u, 1u, 2u };
    REQUIRE(run_invalid_frame_case(&frame, 42u, MR_RDP_ERROR_INVALID_DATA));
    return 1;
}

static int test_frame_callback_view_and_destroy_drain(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t run_thread;
    pthread_t destroy_thread;
    uint8_t pixels[48] = { 0x44u };
    mr_rdp_rect rects[] = {
        { 0u, 0u, 4u, 3u },
        { 1u, 1u, 2u, 1u }
    };
    mr_rdp_desktop_frame frame;

    REQUIRE(test_context_init(&context));
    context.expected_generation = 52u;
    context.expected_hostname = "frame.example.test";
    context.block_frame_callback = 1;
    context.attempt_reentrant_destroy = 1;
    context.reentrant_destroy_status = MR_RDP_STATUS_OK;
    memset(&frame, 0, sizeof(frame));
    frame.struct_size = (uint32_t)sizeof(frame);
    frame.generation = context.expected_generation;
    frame.surface_generation = 3u;
    frame.frame_id = 9u;
    frame.width = 4u;
    frame.height = 3u;
    frame.stride = 16u;
    frame.bytes = pixels;
    frame.length = sizeof(pixels);
    frame.dirty_rects = rects;
    frame.dirty_rect_count = sizeof(rects) / sizeof(rects[0]);
    context.source_frame = &frame;

    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, NULL, 0u);
    script.desktop_frame = &frame;
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    callbacks.on_desktop_frame = poison_frame_callback;

    REQUIRE(pthread_create(&run_thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.frame_seen));
    REQUIRE(context.reentrant_destroy_status == MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(pthread_create(&destroy_thread, NULL, destroy_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.stop_seen));
    REQUIRE(context.destroy_done == 0);

    (void)pthread_mutex_lock(&context.mutex);
    context.release_frame_callback = 1;
    (void)pthread_cond_broadcast(&context.condition);
    (void)pthread_mutex_unlock(&context.mutex);
    REQUIRE(wait_for_field(&context, &context.destroy_done));
    REQUIRE(pthread_join(run_thread, NULL) == 0);
    REQUIRE(pthread_join(destroy_thread, NULL) == 0);

    pixels[0] = 0u;
    rects[0] = (mr_rdp_rect){ 0u, 0u, 1u, 1u };
    REQUIRE(context.copied_frame_first_byte == 0x44u);
    REQUIRE(context.copied_dirty_rect.width == 4u);
    REQUIRE(context.copied_dirty_rect.height == 3u);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(context.destroy_status == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load_explicit(&context.frame_callbacks, memory_order_relaxed) == 1);
    REQUIRE(atomic_load_explicit(&context.poison_callbacks, memory_order_relaxed) == 0);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_destroy_waits_for_callback_drain(void)
{
    test_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    pthread_t run_thread;
    pthread_t destroy_thread;

    REQUIRE(test_context_init(&context));
    context.expected_generation = 13u;
    context.expected_hostname = "destroy.example.test";
    context.block_connected_callback = 1;
    initialize_config(&config, context.expected_hostname);
    config.generation = context.expected_generation;
    initialize_callbacks(&callbacks);
    initialize_mock_script(&script, &context, NULL, 0u);
    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&run_thread, NULL, run_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.connected_seen));
    REQUIRE(pthread_create(&destroy_thread, NULL, destroy_thread_main, &context) == 0);
    REQUIRE(wait_for_field(&context, &context.stop_seen));
    REQUIRE(context.destroy_done == 0);

    (void)pthread_mutex_lock(&context.mutex);
    context.release_connected_callback = 1;
    (void)pthread_cond_broadcast(&context.condition);
    (void)pthread_mutex_unlock(&context.mutex);
    REQUIRE(wait_for_field(&context, &context.destroy_done));
    REQUIRE(pthread_join(run_thread, NULL) == 0);
    REQUIRE(pthread_join(destroy_thread, NULL) == 0);
    REQUIRE(context.run_status == MR_RDP_STATUS_OK);
    REQUIRE(context.destroy_status == MR_RDP_STATUS_OK);
    REQUIRE(context.stop_seen == 1);
    REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
    test_context_destroy(&context);
    return 1;
}

static int test_pre_run_stop_stress(void)
{
    unsigned int iteration;
    for (iteration = 0u; iteration < 100u; ++iteration) {
        test_context context;
        mr_rdp_config config;
        mr_rdp_mock_script script;
        REQUIRE(test_context_init(&context));
        context.expected_generation = iteration + 100u;
        initialize_config(&config, "stress.example.test");
        config.generation = context.expected_generation;
        initialize_mock_script(&script, &context, NULL, 0u);
        REQUIRE(mr_rdp_session_create_mock(
                    &config, NULL, &context, &script, &context.session) ==
                MR_RDP_STATUS_OK);
        REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
        REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
        REQUIRE(mr_rdp_session_run(context.session) == MR_RDP_STATUS_OK);
        REQUIRE(context.stop_seen == 1);
        REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
        REQUIRE(context.stop_seen == 1);
        test_context_destroy(&context);
    }
    return 1;
}

/* Hammers the API surface from a second thread while a session is running and
 * being stopped. The single-shot drain tests above prove the ordering once;
 * this is the shape a sanitizer needs to find the races they cannot: a stop
 * that lands between a challenge wait and its wake, a send that arrives as run
 * is returning, and a response bound to a challenge that no longer exists.
 *
 * Every call here may legitimately fail - the session may already be stopping
 * - so the assertions are on what must never happen: a crash, a data race, or
 * a callback that observed something inconsistent. Destroy is only called
 * after both threads join, which is the same external gate the Swift
 * `RDPNativeCallGate` provides. */
static void *stress_caller_thread_main(void *opaque)
{
    test_context *context = (test_context *)opaque;
    unsigned int index;
    for (index = 0u; index < 64u; ++index) {
        mr_rdp_key_event key;
        mr_rdp_pointer_event pointer;

        mr_rdp_key_event_init(&key);
        key.code = 0x7bu;
        key.action = (index & 1u) ? MR_RDP_KEY_UP : MR_RDP_KEY_DOWN;
        (void)mr_rdp_session_send_key(context->session, &key);

        mr_rdp_pointer_event_init(&pointer);
        pointer.kind = MR_RDP_POINTER_MOVE;
        pointer.x = index;
        pointer.y = index;
        (void)mr_rdp_session_send_pointer(context->session, &pointer);

        /* A stale challenge identity: it must be refused rather than applied
         * to whatever challenge happens to be open. */
        (void)mr_rdp_session_respond_certificate(
            context->session,
            context->expected_generation,
            (uint64_t)index + 1u,
            MR_RDP_CERTIFICATE_ACCEPT_USER_ONCE);
        (void)mr_rdp_session_cancel_challenge(
            context->session,
            context->expected_generation,
            (uint64_t)index + 1u);
        (void)mr_rdp_session_request_stop(context->session);
    }
    return NULL;
}

static int test_concurrent_stop_and_call_stress(void)
{
    unsigned int iteration;
    uint8_t leaf[] = { 0x30u, 0x03u, 0x02u, 0x01u, 0x01u };
    const mr_rdp_der_blob chain[] = { { leaf, sizeof(leaf) } };

    for (iteration = 0u; iteration < 25u; ++iteration) {
        test_context context;
        mr_rdp_config config;
        mr_rdp_callbacks callbacks;
        mr_rdp_mock_script script;
        pthread_t run_thread;
        pthread_t caller_thread;

        REQUIRE(test_context_init(&context));
        context.expected_generation = iteration + 500u;
        context.expected_hostname = "stress.example.test";
        context.expected_chain_count = 1u;
        context.expected_chain_lengths[0] = sizeof(leaf);
        context.expected_chain_first_bytes[0] = leaf[0];

        initialize_config(&config, context.expected_hostname);
        config.generation = context.expected_generation;
        config.certificate_timeout_ms = 1000u;
        initialize_callbacks(&callbacks);
        initialize_mock_script(&script, &context, chain, 1u);
        REQUIRE(mr_rdp_session_create_mock(
                    &config, &callbacks, &context, &script, &context.session) ==
                MR_RDP_STATUS_OK);

        REQUIRE(pthread_create(&run_thread, NULL, run_thread_main, &context) == 0);
        REQUIRE(pthread_create(
                    &caller_thread, NULL, stress_caller_thread_main, &context) == 0);
        REQUIRE(pthread_join(caller_thread, NULL) == 0);
        REQUIRE(pthread_join(run_thread, NULL) == 0);
        REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
        REQUIRE(atomic_load_explicit(&context.failures, memory_order_relaxed) == 0);
        test_context_destroy(&context);
    }
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
        { "default backend unavailable", test_default_backend_is_explicitly_unavailable },
        { "config spans and dimensions", test_config_span_and_dimension_validation },
        { "credential deep copy", test_credentials_are_deep_copied },
        { "certificate copy, identity, input, stop", test_certificate_copy_identity_input_and_idempotent_stop },
        { "explicit challenge cancel", test_explicit_challenge_cancel_wakes_wait },
        { "stop wakes challenge", test_stop_wakes_certificate_wait },
        { "certificate timeout and DER limits", test_certificate_timeout_and_der_limits },
        { "frame validation", test_frame_validation_rejects_invalid_views },
        { "frame callback view and destroy drain", test_frame_callback_view_and_destroy_drain },
        { "destroy drains callback", test_destroy_waits_for_callback_drain },
        { "pre-run stop stress", test_pre_run_stop_stress },
        { "concurrent stop and call stress", test_concurrent_stop_and_call_stress }
    };
    size_t index;
    int passed = 0;
    for (index = 0u; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        const int result = tests[index].function();
        (void)printf("%s %s\n", result ? "PASS" : "FAIL", tests[index].name);
        if (!result) {
            return EXIT_FAILURE;
        }
        ++passed;
    }
    (void)printf("%d contract tests passed\n", passed);
    return EXIT_SUCCESS;
}
