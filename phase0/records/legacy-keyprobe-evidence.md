# Legacy KeyProbe evidence inventory

This inventory preserves what can be established from the pre-Phase 0 `work/getiPadKey` assets
without turning them into a baseline they cannot support.

| Field | Observation |
|---|---|
| Screenshot | `work/KeyProbe_ScrShot.jpeg` (ignored research asset) |
| SHA-256 | `4e3403ac0ef9783e05a7db26867e968af4eadd3f6761769a3c5eb807d33ef243` |
| Visible capture time | 2026-09-03 22:05:11 local time (timezone not recorded) |
| EISU / HID LANG2 0x91 | detected by UIKit and GCKeyboard |
| KANA / HID LANG1 0x90 | detected by UIKit and GCKeyboard |
| Last visible KANA event | `pressesEnded`; GC `pressed=false` |
| `super.presses*` policy | ON |
| Build recheck | unsigned generic iOS Release build succeeded with Xcode 26.6 on 2026-09-04 |

The image does **not** establish the device model, iPadOS version/build, keyboard model/firmware,
connection transport, relevant settings, EISU key-up symmetry, call-super=false behavior, RDP scan
codes, or the 100-cycle requirement. It therefore supports feasibility only and cannot mark any
Phase 0 gate row `PASS`.

Recheck command:

```bash
xcodebuild -project work/getiPadKey/KeyProbe.xcodeproj \
  -scheme KeyProbe -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/mremote-keyprobe-derived \
  CODE_SIGNING_ALLOWED=NO build
```
