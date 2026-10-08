#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 6 surface: the MACRDPX channel - its config, the server messages
 * that reach the app, and the client messages it may send. Run against the
 * mock backend. */

typedef struct abi6_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    int connected;
    int events;
    mrx_message_type types[8];
    uint32_t negotiated[8];
    uint16_t status_fps;
    char source_id[64];
    int sent;
    mrx_message last_sent;
} abi6_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void signal_locked(abi6_context *context)
{
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for(abi6_context *context, const int *flag, int value)
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
    abi6_context *context = (abi6_context *)opaque;
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        signal_locked(context);
    }
}

static void on_macrdpx(void *opaque, const mr_rdp_macrdpx_event *event)
{
    abi6_context *context = (abi6_context *)opaque;
    const mrx_message *message = event->message;
    (void)pthread_mutex_lock(&context->mutex);
    if (context->events < 8) {
        context->types[context->events] = message->type;
        context->negotiated[context->events] = event->negotiated_caps;
    }
    if (message->type == MRX_MSG_STREAM_STATUS) {
        context->status_fps = message->u.stream_status.max_fps;
    }
    if (message->type == MRX_MSG_INPUT_SOURCE) {
        /* Borrowed only for the callback: copy it now. */
        (void)snprintf(context->source_id, sizeof(context->source_id), "%.*s",
                       (int)message->u.input_source.id_length, message->u.input_source.id);
    }
    ++context->events;
    signal_locked(context);
}

