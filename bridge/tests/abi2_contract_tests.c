#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 2 surface: keyboard profile and channel flags in the config,
 * cursor and audio callbacks, Unicode taps and the user-initiated clipboard
 * offer/request pair. Everything runs against the mock backend, so what is
 * tested here is the bridge's validation and dispatch, not FreeRDP. */

typedef struct abi2_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    uint64_t generation;
    int connected;
    int run_done;
    int cursor_count;
    mr_rdp_cursor_kind cursor_kind;
    uint32_t cursor_hotspot_x;
    int audio_count;
    size_t audio_length;
    int remote_formats_count;
    int remote_has_text;
    int offer_accepted;
    int offer_delivered;
    uint64_t offer_id;
    int text_count;
    mr_rdp_status text_status;
    uint64_t text_request_id;
    uint8_t text[64];
    size_t text_length;
    int unicode_count;
    uint16_t unicode_units[8];
    int focus_calls;
    int last_focus;
    mr_rdp_keyboard_profile seen_profile;
    mr_rdp_channel_flags seen_flags;
    atomic_int failures;
} abi2_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void fail(abi2_context *context, const char *message)
{
    (void)fprintf(stderr, "callback failure: %s\n", message);
    (void)atomic_fetch_add(&context->failures, 1);
}

static void signal_locked(abi2_context *context)
{
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for(abi2_context *context, const int *flag, int value)
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
    abi2_context *context = (abi2_context *)opaque;
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        signal_locked(context);
    }
}

static void on_cursor(void *opaque, const mr_rdp_cursor_event *event)
{
    abi2_context *context = (abi2_context *)opaque;
    if (event->struct_size < sizeof(*event) || event->generation != context->generation) {
        fail(context, "cursor identity");
        return;
    }
    (void)pthread_mutex_lock(&context->mutex);
    ++context->cursor_count;
    context->cursor_kind = event->kind;
    context->cursor_hotspot_x = event->hotspot_x;
    signal_locked(context);
}

static void on_audio(void *opaque, const mr_rdp_audio_packet *packet)
{
    abi2_context *context = (abi2_context *)opaque;
    if (packet->generation != context->generation || packet->bits_per_sample != 16u) {
        fail(context, "audio identity");
        return;
    }
    (void)pthread_mutex_lock(&context->mutex);
    ++context->audio_count;
    context->audio_length = packet->length;
    signal_locked(context);
}

static void on_remote_formats(
    void *opaque,
    const mr_rdp_clipboard_remote_formats_event *event)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->remote_formats_count;
    context->remote_has_text = event->has_text;
    signal_locked(context);
}

static void on_offer(void *opaque, const mr_rdp_clipboard_offer_event *event)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    context->offer_id = event->offer_id;
    if (event->stage == MR_RDP_CLIPBOARD_OFFER_ACCEPTED) {
        ++context->offer_accepted;
    } else if (event->stage == MR_RDP_CLIPBOARD_OFFER_DELIVERED) {
        ++context->offer_delivered;
    }
    signal_locked(context);
}

static void on_text(void *opaque, const mr_rdp_clipboard_text_event *event)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    context->text_status = event->status;
    context->text_request_id = event->request_id;
    context->text_length = event->utf16le_byte_count;
    if (event->utf16le_byte_count <= sizeof(context->text) && event->utf16le_bytes != NULL) {
        memcpy(context->text, event->utf16le_bytes, event->utf16le_byte_count);
    }
    ++context->text_count;
    signal_locked(context);
}

static void observe_unicode(void *opaque, const mr_rdp_unicode_event *event)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    if (context->unicode_count < 8) {
        context->unicode_units[context->unicode_count] = event->code_unit;
    }
    ++context->unicode_count;
    signal_locked(context);
}

static void observe_focus(void *opaque, int focused)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->focus_calls;
    context->last_focus = focused;
    signal_locked(context);
}

static void observe_config(
    void *opaque,
    mr_rdp_keyboard_profile profile,
    mr_rdp_channel_flags flags)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    context->seen_profile = profile;
    context->seen_flags = flags;
    signal_locked(context);
}

