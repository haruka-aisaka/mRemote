# FreeRDP 3.31.1 certificate callback spike

## Candidate inspected

- Tag: `3.31.1`
- Commit: `63b948ca5cb94307fd5444ee6e73927a41ccdab4`
- Inspection date: 2026-09-04

This is a source-level feasibility result, not an NLA/TLS end-to-end pass.

## Finding

The public `pVerifyX509Certificate` callback in `include/freerdp/freerdp.h` receives the hostname,
port, flags, and certificate data documented as the **full chain in PEM format**. In
`libfreerdp/crypto/tls.c`, `tls_verify_certificate` selects that callback before FreeRDP's own
OpenSSL/known-hosts path when the `FreeRDP_ExternalCertificateManagement` setting is enabled.
The callback is therefore reachable for certificates that would otherwise pass or fail FreeRDP's
internal verifier.

The implemented candidate integration sets all of the following explicitly:

- `FreeRDP_ExternalCertificateManagement = TRUE`
- `FreeRDP_IgnoreCertificate = FALSE`
- `FreeRDP_AutoAcceptCertificate = FALSE`
- `FreeRDP_AutoDenyCertificate = FALSE`
- `VerifyX509Certificate = mr_freerdp_verify_x509_certificate`

The app-managed trust repository is authoritative; the adapter does not enable or consult a second
FreeRDP known-hosts decision path. Persistent acceptance remains an app Keychain decision. An
accepted connection returns `2` to FreeRDP for session-only acceptance rather than asking FreeRDP
to persist it.

## Implemented adapter conversion

FreeRDP supplies one callback-duration PEM buffer, while the stable bridge deliberately exposes an
array of complete DER certificates. The pinned-version adapter now:

1. Never retains or dispatches the borrowed PEM pointer; it parses synchronously in the callback.
2. Rejects PEM over 8 MiB, non-whitespace outside certificate blocks, malformed/incomplete blocks,
   and more than 16 certificates.
3. Parses every `CERTIFICATE` block with the pinned OpenSSL API.
4. Encodes each parsed certificate as one DER blob, preserving leaf-first chain order.
5. Enforces the bridge's per-certificate and 4 MiB aggregate DER limits.
6. Calls the bridge certificate challenge synchronously on the session worker.
7. Frees/zeros temporary DER buffers after the challenge resolves.
8. Maps acceptance to callback return `2` (this session only), and maps reject/stop/timeout without
   falling through to internal silent acceptance.

The iOS harness independently implements `SecCertificateCreateWithData`,
`SecTrustCreateWithCertificates`, and `SecPolicyCreateSSL(server: true, hostname:)` for the copied
DER array. The C bridge contract tests cover DER deep-copy, challenge identity, timeout, stop wake,
and callback drain. The optional host-OpenSSL parser contract additionally covers leading,
inter-certificate, and trailing whitespace; leading/intermediate/trailing garbage; malformed or
incomplete PEM; the 16-certificate boundary; and the 8 MiB input limit. The artifact still compiles
and links the parser against the pinned OpenSSL slice.

## Remaining gate evidence

- Connect to a real Windows target with NLA/TLS through the actual adapter.
- Confirm callback chain order and whether the server omits the root (both are acceptable if
  `SecTrust` can build the chain from system anchors).
- Exercise public CA, private CA, self-signed, expired, hostname mismatch, and changed-leaf cases.
- Verify cancellation/timeout while the FreeRDP worker is waiting.
- Confirm no FreeRDP known-hosts file is created or used.

Until these checks pass, `P0-TLS-01` remains `NOT RUN` and the candidate is not adopted.
