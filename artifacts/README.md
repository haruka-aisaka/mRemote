# Generated native artifacts

`scripts/build-freerdp-xcframework.sh` writes the static `FreeRDP.xcframework`, SPDX SBOM copy, and
per-file SHA-256 manifest here. `scripts/build-rdp-bridge-xcframework.sh` writes the separate static
`mRemoteRDPBridge.xcframework` and its manifest. Binary artifacts are intentionally not committed.
The bridge artifact contains the pinned adapter but does not copy FreeRDP into itself; the final app
links both XCFrameworks and must select matching device or Simulator slices.

Manifest paths are relative to this directory. Verify them from the repository root with:

```sh
scripts/verify-freerdp-xcframework.sh artifacts/FreeRDP.xcframework
scripts/verify-rdp-bridge-xcframework.sh \
  artifacts/mRemoteRDPBridge.xcframework \
  artifacts/FreeRDP.xcframework
(cd artifacts && shasum -a 256 -c FreeRDP.xcframework.sha256)
(cd artifacts && shasum -a 256 -c mRemoteRDPBridge.xcframework.sha256)
```
