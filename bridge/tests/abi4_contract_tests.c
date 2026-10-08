#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 4 surface: an RD Gateway, a shared drive, touch and pen input,
 * and a second monitor in display resize requests. Run against the mock
 * backend, so what is tested is the bridge's validation and what reaches a
 * backend, not FreeRDP. */

typedef struct abi4_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    int connected;
    int run_done;
    int config_seen;
    char gateway_hostname[256];
    uint16_t gateway_port;
    mr_rdp_gateway_flags gateway_flags;
    char gateway_username[64];
    char gateway_password[64];
    char drive_path[256];
    char drive_name[64];
    int touches;
    mr_rdp_touch_event touch;
    int pens;
    mr_rdp_pen_event pen;
    int resizes;
    mr_rdp_display_resize_request resize;
    int resize_events;
    mr_rdp_display_resize_event resize_event;
    int challenges;
    mr_rdp_certificate_role roles[2];
    char challenge_hosts[2][64];
    uint16_t challenge_ports[2];
} abi4_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void signal_locked(abi4_context *context)
{
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for(abi4_context *context, const int *flag, int value)
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

static void copy_text(char *destination, size_t capacity, const char *source)
{
    if (source == NULL) {
        destination[0] = '\0';
        return;
    }
    (void)snprintf(destination, capacity, "%s", source);
}

static void on_state(void *opaque, const mr_rdp_state_event *event)
{
    abi4_context *context = (abi4_context *)opaque;
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        signal_locked(context);
    }
}

static void on_certificate(void *opaque, const mr_rdp_certificate_challenge *challenge)
{
    abi4_context *context = (abi4_context *)opaque;
    int index;
    (void)pthread_mutex_lock(&context->mutex);
    index = context->challenges;
    if (index < 2) {
        context->roles[index] = challenge->role;
        copy_text(context->challenge_hosts[index], sizeof(context->challenge_hosts[index]),
                  challenge->hostname);
        context->challenge_ports[index] = challenge->port;
    }
    ++context->challenges;
    (void)pthread_mutex_unlock(&context->mutex);
    (void)mr_rdp_session_respond_certificate(
        context->session, challenge->generation, challenge->challenge_id,
        MR_RDP_CERTIFICATE_ACCEPT_USER_ONCE);
}

static void on_resize_event(void *opaque, const mr_rdp_display_resize_event *event)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->resize_events;
    context->resize_event = *event;
    signal_locked(context);
}

static void observe_connection(void *opaque, const mr_rdp_mock_connection_config *config)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->config_seen;
    copy_text(context->gateway_hostname, sizeof(context->gateway_hostname), config->gateway_hostname);
    context->gateway_port = config->gateway_port;
    context->gateway_flags = config->gateway_flags;
    copy_text(context->gateway_username, sizeof(context->gateway_username), config->gateway_username);
    copy_text(context->gateway_password, sizeof(context->gateway_password), config->gateway_password);
    copy_text(context->drive_path, sizeof(context->drive_path), config->drive_path);
    copy_text(context->drive_name, sizeof(context->drive_name), config->drive_name);
    signal_locked(context);
}

static void observe_touch(void *opaque, const mr_rdp_touch_event *event)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->touches;
    context->touch = *event;
    signal_locked(context);
}

static void observe_pen(void *opaque, const mr_rdp_pen_event *event)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->pens;
    context->pen = *event;
    signal_locked(context);
}

static void observe_resize(void *opaque, const mr_rdp_display_resize_request *request)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->resizes;
    context->resize = *request;
    signal_locked(context);
}

