#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 5 surface: clipboard images and files, the microphone, and
 * RemoteApp's program. Run against the mock backend. */

typedef struct abi5_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    int connected;
    int formats_seen;
    mr_rdp_clipboard_remote_formats_event formats;
    int images;
    mr_rdp_status image_status;
    mr_rdp_clipboard_image_format image_format;
    size_t image_bytes;
    int files;
    int files_last;
    char file_names[4][32];
    size_t file_sizes[4];
    mr_rdp_status files_status;
    int capture_events;
    mr_rdp_audio_capture_event capture;
    int captured;
    size_t captured_bytes;
    int image_offers;
    size_t offered_png;
    int files_offers;
    size_t offered_files;
} abi5_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void signal_locked(abi5_context *context)
{
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for(abi5_context *context, const int *flag, int value)
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
    abi5_context *context = (abi5_context *)opaque;
    if (event->state == MR_RDP_SESSION_CONNECTED) {
        (void)pthread_mutex_lock(&context->mutex);
        context->connected = 1;
        signal_locked(context);
    }
}

static void on_formats(void *opaque, const mr_rdp_clipboard_remote_formats_event *event)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->formats_seen;
    context->formats = *event;
    signal_locked(context);
}

static void on_image(void *opaque, const mr_rdp_clipboard_image_event *event)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->images;
    context->image_status = event->status;
    context->image_format = event->format;
    context->image_bytes = event->byte_count;
    signal_locked(context);
}

static void on_file(void *opaque, const mr_rdp_clipboard_file_event *event)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    context->files_status = event->status;
    if (event->status == MR_RDP_STATUS_OK && event->index < 4u) {
        (void)snprintf(context->file_names[event->index], sizeof(context->file_names[0]),
                       "%.*s", (int)event->name_length, event->name);
        context->file_sizes[event->index] = event->byte_count;
    }
    ++context->files;
    if (event->is_last) {
        context->files_last = 1;
    }
    signal_locked(context);
}

static void on_capture(void *opaque, const mr_rdp_audio_capture_event *event)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->capture_events;
    context->capture = *event;
    signal_locked(context);
}

static void observe_capture(void *opaque, const uint8_t *bytes, size_t byte_count)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)bytes;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->captured;
    context->captured_bytes += byte_count;
    signal_locked(context);
}

static void observe_image_offer(void *opaque, const mr_rdp_clipboard_image_offer *offer)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->image_offers;
    context->offered_png = offer->png_byte_count;
    signal_locked(context);
}

static void observe_files_offer(void *opaque, const mr_rdp_clipboard_files_offer *offer)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->files_offers;
    context->offered_files = offer->file_count;
    signal_locked(context);
}

