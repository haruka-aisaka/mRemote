#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 3 surface: desktop and device scale factors in the config and in
 * display resize requests. Run against the mock backend, so what is tested
 * is the bridge's validation and what reaches a backend, not FreeRDP. */

typedef struct abi3_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    int connected;
    int run_done;
    int scale_seen;
    uint32_t desktop_scale;
    uint32_t device_scale;
    int resize_seen;
    mr_rdp_display_resize_request resize;
} abi3_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void signal_locked(abi3_context *context)
{
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for(abi3_context *context, const int *flag, int value)
{
    struct timespec deadline;
    int ok = 1;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 3;
    (void)pthread_mutex_lock(&context->mutex);
    while (*flag < value && ok) {
        ok = pthread_cond_timedwait(&context->condition, &context->mutex, &deadline) == 0;
    }
    (void)pthread_mutex_unlock(&context->mutex);
    return ok;
}

static void on_state(void *opaque, const mr_rdp_state_event *event)
{
    abi3_context *context = (abi3_context *)opaque;
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        signal_locked(context);
    }
}

static void observe_scale(void *opaque, uint32_t desktop, uint32_t device)
{
    abi3_context *context = (abi3_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->scale_seen;
    context->desktop_scale = desktop;
    context->device_scale = device;
    signal_locked(context);
}

static void observe_resize(void *opaque, const mr_rdp_display_resize_request *request)
{
    abi3_context *context = (abi3_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->resize_seen;
    context->resize = *request;
    signal_locked(context);
}

static void *run_thread(void *opaque)
{
    abi3_context *context = (abi3_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->run_done = 1;
    signal_locked(context);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi3.example.test";
    static const char username[] = "user";
    static const char password[] = "password";
    mr_rdp_config_init(config);
    config->generation = generation;
    config->hostname = hostname;
    config->username = username;
    config->username_length = sizeof(username) - 1u;
    config->password = password;
    config->password_length = sizeof(password) - 1u;
}

static int rejected(mr_rdp_config *config)
{
    mr_rdp_session *session = NULL;
    return mr_rdp_session_create_mock(config, NULL, NULL, NULL, &session) ==
               MR_RDP_ERROR_INVALID_ARGUMENT &&
           session == NULL;
}

static int test_config_scale_defaults_and_validation(void)
{
    mr_rdp_config config;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == 3u);
    REQUIRE(config.desktop_scale_factor == 100u);
    REQUIRE(config.device_scale_factor == 100u);

    config.desktop_scale_factor = 99u;
    REQUIRE(rejected(&config));
    config.desktop_scale_factor = 501u;
    REQUIRE(rejected(&config));
    config.desktop_scale_factor = 0u;
    REQUIRE(rejected(&config));
    config.desktop_scale_factor = 300u;
    config.device_scale_factor = 120u;
    REQUIRE(rejected(&config));
    config.device_scale_factor = 0u;
    REQUIRE(rejected(&config));
    return 1;
}

static int test_scale_reaches_the_backend(void)
{
    abi3_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    mr_rdp_display_resize_request request;
    pthread_t thread;

    memset(&context, 0, sizeof(context));
    REQUIRE(pthread_mutex_init(&context.mutex, NULL) == 0);
    REQUIRE(pthread_cond_init(&context.condition, NULL) == 0);
    initialize_config(&config, 9u);
    config.desktop_scale_factor = 300u;
    config.device_scale_factor = 180u;
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = on_state;
    mr_rdp_mock_script_init(&script);
    script.observer_context = &context;
    script.on_scale_config = observe_scale;
    script.on_request_display_resize = observe_resize;

    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, &context) == 0);
    REQUIRE(wait_for(&context, &context.connected, 1));
    REQUIRE(wait_for(&context, &context.scale_seen, 1));
    REQUIRE(context.desktop_scale == 300u);
    REQUIRE(context.device_scale == 180u);

    /* An out-of-range factor is refused before it reaches the backend; zero
     * means "keep", and a valid one travels with the size. */
    mr_rdp_display_resize_request_init(&request);
    request.request_id = 1u;
    request.width = 1338u;
    request.height = 952u;
    request.desktop_scale_factor = 50u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    request.desktop_scale_factor = 200u;
    request.device_scale_factor = 141u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    request.device_scale_factor = 0u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.resize_seen, 1));
    REQUIRE(context.resize.desktop_scale_factor == 200u);
    REQUIRE(context.resize.device_scale_factor == 0u);
    REQUIRE(context.resize.width == 1338u);

    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context.condition);
    (void)pthread_mutex_destroy(&context.mutex);
    return 1;
}

int main(void)
{
    int passed = 1;
    passed &= test_config_scale_defaults_and_validation();
    passed &= test_scale_reaches_the_backend();
    if (!passed) {
        return 1;
    }
    (void)printf("abi3 contract tests passed\n");
    return 0;
}
