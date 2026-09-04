# Native dependency inventory

Phase 0 uses a source-built, static FreeRDP XCFramework. The selection is provisional until the
device gates in `docs/roadmap.md` pass; changing the lock is a reviewed source change, not a local
build override.

| Component | Locked source | Linked purpose | License |
|---|---|---|---|
| FreeRDP | 3.31.1, commit `63b948ca5cb94307fd5444ee6e73927a41ccdab4` | RDP client core and static channel registration | Apache-2.0 |
| WinPR | `winpr/` at the same FreeRDP commit | portable runtime, CredSSP/NTLM primitives | Apache-2.0 |
| OpenSSL | 4.0.1 release archive, SHA-256 `2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09` | TLS and cryptographic primitives required by FreeRDP | Apache-2.0 |
| TPCircularBuffer | FreeRDP commit snapshot | iOS `rdpsnd` PCM ring buffer | Zlib |
| Solar Designer MD4/MD5 | FreeRDP commit snapshot | WinPR internal NTLM-compatible digest implementations | public-domain dedication with permissive fallback terms |
| Keith Pomakis HashTable | FreeRDP commit snapshot | basis of WinPR's hash table | public-domain statement; WinPR changes are Apache-2.0 |
| Unicode CLDR windowsZones data | generated table with `typeVersion: 2021a`, pinned by the FreeRDP commit | IANA/Windows timezone mapping | Unicode-DFS-2016 |

The Phase 0 profile enables `cliprdr`, `rdpsnd`, `drdynvc`, `disp`, and `rdpgfx` client add-ins,
plus the core `rdpdr` client add-in required by FreeRDP's common loader when `rdpsnd` is active.
They are compiled into the client archive. Device service backends remain disabled, so enabling the
core `rdpdr` transport does not enable drive, printer, smart-card, serial, or parallel redirection.
The build does not package a `.dylib`, `.so`, bundle, runtime plugin, LLVM LTO object, or embedded
bitcode. FFmpeg, OpenH264, Opus, JPEG/WebP/PNG helpers, server binaries, camera/microphone
redirection, RemoteApp, and RD Gateway-specific extras are disabled.

The upstream iOS `rdpsnd` subsystem advertises PCM only, but FreeRDP 3.31.1 unconditionally also
compiles its `fake` subsystem, which accepts every format and discards playback. The dependency
artifact therefore is not PCM-only by itself. The implemented pinned adapter registers
`rdpsnd,sys:ios` in both static and dynamic channel collections before the common add-in loader;
FreeRDP's duplicate-name checks preserve those arguments and avoid its `sys:fake` fallback.

FreeRDP 3.31.1's public `rdpsndDevicePlugin` callbacks do not receive the wave block number or
server timestamp, while its core sends both Wave Confirm PDUs around `Play`/`PlayEx`. The stable
`mr_rdpsnd` callback contract is therefore not wired into the stock plugin and does not send an
additional confirmation. The session-isolated SPSC/AVAudioEngine backend in
`docs/architecture.md` remains Phase 5 work; real PCM negotiation/playback and wire confirmation
are still Phase 0 external gate evidence.

The merged static archive requires the Apple `Foundation` and `AudioToolbox` frameworks. The
artifact verifier links representative FreeRDP/OpenSSL calls and every required static add-in entry
against both SDK slices with those frameworks.

Apple SDK frameworks and system libraries used by the final app are platform prerequisites rather
than redistributed packages, so they are not listed as SPDX packages. Build-only host tools are
also outside this runtime SBOM prototype.

## Reproduce and review

```sh
scripts/build-freerdp-xcframework.sh --dry-run
scripts/build-freerdp-xcframework.sh
scripts/verify-freerdp-xcframework.sh artifacts/FreeRDP.xcframework
scripts/generate-dependency-metadata.sh
(cd artifacts && shasum -a 256 -c FreeRDP.xcframework.sha256)
```

For an offline build, first populate a clean checkout at the locked commit and retain the verified
OpenSSL archive, then pass `--offline --source-dir ... --openssl-archive ...`. The build emits a
sorted SHA-256 manifest beside the XCFramework. Its entries are relative to the manifest's own
directory, so verify it from `artifacts/` as shown above; invoking `shasum -c` from the repository
root without changing directory intentionally resolves the entries against the wrong base. A
different Xcode/Clang version is recorded by CI or the Phase 0 test record and must be treated as a
distinct binary provenance even when inputs are identical.

On first extraction, the build also writes a sorted SHA-256 manifest of every regular OpenSSL
source file outside the extracted tree. Every reuse checks all hashes and the regular-file count,
so changed, missing, and additional files are rejected. Newline-containing paths, symbolic links,
and special filesystem entries are rejected; empty directories are not authenticated because they
cannot affect compilation. A cached source tree without its manifest must be removed and extracted
again from the locked archive.

The lock also hashes every separately licensed FreeRDP/WinPR source file listed above. This makes a
source update fail before compilation when a bundled notice or generated CLDR table changes.

Each OpenSSL slice has an input-fingerprint stamp covering the dependency lock, source manifest,
deployment target, SDK, Xcode/Clang, target flags, and build profile. Cached libraries are reused
only when that stamp and both `arm64` archives agree. A missing or changed stamp causes fresh
OpenSSL build/install directories. Each FreeRDP slice separately fingerprints its source path and
commit, platform, SDK/Xcode/CMake versions, OpenSSL stamp, and every CMake argument. A missing or
changed FreeRDP stamp, or a CMake cache bound to another source tree, causes a fresh FreeRDP build
directory. Matching build objects may be reused, but every install tree and package directory is
recreated so files removed by a new configuration cannot leak into the XCFramework.

OpenSSL and FreeRDP install through slice-local `DESTDIR` staging with fixed `/usr/local` runtime
prefixes; OpenSSL's runtime configuration path is fixed at `/etc/ssl`. Generated build-flag headers
canonicalize source/build roots, and the verifier rejects common host paths. The XCFramework plist
is normalized to device-then-Simulator order. These rules make manifests comparable across cold
build roots while leaving the actual build provenance in the external test record.

When updating a dependency:

1. Update `config/dependencies/freerdp.lock`, including full commit and archive/license hashes.
2. Review upstream security advisories, release notes, license changes, and `cmake/DepVersions.cmake`.
3. Regenerate and diff `ThirdParty/SBOM.spdx.json`.
4. Run the full two-slice build and static verification; attach the checksum manifest to the test record.
5. Repeat NLA/TLS, certificate DER, channel negotiation, audio callback, archive/private-API, and teardown gates.

This inventory supports engineering review; it is not a substitute for release legal review.
