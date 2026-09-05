# mRemoteKit

The layers of the product app that do not need UIKit, so they can be built and
tested on the development host without a Simulator. Module boundaries follow
[`docs/architecture.md`](../../docs/architecture.md) section 3; dependencies
point downwards only.

| Module | Holds | Depends on |
|---|---|---|
| `SessionCore` | profiles, global settings, the resolver, session state, the `RemoteSession`/`DesktopSession` protocols, `SessionManager`, `FakeRemoteSession`, the desktop frame store and `ViewportTransform` | Foundation |
| `Persistence` | the versioned profile document, its migration chain, the profile store and repository | `SessionCore` |
| `AppleAdapters` | Keychain credential and trust repositories, OSLog categories, log redaction | `SessionCore`, Security |
| `RDPProtocol` | the C bridge's status/phase/channel vocabulary, FreeRDP error mapping, staged certificate trust evaluation and the review policy | `SessionCore`, Security |
| `InputCore` | pointer normalisation: pressed-button state, scroll quantisation, and the local-to-remote mapping. No protocol mapping, so no scan code appears here | `SessionCore` |

Nothing here imports FreeRDP. `RDPProtocol` is the RDP-specific half that does
not need it - error categories, certificate evaluation, the review policy -
and it mirrors the C ABI's constants rather than including the header, so the
package builds and tests with no native artifact present. The session adapter
that actually calls the bridge lives in `App/RDP/`, because it needs a
bridging header and the generated XCFramework; declaring that XCFramework as a
`binaryTarget` here would make the whole package unresolvable, `swift test`
included, wherever `artifacts/` has not been built.

## Build and test

```sh
swift build --package-path Packages/mRemoteKit
swift test --package-path Packages/mRemoteKit
```

The active toolchain must be a full Xcode rather than the Command Line Tools,
otherwise the test targets cannot resolve XCTest:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/mRemoteKit
```

## What is deliberately not covered by these tests

- `KeychainCredentialRepository` and `KeychainTrustRepository` issue real
  Keychain queries, which need a signed host app. The tests cover the decision
  logic and the in-memory implementations; the queries are exercised on device.
- `FileProfileStore` writes with the iOS data protection class, which only
  applies on iOS. The host tests cover the round trip, not the protection.
- `RDPProtocol` is tested against the header rather than against the bridge:
  `RDPBridgeStatusABITests` reads `bridge/include/mremote/rdp_bridge.h` and
  fails if the mirrored constants drift. Running the bridge itself needs the
  Simulator, and those tests live in `AppTests/RDPRemoteSessionTests`.
