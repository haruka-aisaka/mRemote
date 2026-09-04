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
} mr_rdp_owned_config;

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
    void (*destroy)(mr_rdp_backend *backend);
} mr_rdp_backend_vtable;

struct mr_rdp_backend {
    const mr_rdp_backend_vtable *vtable;
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
