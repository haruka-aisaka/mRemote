# Phase 0 — Go/No-Go spike

This directory is the entry point for the executable work behind
[`docs/roadmap.md`](../docs/roadmap.md#2-phase-0--gono-go-スパイク). Its goal was a personal
Core Adoption decision: whether the candidate native core works on the available iPad, keyboard,
and Windows target.

## Decision: GO (2026-09-05)

The candidate is adopted for this personal baseline. This is not a product, compatibility, or
release approval, and it says nothing about any device, keyboard, or Windows version other than
the one below.

| Core Gate row | Result |
|---|---|
| `P0-BUILD-01` pinned FreeRDP/WinPR device arm64 slice | PASS |
| `P0-TLS-01` NLA/TLS connection with authoritative `SecTrust` evaluation | PASS |
| `P0-DSP-01` connected desktop presents a BGRA frame | PASS |
| `KEY-EISU-01` Eisu reaches Windows as Muhenkan | PASS |
| `KEY-KANA-01` Kana reaches Windows as Henkan | PASS |
| `KEY-IME-02` consumed press shows no iPadOS IME/input-source UI | PASS |
| `P0-TEARDOWN-01` disconnect and reconnect without crash or hang | PASS |

Baseline: iPad mini (7th generation), Apple Magic Keyboard (JIS), one Windows 11 host, harness
`Phase0HarnessNative` at commit `dff675b`, FreeRDP 3.31.1
(`63b948ca5cb94307fd5444ee6e73927a41ccdab4`).

Every row passed on operator observation across roughly three trial sessions, which is the
verification scale this project works at (see `docs/README.md`, "開発体制と試験スケール"). The
full record, including what each row actually observed, is the uncommitted
`records/phase0-test-ipad-mini7-magic-keyboard.local.md` -- records are ignored by git because
they name the operator and the Windows host.

Deliberately carried forward rather than done here:

- KeyEcho 10-cycle Eisu/Kana JSONL measurement, to Phase 3
- sanitizer stress and the 20x connect/disconnect loop, to Phase 2 -- **both done**
  on 2026-09-05: the bridge contract tests run clean under Address/UB and Thread
  sanitizers with a new concurrent teardown stress test, and the connect/disconnect
  loop is `AppTests/RDPRemoteSessionTests`. See docs/roadmap.md, Phase 2
- pointer, channels, audio, 4K, multi-session, archive and SBOM audit, to their own phases

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
| iOS harness | [`tools/Phase0Harness/`](../tools/Phase0Harness/) UIKit/Metal surface, physical input routing, HID-to-Set-1 mapping, pointer routes, IME proxies, `SecTrust` evaluator, and native bridge session | The fixture scheme remains connection-free; `Phase0HarnessNative` links both generated XCFrameworks and can establish the real session |
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
# tools/Phase0Harness/README.md, inspect their distribution shape and static symbols
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
  swift test --package-path tools/Phase0Harness \
  --scratch-path /tmp/mremote-phase0-swiftpm-build
```

The bridge README has separate Address/Undefined Behavior and Thread Sanitizer commands. The iOS
harness README has Xcode build, Simulator test, device-run, trace-export, and rendering-baseline
instructions.

The full dependency builder refuses to replace an existing output. Preserve its checksum manifest
as evidence, or select a fresh `--output` path for another run. Manifest entries are relative to
the directory containing the manifest, so checksum verification must run from `artifacts/` as in
the command above.

## Re-running the Core Gate

The Gate is closed. Re-run it only when something invalidates the decision: a FreeRDP version
change, a bridge rewrite, or evaluating an alternative RDP core.

1. Copy `records/phase0-test-record.template.md` for the run. Leave each row `NOT RUN` until it has
   been observed.
2. With the signed `Phase0HarnessNative` build, exercise NLA/TLS and make copied DER plus the SSL
   hostname policy in `SecTrust` authoritative. Confirm the native session can connect, stop, and
   reconnect.
3. Exercise the Eisu/Kana hardware keys and `KEY-IME-02` on the iPad. For a measured rather than
   observed result, build KeyEcho on Windows and capture independent Eisu-only and Kana-only JSONL
   files, then analyze them with the matching mode.
4. Mark `GO` only when its seven rows pass, and update the decision table above.

Simulator input, source inspection, symbol presence, and mock bridge tests cannot substitute for
physical Eisu/Kana, `KEY-IME-02`, real NLA/TLS, or teardown evidence, however small the run is.
