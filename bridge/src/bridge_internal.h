#ifndef MREMOTE_RDP_BRIDGE_INTERNAL_H
#define MREMOTE_RDP_BRIDGE_INTERNAL_H

#include "mremote/rdp_bridge.h"

typedef struct mr_rdp_backend mr_rdp_backend;

mr_rdp_status mr_rdp_sha256(
    const uint8_t *bytes,
    size_t length,
    uint8_t digest[MR_RDP_SHA256_BYTES]);

typedef struct mr_rdp_backend_clipboard_probe {
    uint64_t probe_id;
    const uint8_t *utf16le_bytes;
    size_t utf16le_byte_count;
    uint8_t payload_sha256[MR_RDP_SHA256_BYTES];
} mr_rdp_backend_clipboard_probe;

typedef struct mr_rdp_owned_config {
    uint64_t generation;
    char *hostname;
    size_t hostname_length;
    uint16_t port;
    uint32_t certificate_timeout_ms;
    uint32_t desktop_width;
    uint32_t desktop_height;
    char *username;
    size_t username_length;
    char *domain;
    size_t domain_length;
    char *password;
    size_t password_length;
    mr_rdp_keyboard_profile keyboard_profile;
    mr_rdp_channel_flags channel_flags;
    uint32_t desktop_scale_factor;
    uint32_t device_scale_factor;
} mr_rdp_owned_config;

typedef struct mr_rdp_backend_clipboard_offer {
    uint64_t offer_id;
    const uint8_t *utf16le_bytes;
    size_t utf16le_byte_count;
} mr_rdp_backend_clipboard_offer;

typedef struct mr_rdp_backend_host {
    void *context;
    mr_rdp_status (*present_certificate)(
        void *context,
        const mr_rdp_der_blob *chain,
        size_t chain_count);
    mr_rdp_status (*connected)(void *context);
    mr_rdp_status (*present_frame)(
        void *context,
        const mr_rdp_desktop_frame *frame);
    mr_rdp_status (*channel_event)(
        void *context,
        mr_rdp_channel_kind channel,
        mr_rdp_channel_transition transition);
    mr_rdp_status (*clipboard_probe_event)(
        void *context,
        const mr_rdp_backend_clipboard_probe *probe,
        mr_rdp_clipboard_probe_stage stage,
        mr_rdp_status status);
    mr_rdp_status (*display_resize_event)(
        void *context,
        const mr_rdp_display_resize_request *request,
        mr_rdp_status status);
    /* ABI 2. Each validates its input before reaching the application. */
    mr_rdp_status (*cursor_event)(
        void *context,
        const mr_rdp_cursor_event *event);
    mr_rdp_status (*audio_packet)(
        void *context,
        const mr_rdp_audio_packet *packet);
    mr_rdp_status (*clipboard_remote_formats)(
        void *context,
        int has_text);
    mr_rdp_status (*clipboard_offer_event)(
        void *context,
        uint64_t offer_id,
        mr_rdp_clipboard_offer_stage stage,
        mr_rdp_status status);
    mr_rdp_status (*clipboard_text)(
        void *context,
        uint64_t request_id,
        mr_rdp_status status,
        const uint8_t *utf16le_bytes,
        size_t utf16le_byte_count);
} mr_rdp_backend_host;

typedef struct mr_rdp_backend_vtable {
    /* run owns backend protocol work on the session worker. Other functions
     * are thread-safe and must not call application callbacks. Clipboard
     * payloads must be copied before start_clipboard_probe returns. Telemetry
     * is delivered later from run through the host callbacks. request_stop
     * must only signal/wake and must be idempotent at the backend level too. */
    mr_rdp_status (*run)(mr_rdp_backend *backend);
    void (*request_stop)(mr_rdp_backend *backend);
    mr_rdp_status (*send_key)(mr_rdp_backend *backend, const mr_rdp_key_event *event);
    mr_rdp_status (*send_pointer)(mr_rdp_backend *backend, const mr_rdp_pointer_event *event);
    mr_rdp_status (*start_clipboard_probe)(
        mr_rdp_backend *backend,
        const mr_rdp_backend_clipboard_probe *probe);
    mr_rdp_status (*request_display_resize)(
        mr_rdp_backend *backend,
        const mr_rdp_display_resize_request *request);
    /* ABI 2. offer_clipboard_text must copy the payload before returning. */
    mr_rdp_status (*send_unicode)(
        mr_rdp_backend *backend,
        const mr_rdp_unicode_event *event);
    void (*set_audio_focused)(mr_rdp_backend *backend, int focused);
    mr_rdp_status (*offer_clipboard_text)(
        mr_rdp_backend *backend,
        const mr_rdp_backend_clipboard_offer *offer);
    mr_rdp_status (*request_clipboard_text)(
        mr_rdp_backend *backend,
        uint64_t request_id);
    void (*destroy)(mr_rdp_backend *backend);
} mr_rdp_backend_vtable;

struct mr_rdp_backend {
    const mr_rdp_backend_vtable *vtable;
    /* Backend-specific failure detail for the last run, reported as the error
     * event's native_code. Zero means "no detail". Only run writes it, and the
     * session reads it on that same thread after run returns, so it needs no
     * lock of its own. */
    int32_t last_native_error;
};

typedef mr_rdp_status (*mr_rdp_backend_factory)(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend);

mr_rdp_status mr_rdp_session_create_internal(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    mr_rdp_backend_factory factory,
    const void *factory_context,
    mr_rdp_session **out_session);

mr_rdp_status mr_rdp_backend_create_default(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend);

#endif
