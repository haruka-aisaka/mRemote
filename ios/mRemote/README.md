# mRemoteKit

The layers of the product app that do not need UIKit, so they can be built and
tested on the development host without a Simulator. Module boundaries follow
[`docs/architecture.md`](../../docs/architecture.md) section 3; dependencies
point downwards only.

| Module | Holds | Depends on |
|---|---|---|
| `SessionCore` | profiles, global settings, the resolver, session state, the `RemoteSession` protocol, `SessionManager`, `FakeRemoteSession` | Foundation |
| `Persistence` | the versioned profile document, its migration chain, the profile store and repository | `SessionCore` |
| `AppleAdapters` | Keychain credential and trust repositories, OSLog categories, log redaction | `SessionCore`, Security |

Nothing here imports a protocol implementation. FreeRDP types stop at the
bridge, and the RDP session adapter will sit beside these modules rather than
inside them.

## Build and test

```sh
swift build --package-path ios/mRemote
swift test --package-path ios/mRemote
```

The active toolchain must be a full Xcode rather than the Command Line Tools,
otherwise the test targets cannot resolve XCTest:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path ios/mRemote
```

## What is deliberately not covered by these tests

- `KeychainCredentialRepository` and `KeychainTrustRepository` issue real
  Keychain queries, which need a signed host app. The tests cover the decision
  logic and the in-memory implementations; the queries are exercised on device.
- `FileProfileStore` writes with the iOS data protection class, which only
  applies on iOS. The host tests cover the round trip, not the protection.
