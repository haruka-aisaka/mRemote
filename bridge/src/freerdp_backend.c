#include "bridge_internal.h"
#include "certificate_chain.h"
#include "control_deadline.h"
#include "input_command_queue.h"

#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/codec/color.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/locale/keyboard.h>
#include <freerdp/settings.h>

#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MR_FREERDP_PROTOCOL_HYBRID 0x00000002u
#define MR_FREERDP_CLIPBOARD_PROBE_TIMEOUT_MS 10000u
#define MR_FREERDP_COMMAND_BATCH_LIMIT 64u

typedef struct mr_freerdp_backend mr_freerdp_backend;

typedef struct mr_freerdp_clipboard_probe {
    mr_rdp_backend_clipboard_probe descriptor;
    uint8_t *bytes;
} mr_freerdp_clipboard_probe;

typedef struct mr_freerdp_context {
    rdpClientContext common;
    mr_freerdp_backend *backend;
} mr_freerdp_context;

struct mr_freerdp_backend {
    mr_rdp_backend base;
    pthread_mutex_t mutex;
    int mutex_initialized;
    mr_rdp_backend_host host;
    rdpContext *context;
    freerdp *instance;
    HANDLE command_event;
    char *expected_hostname;
    uint16_t expected_port;
    uint64_t generation;

    mr_input_command_queue command_queue;
    CliprdrClientContext *cliprdr;
    int cliprdr_ready;
    DispClientContext *disp;
    mr_freerdp_clipboard_probe *pending_clipboard_probe;
    mr_freerdp_clipboard_probe *active_clipboard_probe;
    mr_control_deadline clipboard_probe_deadline;
    int clipboard_probe_timed_out;
    mr_rdp_display_resize_request pending_display_resize;
    int display_resize_pending;
    int stop_requested;
    int accepting_input;
    int gdi_initialized;
    int channels_subscribed;
    mr_rdp_status callback_status;
    mr_rdp_status input_failure_status;
    uint64_t surface_generation;
    uint64_t frame_id;
};

static mr_freerdp_backend *mr_freerdp_backend_from_instance(freerdp *instance)
{
    mr_freerdp_context *context;
    if (instance == NULL || instance->context == NULL) {
        return NULL;
    }
    context = (mr_freerdp_context *)instance->context;
    return context->backend;
}

static int mr_freerdp_is_stopped(mr_freerdp_backend *backend)
{
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    (void)pthread_mutex_unlock(&backend->mutex);
    return stopped;
}

