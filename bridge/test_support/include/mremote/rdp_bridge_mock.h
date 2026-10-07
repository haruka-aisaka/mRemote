#ifndef MREMOTE_RDP_BRIDGE_MOCK_H
#define MREMOTE_RDP_BRIDGE_MOCK_H

#include "mremote/rdp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mr_rdp_mock_stop_observer)(void *context);
typedef void (*mr_rdp_mock_key_observer)(
    void *context,
    const mr_rdp_key_event *event);
typedef void (*mr_rdp_mock_pointer_observer)(
    void *context,
    const mr_rdp_pointer_event *event);
typedef void (*mr_rdp_mock_clipboard_probe_observer)(
    void *context,
    uint64_t probe_id,
    const uint8_t *utf16le_bytes,
    size_t utf16le_byte_count,
    const uint8_t payload_sha256[MR_RDP_SHA256_BYTES]);
typedef void (*mr_rdp_mock_display_resize_observer)(
    void *context,
    const mr_rdp_display_resize_request *request);
typedef void (*mr_rdp_mock_config_observer)(
    void *context,
    const char *username,
    size_t username_length,
    const char *domain,
    size_t domain_length,
    const char *password,
    size_t password_length,
    uint32_t desktop_width,
    uint32_t desktop_height);

typedef void (*mr_rdp_mock_unicode_observer)(
    void *context,
    const mr_rdp_unicode_event *event);
typedef void (*mr_rdp_mock_audio_focus_observer)(void *context, int focused);
typedef void (*mr_rdp_mock_session_config_observer)(
    void *context,
    mr_rdp_keyboard_profile keyboard_profile,
    mr_rdp_channel_flags channel_flags);
typedef void (*mr_rdp_mock_scale_observer)(
    void *context,
    uint32_t desktop_scale_factor,
    uint32_t device_scale_factor);
typedef void (*mr_rdp_mock_clipboard_offer_observer)(
    void *context,
    uint64_t offer_id,
    const uint8_t *utf16le_bytes,
    size_t utf16le_byte_count);

typedef struct mr_rdp_mock_channel_transition {
    mr_rdp_channel_kind channel;
    mr_rdp_channel_transition transition;
    uint8_t reserved[6];
} mr_rdp_mock_channel_transition;

typedef struct mr_rdp_mock_script {
    uint32_t struct_size;
    uint32_t delay_before_certificate_ms;
    const mr_rdp_der_blob *certificate_chain;
    size_t certificate_chain_count;
    void *observer_context;
    mr_rdp_mock_stop_observer on_request_stop;
    mr_rdp_mock_key_observer on_send_key;
    mr_rdp_mock_pointer_observer on_send_pointer;
    mr_rdp_mock_config_observer on_config;
    const mr_rdp_desktop_frame *desktop_frame;
    const mr_rdp_mock_channel_transition *channel_transitions;
    size_t channel_transition_count;
    mr_rdp_mock_clipboard_probe_observer on_start_clipboard_probe;
    mr_rdp_mock_display_resize_observer on_request_display_resize;
    /* ABI 2. The cursor and audio views are borrowed through run returning
     * and emitted once each after the desktop frame. A non-NULL remote
     * clipboard announces text after connect and answers every request with
     * it (count 0 with a non-NULL pointer answers with empty text). */
    mr_rdp_mock_unicode_observer on_send_unicode;
    mr_rdp_mock_audio_focus_observer on_set_audio_focused;
    mr_rdp_mock_session_config_observer on_session_config;
    mr_rdp_mock_clipboard_offer_observer on_offer_clipboard_text;
    const mr_rdp_cursor_event *cursor_event;
    const mr_rdp_audio_packet *audio_packet;
    const uint8_t *remote_clipboard_utf16le;
    size_t remote_clipboard_utf16le_byte_count;
    /* ABI 3. Called at run with the scale factors the session was created
     * with. */
    mr_rdp_mock_scale_observer on_scale_config;
} mr_rdp_mock_script;

void mr_rdp_mock_script_init(mr_rdp_mock_script *script);

/*
 * Test-only backend injection. Blob and desktop-frame descriptors are copied
 * at create, while their byte buffers and dirty rectangles are borrowed
 * through run returning. This deliberately models callback-scoped
 * FreeRDP/OpenSSL/GDI memory: the bridge deep-copies DER, while frame consumers
 * must copy the validated framebuffer view during their callback.
 */
mr_rdp_status mr_rdp_session_create_mock(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    const mr_rdp_mock_script *script,
    mr_rdp_session **out_session);

#ifdef __cplusplus
}
#endif

#endif
