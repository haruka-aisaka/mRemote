# Phase 0 local verification snapshot — 2026-09-04

This note records reproducible local evidence for the candidate implementation. It is not a
completed physical-device/Windows [Phase 0 test record](../records/phase0-test-record.template.md),
and none of the results below substitutes for the external Gate evidence named in that record.

## Decision

**Superseded by the physical-device run of 2026-09-05: the decision is now GO.** See
[`phase0/README.md`](../README.md). This note is kept as the record of what was verifiable
locally on 2026-09-04, one day before that run.

At the time of writing, the candidate had passed the available source, host, Simulator,
static-link, and unsigned archive checks only, and was **UNDECIDED**.

## Verification environment

The checked-in [development host record](../records/development-host.json) contains the structured
capture. The relevant values were:

| Item | Value |
|---|---|
| Host | macOS 26.6.2 (25G83), arm64 |
| Xcode | 26.6 (17F113) |
| Apple Clang | 21.0.0 |
| Swift | 6.3.3 |
| CMake | 4.4.2 |
| Simulator test device | iPad Pro 13-inch (M5), iOS 26.5 (23F77), arm64 Simulator |
| Candidate minimum deployment target | iPadOS/iOS 17.0 |

## Candidate fingerprints

| Item | SHA-256 |
|---|---|
| FreeRDP manifest (819 entries) | `2b659ac1028f3bcc07733c6df4ac6fa5d3bc1801760358d9b69063bd0d337228` |
| FreeRDP device archive | `97c058b34f76ff7ccc804bafb4636c23d70c40e8cdb873109cda3b1dcbc7a718` |
| FreeRDP Simulator archive | `007bf6625c6393b8f880e4c9e689749da64bea677c2ef65b65166f3168ff9914` |
| Bridge manifest (7 entries) | `c3b00393e3c377a6bd3c9110103ea6ac7e91861db88d46b1e845d8b893fa3e23` |
| Bridge device archive | `c1e69f2c9c71f2906b48c14d333d0cd70771b3f99af6882ecae36711c06bb2a0` |
| Bridge Simulator archive | `72c3736c51fb656184e4af2f03076751cbc75dd6c9141b401de325e3273bcbc5` |
| SPDX SBOM | `c1f46c5d6f35134836a4544f8680cf768e713efa11a798be6c4811182194a2c6` |
| Unsigned distribution-shaped Release executable | `7b47d5750f43db123bd3c87a395c6a0b6c671834e82b0f756e7010d8902761e3` |
| Unsigned SymbolAudit executable | `a247f4bcab282e2e7a9dc19c62dd43dda4f15d8b4e390e00ce23ba1bda460f37` |

The FreeRDP/WinPR source is 3.31.1 at
`63b948ca5cb94307fd5444ee6e73927a41ccdab4`; OpenSSL is the locked 4.0.1 release
archive. The generated binary artifacts are ignored by Git and must be rebuilt or preserved with
their manifests as run evidence.

## Available checks completed