static void *run_thread(void *opaque)
{
    abi4_context *context = (abi4_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->run_done = 1;
    signal_locked(context);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi4.example.test";
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

static int accepted(mr_rdp_config *config)
{
    mr_rdp_session *session = NULL;
    if (mr_rdp_session_create_mock(config, NULL, NULL, NULL, &session) != MR_RDP_STATUS_OK) {
        return 0;
    }
    return mr_rdp_session_destroy(session) == MR_RDP_STATUS_OK;
}

static int rejected(mr_rdp_config *config)
{
    mr_rdp_session *session = NULL;
    return mr_rdp_session_create_mock(config, NULL, NULL, NULL, &session) ==
               MR_RDP_ERROR_INVALID_ARGUMENT &&
           session == NULL;
}

static int start(abi4_context *context, mr_rdp_config *config, mr_rdp_mock_script *script,
                 pthread_t *thread)
{
    mr_rdp_callbacks callbacks;
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = on_state;
    callbacks.on_certificate_challenge = on_certificate;
    callbacks.on_display_resize_event = on_resize_event;
    script->observer_context = context;
    script->on_connection_config = observe_connection;
    script->on_send_touch = observe_touch;
    script->on_send_pen = observe_pen;
    script->on_request_display_resize = observe_resize;
    REQUIRE(mr_rdp_session_create_mock(config, &callbacks, context, script, &context->session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(thread, NULL, run_thread, context) == 0);
    REQUIRE(wait_for(context, &context->connected, 1));
    return 1;
}

static int finish(abi4_context *context, pthread_t thread)
{
    REQUIRE(mr_rdp_session_request_stop(context->session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context->session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
    return 1;
}

static int init_context(abi4_context *context)
{
    memset(context, 0, sizeof(*context));
    REQUIRE(pthread_mutex_init(&context->mutex, NULL) == 0);
    REQUIRE(pthread_cond_init(&context->condition, NULL) == 0);
    return 1;
}

static int test_defaults(void)
{
    mr_rdp_config config;
    mr_rdp_touch_event touch;
    mr_rdp_pen_event pen;
    mr_rdp_display_resize_request request;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == 4u);
    REQUIRE(config.gateway_hostname == NULL);
    REQUIRE(config.gateway_flags == 0u);
    REQUIRE(config.drive_path == NULL);
    REQUIRE((config.channel_flags & (MR_RDP_CHANNEL_FLAG_DRIVE | MR_RDP_CHANNEL_FLAG_TOUCH)) == 0u);
    mr_rdp_touch_event_init(&touch);
    REQUIRE(touch.struct_size == sizeof(touch) && touch.action == MR_RDP_TOUCH_DOWN);
    mr_rdp_pen_event_init(&pen);
    REQUIRE(pen.struct_size == sizeof(pen) && pen.action == MR_RDP_PEN_HOVER);
    mr_rdp_display_resize_request_init(&request);
    REQUIRE(request.secondary_width == 0u && request.secondary_height == 0u);
    return 1;
}

static int test_gateway_validation(void)
{
    static const char gateway[] = "gw.example.test";
    static const char user[] = "gwuser";
    static const char password[] = "gwpass";
    mr_rdp_config config;

    initialize_config(&config, 2u);
    config.gateway_flags = MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL;
    REQUIRE(rejected(&config));
    config.gateway_flags = 0u;
    config.gateway_port = 8443u;
    REQUIRE(rejected(&config));

    initialize_config(&config, 3u);
    config.gateway_hostname = gateway;
    REQUIRE(rejected(&config));
    config.gateway_flags = MR_RDP_GATEWAY_FLAG_SAME_CREDENTIALS;
    REQUIRE(accepted(&config));
    config.gateway_username = user;
    config.gateway_username_length = sizeof(user) - 1u;
    REQUIRE(rejected(&config));
    config.gateway_flags = 0u;
    REQUIRE(rejected(&config));
    config.gateway_password = password;
    config.gateway_password_length = sizeof(password) - 1u;
    REQUIRE(accepted(&config));
    config.gateway_flags = 1u << 7;
    REQUIRE(rejected(&config));
    config.gateway_flags = 0u;
    config.reserved_abi4 = 1u;
    REQUIRE(rejected(&config));
    config.reserved_abi4 = 0u;
    config.gateway_password_length = 0u;
    REQUIRE(rejected(&config));
    return 1;
}

static int test_drive_validation(void)
{
    static const char path[] = "/var/mobile/Shared";
    static const char relative[] = "Shared";
    static const char name[] = "iPhone";
    static const char bad_name[] = "C:";
    mr_rdp_config config;

    initialize_config(&config, 4u);
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_DRIVE;
    REQUIRE(rejected(&config));
    config.drive_path = path;
    config.drive_path_length = sizeof(path) - 1u;
    REQUIRE(rejected(&config));
    config.drive_name = name;
    config.drive_name_length = sizeof(name) - 1u;
    REQUIRE(accepted(&config));
    config.drive_name = bad_name;
    config.drive_name_length = sizeof(bad_name) - 1u;
    REQUIRE(rejected(&config));
    config.drive_name = name;
    config.drive_name_length = sizeof(name) - 1u;
    config.drive_path = relative;
    config.drive_path_length = sizeof(relative) - 1u;
    REQUIRE(rejected(&config));
    config.drive_path = path;
    config.drive_path_length = sizeof(path) - 1u;
    config.channel_flags &= ~(mr_rdp_channel_flags)MR_RDP_CHANNEL_FLAG_DRIVE;
    REQUIRE(rejected(&config));
    return 1;
}

static int test_gateway_and_drive_reach_the_backend(void)
{
    static const char gateway[] = "gw.example.test";
    static const char user[] = "gwuser";
    static const char password[] = "gwpass";
    static const char path[] = "/tmp/shared";
    static const char name[] = "iPad";
    static const uint8_t gateway_leaf[] = { 0x30, 0x01, 0x01 };
    static const uint8_t server_leaf[] = { 0x30, 0x01, 0x02 };
    const mr_rdp_der_blob gateway_chain[] = { { gateway_leaf, sizeof(gateway_leaf) } };
    const mr_rdp_der_blob server_chain[] = { { server_leaf, sizeof(server_leaf) } };
    abi4_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    pthread_t thread;

    REQUIRE(init_context(&context));
    initialize_config(&config, 5u);
    config.gateway_hostname = gateway;
    config.gateway_username = user;
    config.gateway_username_length = sizeof(user) - 1u;
    config.gateway_password = password;
    config.gateway_password_length = sizeof(password) - 1u;
    config.gateway_flags = MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL;
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_DRIVE;
    config.drive_path = path;
    config.drive_path_length = sizeof(path) - 1u;
    config.drive_name = name;
    config.drive_name_length = sizeof(name) - 1u;
    mr_rdp_mock_script_init(&script);
    script.gateway_certificate_chain = gateway_chain;
    script.gateway_certificate_chain_count = 1u;
    script.certificate_chain = server_chain;
    script.certificate_chain_count = 1u;
    REQUIRE(start(&context, &config, &script, &thread));
    REQUIRE(wait_for(&context, &context.config_seen, 1));
    REQUIRE(strcmp(context.gateway_hostname, gateway) == 0);
    REQUIRE(context.gateway_port == MR_RDP_DEFAULT_GATEWAY_PORT);
    REQUIRE(context.gateway_flags == MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL);
    REQUIRE(strcmp(context.gateway_username, user) == 0);
    REQUIRE(strcmp(context.gateway_password, password) == 0);
    REQUIRE(strcmp(context.drive_path, path) == 0);
    REQUIRE(strcmp(context.drive_name, name) == 0);

    /* The gateway is asked about first, under its own name and port. */
    REQUIRE(context.challenges == 2);
    REQUIRE(context.roles[0] == MR_RDP_CERTIFICATE_ROLE_GATEWAY);
    REQUIRE(strcmp(context.challenge_hosts[0], gateway) == 0);
    REQUIRE(context.challenge_ports[0] == MR_RDP_DEFAULT_GATEWAY_PORT);
    REQUIRE(context.roles[1] == MR_RDP_CERTIFICATE_ROLE_SERVER);
    REQUIRE(strcmp(context.challenge_hosts[1], "abi4.example.test") == 0);
    REQUIRE(context.challenge_ports[1] == MR_RDP_DEFAULT_PORT);
    return finish(&context, thread);
}

static int test_a_gateway_role_without_a_gateway_is_refused(void)
{
    static const uint8_t leaf[] = { 0x30, 0x01, 0x01 };
    const mr_rdp_der_blob chain[] = { { leaf, sizeof(leaf) } };
    abi4_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_callbacks callbacks;
    pthread_t thread;

    REQUIRE(init_context(&context));
    initialize_config(&config, 6u);
    mr_rdp_mock_script_init(&script);
    script.gateway_certificate_chain = chain;
    script.gateway_certificate_chain_count = 1u;
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = on_state;
    callbacks.on_certificate_challenge = on_certificate;
    REQUIRE(mr_rdp_session_create_mock(&config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, &context) == 0);
    REQUIRE(wait_for(&context, &context.run_done, 1));
    REQUIRE(context.connected == 0);
    REQUIRE(context.challenges == 0);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context.condition);
    (void)pthread_mutex_destroy(&context.mutex);
    return 1;
}

static int test_touch_and_pen(void)
{
    abi4_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_touch_event touch;
    mr_rdp_pen_event pen;
    pthread_t thread;

    /* Without the flag, refused as unsupported. */
    REQUIRE(init_context(&context));
    initialize_config(&config, 7u);
    mr_rdp_mock_script_init(&script);
    REQUIRE(start(&context, &config, &script, &thread));
    mr_rdp_touch_event_init(&touch);
    REQUIRE(mr_rdp_session_send_touch(context.session, &touch) == MR_RDP_ERROR_UNSUPPORTED);
    mr_rdp_pen_event_init(&pen);
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_ERROR_UNSUPPORTED);
    REQUIRE(finish(&context, thread));

    REQUIRE(init_context(&context));
    initialize_config(&config, 8u);
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_TOUCH;
    mr_rdp_mock_script_init(&script);
    REQUIRE(start(&context, &config, &script, &thread));

    mr_rdp_touch_event_init(&touch);
    touch.contact_id = 3u;
    touch.x = 640u;
    touch.y = 360u;
    touch.action = MR_RDP_TOUCH_MOVE;
    REQUIRE(mr_rdp_session_send_touch(context.session, &touch) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.touches, 1));
    REQUIRE(context.touch.contact_id == 3u && context.touch.x == 640u &&
            context.touch.action == MR_RDP_TOUCH_MOVE);
    touch.contact_id = MR_RDP_MAX_TOUCH_CONTACT_ID + 1u;
    REQUIRE(mr_rdp_session_send_touch(context.session, &touch) == MR_RDP_ERROR_INVALID_ARGUMENT);
    touch.contact_id = 0u;
    touch.action = MR_RDP_TOUCH_CANCEL + 1u;
    REQUIRE(mr_rdp_session_send_touch(context.session, &touch) == MR_RDP_ERROR_INVALID_ARGUMENT);
    touch.action = MR_RDP_TOUCH_UP;
    touch.reserved[1] = 1u;
    REQUIRE(mr_rdp_session_send_touch(context.session, &touch) == MR_RDP_ERROR_INVALID_ARGUMENT);

    mr_rdp_pen_event_init(&pen);
    pen.x = 10u;
    pen.y = 20u;
    pen.pressure = 512u;
    pen.tilt_x = -30;
    pen.tilt_y = 45;
    pen.rotation = 90u;
    pen.action = MR_RDP_PEN_DOWN;
    pen.flags = MR_RDP_PEN_FLAG_BARREL;
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.pens, 1));
    REQUIRE(context.pen.pressure == 512u && context.pen.tilt_y == 45 &&
            context.pen.flags == MR_RDP_PEN_FLAG_BARREL);
    pen.pressure = MR_RDP_MAX_PEN_PRESSURE + 1u;
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_ERROR_INVALID_ARGUMENT);
    pen.pressure = 0u;
    pen.tilt_x = 91;
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_ERROR_INVALID_ARGUMENT);
    pen.tilt_x = 0;
    pen.rotation = 360u;
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_ERROR_INVALID_ARGUMENT);
    pen.rotation = 0u;
    pen.flags = 1u << 5;
    REQUIRE(mr_rdp_session_send_pen(context.session, &pen) == MR_RDP_ERROR_INVALID_ARGUMENT);
    return finish(&context, thread);
}

