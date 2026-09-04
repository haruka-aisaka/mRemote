# Phase 0 — Go/No-Go spike

This directory is the entry point for the executable work behind
[`docs/roadmap.md`](../docs/roadmap.md#2-phase-0--gono-go-スパイク). Its first goal is a personal
Core Adoption decision: whether the candidate native core works on the available iPad, keyboard,
and Windows target. The current decision is **UNDECIDED**, not GO. This decision is not a product,
compatibility, or release approval.

## Candidate configuration

| Item | Candidate |
|---|---|
| FreeRDP / WinPR | 3.31.1 at `63b948ca5cb94307fd5444ee6e73927a41ccdab4` |
| OpenSSL | 4.0.1 release archive, SHA-256 pinned in the dependency lock |
| Minimum OS | iPadOS/iOS 17.0 |
| Architectures | device arm64 and Simulator arm64 |
| Static add-ins | `cliprdr`, `rdpsnd` SVC/DVC, `rdpdr`, `drdynvc`, `disp`, and `rdpgfx`; the adapter registers `rdpsnd,sys:ios` in both SVC/DVC collections |
| Audio spike | Upstream PCM-only `sys:ios` playback, no microphone. The artifact also contains mandatory `fake`, but the implemented adapter explicitly bypasses that fallback |

## What is in the repository

| Boundary | Implementation | Scope limit |
|---|---|---|
| Native dependency | [`config/dependencies/freerdp.lock`](../config/dependencies/freerdp.lock), build/verification scripts, notices, and SPDX SBOM | A generated XCFramework under `artifacts/` is intentionally ignored and must be rebuilt or retained as test evidence |
| C ABI | [`bridge/`](../bridge/) opaque session API, pinned FreeRDP 3.31.1 adapter, strict PEM-to-DER certificate challenge, BGRA frames, bounded key/pointer queue, channel telemetry, count/hash-only `CF_UNICODETEXT` probe, DISP resize request, and PCM `rdpsnd` contract | Host contract tests deliberately use the unavailable/mock backend; only the generated bridge XCFramework contains the real adapter |
| iOS harness | [`ios/Phase0Harness/`](../ios/Phase0Harness/) UIKit/Metal surface, physical input routing, HID-to-Set-1 mapping, pointer routes, IME proxies, `SecTrust` evaluator, and native bridge session | The fixture scheme remains connection-free; `Phase0HarnessNative` links both generated XCFrameworks and can establish the real session |
| Windows observer | [`tools/KeyEcho/`](../tools/KeyEcho/) Win32 low-level keyboard event recorder and JSONL analyzer | The executable must be built and run on Windows |
| Evidence | [`records/`](records/) Core test record, optional detailed baseline schema/matrix, validators, and legacy KeyProbe inventory | The first Core Gate needs no JSON baseline or matrix; templates and Simulator results are not physical-device evidence |
| Certificate research | [`notes/freerdp-3.31.1-certificate-spike.md`](notes/freerdp-3.31.1-certificate-spike.md) | Source inspection proves callback feasibility, not NLA/TLS behavior |
| Local verification | [`notes/local-verification-2026-09-04.md`](notes/local-verification-2026-09-04.md) | Reproducible host/Simulator/static-link results; explicitly not a completed physical-device/Windows Gate record |

## Reproduce the local checks

Run from the repository root. Build directories are outside source-controlled paths where practical.

```sh
# Dependency metadata and build plan
scripts/build-freerdp-xcframework.sh --dry-run
scripts/generate-dependency-metadata.sh --output /tmp/mremote-phase0-sbom.json
cmp ThirdParty/SBOM.spdx.json /tmp/mremote-phase0-sbom.json

# Full native dependency build (downloads locked sources when the cache is empty)
scripts/build-freerdp-xcframework.sh
scripts/verify-freerdp-xcframework.sh artifacts/FreeRDP.xcframework
(cd artifacts && shasum -a 256 -c FreeRDP.xcframework.sha256)

# C ABI, PCM contract, and strict PEM parser contract
cmake -S bridge -B /tmp/mremote-phase0-bridge \
  -DBUILD_TESTING=ON \
  -DMR_BRIDGE_BACKEND=unavailable \
  -DMR_BRIDGE_CERTIFICATE_TESTS=ON \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
cmake --build /tmp/mremote-phase0-bridge
ctest --test-dir /tmp/mremote-phase0-bridge --output-on-failure

# Real FreeRDP-backed bridge, strict two-slice compile and link smoke
scripts/build-rdp-bridge-xcframework.sh
scripts/verify-rdp-bridge-xcframework.sh \
  artifacts/mRemoteRDPBridge.xcframework \
  artifacts/FreeRDP.xcframework
(cd artifacts && shasum -a 256 -c mRemoteRDPBridge.xcframework.sha256)

# After creating the unsigned Release and SymbolAudit archives documented in
# ios/Phase0Harness/README.md, inspect their distribution shape and static symbols
scripts/verify-phase0-native-archives.sh \
  /tmp/mremote-phase0-native.xcarchive \
  /tmp/mremote-phase0-native-symbol-audit.xcarchive

# Record and KeyEcho analyzers
phase0/records/tests/test-validator.sh
phase0/records/tests/test-phase0-markdown-validator.sh
tools/KeyEcho/tests/test-analyzer.sh

# Platform-independent iOS harness logic
env \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/mremote-phase0-swiftpm-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/mremote-phase0-clang-module-cache \
  swift test --package-path ios/Phase0Harness \
  --scratch-path /tmp/mremote-phase0-swiftpm-build
```

The bridge README has separate Address/Undefined Behavior and Thread Sanitizer commands. The iOS
harness README has Xcode build, Simulator test, device-run, trace-export, and rendering-baseline
instructions.

The full dependency builder refuses to replace an existing output. Preserve its checksum manifest
as evidence, or select a fresh `--output` path for another run. Manifest entries are relative to
the directory containing the manifest, so checksum verification must run from `artifacts/` as in
the command above.

## Complete the Core Gate

1. Copy `records/phase0-test-record.template.md` for the run. The concise record has only the six
  Core Gate results; leave each `NOT RUN` until its named evidence exists.
2. Build KeyEcho on Windows. Capture independent Eisu-only and Kana-only 100-cycle JSONL files and
   analyze them with the matching mode.
3. With the signed `Phase0HarnessNative` build, exercise NLA/TLS and make copied DER plus the SSL
  hostname policy in `SecTrust` authoritative. Confirm the native session can connect, stop, and
  reconnect.
4. Exercise the Eisu/Kana hardware keys and `KEY-IME-02` on the iPad. Record only the device,
  keyboard, OS, Windows, and input-policy details that affected the run in the Core record.
5. Mark `GO` only when its seven rows pass. That adopts the core for this personal baseline; it does
  not claim compatibility beyond it.

The detailed input JSON, compatibility matrix, pointer paths, 4K and multi-session measurement,
channel/audio round trips, and final archive/SBOM audit remain valuable deferred validation. Run
them when their feature is implemented or an additional environment is supported. In particular,
Simulator input, source inspection, symbol presence, and mock bridge tests cannot substitute for
physical Eisu/Kana, `KEY-IME-02`, real NLA/TLS, or safe teardown evidence.
