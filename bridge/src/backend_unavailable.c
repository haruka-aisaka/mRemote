#include "bridge_internal.h"

mr_rdp_status mr_rdp_backend_create_default(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend)
{
    (void)config;
    (void)host;
    (void)factory_context;
    if (out_backend != NULL) {
        *out_backend = NULL;
    }
    return MR_RDP_ERROR_BACKEND_UNAVAILABLE;
}
