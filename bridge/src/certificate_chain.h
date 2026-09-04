#ifndef MREMOTE_CERTIFICATE_CHAIN_H
#define MREMOTE_CERTIFICATE_CHAIN_H

#include "mremote/rdp_bridge.h"

#define MR_FREERDP_MAX_CERTIFICATE_PEM_BYTES (8u * 1024u * 1024u)

mr_rdp_status mr_rdp_certificate_chain_from_pem(
    const uint8_t *pem,
    size_t pem_length,
    mr_rdp_der_blob *chain,
    size_t *out_chain_count);

void mr_rdp_certificate_chain_free(
    mr_rdp_der_blob *chain,
    size_t chain_count);

#endif