static int test_second_monitor(void)
{
    abi4_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_display_resize_request request;
    pthread_t thread;

    REQUIRE(init_context(&context));
    initialize_config(&config, 9u);
    mr_rdp_mock_script_init(&script);
    REQUIRE(start(&context, &config, &script, &thread));

    mr_rdp_display_resize_request_init(&request);
    request.request_id = 1u;
    request.width = 1206u;
    request.height = 2622u;
    request.secondary_width = 1921u;
    request.secondary_height = 1080u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    request.secondary_width = 1920u;
    request.secondary_height = 0u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    request.width = 8192u;
    request.secondary_width = 8194u;
    request.secondary_height = 1080u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    request.width = 1206u;
    request.secondary_width = 1920u;
    REQUIRE(mr_rdp_session_request_display_resize(context.session, &request) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.resizes, 1));
    REQUIRE(context.resize.secondary_width == 1920u && context.resize.secondary_height == 1080u);
    REQUIRE(wait_for(&context, &context.resize_events, 1));
    REQUIRE(context.resize_event.secondary_width == 1920u);
    REQUIRE(context.resize_event.secondary_height == 1080u);
    return finish(&context, thread);
}

int main(void)
{
    int passed = 1;
    passed &= test_defaults();
    passed &= test_gateway_validation();
    passed &= test_drive_validation();
    passed &= test_gateway_and_drive_reach_the_backend();
    passed &= test_a_gateway_role_without_a_gateway_is_refused();
    passed &= test_touch_and_pen();
    passed &= test_second_monitor();
    if (!passed) {
        return 1;
    }
    (void)printf("abi4 contract tests passed\n");
    return 0;
}
