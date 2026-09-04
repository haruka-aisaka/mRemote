# Phase 0 iOS Surface/Input Harness

This standalone iOS 17+ app exercises the Phase 0 surface, input, trust, and
native-session boundaries. The default scheme remains usable without an RDP
connection:

- validated BGRA desktop updates rendered by one `MTKView`, with 720p/1080p/4K
  fixtures and app-side upload/present timing counters;
- a physical-keyboard responder that does **not** conform to `UIKeyInput`;
- an Objective-C `UIKey.keyCode` adapter plus a Debug comparison with Swift's
  public `rawValue` API;
- independent per-usage UIKit/GCKeyboard/Off selection for Eisu and Kana, plus
  duplicate/orphan suppression before one recording input sink;
- an explicit Phase 0 mapping of Eisu/Kana HID usages to Set 1 `0x7B`/`0x79`;
- fixed UIKit/GCMouse pointer source selection, button release on focus loss,
  hover/move, left/right button, and vertical/horizontal scroll observation;
  axis-independent fractional wheel accumulation and an explicit Normal/Reversed
  remote-scroll control;
- host/local IME modes using a small `UITextView` (`UITextInput`) proxy. Host
  mode requests an ASCII-capable keyboard and disables local correction;
  local mode records marked text locally and forwards only committed text;
- an optional host/port/domain/user/password connection form. The password
  uses secure entry, is cleared on connect, export, backgrounding, and
  teardown, and is held by a redacting, explicitly cleared model.

The stable switching input sink starts on the recording destination and can
move to a FreeRDP-backed session without rebuilding the input arbiters. The
ordinary `Phase0Harness` scheme intentionally remains fixture-only and does
not require a generated native artifact.

The Metal shaders are compiled from source at runtime so this standalone
harness remains buildable without a repository-generated `.metallib`. This is
a harness tradeoff, not the intended production shader packaging strategy.

## Open and run

1. Open `Phase0Harness.xcodeproj` in Xcode.
2. Select the `Phase0Harness` scheme and an iOS 17+ device or Simulator.
3. Choose a development team if device signing requires one.
4. Run. The project generates its Info.plist and has no package dependencies.

Both app targets generate an Info.plist containing
`NSLocalNetworkUsageDescription` for connections to user-selected Windows
computers on the local network.

Command-line Simulator build (signing disabled):

```sh
xcodebuild \
  -project tools/Phase0Harness/Phase0Harness.xcodeproj \
  -scheme Phase0Harness \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Run unit tests on an installed Simulator by replacing the destination:

```sh
xcodebuild \
  -project tools/Phase0Harness/Phase0Harness.xcodeproj \
  -scheme Phase0Harness \
  -destination 'platform=iOS Simulator,name=<installed iPad simulator>' \
  CODE_SIGNING_ALLOWED=NO test
```

The protocol-independent input and `SecTrust` tests can also run without a
Simulator:

```sh
swift test --package-path tools/Phase0Harness
```

## Native RDP smoke build

The shared `Phase0HarnessNative` scheme compiles the same harness with
`PHASE0_NATIVE` and statically links these generated artifacts:

- `artifacts/FreeRDP.xcframework`
- `artifacts/mRemoteRDPBridge.xcframework`

Build and verify both artifacts from the repository root before selecting the
native scheme:

```sh
scripts/build-freerdp-xcframework.sh
scripts/verify-freerdp-xcframework.sh artifacts/FreeRDP.xcframework
scripts/build-rdp-bridge-xcframework.sh
scripts/verify-rdp-bridge-xcframework.sh \
  artifacts/mRemoteRDPBridge.xcframework \
  artifacts/FreeRDP.xcframework
```

Then build or archive the statically linked app:

```sh
xcodebuild \
  -project tools/Phase0Harness/Phase0Harness.xcodeproj \
  -scheme Phase0HarnessNative \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/mremote-phase0-native-build \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild \
  -project tools/Phase0Harness/Phase0Harness.xcodeproj \
  -scheme Phase0HarnessNative \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/mremote-phase0-native.xcarchive \
  -derivedDataPath /tmp/mremote-phase0-native-archive-build \
  CODE_SIGNING_ALLOWED=NO archive
