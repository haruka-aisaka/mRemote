#include "certificate_chain.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Non-secret test certificate from the pinned FreeRDP 3.31.1 crypto tests
 * (ecdsa_sha256_cert.pem, Apache-2.0). */
#define TEST_CERTIFICATE_PEM \
    "-----BEGIN CERTIFICATE-----\n" \
    "MIIBdDCCARmgAwIBAgIUUDFppYHwhd7smJSH6W8QSLttoNEwCgYIKoZIzj0EAwIw\n" \
    "DzENMAsGA1UEAwwEVGVzdDAeFw0yNDAyMDYwMzA5MzRaFw0zNDAyMDMwMzA5MzRa\n" \
    "MA8xDTALBgNVBAMMBFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATfQ2ox\n" \
    "CF1xh6Dwcsi3BqyUIlKxgY3J2qOSmOzepOMLWhPpiDsneKskpKx4b5JM92mmIyiq\n" \
    "UMMR7mXlclDHyQtro1MwUTAdBgNVHQ4EFgQUgoV/fxICc75gTRslwgvs/I1YbOUw\n" \
    "HwYDVR0jBBgwFoAUgoV/fxICc75gTRslwgvs/I1YbOUwDwYDVR0TAQH/BAUwAwEB\n" \
    "/zAKBggqhkjOPQQDAgNJADBGAiEAyVInWgy3JVEUPDSpjNseJKPie/hINfO6KbrK\n" \
    "IqGQ0+ACIQDk/oXOIwFZr26TTghYKOn12aOuPCxOqeBu5ObeFMf91Q==\n" \
    "-----END CERTIFICATE-----\n"

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf( \
                stderr, "%s:%d: requirement failed: %s\n", \
                __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static const uint8_t test_certificate_pem[] = TEST_CERTIFICATE_PEM;

static int chain_is_clear(
    const mr_rdp_der_blob *chain,
    size_t chain_count)
{
    size_t index;
    for (index = 0u; index < chain_count; ++index) {
        if (chain[index].bytes != NULL || chain[index].length != 0u) {
            return 0;
        }
    }
    return 1;
}

static int test_valid_chain_and_whitespace(void)
{
    static const uint8_t wrapped[] =
        " \t\r\n" TEST_CERTIFICATE_PEM
        "\v\f\n" TEST_CERTIFICATE_PEM
        "\r\n\t ";
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 99u;

    REQUIRE(mr_rdp_certificate_chain_from_pem(
                wrapped, sizeof(wrapped) - 1u, chain, &chain_count) ==
            MR_RDP_STATUS_OK);
    REQUIRE(chain_count == 2u);
    REQUIRE(chain[0].bytes != NULL);
    REQUIRE(chain[0].length > 0u);
    REQUIRE(chain[0].bytes[0] == 0x30u);
    REQUIRE(chain[0].length == chain[1].length);
    REQUIRE(memcmp(chain[0].bytes, chain[1].bytes, chain[0].length) == 0);
    mr_rdp_certificate_chain_free(chain, chain_count);
    REQUIRE(chain_is_clear(chain, chain_count));
    return 1;
}

static int require_invalid_data(
    const uint8_t *pem,
    size_t pem_length)
{
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 99u;
    memset(chain, 0xa5, sizeof(chain));
    REQUIRE(mr_rdp_certificate_chain_from_pem(
                pem, pem_length, chain, &chain_count) ==
            MR_RDP_ERROR_INVALID_DATA);
    REQUIRE(chain_count == 0u);
    REQUIRE(chain_is_clear(chain, MR_RDP_MAX_CERTIFICATE_CHAIN));
    return 1;
}

static int test_rejects_non_whitespace_and_malformed_pem(void)
{
    static const uint8_t leading_garbage[] =
        "not-a-certificate\n" TEST_CERTIFICATE_PEM;
    static const uint8_t between_garbage[] =
        TEST_CERTIFICATE_PEM "not-a-certificate\n" TEST_CERTIFICATE_PEM;
    static const uint8_t trailing_garbage[] =
        TEST_CERTIFICATE_PEM "not-a-certificate\n";
    static const uint8_t incomplete_after_valid[] =
        TEST_CERTIFICATE_PEM "-----BEGIN CERTIFICATE-----\nAAAA\n";
    static const uint8_t malformed[] =
        "-----BEGIN CERTIFICATE-----\n"
        "not-base64!\n"
        "-----END CERTIFICATE-----\n";
    static const uint8_t whitespace_only[] = " \t\r\n\v\f";

    REQUIRE(require_invalid_data(
        leading_garbage, sizeof(leading_garbage) - 1u));
    REQUIRE(require_invalid_data(
        between_garbage, sizeof(between_garbage) - 1u));
    REQUIRE(require_invalid_data(
        trailing_garbage, sizeof(trailing_garbage) - 1u));
    REQUIRE(require_invalid_data(
        incomplete_after_valid, sizeof(incomplete_after_valid) - 1u));
    REQUIRE(require_invalid_data(malformed, sizeof(malformed) - 1u));
    REQUIRE(require_invalid_data(
        whitespace_only, sizeof(whitespace_only) - 1u));
    return 1;
}

static int test_chain_count_limit(void)
{
    const size_t certificate_length = sizeof(test_certificate_pem) - 1u;
    const size_t accepted_length =
        certificate_length * MR_RDP_MAX_CERTIFICATE_CHAIN;
    const size_t rejected_length =
        certificate_length * (MR_RDP_MAX_CERTIFICATE_CHAIN + 1u);
    uint8_t *pem = (uint8_t *)malloc(rejected_length);
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 0u;
    size_t index;

    REQUIRE(pem != NULL);
    for (index = 0u; index < MR_RDP_MAX_CERTIFICATE_CHAIN + 1u; ++index) {
        memcpy(
            pem + (index * certificate_length),
            test_certificate_pem,
            certificate_length);
    }
    REQUIRE(mr_rdp_certificate_chain_from_pem(
                pem, accepted_length, chain, &chain_count) ==
            MR_RDP_STATUS_OK);
    REQUIRE(chain_count == MR_RDP_MAX_CERTIFICATE_CHAIN);
    mr_rdp_certificate_chain_free(chain, chain_count);

    chain_count = 99u;
    REQUIRE(mr_rdp_certificate_chain_from_pem(
                pem, rejected_length, chain, &chain_count) ==
            MR_RDP_ERROR_LIMIT_EXCEEDED);
    REQUIRE(chain_count == 0u);
    REQUIRE(chain_is_clear(chain, MR_RDP_MAX_CERTIFICATE_CHAIN));
    free(pem);
    return 1;
}

static int test_pem_size_limit(void)
{
    const size_t oversized_length =
        (size_t)MR_FREERDP_MAX_CERTIFICATE_PEM_BYTES + 1u;
    uint8_t *oversized = (uint8_t *)malloc(oversized_length);
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 99u;

    REQUIRE(oversized != NULL);
    memset(oversized, ' ', oversized_length);
    REQUIRE(mr_rdp_certificate_chain_from_pem(
                oversized, oversized_length, chain, &chain_count) ==
            MR_RDP_ERROR_LIMIT_EXCEEDED);
    REQUIRE(chain_count == 0u);
    REQUIRE(chain_is_clear(chain, MR_RDP_MAX_CERTIFICATE_CHAIN));
    free(oversized);
    return 1;
}

int main(void)
{
    REQUIRE(test_valid_chain_and_whitespace());
    REQUIRE(test_rejects_non_whitespace_and_malformed_pem());
    REQUIRE(test_chain_count_limit());
    REQUIRE(test_pem_size_limit());
    (void)printf("PASS certificate chain parser contract\n");
    return 0;
}