static void *run_thread(void *opaque)
{
    abi2_context *context = (abi2_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    (void)pthread_mutex_lock(&context->mutex);
    context->run_done = 1;
    signal_locked(context);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi2.example.test";
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

static void initialize_callbacks(mr_rdp_callbacks *callbacks)
{
    mr_rdp_callbacks_init(callbacks);
    callbacks->on_state_changed = on_state;
    callbacks->on_cursor = on_cursor;
    callbacks->on_audio = on_audio;
    callbacks->on_clipboard_remote_formats = on_remote_formats;
    callbacks->on_clipboard_offer = on_offer;
    callbacks->on_clipboard_text = on_text;
}

static int context_init(abi2_context *context, uint64_t generation)
{
    memset(context, 0, sizeof(*context));
    atomic_init(&context->failures, 0);
    context->generation = generation;
    return pthread_mutex_init(&context->mutex, NULL) == 0 &&
        pthread_cond_init(&context->condition, NULL) == 0;
}

static void context_destroy(abi2_context *context)
{
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
}

static int test_config_defaults_and_validation(void)
{
    mr_rdp_config config;
    mr_rdp_session *session = NULL;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == MR_RDP_BRIDGE_ABI_VERSION);
    REQUIRE(config.keyboard_profile == MR_RDP_KEYBOARD_JAPANESE);
    REQUIRE(config.channel_flags ==
            (MR_RDP_CHANNEL_FLAG_AUDIO | MR_RDP_CHANNEL_FLAG_CLIPBOARD));

    config.keyboard_profile = 0u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    config.keyboard_profile = 4u;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    config.keyboard_profile = MR_RDP_KEYBOARD_US;
    config.channel_flags = 1u << 7;
    REQUIRE(mr_rdp_session_create_mock(&config, NULL, NULL, NULL, &session) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(session == NULL);
    return 1;
}

static int test_connected_session_surface(void)
{
    /* "ab" + NUL in UTF-16LE. */
    static const uint8_t remote_text[] = { 'a', 0, 'b', 0 };
    static const uint8_t offer_text[] = { 'h', 0, 0xA2, 0x30, 0, 0 };
    static uint8_t cursor_pixels[2 * 2 * 4];
    static const uint8_t pcm[8] = { 0 };
    abi2_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    mr_rdp_cursor_event cursor;
    mr_rdp_audio_packet audio;
    mr_rdp_unicode_event unicode;
    mr_rdp_clipboard_offer offer;
    pthread_t thread;

    REQUIRE(context_init(&context, 7u));
    initialize_config(&config, 7u);
    config.keyboard_profile = MR_RDP_KEYBOARD_US;
    config.channel_flags = MR_RDP_CHANNEL_FLAG_CLIPBOARD;
    initialize_callbacks(&callbacks);

    memset(&cursor, 0, sizeof(cursor));
    cursor.struct_size = (uint32_t)sizeof(cursor);
    cursor.kind = MR_RDP_CURSOR_SHAPE;
    cursor.generation = 7u;
    cursor.width = 2u;
    cursor.height = 2u;
    cursor.hotspot_x = 1u;
    cursor.stride = 8u;
    cursor.bytes = cursor_pixels;
    cursor.length = sizeof(cursor_pixels);

    memset(&audio, 0, sizeof(audio));
    audio.struct_size = (uint32_t)sizeof(audio);
    audio.generation = 7u;
    audio.samples_per_second = 48000u;
    audio.channels = 2u;
    audio.bits_per_sample = 16u;
    audio.bytes = pcm;
    audio.length = sizeof(pcm);

    mr_rdp_mock_script_init(&script);
    script.observer_context = &context;
    script.on_send_unicode = observe_unicode;
    script.on_set_audio_focused = observe_focus;
    script.on_session_config = observe_config;
    script.cursor_event = &cursor;
    script.audio_packet = &audio;
    script.remote_clipboard_utf16le = remote_text;
    script.remote_clipboard_utf16le_byte_count = sizeof(remote_text);

    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    /* Focus is accepted before run, so a session that starts focused hears
     * its first packet. */
    REQUIRE(mr_rdp_session_set_audio_focused(context.session, 2u) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(mr_rdp_session_set_audio_focused(context.session, 1u) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, &context) == 0);
    REQUIRE(wait_for(&context, &context.remote_formats_count, 1));

    REQUIRE(context.seen_profile == MR_RDP_KEYBOARD_US);
    REQUIRE(context.seen_flags == MR_RDP_CHANNEL_FLAG_CLIPBOARD);
    REQUIRE(context.cursor_count == 1);
    REQUIRE(context.cursor_kind == MR_RDP_CURSOR_SHAPE);
    REQUIRE(context.cursor_hotspot_x == 1u);
    REQUIRE(context.audio_count == 1);
    REQUIRE(context.audio_length == sizeof(pcm));
    REQUIRE(context.remote_has_text == 1);
    REQUIRE(context.focus_calls == 1 && context.last_focus == 1);

    mr_rdp_unicode_event_init(&unicode);
    REQUIRE(mr_rdp_session_send_unicode(context.session, &unicode) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    unicode.code_unit = 0x3042u;
    REQUIRE(mr_rdp_session_send_unicode(context.session, &unicode) == MR_RDP_STATUS_OK);
    unicode.code_unit = 0xD83Du;
    REQUIRE(mr_rdp_session_send_unicode(context.session, &unicode) == MR_RDP_STATUS_OK);
    REQUIRE(context.unicode_count == 2);
    REQUIRE(context.unicode_units[0] == 0x3042u && context.unicode_units[1] == 0xD83Du);

    mr_rdp_clipboard_offer_init(&offer);
    offer.offer_id = 11u;
    offer.utf16le_bytes = remote_text; /* no trailing NUL */
    offer.utf16le_byte_count = sizeof(remote_text);
    REQUIRE(mr_rdp_session_offer_clipboard_text(context.session, &offer) ==
            MR_RDP_ERROR_INVALID_DATA);
    offer.utf16le_bytes = offer_text;
    offer.utf16le_byte_count = sizeof(offer_text);
    REQUIRE(mr_rdp_session_offer_clipboard_text(context.session, &offer) ==
            MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.offer_delivered, 1));
    REQUIRE(context.offer_accepted == 1 && context.offer_id == 11u);

    REQUIRE(mr_rdp_session_request_clipboard_text(context.session, 0u) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(mr_rdp_session_request_clipboard_text(context.session, 5u) ==
            MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.text_count, 1));
    REQUIRE(context.text_status == MR_RDP_STATUS_OK);
    REQUIRE(context.text_request_id == 5u);
    REQUIRE(context.text_length == sizeof(remote_text));
    REQUIRE(memcmp(context.text, remote_text, sizeof(remote_text)) == 0);

    REQUIRE(mr_rdp_session_request_stop(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    /* After stop nothing new is accepted, but focus stays a harmless no-op. */
    REQUIRE(mr_rdp_session_send_unicode(context.session, &unicode) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdp_session_request_clipboard_text(context.session, 6u) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdp_session_set_audio_focused(context.session, 0u) == MR_RDP_STATUS_OK);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    REQUIRE(atomic_load(&context.failures) == 0);
    context_destroy(&context);
    return 1;
}

static int test_disabled_channels_and_unfocused_audio(void)
{
    static const uint8_t text[] = { 'x', 0, 0, 0 };
    static const uint8_t pcm[4] = { 0 };
    static const uint8_t bad_cursor_pixels[4] = { 0 };
    abi2_context context;
    mr_rdp_config config;
    mr_rdp_callbacks callbacks;
    mr_rdp_mock_script script;
    mr_rdp_audio_packet audio;
    mr_rdp_cursor_event cursor;
    mr_rdp_clipboard_offer offer;
    pthread_t thread;

    REQUIRE(context_init(&context, 9u));
    initialize_config(&config, 9u);
    config.channel_flags = 0u;
    initialize_callbacks(&callbacks);

    memset(&audio, 0, sizeof(audio));
    audio.struct_size = (uint32_t)sizeof(audio);
    audio.generation = 9u;
    audio.samples_per_second = 44100u;
    audio.channels = 1u;
    audio.bits_per_sample = 16u;
    audio.bytes = pcm;
    audio.length = sizeof(pcm);

    /* A hotspot outside the image is refused before the app sees it, and the
     * refusal ends the run like any other invalid backend data. Emitted
     * after audio in the mock, so it also proves unfocused audio was quiet. */
    memset(&cursor, 0, sizeof(cursor));
    cursor.struct_size = (uint32_t)sizeof(cursor);
    cursor.kind = MR_RDP_CURSOR_SHAPE;
    cursor.generation = 9u;
    cursor.width = 1u;
    cursor.height = 1u;
    cursor.hotspot_x = 1u;
    cursor.stride = 4u;
    cursor.bytes = bad_cursor_pixels;
    cursor.length = sizeof(bad_cursor_pixels);

    mr_rdp_mock_script_init(&script);
    script.observer_context = &context;
    script.audio_packet = &audio;
    script.cursor_event = &cursor;

    REQUIRE(mr_rdp_session_create_mock(
                &config, &callbacks, &context, &script, &context.session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, &context) == 0);
    REQUIRE(wait_for(&context, &context.run_done, 1));
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(context.connected == 1);
    REQUIRE(context.cursor_count == 0);
    REQUIRE(context.audio_count == 0);

    mr_rdp_clipboard_offer_init(&offer);
    offer.offer_id = 1u;
    offer.utf16le_bytes = text;
    offer.utf16le_byte_count = sizeof(text);
    REQUIRE(mr_rdp_session_offer_clipboard_text(context.session, &offer) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdp_session_request_clipboard_text(context.session, 1u) ==
            MR_RDP_ERROR_INVALID_STATE);
    REQUIRE(mr_rdp_session_destroy(context.session) == MR_RDP_STATUS_OK);
    context_destroy(&context);
    return 1;
}

int main(void)
{
    int passed = 1;
    passed &= test_config_defaults_and_validation();
    passed &= test_connected_session_surface();
    passed &= test_disabled_channels_and_unfocused_audio();
    if (!passed) {
        return 1;
    }
    (void)printf("abi2 contract tests passed\n");
    return 0;
}