static void mr_freerdp_record_status(
    mr_freerdp_backend *backend,
    mr_rdp_status status)
{
    if (status == MR_RDP_STATUS_OK) {
        return;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->callback_status == MR_RDP_STATUS_OK) {
        backend->callback_status = status;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
}

static mr_rdp_status mr_freerdp_current_status(mr_freerdp_backend *backend)
{
    mr_rdp_status status;
    (void)pthread_mutex_lock(&backend->mutex);
    status = backend->input_failure_status != MR_RDP_STATUS_OK
        ? backend->input_failure_status
        : backend->callback_status;
    (void)pthread_mutex_unlock(&backend->mutex);
    return status;
}

static void mr_freerdp_clipboard_probe_destroy(
    mr_freerdp_clipboard_probe *probe)
{
    if (probe == NULL) {
        return;
    }
    if (probe->bytes != NULL) {
        SecureZeroMemory(probe->bytes, probe->descriptor.utf16le_byte_count);
        free(probe->bytes);
    }
    SecureZeroMemory(probe, sizeof(*probe));
    free(probe);
}

static mr_rdp_status mr_freerdp_emit_clipboard_probe_event(
    mr_freerdp_backend *backend,
    const mr_freerdp_clipboard_probe *probe,
    mr_rdp_clipboard_probe_stage stage,
    mr_rdp_status operation_status)
{
    mr_rdp_backend_clipboard_probe metadata;
    mr_rdp_status status;
    if (backend == NULL || probe == NULL ||
        backend->host.clipboard_probe_event == NULL) {
        return MR_RDP_ERROR_BACKEND;
    }
    metadata = probe->descriptor;
    /* Telemetry carries only identity, byte count, and digest. The copied
     * clipboard contents never cross back through the host callback. */
    metadata.utf16le_bytes = NULL;
    status = backend->host.clipboard_probe_event(
        backend->host.context, &metadata, stage, operation_status);
    SecureZeroMemory(&metadata, sizeof(metadata));
    if (status != MR_RDP_STATUS_OK) {
        mr_freerdp_record_status(backend, status);
    }
    return status;
}

static void mr_freerdp_arm_clipboard_probe_deadline_locked(
    mr_freerdp_backend *backend,
    mr_rdp_clipboard_probe_stage awaited_stage)
{
    mr_control_deadline_arm(
        &backend->clipboard_probe_deadline,
        GetTickCount64(),
        MR_FREERDP_CLIPBOARD_PROBE_TIMEOUT_MS,
        awaited_stage);
}

static DWORD mr_freerdp_clipboard_probe_wait_timeout(
    mr_freerdp_backend *backend)
{
    uint32_t timeout_ms;
    (void)pthread_mutex_lock(&backend->mutex);
    timeout_ms = mr_control_deadline_remaining_ms(
        &backend->clipboard_probe_deadline, GetTickCount64());
    (void)pthread_mutex_unlock(&backend->mutex);
    return (DWORD)timeout_ms;
}

static mr_rdp_status mr_freerdp_expire_clipboard_probe(
    mr_freerdp_backend *backend)
{
    mr_freerdp_clipboard_probe *probe = NULL;
    uint8_t awaited_stage = 0u;
    mr_rdp_status host_status;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->active_clipboard_probe == NULL) {
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else if (mr_control_deadline_take_expired(
                   &backend->clipboard_probe_deadline,
                   GetTickCount64(),
                   &awaited_stage)) {
        probe = backend->active_clipboard_probe;
        backend->active_clipboard_probe = NULL;
        /* CLIPRDR responses do not carry our probe id. A late response from
         * this timed-out offer could otherwise be misattributed to a later
         * probe, so retries require a fresh channel/session. */
        backend->clipboard_probe_timed_out = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    if (probe == NULL) {
        return MR_RDP_STATUS_OK;
    }
    host_status = mr_freerdp_emit_clipboard_probe_event(
        backend,
        probe,
        (mr_rdp_clipboard_probe_stage)awaited_stage,
        MR_RDP_ERROR_TIMEOUT);
    mr_freerdp_clipboard_probe_destroy(probe);
    return host_status;
}

static UINT mr_freerdp_cliprdr_monitor_ready(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_MONITOR_READY *monitor_ready)
{
    CLIPRDR_CAPABILITIES capabilities;
    CLIPRDR_GENERAL_CAPABILITY_SET general;
    if (cliprdr == NULL || monitor_ready == NULL ||
        cliprdr->custom == NULL || cliprdr->ClientCapabilities == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    memset(&capabilities, 0, sizeof(capabilities));
    memset(&general, 0, sizeof(general));
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1u;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    {
        const UINT status = cliprdr->ClientCapabilities(cliprdr, &capabilities);
        mr_freerdp_backend *backend =
            (mr_freerdp_backend *)cliprdr->custom;
        if (status == CHANNEL_RC_OK) {
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->cliprdr == cliprdr) {
                backend->cliprdr_ready = 1;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
        }
        return status;
    }
}

static UINT mr_freerdp_cliprdr_server_capabilities(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_CAPABILITIES *capabilities)
{
    if (cliprdr == NULL || capabilities == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    return CHANNEL_RC_OK;
}

static UINT mr_freerdp_cliprdr_server_format_list(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST *format_list)
{
    CLIPRDR_FORMAT_LIST_RESPONSE response;
    if (cliprdr == NULL || format_list == NULL || cliprdr->custom == NULL ||
        cliprdr->ClientFormatListResponse == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    return cliprdr->ClientFormatListResponse(cliprdr, &response);
}

static UINT mr_freerdp_cliprdr_server_format_list_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *probe;
    mr_rdp_status operation_status;
    mr_rdp_status host_status;
    if (cliprdr == NULL || response == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    probe = mr_control_deadline_is_armed_for(
                &backend->clipboard_probe_deadline,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE)
        ? backend->active_clipboard_probe
        : NULL;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (probe == NULL) {
        return CHANNEL_RC_OK;
    }
    operation_status = (response->common.msgFlags & CB_RESPONSE_OK) != 0u
        ? MR_RDP_STATUS_OK
        : MR_RDP_ERROR_BACKEND;
    host_status = mr_freerdp_emit_clipboard_probe_event(
        backend,
        probe,
        MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE,
        operation_status);
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->active_clipboard_probe != probe ||
        !mr_control_deadline_is_armed_for(
            &backend->clipboard_probe_deadline,
            MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE)) {
        probe = NULL;
    } else if (operation_status != MR_RDP_STATUS_OK ||
               host_status != MR_RDP_STATUS_OK) {
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else {
        mr_freerdp_arm_clipboard_probe_deadline_locked(
            backend, MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST);
        probe = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(probe);
    return host_status == MR_RDP_STATUS_OK
        ? CHANNEL_RC_OK
        : CHANNEL_RC_INITIALIZATION_ERROR;
}

static UINT mr_freerdp_cliprdr_server_format_data_request(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *probe;
    CLIPRDR_FORMAT_DATA_RESPONSE response;
    mr_rdp_status request_status;
    mr_rdp_status response_status;
    mr_rdp_status host_status = MR_RDP_STATUS_OK;
    UINT channel_status;
    if (cliprdr == NULL || request == NULL || cliprdr->custom == NULL ||
        cliprdr->ClientFormatDataResponse == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    probe = backend->active_clipboard_probe;
    if (probe != NULL && request->requestedFormatId == CF_UNICODETEXT &&
        mr_control_deadline_is_armed_for(
            &backend->clipboard_probe_deadline,
            MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST)) {
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else {
        probe = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (probe != NULL) {
        request_status = MR_RDP_STATUS_OK;
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)probe->descriptor.utf16le_byte_count;
        response.requestedFormatData = probe->bytes;
    } else {
        request_status = MR_RDP_ERROR_UNSUPPORTED;
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    if (probe != NULL) {
        host_status = mr_freerdp_emit_clipboard_probe_event(
            backend,
            probe,
            MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST,
            request_status);
    }
    channel_status = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    response_status = channel_status == CHANNEL_RC_OK
        ? MR_RDP_STATUS_OK
        : MR_RDP_ERROR_BACKEND;
    if (probe != NULL) {
        const mr_rdp_status final_host_status =
            mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT,
                response_status);
        if (host_status == MR_RDP_STATUS_OK) {
            host_status = final_host_status;
        }
    }
    mr_freerdp_clipboard_probe_destroy(probe);
    if (host_status != MR_RDP_STATUS_OK) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    return channel_status;
}

static int mr_freerdp_channel_kind_from_name(
    const char *name,
    mr_rdp_channel_kind *out_kind)
{
    if (name == NULL || out_kind == NULL) {
        return 0;
    }
    if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_CLIPRDR;
    } else if (strcmp(name, RDPSND_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPSND_DVC_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPSND_LOSSY_DVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPSND;
    } else if (strcmp(name, DRDYNVC_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_DRDYNVC;
    } else if (strcmp(name, DISP_DVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_DISP;
    } else if (strcmp(name, RDPGFX_DVC_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPGFX_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPGFX;
    } else {
        return 0;
    }
    return 1;
}

static void mr_freerdp_on_channel_connected(
    void *context,
    const ChannelConnectedEventArgs *event)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    mr_rdp_channel_kind kind;
    mr_rdp_status status;
    if (client_context == NULL || event == NULL || event->name == NULL ||
        client_context->backend == NULL) {
        return;
    }
    backend = client_context->backend;
    freerdp_client_OnChannelConnectedEventHandler(context, event);
    (void)pthread_mutex_lock(&backend->mutex);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        backend->cliprdr = (CliprdrClientContext *)event->pInterface;
        backend->cliprdr_ready = 0;
        backend->clipboard_probe_timed_out = 0;
        if (backend->cliprdr != NULL) {
            backend->cliprdr->custom = backend;
            backend->cliprdr->MonitorReady = mr_freerdp_cliprdr_monitor_ready;
            backend->cliprdr->ServerCapabilities =
                mr_freerdp_cliprdr_server_capabilities;
            backend->cliprdr->ServerFormatList =
                mr_freerdp_cliprdr_server_format_list;
            backend->cliprdr->ServerFormatListResponse =
                mr_freerdp_cliprdr_server_format_list_response;
            backend->cliprdr->ServerFormatDataRequest =
                mr_freerdp_cliprdr_server_format_data_request;
        }
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        backend->disp = (DispClientContext *)event->pInterface;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (mr_freerdp_channel_kind_from_name(event->name, &kind)) {
        status = backend->host.channel_event(
            backend->host.context, kind, MR_RDP_CHANNEL_CONNECTED);
        mr_freerdp_record_status(backend, status);
        if (status != MR_RDP_STATUS_OK && backend->context != NULL) {
            (void)freerdp_abort_connect_context(backend->context);
        }
    }
}

static void mr_freerdp_on_channel_disconnected(
    void *context,
    const ChannelDisconnectedEventArgs *event)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *pending_probe = NULL;
    mr_freerdp_clipboard_probe *active_probe = NULL;
    mr_rdp_channel_kind kind;
    mr_rdp_status status;
    if (client_context == NULL || event == NULL || event->name == NULL ||
        client_context->backend == NULL) {
        return;
    }
    backend = client_context->backend;
    (void)pthread_mutex_lock(&backend->mutex);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (backend->cliprdr == (CliprdrClientContext *)event->pInterface &&
            backend->cliprdr != NULL) {
            backend->cliprdr->custom = NULL;
            backend->cliprdr = NULL;
        }
        backend->cliprdr_ready = 0;
        pending_probe = backend->pending_clipboard_probe;
        active_probe = backend->active_clipboard_probe;
        backend->pending_clipboard_probe = NULL;
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
        backend->clipboard_probe_timed_out = 0;
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        if (backend->disp == (DispClientContext *)event->pInterface) {
            backend->disp = NULL;
        }
        backend->display_resize_pending = 0;
        memset(&backend->pending_display_resize, 0,
               sizeof(backend->pending_display_resize));
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(pending_probe);
    mr_freerdp_clipboard_probe_destroy(active_probe);
    freerdp_client_OnChannelDisconnectedEventHandler(context, event);
    if (mr_freerdp_channel_kind_from_name(event->name, &kind)) {
        status = backend->host.channel_event(
            backend->host.context, kind, MR_RDP_CHANNEL_DISCONNECTED);
        mr_freerdp_record_status(backend, status);
        if (status != MR_RDP_STATUS_OK && backend->context != NULL) {
            (void)freerdp_abort_connect_context(backend->context);
        }
    }
}

static void mr_freerdp_clear_password(rdpSettings *settings)
{
    if (settings != NULL) {
        /* Pinned FreeRDP 3.31.1's generated setter clears the previous
         * allocation with memset(strlen) before freeing it. The bridge rejects
         * embedded NUL bytes, so this covers the complete credential span. */
        (void)freerdp_settings_set_string(settings, FreeRDP_Password, NULL);
    }
}

static int mr_freerdp_verify_x509_certificate(
    freerdp *instance,
    const BYTE *pem,
    size_t pem_length,
    const char *hostname,
    UINT16 port,
    DWORD flags)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 0u;
    mr_rdp_status status;

    if (backend == NULL) {
        return -1;
    }
    if ((flags & (VERIFY_CERT_FLAG_GATEWAY | VERIFY_CERT_FLAG_REDIRECT)) != 0u ||
        hostname == NULL || strcmp(hostname, backend->expected_hostname) != 0 ||
        port != backend->expected_port) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
        return -1;
    }
    status = mr_rdp_certificate_chain_from_pem(
        pem, pem_length, chain, &chain_count);
    if (status == MR_RDP_STATUS_OK) {
        status = backend->host.present_certificate(
            backend->host.context, chain, chain_count);
    }
    mr_rdp_certificate_chain_free(chain, chain_count);
    if (status == MR_RDP_STATUS_OK) {
        /* Platform trust/pin persistence is owned by the app. Never ask
         * FreeRDP to store a parallel known-hosts decision. */
        return 2;
    }
    mr_freerdp_record_status(backend, status);
    if (status == MR_RDP_ERROR_CERTIFICATE_REJECTED ||
        status == MR_RDP_ERROR_TIMEOUT) {
        return 0;
    }
    return -1;
}

static int mr_freerdp_clip_region(
    const GDI_RGN *source,
    uint32_t frame_width,
    uint32_t frame_height,
    mr_rdp_rect *out_rect)
{
    int64_t left;
    int64_t top;
    int64_t right;
    int64_t bottom;

    if (source == NULL || out_rect == NULL || source->null ||
        source->w <= 0 || source->h <= 0) {
        return 0;
    }
    left = source->x;
    top = source->y;
    right = left + (int64_t)source->w;
    bottom = top + (int64_t)source->h;
    if (left < 0) {
        left = 0;
    }
    if (top < 0) {
        top = 0;
    }
    if (right > (int64_t)frame_width) {
        right = (int64_t)frame_width;
    }
    if (bottom > (int64_t)frame_height) {
        bottom = (int64_t)frame_height;
    }
    if (right <= left || bottom <= top || left >= (int64_t)frame_width ||
        top >= (int64_t)frame_height) {
        return 0;
    }
    out_rect->x = (uint32_t)left;
    out_rect->y = (uint32_t)top;
    out_rect->width = (uint32_t)(right - left);
    out_rect->height = (uint32_t)(bottom - top);
    return 1;
}

static BOOL mr_freerdp_present_gdi_frame(
    mr_freerdp_backend *backend,
    const mr_rdp_rect *dirty_rects,
    size_t dirty_rect_count)
{
    rdpGdi *gdi;
    mr_rdp_desktop_frame frame;
    size_t length;
    mr_rdp_status status;

    if (backend == NULL || backend->context == NULL ||
        dirty_rects == NULL || dirty_rect_count == 0u) {
        return FALSE;
    }
    gdi = backend->context->gdi;
    if (gdi == NULL || gdi->primary_buffer == NULL ||
        gdi->dstFormat != PIXEL_FORMAT_BGRA32 || gdi->width <= 0 ||
        gdi->height <= 0 || (uint32_t)gdi->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        (uint32_t)gdi->height > MR_RDP_MAX_DESKTOP_DIMENSION ||
        gdi->stride < (uint32_t)gdi->width * 4u ||
        (size_t)gdi->stride > SIZE_MAX / (size_t)gdi->height) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_INVALID_DATA);
        return FALSE;
    }
    length = (size_t)gdi->stride * (size_t)gdi->height;
    if (length > MR_RDP_MAX_DESKTOP_FRAME_BYTES) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    ++backend->frame_id;
    if (backend->frame_id == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    memset(&frame, 0, sizeof(frame));
    frame.struct_size = (uint32_t)sizeof(frame);
    frame.generation = backend->generation;
    frame.surface_generation = backend->surface_generation;
    frame.frame_id = backend->frame_id;
    frame.width = (uint32_t)gdi->width;
    frame.height = (uint32_t)gdi->height;
    frame.stride = gdi->stride;
    frame.bytes = gdi->primary_buffer;
    frame.length = length;
    frame.dirty_rects = dirty_rects;
    frame.dirty_rect_count = dirty_rect_count;
    status = backend->host.present_frame(backend->host.context, &frame);
    if (status != MR_RDP_STATUS_OK) {
        mr_freerdp_record_status(backend, status);
        return FALSE;
    }
    return TRUE;
}

static BOOL mr_freerdp_begin_paint(rdpContext *context)
{
    HGDI_WND window;
    if (context == NULL || context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL) {
        return FALSE;
    }
    window = context->gdi->primary->hdc->hwnd;
    if (window != NULL) {
        if (window->invalid != NULL) {
            window->invalid->null = TRUE;
        }
        window->ninvalid = 0;
    }
    return TRUE;
}

static BOOL mr_freerdp_end_paint(rdpContext *context)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    rdpGdi *gdi;
    HGDI_WND window;
    mr_rdp_rect dirty_rects[MR_RDP_MAX_DESKTOP_DIRTY_RECTS];
    size_t dirty_count = 0u;
    int index;

    if (client_context == NULL || client_context->backend == NULL ||
        context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL) {
        return FALSE;
    }
    backend = client_context->backend;
    gdi = context->gdi;
    window = gdi->primary->hdc->hwnd;
    if (window == NULL || window->invalid == NULL || window->invalid->null) {
        return TRUE;
    }

    if (window->ninvalid > 0 && window->cinvalid != NULL &&
        (size_t)window->ninvalid <= MR_RDP_MAX_DESKTOP_DIRTY_RECTS) {
        for (index = 0; index < window->ninvalid; ++index) {
            if (mr_freerdp_clip_region(
                    &window->cinvalid[index],
                    (uint32_t)gdi->width,
                    (uint32_t)gdi->height,
                    &dirty_rects[dirty_count])) {
                ++dirty_count;
            }
        }
    } else if (mr_freerdp_clip_region(
                   window->invalid,
                   (uint32_t)gdi->width,
                   (uint32_t)gdi->height,
                   &dirty_rects[0])) {
        dirty_count = 1u;
    }
    if (dirty_count == 0u) {
        return TRUE;
    }
    return mr_freerdp_present_gdi_frame(backend, dirty_rects, dirty_count);
}

static BOOL mr_freerdp_desktop_resize(rdpContext *context)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    uint32_t width;
    uint32_t height;
    mr_rdp_rect full;

    if (client_context == NULL || client_context->backend == NULL ||
        context->settings == NULL || context->gdi == NULL) {
        return FALSE;
    }
    backend = client_context->backend;
    width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    if (!gdi_resize(context->gdi, width, height)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }
    ++backend->surface_generation;
    if (backend->surface_generation == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    full = (mr_rdp_rect){ 0u, 0u, width, height };
    return mr_freerdp_present_gdi_frame(backend, &full, 1u);
}

static BOOL mr_freerdp_pre_connect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    rdpSettings *settings;
    const char *rdpsnd[] = { "rdpsnd", "sys:ios" };

    if (backend == NULL || instance->context == NULL ||
        instance->context->settings == NULL || mr_freerdp_is_stopped(backend)) {
        if (backend != NULL) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        }
        return FALSE;
    }
    settings = instance->context->settings;
    /* Schedule rdpsnd with explicit iOS arguments before the common add-in
     * loader runs. In FreeRDP 3.31.1 client/common/cmdline.c, both
     * freerdp_client_add_*_channel functions return at the duplicate-name
     * lookup before allocating a replacement ADDIN_ARGV. The loader's later
     * one-argument registrations therefore preserve this sys:ios selection.
     * Register both forms because the server may negotiate the SVC or DVC.
     * The loader also enables RDPDR for rdpsnd and loads cliprdr/drdynvc plus
     * the requested DVCs. AudioPlayback must be true for that path. */
    if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) ||
        !freerdp_client_add_static_channel(
            settings, sizeof(rdpsnd) / sizeof(rdpsnd[0]), rdpsnd) ||
        !freerdp_client_add_dynamic_channel(
            settings, sizeof(rdpsnd) / sizeof(rdpsnd[0]), rdpsnd)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }

    if (!backend->channels_subscribed) {
        if (PubSub_SubscribeChannelConnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_connected) < 0) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
            return FALSE;
        }
        if (PubSub_SubscribeChannelDisconnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_disconnected) < 0) {
            PubSub_UnsubscribeChannelConnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_connected);
            mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
            return FALSE;
        }
        backend->channels_subscribed = 1;
    }
    if (mr_freerdp_is_stopped(backend)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        return FALSE;
    }
    return TRUE;
}