| Check | Local result | What it establishes |
|---|---|---|
| FreeRDP two-slice cold rebuild in two independent roots | PASS, 819/819 files byte-identical | Locked inputs and canonical packaging reproduce on this host/toolchain |
| Bridge two-slice rebuild and artifact verifier | PASS, 7-file checksum manifest | Current device/Simulator bridge packages expose the required ABI and link against the locked FreeRDP artifact |
| C bridge normal contract suite | PASS, 6/6 tests | Opaque ABI/lifecycle, bounded input queue, channel/clipboard/DISP telemetry and deadlines, PCM mock, and strict PEM parser contracts |
| C bridge Address/Undefined Behavior Sanitizer suite | PASS, 6/6 tests | No sanitizer finding in the exercised host contracts |
| C bridge Thread Sanitizer suite | PASS, 6/6 tests in 5 repetitions | No TSan finding in the exercised host contracts |
| SwiftPM harness logic suite | PASS, 70/70 tests | Input routing, scan-code mapping, BGRA validation/coalescing, ordered delivery, scroll accumulation, session/channel models, trust classification, redaction, and lifecycle response logic |
| iPad Simulator XCTest suite | PASS, 70/70 tests | The same logic runs in an arm64 iPad Simulator app test host |
| Fixture device Release plus native Simulator Debug/Release builds | PASS | The harness variants compile across the locally available candidate build shapes |
| FreeRDP and bridge artifact verifiers | PASS | arm64 slices, static link smoke, required add-in symbols, and system-only link dependencies |
| Unsigned Release/SymbolAudit archive verifier | PASS | arm64 iOS 17 shape, system-only dynamic dependencies, no packaged plugin, redacted Release paths, and required dSYM/static symbols |
| Record validator and KeyEcho analyzer tests | PASS | Evidence schemas/analyzers accept and reject their fixtures as intended |
| KeyEcho Windows x64 cross-link smoke using Zig | PASS | The Win32 observer source links as a Windows GUI executable; it was not run on Windows |
| SBOM regeneration comparison | PASS, 8 packages and 13 relationships | Generated SPDX output matches the repository copy |

The Simulator result bundle was retained temporarily as
`/tmp/mremote-phase0-simulator-tests-final/Logs/Test/` followed by
`Test-Phase0Harness-2026.09.04_17-24-24-+0900.xcresult`. It reports 70 passed
tests and zero failed/skipped tests.

## Unsigned archive inspection

The distribution-shaped executable in
`/tmp/mremote-phase0-native-release-current.xcarchive` is Mach-O arm64,
declares platform iOS and minimum OS 17.0, links only Apple system
dylibs/frameworks, and contains the generated Local Network usage description.
Its installed executable is stripped to one public Mach-O header symbol and
contains no local source/build path. The retained dSYM confirms that the
required SVC/DVC and iOS PCM add-in entry points survived dead-code stripping.

The separate `/tmp/mremote-phase0-native-symbolaudit-current.xcarchive`
uses the `SymbolAudit` configuration, which keeps `-all_load` and disables
dead-code/install/copy stripping. Its executable retains the bridge and all
required static add-in symbols, as well as local build paths by design.

These are unsigned build and symbol inspections, not `P0-ARCHIVE-01` evidence.
Linked dependencies still reference `dlopen`/`dlsym`; no plugin bundle is
packaged, but an App Store-equivalent dynamic-plugin/private-API scan has not
been performed. No signed export or physical-device installation was
performed. `P0-ARCHIVE-01` therefore remains `NOT RUN` in an external test
record.

## Remaining external Gate evidence

- Real Windows NLA/TLS with copied leaf/chain DER and authoritative `SecTrust` SSL-hostname
  evaluation, including reject and one-session Trust Once behavior.
- Physical Eisu and Kana delivery (100 cycles each), delayed-source duplicate suppression, and
  visual `KEY-IME-02` confirmation on each agreed iPad/keyboard/OS combination.
- Physical mouse/trackpad button, drag, cancel, and vertical/horizontal wheel delivery.
- Real `cliprdr`, `rdpsnd`, `drdynvc`/`disp` negotiation and data round trips, plus wire-side Wave
  Confirm observation. Stock FreeRDP 3.31.1 owns Wave Confirm; the mock `mr_rdpsnd` contract is not
  connected to that stock device vtable and is not Gate evidence.
- Sustained 1080p/4K display measurements and two/three-session memory, thermal, and teardown runs.
- A signed final Release archive and App Store-equivalent architecture/dynamic-plugin/private-API
  audit.

Of these, the physical-device run of 2026-09-05 covered Eisu/Kana delivery, `KEY-IME-02`, real
NLA/TLS, a rendered desktop, and manual teardown, which is what the Core Gate needed. The rest are
carried into the phase that implements the corresponding feature, at the verification scale in
`docs/README.md`; a full matrix is explicitly not a goal of this project.
