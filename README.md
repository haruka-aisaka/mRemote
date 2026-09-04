# mRemote

An RDP client for iPadOS/iOS. Its reason to exist is the Japanese keyboard:
the Eisu and Kana keys on a physical JIS keyboard are sent to Windows as
Muhenkan and Henkan instead of being consumed by the iPadOS input switcher.

This is a personal project, developed by one person against one iPad, one
keyboard and one Windows host. See
[`docs/README.md`](docs/README.md) for the design documents and for the
verification scale everything here is held to.

## Layout

The repository is one product, so the tree is organised by role rather than by
platform.

| Path | Contents |
|---|---|
| `App/`, `mRemote.xcodeproj` | The app itself. Not created yet -- Phase 1 is still building the layers below. |
| `Packages/mRemoteKit/` | The app layers that need no UIKit, so they build and test on the development host: `SessionCore`, `Persistence`, `AppleAdapters`. |
| `bridge/` | The C ABI over FreeRDP. Opaque handles only; no FreeRDP type reaches Swift. |
| `scripts/`, `config/`, `ThirdParty/`, `artifacts/` | Reproducible builds of the pinned native dependencies, their lock file, notices and SBOM, and the generated XCFrameworks. |
| `tools/KeyEcho/` | A Win32 recorder that logs what scancodes actually arrived at Windows. |
| `tools/Phase0Harness/` | The UIKit/Metal spike app. Now a fixture for physical input checks rather than product code. |
| `docs/` | Requirements, architecture, input design, UI flow, data and security, test plan, roadmap. |
| `phase0/` | The Go/No-Go spike: its decision, records and notes. |

## Status

Phase 0 is closed with a `GO` for the personal baseline: FreeRDP runs on
device, a real NLA/TLS session renders a desktop, and Eisu/Kana reach Windows
as Muhenkan/Henkan without iPadOS consuming them. See
[`phase0/README.md`](phase0/README.md).

Phase 1 is in progress: the foundation modules exist and are tested; the app
shell and its screens are not built yet.

## Build and test

```sh
# Host-testable app layers
swift test --package-path Packages/mRemoteKit

# Phase 0 harness logic
swift test --package-path tools/Phase0Harness

# C bridge contract tests
cmake -S bridge -B /tmp/mremote-bridge -DBUILD_TESTING=ON -DMR_BRIDGE_BACKEND=unavailable
cmake --build /tmp/mremote-bridge && ctest --test-dir /tmp/mremote-bridge
```

The active toolchain must be a full Xcode rather than the Command Line Tools,
otherwise the Swift test targets cannot resolve XCTest. Prefix with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
`xcode-select -p` points at `/Library/Developer/CommandLineTools`.

Building the native dependencies from source is documented in
[`phase0/README.md`](phase0/README.md).

## License

Dependency licenses and the SBOM are under [`ThirdParty/`](ThirdParty/).