static BOOL mr_freerdp_post_connect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    rdpContext *context;
    uint32_t width;
    uint32_t height;
    mr_rdp_status status;

    if (backend == NULL || instance->context == NULL ||
        instance->context->settings == NULL || instance->context->update == NULL ||
        mr_freerdp_is_stopped(backend)) {
        if (backend != NULL) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        }
        return FALSE;
    }
    context = instance->context;
    /* PostConnect is reached only after authentication. This adapter does not
     * support automatic reconnect, so retaining FreeRDP's credential copy for
     * the rest of the desktop session serves no purpose. */
    mr_freerdp_clear_password(context->settings);
    /* PROTOCOL_HYBRID is deliberately adapter-local: protocol constants are
     * internal in pinned FreeRDP 3.31.1. NLA uses TLS as its transport, but a
     * server selecting TLS-only, classic RDP, HYBRID_EX, RDSTLS, or AAD must
     * never reach GDI/input activation. */
    if (freerdp_settings_get_uint32(
            context->settings, FreeRDP_SelectedProtocol) !=
        MR_FREERDP_PROTOCOL_HYBRID) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
        return FALSE;
    }
    width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }
    backend->gdi_initialized = 1;
    ++backend->surface_generation;
    if (backend->surface_generation == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    context->update->BeginPaint = mr_freerdp_begin_paint;
    context->update->EndPaint = mr_freerdp_end_paint;
    context->update->DesktopResize = mr_freerdp_desktop_resize;

    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = !backend->stop_requested;
    (void)pthread_mutex_unlock(&backend->mutex);
    status = backend->host.connected(backend->host.context);
    if (status != MR_RDP_STATUS_OK) {
        (void)pthread_mutex_lock(&backend->mutex);
        backend->accepting_input = 0;
        (void)pthread_mutex_unlock(&backend->mutex);
        mr_freerdp_record_status(backend, status);
        return FALSE;
    }
    return TRUE;
}