static void observe_send(void *opaque, const mrx_message *message)
{
    abi6_context *context = (abi6_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->sent;
    context->last_sent = *message;
    signal_locked(context);
}

static void *run_thread(void *opaque)
{
    abi6_context *context = (abi6_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi6.example.test";
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

static int created(mr_rdp_config *config)
{
    mr_rdp_session *session = NULL;
    if (mr_rdp_session_create_mock(config, NULL, NULL, NULL, &session) != MR_RDP_STATUS_OK) {
        return 0;
    }
    return mr_rdp_session_destroy(session) == MR_RDP_STATUS_OK;
}

static int test_config_validation(void)
{
    mr_rdp_config config;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == MR_RDP_BRIDGE_ABI_VERSION && MR_RDP_BRIDGE_ABI_VERSION >= 6u);
    REQUIRE(config.macrdpx_caps == 0u && config.reserved_abi6 == 0u);
    REQUIRE(created(&config));
    /* Caps without the flag, and the flag without caps, are both refused. */
    config.macrdpx_caps = MRX_CAP_MAC_KEYS | MRX_CAP_POINTER;
    REQUIRE(!created(&config));
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_MACRDPX;
    REQUIRE(created(&config));
    config.macrdpx_caps = 0u;
    REQUIRE(!created(&config));
    config.macrdpx_caps = MRX_CAP_PRECISE_SCROLL;
    config.reserved_abi6 = 1u;
    REQUIRE(!created(&config));
    config.reserved_abi6 = 0u;
    config.channel_flags |= 1u << 7;
    REQUIRE(!created(&config));
    return 1;
}

static int test_server_messages_and_sending(void)
{
    static const char server_name[] = "macos-rdp-server";
    static const char source[] = "com.apple.keylayout.ABC";
    mrx_message script_messages[4];
    abi6_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_callbacks callbacks;
    mrx_message message;
    pthread_t thread;

    memset(script_messages, 0, sizeof(script_messages));
    script_messages[0].type = MRX_MSG_HELLO;
    script_messages[0].u.hello.version = 1u;
    script_messages[0].u.hello.role = MRX_ROLE_SERVER;
    script_messages[0].u.hello.caps = MRX_CAP_MAC_KEYS | MRX_CAP_POINTER | MRX_CAP_STREAM_CONFIG |
        MRX_CAP_INPUT_SOURCE;
    script_messages[0].u.hello.name = server_name;
    script_messages[0].u.hello.name_length = (uint8_t)(sizeof(server_name) - 1u);
    script_messages[1].type = MRX_MSG_STREAM_STATUS;
    script_messages[1].u.stream_status.max_fps = 60u;
    script_messages[2].type = MRX_MSG_INPUT_SOURCE;
    script_messages[2].u.input_source.ascii_capable = 1u;
    script_messages[2].u.input_source.id = source;
    script_messages[2].u.input_source.id_length = (uint8_t)(sizeof(source) - 1u);
    /* A client-only type from the server is rejected before the app. */
    script_messages[3].type = MRX_MSG_KEY;
    script_messages[3].u.key.keycode = 1u;

    initialize_config(&config, 2u);
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_MACRDPX;
    config.macrdpx_caps = MRX_CAP_MAC_KEYS | MRX_CAP_POINTER | MRX_CAP_PRECISE_SCROLL |
        MRX_CAP_STREAM_CONFIG;
    mr_rdp_mock_script_init(&script);
    script.macrdpx_messages = script_messages;
    script.macrdpx_message_count = 3u;
    script.on_send_macrdpx = observe_send;

    memset(&context, 0, sizeof(context));
    REQUIRE(pthread_mutex_init(&context.mutex, NULL) == 0);
    REQUIRE(pthread_cond_init(&context.condition, NULL) == 0);
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = on_state;
    callbacks.on_macrdpx = on_macrdpx;
    script.observer_context = &context;
    REQUIRE(mr_rdp_session_create_mock(&config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, &context) == 0);
    REQUIRE(wait_for(&context, &context.connected, 1));
    REQUIRE(wait_for(&context, &context.events, 3));

    (void)pthread_mutex_lock(&context.mutex);
    REQUIRE(context.types[0] == MRX_MSG_HELLO);
    REQUIRE(context.negotiated[0] == (MRX_CAP_MAC_KEYS | MRX_CAP_POINTER | MRX_CAP_STREAM_CONFIG));
    REQUIRE(context.types[1] == MRX_MSG_STREAM_STATUS && context.status_fps == 60u);
    REQUIRE(context.types[2] == MRX_MSG_INPUT_SOURCE && strcmp(context.source_id, source) == 0);
    (void)pthread_mutex_unlock(&context.mutex);

    /* Client-to-server types pass; others and invalid values do not. */
    memset(&message, 0, sizeof(message));
    message.type = MRX_MSG_KEY;
    message.u.key.keycode = 13u;
    message.u.key.modifier_flags = MRX_FLAG_COMMAND | MRX_FLAG_DEVICE_LEFT_COMMAND;
    REQUIRE(mr_rdp_session_send_macrdpx(context.session, &message) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.sent, 1));
    REQUIRE(context.last_sent.type == MRX_MSG_KEY && context.last_sent.u.key.keycode == 13u);
    message.u.key.keycode = 200u;
    REQUIRE(mr_rdp_session_send_macrdpx(context.session, &message) == MR_RDP_ERROR_INVALID_ARGUMENT);
    message.type = MRX_MSG_HELLO;
    message.u.hello.role = MRX_ROLE_CLIENT;
    REQUIRE(mr_rdp_session_send_macrdpx(context.session, &message) == MR_RDP_ERROR_INVALID_ARGUMENT);
    memset(&message, 0, sizeof(message));
    message.type = MRX_MSG_STREAM_CONFIG;
    message.u.stream_config.max_fps = 15u;
    message.u.stream_config.bitrate_kbps = 1000u;
    REQUIRE(mr_rdp_session_send_macrdpx(context.session, &message) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.sent, 2));
    REQUIRE(mr_rdp_session_send_macrdpx(context.session, NULL) == MR_RDP_ERROR_INVALID_ARGUMENT);

    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context.condition);
    (void)pthread_mutex_destroy(&context.mutex);
    return 1;
}

static int test_unsupported_without_flag(void)
{
    mr_rdp_config config;
    mr_rdp_session *session = NULL;
    mrx_message message;
    initialize_config(&config, 3u);
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) == MR_RDP_STATUS_OK);
    memset(&message, 0, sizeof(message));
    message.type = MRX_MSG_MODIFIERS;
    REQUIRE(mr_rdp_session_send_macrdpx(session, &message) == MR_RDP_ERROR_UNSUPPORTED);
    REQUIRE(mr_rdp_session_destroy(session) == MR_RDP_STATUS_OK);
    return 1;
}

int main(void)
{
    int ok = 1;
    ok &= test_config_validation();
    ok &= test_server_messages_and_sending();
    ok &= test_unsupported_without_flag();
    if (!ok) {
        return 1;
    }
    (void)puts("abi6 contract tests passed");
    return 0;
}
