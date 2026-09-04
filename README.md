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
| `mRemote.xcodeproj`, `App/` | The app: the connection list, the profile editor, settings and the full-screen session workspace. `AppTests/` and `AppUITests/` sit beside it. |
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

Phase 1 meets its exit criteria: the app runs end to end against
`FakeRemoteSession`, passwords never reach the profile document, the schema is
versioned with a tested migration chain, and a second protocol would be added
by registering a factory rather than by changing a call site.

Phase 2 is next: the real RDP session behind the same `RemoteSession`
interface, and the Metal surface behind the workspace's placeholder.

## Build and test

```sh
# The app, its unit tests and the end-to-end UI test
xcodebuild test -project mRemote.xcodeproj -scheme mRemote \
  -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)'

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