static void mr_freerdp_post_disconnect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    mr_freerdp_clipboard_probe *pending_probe;
    mr_freerdp_clipboard_probe *active_probe;
    if (backend == NULL || instance->context == NULL) {
        return;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = 0;
    mr_input_command_queue_reset(&backend->command_queue);
    if (backend->cliprdr != NULL) {
        backend->cliprdr->custom = NULL;
    }
    backend->cliprdr = NULL;
    backend->cliprdr_ready = 0;
    backend->disp = NULL;
    pending_probe = backend->pending_clipboard_probe;
    active_probe = backend->active_clipboard_probe;
    backend->pending_clipboard_probe = NULL;
    backend->active_clipboard_probe = NULL;
    mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    backend->clipboard_probe_timed_out = 0;
    backend->display_resize_pending = 0;
    memset(&backend->pending_display_resize, 0,
           sizeof(backend->pending_display_resize));
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(pending_probe);
    mr_freerdp_clipboard_probe_destroy(active_probe);
    if (backend->channels_subscribed) {
        PubSub_UnsubscribeChannelConnected(
            instance->context->pubSub,
            mr_freerdp_on_channel_connected);
        PubSub_UnsubscribeChannelDisconnected(
            instance->context->pubSub,
            mr_freerdp_on_channel_disconnected);
        backend->channels_subscribed = 0;
    }
    if (backend->gdi_initialized) {
        gdi_free(instance);
        backend->gdi_initialized = 0;
    }
}

