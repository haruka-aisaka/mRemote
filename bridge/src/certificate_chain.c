#include "certificate_chain.h"

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const char mr_pem_certificate_begin[] =
    "-----BEGIN CERTIFICATE-----";

static void mr_certificate_secure_zero(void *memory, size_t length)
{
    volatile uint8_t *bytes = (volatile uint8_t *)memory;
    while (length > 0u) {
        *bytes = 0u;
        ++bytes;
        --length;
    }
}

static int mr_is_ascii_whitespace(uint8_t byte)
{
    return byte == (uint8_t)' ' || byte == (uint8_t)'\t' ||
        byte == (uint8_t)'\r' || byte == (uint8_t)'\n' ||
        byte == (uint8_t)'\f' || byte == (uint8_t)'\v';
}

void mr_rdp_certificate_chain_free(
    mr_rdp_der_blob *chain,
    size_t chain_count)
{
    size_t index;
    if (chain == NULL) {
        return;
    }
    for (index = 0u; index < chain_count; ++index) {
        uint8_t *der = (uint8_t *)(uintptr_t)chain[index].bytes;
        if (der != NULL) {
            mr_certificate_secure_zero(der, chain[index].length);
            free(der);
        }
        chain[index].bytes = NULL;
        chain[index].length = 0u;
    }
}

mr_rdp_status mr_rdp_certificate_chain_from_pem(
    const uint8_t *pem,
    size_t pem_length,
    mr_rdp_der_blob *chain,
    size_t *out_chain_count)
{
    BIO *bio = NULL;
    size_t chain_count = 0u;
    size_t total_length = 0u;
    mr_rdp_status status = MR_RDP_ERROR_INVALID_DATA;

    if (pem == NULL || pem_length == 0u || chain == NULL ||
        out_chain_count == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_chain_count = 0u;
    memset(chain, 0, sizeof(*chain) * MR_RDP_MAX_CERTIFICATE_CHAIN);
    if (pem_length > MR_FREERDP_MAX_CERTIFICATE_PEM_BYTES ||
        pem_length > (size_t)INT_MAX) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    bio = BIO_new_mem_buf(pem, (int)pem_length);
    if (bio == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }

    for (;;) {
        char *remaining = NULL;
        long remaining_length;
        size_t offset = 0u;
        X509 *certificate;
        int der_length;
        uint8_t *der;
        uint8_t *cursor;

        remaining_length = BIO_get_mem_data(bio, &remaining);
        if (remaining_length < 0 ||
            (remaining_length > 0 && remaining == NULL)) {
            status = MR_RDP_ERROR_INVALID_DATA;
            goto cleanup;
        }
        while (offset < (size_t)remaining_length &&
               mr_is_ascii_whitespace((uint8_t)remaining[offset])) {
            ++offset;
        }
        if (offset == (size_t)remaining_length) {
            break;
        }
        if ((size_t)remaining_length - offset <
                sizeof(mr_pem_certificate_begin) - 1u ||
            memcmp(
                remaining + offset,
                mr_pem_certificate_begin,
                sizeof(mr_pem_certificate_begin) - 1u) != 0) {
            status = MR_RDP_ERROR_INVALID_DATA;
            goto cleanup;
        }

        ERR_clear_error();
        certificate = PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (certificate == NULL) {
            ERR_clear_error();
            status = MR_RDP_ERROR_INVALID_DATA;
            goto cleanup;
        }
        if (chain_count >= MR_RDP_MAX_CERTIFICATE_CHAIN) {
            X509_free(certificate);
            status = MR_RDP_ERROR_LIMIT_EXCEEDED;
            goto cleanup;
        }
        der_length = i2d_X509(certificate, NULL);
        if (der_length <= 0) {
            X509_free(certificate);
            status = MR_RDP_ERROR_INVALID_DATA;
            goto cleanup;
        }
        if ((size_t)der_length > MR_RDP_MAX_CERTIFICATE_DER_BYTES ||
            (size_t)der_length > MR_RDP_MAX_CERTIFICATE_CHAIN_BYTES - total_length) {
            X509_free(certificate);
            status = MR_RDP_ERROR_LIMIT_EXCEEDED;
            goto cleanup;
        }
        der = (uint8_t *)malloc((size_t)der_length);
        if (der == NULL) {
            X509_free(certificate);
            status = MR_RDP_ERROR_OUT_OF_MEMORY;
            goto cleanup;
        }
        cursor = der;
        if (i2d_X509(certificate, &cursor) != der_length) {
            mr_certificate_secure_zero(der, (size_t)der_length);
            free(der);
            X509_free(certificate);
            status = MR_RDP_ERROR_INVALID_DATA;
            goto cleanup;
        }
        X509_free(certificate);
        chain[chain_count].bytes = der;
        chain[chain_count].length = (size_t)der_length;
        total_length += (size_t)der_length;
        ++chain_count;
    }

    if (chain_count == 0u) {
        status = MR_RDP_ERROR_INVALID_DATA;
        goto cleanup;
    }
    *out_chain_count = chain_count;
    status = MR_RDP_STATUS_OK;

cleanup:
    BIO_free(bio);
    if (status != MR_RDP_STATUS_OK) {
        mr_rdp_certificate_chain_free(chain, chain_count);
    }
    return status;
}