static void *run_thread(void *opaque)
{
    abi5_context *context = (abi5_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi5.example.test";
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

static int start(abi5_context *context, mr_rdp_config *config, mr_rdp_mock_script *script,
                 pthread_t *thread)
{
    mr_rdp_callbacks callbacks;
    memset(context, 0, sizeof(*context));
    REQUIRE(pthread_mutex_init(&context->mutex, NULL) == 0);
    REQUIRE(pthread_cond_init(&context->condition, NULL) == 0);
    mr_rdp_callbacks_init(&callbacks);
    callbacks.on_state_changed = on_state;
    callbacks.on_clipboard_remote_formats = on_formats;
    callbacks.on_clipboard_image = on_image;
    callbacks.on_clipboard_file = on_file;
    callbacks.on_audio_capture = on_capture;
    script->observer_context = context;
    script->on_send_audio_capture = observe_capture;
    script->on_offer_clipboard_image = observe_image_offer;
    script->on_offer_clipboard_files = observe_files_offer;
    REQUIRE(mr_rdp_session_create_mock(config, &callbacks, context, script, &context->session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(thread, NULL, run_thread, context) == 0);
    REQUIRE(wait_for(context, &context->connected, 1));
    return 1;
}

static int finish(abi5_context *context, pthread_t thread)
{
    REQUIRE(mr_rdp_session_request_stop(context->session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context->session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
    return 1;
}

static int test_remote_program_validation(void)
{
    static const char program[] = "||notepad";
    static const char arguments[] = "C:\\temp\\a.txt";
    mr_rdp_config config;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == MR_RDP_BRIDGE_ABI_VERSION && MR_RDP_BRIDGE_ABI_VERSION >= 5u);
    REQUIRE(config.remote_program == NULL);
    config.remote_arguments = arguments;
    config.remote_arguments_length = sizeof(arguments) - 1u;
    REQUIRE(!created(&config));
    config.remote_program = program;
    config.remote_program_length = sizeof(program) - 1u;
    REQUIRE(created(&config));
    config.remote_program_length = 0u;
    REQUIRE(!created(&config));
    config.channel_flags |= 1u << 7;
    config.remote_program_length = sizeof(program) - 1u;
    REQUIRE(!created(&config));
    config.channel_flags &= ~(mr_rdp_channel_flags)(1u << 7);
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_MICROPHONE | MR_RDP_CHANNEL_FLAG_H264;
    REQUIRE(created(&config));
    return 1;
}

static int test_remote_image_and_files(void)
{
    static const uint8_t png[] = { 0x89, 'P', 'N', 'G', 1, 2, 3 };
    static const uint8_t first[] = { 'a', 'b', 'c' };
    static const mr_rdp_clipboard_file files[] = {
        { "report.txt", 10u, first, sizeof(first) },
        { "empty.bin", 9u, NULL, 0u },
    };
    static const uint8_t text[] = { 'h', 0, 0, 0 };
    abi5_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    pthread_t thread;

    initialize_config(&config, 2u);
    mr_rdp_mock_script_init(&script);
    script.remote_clipboard_utf16le = text;
    script.remote_clipboard_utf16le_byte_count = 2u;
    script.remote_image_png = png;
    script.remote_image_png_byte_count = sizeof(png);
    script.remote_files = files;
    script.remote_file_count = 2u;
    REQUIRE(start(&context, &config, &script, &thread));
    REQUIRE(wait_for(&context, &context.formats_seen, 1));
    REQUIRE(context.formats.has_text == 1u);
    REQUIRE(context.formats.has_image == 1u);
    REQUIRE(context.formats.has_files == 1u);

    REQUIRE(mr_rdp_session_request_clipboard_image(context.session, 0u) == MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(mr_rdp_session_request_clipboard_image(context.session, 7u) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.images, 1));
    REQUIRE(context.image_status == MR_RDP_STATUS_OK);
    REQUIRE(context.image_format == MR_RDP_CLIPBOARD_IMAGE_PNG);
    REQUIRE(context.image_bytes == sizeof(png));

    REQUIRE(mr_rdp_session_request_clipboard_files(context.session, 8u) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.files_last, 1));
    REQUIRE(context.files == 2);
    REQUIRE(context.files_status == MR_RDP_STATUS_OK);
    REQUIRE(strcmp(context.file_names[0], "report.txt") == 0);
    REQUIRE(context.file_sizes[0] == sizeof(first));
    REQUIRE(strcmp(context.file_names[1], "empty.bin") == 0);
    REQUIRE(context.file_sizes[1] == 0u);
    return finish(&context, thread);
}

static int test_offers_are_checked_before_the_backend(void)
{
    static const uint8_t png[] = { 0x89, 'P', 'N', 'G' };
    static const uint8_t bytes[] = { 1, 2, 3 };
    abi5_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    mr_rdp_clipboard_image_offer image;
    mr_rdp_clipboard_files_offer offer;
    mr_rdp_clipboard_file files[2];
    pthread_t thread;

    initialize_config(&config, 3u);
    mr_rdp_mock_script_init(&script);
    REQUIRE(start(&context, &config, &script, &thread));

    mr_rdp_clipboard_image_offer_init(&image);
    image.offer_id = 1u;
    REQUIRE(mr_rdp_session_offer_clipboard_image(context.session, &image) == MR_RDP_ERROR_INVALID_ARGUMENT);
    image.png_bytes = png;
    REQUIRE(mr_rdp_session_offer_clipboard_image(context.session, &image) == MR_RDP_ERROR_INVALID_ARGUMENT);
    image.png_byte_count = sizeof(png);
    REQUIRE(mr_rdp_session_offer_clipboard_image(context.session, &image) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.image_offers, 1));
    REQUIRE(context.offered_png == sizeof(png));

    memset(files, 0, sizeof(files));
    files[0].name = "a/b.txt";
    files[0].name_length = 7u;
    files[0].bytes = bytes;
    files[0].byte_count = sizeof(bytes);
    files[1].name = "c.txt";
    files[1].name_length = 5u;
    mr_rdp_clipboard_files_offer_init(&offer);
    offer.offer_id = 2u;
    offer.files = files;
    offer.file_count = 2u;
    REQUIRE(mr_rdp_session_offer_clipboard_files(context.session, &offer) == MR_RDP_ERROR_INVALID_ARGUMENT);
    files[0].name = "b.txt";
    files[0].name_length = 5u;
    REQUIRE(mr_rdp_session_offer_clipboard_files(context.session, &offer) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.files_offers, 1));
    REQUIRE(context.offered_files == 2u);
    offer.file_count = 0u;
    REQUIRE(mr_rdp_session_offer_clipboard_files(context.session, &offer) == MR_RDP_ERROR_INVALID_ARGUMENT);
    return finish(&context, thread);
}

static int test_microphone(void)
{
    static const uint8_t pcm[] = { 0, 0, 1, 0 };
    abi5_context context;
    mr_rdp_config config;
    mr_rdp_mock_script script;
    pthread_t thread;

    /* Without the flag: refused, and the microphone never opens. */
    initialize_config(&config, 4u);
    mr_rdp_mock_script_init(&script);
    script.audio_capture_rate = 48000u;
    REQUIRE(start(&context, &config, &script, &thread));
    REQUIRE(mr_rdp_session_send_audio_capture(context.session, pcm, sizeof(pcm)) == MR_RDP_ERROR_UNSUPPORTED);
    REQUIRE(context.capture_events == 0);
    REQUIRE(finish(&context, thread));

    initialize_config(&config, 5u);
    config.channel_flags |= MR_RDP_CHANNEL_FLAG_MICROPHONE;
    mr_rdp_mock_script_init(&script);
    script.audio_capture_rate = 48000u;
    REQUIRE(start(&context, &config, &script, &thread));
    REQUIRE(wait_for(&context, &context.capture_events, 1));
    REQUIRE(context.capture.is_open == 1u);
    REQUIRE(context.capture.samples_per_second == 48000u);
    REQUIRE(context.capture.bits_per_sample == 16u);
    REQUIRE(mr_rdp_session_send_audio_capture(context.session, pcm, 0u) == MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(mr_rdp_session_send_audio_capture(context.session, pcm, MR_RDP_MAX_AUDIO_CAPTURE_PACKET_BYTES + 1u) ==
            MR_RDP_ERROR_INVALID_ARGUMENT);
    REQUIRE(mr_rdp_session_send_audio_capture(context.session, pcm, sizeof(pcm)) == MR_RDP_STATUS_OK);
    REQUIRE(wait_for(&context, &context.captured, 1));
    REQUIRE(context.captured_bytes == sizeof(pcm));
    return finish(&context, thread);
}

int main(void)
{
    int passed = 1;
    passed &= test_remote_program_validation();
    passed &= test_remote_image_and_files();
    passed &= test_offers_are_checked_before_the_backend();
    passed &= test_microphone();
    if (!passed) {
        return 1;
    }
    (void)printf("abi5 contract tests passed\n");
    return 0;
}