static BOOL mr_freerdp_send_key_command(
    mr_freerdp_backend *backend,
    const mr_rdp_key_event *event)
{
    UINT16 flags = 0u;
    rdpInput *input;
    if (backend->context == NULL || backend->context->input == NULL) {
        return FALSE;
    }
    input = backend->context->input;
    if (event->action == MR_RDP_KEY_UP) {
        flags |= KBD_FLAGS_RELEASE;
    }
    if (event->extended != 0u) {
        flags |= KBD_FLAGS_EXTENDED;
    }
    if (event->extended1 != 0u) {
        flags |= KBD_FLAGS_EXTENDED1;
    }
    /* Do not use freerdp_input_send_keyboard_event_ex: the 3.31.1 helper
     * derives EXTENDED but cannot preserve an explicit EXTENDED1 selector. */
    return freerdp_input_send_keyboard_event(input, flags, (UINT8)event->code);
}

static BOOL mr_freerdp_send_wheel_axis(
    rdpInput *input,
    UINT16 axis_flag,
    int32_t value,
    UINT16 x,
    UINT16 y)
{
    uint64_t remaining;
    int negative;
    if (value == 0) {
        return TRUE;
    }
    negative = value < 0;
    remaining = negative
        ? (uint64_t)(-(int64_t)value)
        : (uint64_t)value;
    while (remaining > 0u) {
        const UINT16 magnitude = remaining > 0xffu
            ? 0xffu
            : (UINT16)remaining;
        UINT16 encoded = magnitude;
        UINT16 flags = axis_flag;
        if (negative) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
            encoded = (UINT16)(0x100u - magnitude);
        }
        if (!freerdp_input_send_mouse_event(input, (UINT16)(flags | encoded), x, y)) {
            return FALSE;
        }
        remaining -= magnitude;
    }
    return TRUE;
}

static BOOL mr_freerdp_send_pointer_command(
    mr_freerdp_backend *backend,
    const mr_rdp_pointer_event *event)
{
    rdpInput *input;
    UINT16 flags;
    UINT16 x;
    UINT16 y;
    if (backend->context == NULL || backend->context->input == NULL ||
        event->x > UINT16_MAX || event->y > UINT16_MAX) {
        return FALSE;
    }
    input = backend->context->input;
    x = (UINT16)event->x;
    y = (UINT16)event->y;
    if (event->kind == MR_RDP_POINTER_MOVE) {
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
    }
    if (event->kind == MR_RDP_POINTER_BUTTON) {
        switch (event->button) {
            case MR_RDP_POINTER_BUTTON_LEFT:
                flags = PTR_FLAGS_BUTTON1;
                break;
            case MR_RDP_POINTER_BUTTON_RIGHT:
                flags = PTR_FLAGS_BUTTON2;
                break;
            case MR_RDP_POINTER_BUTTON_MIDDLE:
                flags = PTR_FLAGS_BUTTON3;
                break;
            default:
                return FALSE;
        }
        if (event->action == MR_RDP_KEY_DOWN) {
            flags |= PTR_FLAGS_DOWN;
        }
        return freerdp_input_send_mouse_event(input, flags, x, y);
    }
    if (!mr_freerdp_send_wheel_axis(
            input, PTR_FLAGS_WHEEL, event->wheel_y, x, y)) {
        return FALSE;
    }
    return mr_freerdp_send_wheel_axis(
        input, PTR_FLAGS_HWHEEL, event->wheel_x, x, y);
}