```

`Phase0HarnessNative` Release enables dead-code stripping and installed-product
stripping for the distribution-shaped archive while retaining `-all_load` for
the required static add-ins. To retain local symbols for a separate static-link
inspection, use the non-distributable audit scheme:

```sh
xcodebuild \
  -project tools/Phase0Harness/Phase0Harness.xcodeproj \
  -scheme Phase0HarnessNativeSymbolAudit \
  -configuration SymbolAudit \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/mremote-phase0-native-symbol-audit.xcarchive \
  -derivedDataPath /tmp/mremote-phase0-native-symbol-audit-build \
  CODE_SIGNING_ALLOWED=NO archive

scripts/verify-phase0-native-archives.sh \
  /tmp/mremote-phase0-native.xcarchive \
  /tmp/mremote-phase0-native-symbol-audit.xcarchive
```

On **Connect**, the native variant creates the bridge session on a dedicated
worker and switches the stable input sink to it. Certificate DER and desktop
frames are copied before their callbacks return. System-trusted certificates
are accepted through `SecTrust` with an SSL hostname policy. A leaf-first
presented chain that separately passes terminal-certificate-anchored Basic
X.509 and hostname-aware SSL checks may present the endpoint, leaf SHA-256,
and trust summary for an explicit
one-session **Trust Once** or **Reject** decision. Expired certificates and
hostname mismatches are rejected without an override action. Trust Once is
not persisted. Exportable certificate diagnostics record the outcome,
`SecTrust` result, and SHA-256 fingerprints for the leaf and every entry in the
ordered presented chain; they never include DER, hostname, subject/issuer, or
credentials. A malformed callback that cannot be safely copied is rejected as
a bridge contract failure before trust evaluation and cannot be used as
certificate evidence. As in normal TLS delivery, a server may omit its root.
For session-only classification the final presented intermediate is then the
temporary anchor, while every presented leaf-to-intermediate link still has to
pass both policies. Stop/teardown closes the input gate before destroying the
native session.

The `SymbolAudit` configuration deliberately disables dead-code and
install/copy stripping. Symbol presence there, or in the distribution
archive's dSYM, establishes static inclusion only; it does not prove channel
negotiation or data round trips.

## Device checks

The Simulator is useful for build, logic, and basic UI checks only. Run these
on the baseline iPad and export the in-memory log after each case.

1. Fill in the record header fields before export: device model, OS
   version/build, keyboard/mouse model and connection, keyboard layout,
   Caps Lock/Globe assignment, Full Keyboard Access, modifier remapping,
   Stage Manager/Split View, and orientation.
2. In **Hardware** mode, select **UIKit** and press Eisu (`0x91`) and Kana
   (`0x90`) 100 times. Each cycle must have one `SEND key down` and one
   `SEND key up`. Selected presses are consumed without calling `super`.
   Confirm that iPadOS shows no candidate or input-source UI (`KEY-IME-02`).
3. Repeat while GCKeyboard observation is connected. `OBS GCKeyboard` may
   appear, but with UIKit selected it must be followed by `DROP source`, never
   a second `SEND` (`KEY-DUP-01/02`).
4. Only after a device matrix proves UIKit delivery is unsuitable for a
   usage, change that usage's **Eisu** or **Kana** selector to **GC** (or
   **Off** if unsupported). Other usages remain on UIKit. Policy changes wait
   until all observed keys are neutral.
5. Hold a key, tap **Release all**, then release it. The sink must receive one
   synthetic up; later physical tails are quarantined and dropped until both
   UIKit and GameController observations report that usage neutral.
6. Switch to **Host IME**, start with Japanese enabled system-wide, and show
   the keyboard. Confirm an ASCII layout, no marked text, and one host ASCII
   sink event per tap (`SFT-POC-01`). This is an observation, not proof that
   every OS/input-source combination is suppressed.
7. Switch to **Local IME**. During composition, `MARKED` changes but no
   committed-text `SEND` appears. Commit once and verify one `SEND text`.
8. With **UIKit pointer** selected, check left/right click and drag, vertical
   and horizontal scroll, cancellation, and focus loss. Exercise both **Normal**
   and **Reversed** remote scroll directions and record signed vertical and
   horizontal totals; the harness applies this choice exactly once and does not
   infer the OS natural-scroll setting. Then choose
   **GCMouse** and verify that UIKit events become observations/drops and only
   GC callbacks reach the sink. Do not infer a merge from timestamps.
9. Select **720p**, **1080p**, then **4K** and tap **Dirty update** repeatedly.
   The colored rectangle and frame counter must update without retaining a
   FreeRDP-owned buffer. Record `apply` CPU milliseconds, completed-present
   milliseconds, and their counts from the status line; the same measurements
   are written to the exported trace.
10. While holding a key/button and while composing marked text, deactivate and
    reactivate the app. Inactive callbacks must be dropped, marked text must be
    cancelled, and only Hardware mode may reopen the hardware gate on resume.
11. In Hardware mode, tap, hover, and wheel over each local selector/button,
    the scrolling page, the environment-notes editor, and **Export** while
    GCMouse is selected. The gate must close before those local actions and no
    click/scroll may reach the sink. Only tapping the surface or **Focus /
    keyboard** may intentionally recapture input. Confirm this from the export:
    UIKit hit testing and GameController callback ordering is not API-guaranteed.
12. Repeat the connection cases with the signed `Phase0HarnessNative` scheme.
    For a system-trusted server, verify that connecting reaches the native
    surface without a trust prompt. For an intentionally untrusted server,
    verify the displayed endpoint and leaf SHA-256 out of band, then exercise
    **Reject** and **Trust Once** in separate sessions. A later session must
    prompt again.
13. While the native session is connected, confirm the channel counter reports
    `cliprdr`, `rdpsnd`, and `drdynvc` connected. Tap **Cliprdr probe** once;
    correlate its ID, four stage counts, byte count, and SHA-256 with Windows or
    wire-side evidence. The payload body is intentionally absent from the
    trace/export. Select each fixture size and tap **Send DISP size** only when
    `disp` is connected; correlate its request ID/dimensions/status and the
    resulting desktop update. Repeat keyboard, pointer, and PCM cases. Static
    archive symbols or mock callbacks are not a substitute for these observations.
14. Disconnect and repeat while a key/button is held, while a certificate
    review is open, and while backgrounding the app. Input must switch back to
    the recording sink, pending trust must reject, the worker must finish, and
    the trace must record both run and destroy status.

`Export` includes only the explicitly entered environment notes and this
development harness's redacted event trace. Printable hardware-key outcomes
increment aggregate counters without creating event lines; Eisu/Kana are the
explicit non-printable event-detail allow-list. Detailed raw fixture events are
retained in memory only in Debug builds. Do not enter passwords in environment
notes.

The connection endpoint, account, and password are never appended in plaintext
to the trace or export; their diagnostic descriptions use literal redaction
markers. Text input diagnostics retain lengths only, and the in-memory fixture
record is bounded and cleared with the trace. In a fixture-only build,
**Connect** validates the form, clears the password, and reports that the
native bridge is absent.

## Known Phase 0 limits

- The native device and Simulator products can be compiled and the Release
  archive can be inspected without signing, but real Windows NLA/TLS, system
  trust/Trust Once interaction, desktop updates, input delivery, channel data,
  and PCM playback still require a signed physical-device run and independent
  Windows/wire evidence.
- This app records normalized output; Windows scan-code receipt still needs
  the repository's separate KeyEcho/end-to-end runbook.
- UIKit pointer delivery differs by OS/device. The app exposes raw mask/state
  transitions so the baseline run can decide whether UIKit or GCMouse is the
  supported route; it does not declare either route validated in advance.
- UIKit `touchesEnded`/`touchesCancelled` currently closes the observed button
  mask as one gesture boundary. Whether iPadOS emits a separate remaining mask
  for simultaneous multi-button presses is device/OS dependent; explicitly
  test this case before calling UIKit pointer capture lossless.
- `keyboardType = .asciiCapable` is a public trait request, not an API that
  forcibly changes the user's input source. `SFT-POC-01` therefore remains a
  device result.
- The local IME proxy proves composition separation only. Unicode-to-RDP
  encoding and clipboard fallback belong to the later protocol adapter.
- Fixture updates use one shared Metal texture and synchronously wait for its
  preceding command buffer before each CPU replace. `apply` timing includes
  that wait and reports it separately. This removes the read/write race for the
  manual fixture, but is not a sustained callback-rate architecture: the
  production renderer still needs immutable/multi-buffered slots with GPU
  lifetime tracking before the sustained `P0-DSP` gate can pass.