static mr_rdp_status mr_freerdp_process_control_command(
    mr_freerdp_backend *backend,
    int *out_processed)
{
    mr_freerdp_clipboard_probe *probe = NULL;
    mr_rdp_display_resize_request resize_request;
    CliprdrClientContext *cliprdr = NULL;
    DispClientContext *disp = NULL;
    int process_resize = 0;
    mr_rdp_status gate_status = MR_RDP_STATUS_OK;
    mr_rdp_status operation_status;
    mr_rdp_status host_status;
    UINT channel_status;

    *out_processed = 0;
    memset(&resize_request, 0, sizeof(resize_request));
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        gate_status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        gate_status = backend->input_failure_status;
    } else if (backend->pending_clipboard_probe != NULL) {
        probe = backend->pending_clipboard_probe;
        backend->pending_clipboard_probe = NULL;
        cliprdr = backend->cliprdr_ready ? backend->cliprdr : NULL;
        if (cliprdr != NULL && backend->active_clipboard_probe == NULL) {
            backend->active_clipboard_probe = probe;
            mr_freerdp_arm_clipboard_probe_deadline_locked(
                backend, MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE);
        } else {
            cliprdr = NULL;
        }
        *out_processed = 1;
    } else if (backend->display_resize_pending) {
        resize_request = backend->pending_display_resize;
        memset(&backend->pending_display_resize, 0,
               sizeof(backend->pending_display_resize));
        backend->display_resize_pending = 0;
        disp = backend->disp;
        process_resize = 1;
        *out_processed = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (gate_status != MR_RDP_STATUS_OK) {
        return gate_status;
    }

    if (probe != NULL) {
        CLIPRDR_FORMAT format;
        CLIPRDR_FORMAT_LIST format_list;
        if (cliprdr == NULL) {
            operation_status = MR_RDP_ERROR_INVALID_STATE;
            host_status = mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT,
                operation_status);
        } else {
            memset(&format, 0, sizeof(format));
            memset(&format_list, 0, sizeof(format_list));
            format.formatId = CF_UNICODETEXT;
            format_list.common.msgType = CB_FORMAT_LIST;
            format_list.numFormats = 1u;
            format_list.formats = &format;
            channel_status = cliprdr->ClientFormatList == NULL
                ? CHANNEL_RC_INITIALIZATION_ERROR
                : cliprdr->ClientFormatList(cliprdr, &format_list);
            operation_status = channel_status == CHANNEL_RC_OK
                ? MR_RDP_STATUS_OK
                : MR_RDP_ERROR_BACKEND;
            host_status = mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT,
                operation_status);
        }
        if (operation_status != MR_RDP_STATUS_OK ||
            host_status != MR_RDP_STATUS_OK) {
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->active_clipboard_probe == probe) {
                backend->active_clipboard_probe = NULL;
                mr_control_deadline_reset(&backend->clipboard_probe_deadline);
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_clipboard_probe_destroy(probe);
        }
        return host_status;
    }

    if (process_resize) {
        DISPLAY_CONTROL_MONITOR_LAYOUT layout;
        memset(&layout, 0, sizeof(layout));
        layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        layout.Width = resize_request.width;
        layout.Height = resize_request.height;
        if (backend->context != NULL && backend->context->settings != NULL) {
            layout.Orientation = freerdp_settings_get_uint16(
                backend->context->settings, FreeRDP_DesktopOrientation);
            layout.DesktopScaleFactor = freerdp_settings_get_uint32(
                backend->context->settings, FreeRDP_DesktopScaleFactor);
            layout.DeviceScaleFactor = freerdp_settings_get_uint32(
                backend->context->settings, FreeRDP_DeviceScaleFactor);
        }
        channel_status = disp == NULL || disp->SendMonitorLayout == NULL
            ? CHANNEL_RC_NOT_CONNECTED
            : disp->SendMonitorLayout(disp, 1u, &layout);
        operation_status = channel_status == CHANNEL_RC_OK
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_BACKEND;
        host_status = backend->host.display_resize_event(
            backend->host.context, &resize_request, operation_status);
        if (host_status != MR_RDP_STATUS_OK) {
            mr_freerdp_record_status(backend, host_status);
        }
        return host_status;
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_freerdp_enqueue_command(
    mr_freerdp_backend *backend,
    const mr_input_command *command)
{
    mr_input_enqueue_result result;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (!backend->accepting_input) {
        status = backend->input_failure_status != MR_RDP_STATUS_OK
            ? backend->input_failure_status
            : MR_RDP_ERROR_INVALID_STATE;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        result = mr_input_command_queue_enqueue(
            &backend->command_queue, command);
        if (result == MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW ||
            result == MR_INPUT_ENQUEUE_INVALID) {
            status = result == MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW
                ? MR_RDP_ERROR_LIMIT_EXCEEDED
                : MR_RDP_ERROR_BACKEND;
            backend->input_failure_status = status;
            backend->accepting_input = 0;
            mr_input_command_queue_reset(&backend->command_queue);
            context_to_abort = backend->context;
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    return status;
}

static int mr_freerdp_dequeue_command(
    mr_freerdp_backend *backend,
    mr_input_command *out_command,
    mr_rdp_status *out_status)
{
    int has_command = 0;
    (void)pthread_mutex_lock(&backend->mutex);
    *out_status = MR_RDP_STATUS_OK;
    if (backend->stop_requested) {
        *out_status = MR_RDP_ERROR_STOPPED;
        mr_input_command_queue_reset(&backend->command_queue);
        (void)ResetEvent(backend->command_event);
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        *out_status = backend->input_failure_status;
        mr_input_command_queue_reset(&backend->command_queue);
        (void)ResetEvent(backend->command_event);
    } else if (mr_input_command_queue_dequeue(
                   &backend->command_queue, out_command)) {
        has_command = 1;
        if (mr_input_command_queue_count(&backend->command_queue) == 0u &&
            backend->pending_clipboard_probe == NULL &&
            !backend->display_resize_pending) {
            (void)ResetEvent(backend->command_event);
        }
    } else {
        if (backend->pending_clipboard_probe == NULL &&
            !backend->display_resize_pending) {
            (void)ResetEvent(backend->command_event);
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return has_command;
}

static mr_rdp_status mr_freerdp_drain_commands(mr_freerdp_backend *backend)
{
    size_t commands_processed = 0u;
    for (;;) {
        mr_input_command command;
        mr_rdp_status dequeue_status;
        mr_rdp_status control_status;
        int processed_control;
        BOOL sent;
        control_status = mr_freerdp_process_control_command(
            backend, &processed_control);
        if (control_status != MR_RDP_STATUS_OK) {
            return control_status;
        }
        if (processed_control) {
            continue;
        }
        if (!mr_freerdp_dequeue_command(
                backend, &command, &dequeue_status)) {
            return dequeue_status;
        }
        if (command.kind == MR_INPUT_COMMAND_KEY) {
            sent = mr_freerdp_send_key_command(backend, &command.value.key);
        } else if (command.kind == MR_INPUT_COMMAND_POINTER) {
            sent = mr_freerdp_send_pointer_command(backend, &command.value.pointer);
        } else {
            sent = FALSE;
        }
        if (!sent) {
            return MR_RDP_ERROR_BACKEND;
        }
        ++commands_processed;
        if (commands_processed >= MR_FREERDP_COMMAND_BATCH_LIMIT) {
            /* Leave command_event signaled while work remains. Returning to
             * the outer loop gives FreeRDP handles and control deadlines a
             * bounded chance to run under sustained input. */
            return MR_RDP_STATUS_OK;
        }
    }
}

static mr_rdp_status mr_freerdp_run(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    BOOL connected;

    base->last_native_error = 0;
    if (mr_freerdp_is_stopped(backend)) {
        return MR_RDP_ERROR_STOPPED;
    }
    connected = freerdp_connect(backend->instance);
    if (!connected) {
        status = mr_freerdp_current_status(backend);
        /* Without this the app only sees MR_RDP_ERROR_BACKEND and cannot tell
         * a refused socket from a logon failure. FreeRDP's own connect error
         * survives freerdp_connect returning FALSE. */
        base->last_native_error = (int32_t)freerdp_get_last_error(backend->context);
        if (mr_freerdp_is_stopped(backend)) {
            status = MR_RDP_ERROR_STOPPED;
        } else if (status == MR_RDP_STATUS_OK) {
            status = MR_RDP_ERROR_BACKEND;
        }
        goto cleanup;
    }

    while (!freerdp_shall_disconnect_context(backend->context)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD handle_count;
        DWORD wait_status;
        DWORD wait_timeout;

        if (mr_freerdp_is_stopped(backend)) {
            status = MR_RDP_ERROR_STOPPED;
            break;
        }
        status = mr_freerdp_expire_clipboard_probe(backend);
        if (status != MR_RDP_STATUS_OK) {
            break;
        }
        memset(handles, 0, sizeof(handles));
        handle_count = freerdp_get_event_handles(
            backend->context, handles, MAXIMUM_WAIT_OBJECTS - 1u);
        if (handle_count == 0u || handle_count >= MAXIMUM_WAIT_OBJECTS) {
            status = MR_RDP_ERROR_BACKEND;
            break;
        }
        handles[handle_count++] = backend->command_event;
        wait_timeout = mr_freerdp_clipboard_probe_wait_timeout(backend);
        wait_status = WaitForMultipleObjects(
            handle_count, handles, FALSE, wait_timeout);
        if (wait_status == WAIT_FAILED) {
            status = MR_RDP_ERROR_BACKEND;
            break;
        }
        if (wait_status == WAIT_TIMEOUT) {
            status = mr_freerdp_expire_clipboard_probe(backend);
            if (status != MR_RDP_STATUS_OK) {
                break;
            }
            continue;
        }

        status = mr_freerdp_drain_commands(backend);
        if (status != MR_RDP_STATUS_OK) {
            break;
        }
        if (!freerdp_check_event_handles(backend->context)) {
            status = mr_freerdp_current_status(backend);
            if (status == MR_RDP_STATUS_OK) {
                status = MR_RDP_ERROR_BACKEND;
            }
            break;
        }
    }

    if (status == MR_RDP_STATUS_OK) {
        status = mr_freerdp_current_status(backend);
    }
    if (status != MR_RDP_STATUS_OK) {
        base->last_native_error = (int32_t)freerdp_get_last_error(backend->context);
    }
    if (mr_freerdp_is_stopped(backend)) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (status == MR_RDP_STATUS_OK) {
        status = MR_RDP_ERROR_BACKEND;
    }

cleanup:
    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = 0;
    (void)pthread_mutex_unlock(&backend->mutex);
    /* FreeRDP 3.31.1 already disconnects internally when connect fails. */
    if (connected) {
        (void)freerdp_disconnect(backend->instance);
    }
    mr_freerdp_clear_password(backend->context->settings);
    return status;
}

static void mr_freerdp_request_stop(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    rdpContext *context;
    (void)pthread_mutex_lock(&backend->mutex);
    backend->stop_requested = 1;
    backend->accepting_input = 0;
    context = backend->context;
    if (backend->command_event != NULL) {
        (void)SetEvent(backend->command_event);
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context != NULL) {
        (void)freerdp_abort_connect_context(context);
    }
}

static mr_rdp_status mr_freerdp_send_key(
    mr_rdp_backend *base,
    const mr_rdp_key_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_KEY;
    command.value.key = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_send_pointer(
    mr_rdp_backend *base,
    const mr_rdp_pointer_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    if (event->x > UINT16_MAX || event->y > UINT16_MAX) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_POINTER;
    command.value.pointer = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_start_clipboard_probe(
    mr_rdp_backend *base,
    const mr_rdp_backend_clipboard_probe *probe)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_freerdp_clipboard_probe *copy;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (backend == NULL || probe == NULL || probe->probe_id == 0u ||
        probe->utf16le_bytes == NULL || probe->utf16le_byte_count == 0u ||
        probe->utf16le_byte_count > MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    copy = (mr_freerdp_clipboard_probe *)calloc(1u, sizeof(*copy));
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->bytes = (uint8_t *)malloc(probe->utf16le_byte_count);
    if (copy->bytes == NULL) {
        mr_freerdp_clipboard_probe_destroy(copy);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(copy->bytes, probe->utf16le_bytes, probe->utf16le_byte_count);
    copy->descriptor = *probe;
    copy->descriptor.utf16le_bytes = copy->bytes;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->cliprdr == NULL ||
               !backend->cliprdr_ready) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->clipboard_probe_timed_out) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->pending_clipboard_probe != NULL ||
               backend->active_clipboard_probe != NULL) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        backend->pending_clipboard_probe = copy;
        copy = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    mr_freerdp_clipboard_probe_destroy(copy);
    return status;
}

static mr_rdp_status mr_freerdp_request_display_resize(
    mr_rdp_backend *base,
    const mr_rdp_display_resize_request *request)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (backend == NULL || request == NULL || request->request_id == 0u ||
        request->width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        request->height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->disp == NULL) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->display_resize_pending) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        backend->pending_display_resize = *request;
        backend->display_resize_pending = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    return status;
}

static void mr_freerdp_destroy(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    if (backend == NULL) {
        return;
    }
    if (backend->context != NULL) {
        mr_freerdp_clear_password(backend->context->settings);
    }
    if (backend->instance != NULL) {
        mr_freerdp_post_disconnect(backend->instance);
    }
    if (backend->context != NULL) {
        mr_freerdp_context *context = (mr_freerdp_context *)backend->context;
        context->backend = NULL;
        freerdp_client_context_free(backend->context);
        backend->context = NULL;
        backend->instance = NULL;
    }
    if (backend->command_event != NULL) {
        (void)CloseHandle(backend->command_event);
        backend->command_event = NULL;
    }
    if (backend->mutex_initialized) {
        (void)pthread_mutex_destroy(&backend->mutex);
    }
    free(backend->expected_hostname);
    SecureZeroMemory(backend, sizeof(*backend));
    free(backend);
}

static const mr_rdp_backend_vtable mr_freerdp_vtable = {
    .run = mr_freerdp_run,
    .request_stop = mr_freerdp_request_stop,
    .send_key = mr_freerdp_send_key,
    .send_pointer = mr_freerdp_send_pointer,
    .start_clipboard_probe = mr_freerdp_start_clipboard_probe,
    .request_display_resize = mr_freerdp_request_display_resize,
    .destroy = mr_freerdp_destroy
};

static mr_rdp_status mr_freerdp_configure_settings(
    mr_freerdp_backend *backend,
    const mr_rdp_owned_config *config)
{
    rdpSettings *settings = backend->context->settings;
    if (!freerdp_settings_set_string_len(
            settings, FreeRDP_ServerHostname,
            config->hostname, config->hostname_length) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config->port) ||
        !freerdp_settings_set_string_len(
            settings, FreeRDP_Username,
            config->username, config->username_length) ||
        !freerdp_settings_set_string_len(
            settings, FreeRDP_Password,
            config->password, config->password_length) ||
        (config->domain != NULL &&
         !freerdp_settings_set_string_len(
             settings, FreeRDP_Domain,
             config->domain, config->domain_length)) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DesktopWidth, config->desktop_width) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DesktopHeight, config->desktop_height) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32u) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_KeyboardLayout, (uint32_t)KBD_JAPANESE) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_KeyboardType,
            (uint32_t)WINPR_KBD_TYPE_JAPANESE) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_KeyboardSubType, 2u) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_KeyboardFunctionKey, 12u) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_ExternalCertificateManagement, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_CertificateCallbackPreferPEM, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AutoDenyCertificate, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RdstlsSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AadSecurity, FALSE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_UseRdpSecurityLayer, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE) ||
        /* These are the three settings FreeRDP 3.31.1 actually consumes for
         * update, rdpsnd SVC, and rdpsnd/drdynvc DVC dispatch respectively.
         * FreeRDP_AsyncChannels is only a deprecated stored property in that
         * release, so it is intentionally not relied upon here. */
        !freerdp_settings_set_bool(settings, FreeRDP_AsyncUpdate, FALSE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_SynchronousStaticChannels, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_SynchronousDynamicChannels, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxH264, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxCodecAV1, FALSE)) {
        return MR_RDP_ERROR_BACKEND;
    }
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_backend_create_default(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend)
{
    mr_freerdp_backend *backend;
    RDP_CLIENT_ENTRY_POINTS entry_points;
    mr_rdp_status status = MR_RDP_ERROR_BACKEND;
    (void)factory_context;

    if (config == NULL || host == NULL || host->present_certificate == NULL ||
        host->connected == NULL || host->present_frame == NULL ||
        host->channel_event == NULL || host->clipboard_probe_event == NULL ||
        host->display_resize_event == NULL ||
        out_backend == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_backend = NULL;
    backend = (mr_freerdp_backend *)calloc(1u, sizeof(*backend));
    if (backend == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    backend->base.vtable = &mr_freerdp_vtable;
    backend->host = *host;
    backend->generation = config->generation;
    backend->expected_port = config->port;
    backend->callback_status = MR_RDP_STATUS_OK;
    backend->input_failure_status = MR_RDP_STATUS_OK;
    if (!mr_input_command_queue_init(
            &backend->command_queue, MR_INPUT_COMMAND_QUEUE_CAPACITY)) {
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    if (pthread_mutex_init(&backend->mutex, NULL) != 0) {
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    backend->mutex_initialized = 1;
    backend->command_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (backend->command_event == NULL) {
        goto fail;
    }
    backend->expected_hostname = strdup(config->hostname);
    if (backend->expected_hostname == NULL) {
        status = MR_RDP_ERROR_OUT_OF_MEMORY;
        goto fail;
    }

    memset(&entry_points, 0, sizeof(entry_points));
    entry_points.Size = sizeof(entry_points);
    entry_points.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry_points.ContextSize = sizeof(mr_freerdp_context);
    backend->context = freerdp_client_context_new(&entry_points);
    if (backend->context == NULL) {
        goto fail;
    }
    backend->instance = backend->context->instance;
    ((mr_freerdp_context *)backend->context)->backend = backend;
    backend->instance->PreConnect = mr_freerdp_pre_connect;
    backend->instance->PostConnect = mr_freerdp_post_connect;
    backend->instance->PostDisconnect = mr_freerdp_post_disconnect;
    backend->instance->VerifyX509Certificate = mr_freerdp_verify_x509_certificate;
    /* Credentials are supplied up front and Phase 0 has no interactive
     * gateway/smart-card/AAD flow. Do not inherit common CLI callbacks that
     * could try to read stdin from the session worker. */
    backend->instance->AuthenticateEx = NULL;
    backend->instance->ChooseSmartcard = NULL;
    backend->instance->PresentGatewayMessage = NULL;
    backend->instance->GetAccessToken = NULL;
    backend->instance->RetryDialog = NULL;

    status = mr_freerdp_configure_settings(backend, config);
    if (status != MR_RDP_STATUS_OK) {
        goto fail;
    }

    /* FreeRDP 3.31.1's public rdpsnd device vtable does not expose block
     * number/server timestamp and its core sends WaveConfirm around Play.
     * Therefore this adapter selects the stock PCM-only sys:ios subsystem and
     * deliberately does not wire mr_rdpsnd or emit a second confirmation. */
    *out_backend = &backend->base;
    return MR_RDP_STATUS_OK;

fail:
    mr_freerdp_destroy(&backend->base);
    return status;
}
