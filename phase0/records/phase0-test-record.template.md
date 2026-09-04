# Phase 0 Core Adoption test record

## Run metadata

| Field | Value |
|---|---|
| Run ID | `__REQUIRED__` |
| Date/time and timezone | `__REQUIRED__` |
| Git commit | `__REQUIRED__` |
| FreeRDP commit | `__REQUIRED__` |
| Harness build/configuration | `__REQUIRED__` |
| Windows target (redacted name) | `__REQUIRED__` |
| Operator | `__REQUIRED_OR_REDACTED__` |

Record only the environment details that can affect this run in the Notes column. Store large/raw
evidence under the ignored `phase0/records/evidence/<run-id>/` directory. Do not commit passwords,
certificate private keys, framebuffer dumps, clipboard contents, or printable-key traces.

## Results

Use `PASS`, `FAIL`, `BLOCKED`, or `NOT RUN`. A `PASS` requires evidence someone can review later;
at this project's scale (`docs/README.md`, "開発体制と試験スケール") a recorded operator
observation counts, as long as the row says what was actually observed and what was deferred.
These seven rows decide only whether to adopt the native core on this personal baseline.

| ID | Result | Evidence / measured value | Notes |
|---|---|---|---|
| `P0-BUILD-01` pinned FreeRDP/WinPR device arm64 slice | `NOT RUN` | XCFramework metadata, source commit/checksum, build log SHA-256 | |
| `P0-TLS-01` NLA/TLS connection and authoritative SecTrust SSL hostname evaluation | `NOT RUN` | redacted leaf/chain fingerprints, SecTrust result, challenge decision | Gate |
| `P0-DSP-01` connected desktop presents a BGRA frame | `NOT RUN` | redacted screenshot or frame counter and desktop resolution | |
| `KEY-EISU-01` HID 0x91 to scan 0x7B down/up | `NOT RUN` | operator observation, or an EISU-only KeyEcho JSONL SHA-256 with `target_mode=eisu` and its down/up/repeat/mismatch/unexpected counts | Gate |
| `KEY-KANA-01` HID 0x90 to scan 0x79 down/up | `NOT RUN` | operator observation, or a KANA-only KeyEcho JSONL SHA-256 with `target_mode=kana` and its down/up/repeat/mismatch/unexpected counts | Gate |
| `KEY-IME-02` consumed press does not show iPadOS IME/input-source UI | `NOT RUN` | screen recording or observer notes; call-super=false | Gate |
| `P0-TEARDOWN-01` stop/destroy wakes waits and drains callbacks | `NOT RUN` | sanitizer/stress iteration result | Gate |

## Gate decision

`GO` requires all seven Results rows to be `PASS`. It means only that this FreeRDP bridge can be
adopted for the recorded personal baseline; it is not a product or release decision. Otherwise
keep `UNDECIDED`, unless an explicit rejection is recorded as `NO-GO`.

- Decision: `UNDECIDED` (`GO`, `NO-GO`, or `UNDECIDED`)
- Accepted FreeRDP version/commit: `__PENDING__`
- Minimum OS: `iPadOS/iOS 17.0` (provisional)
- Deferred validation: `__PENDING__`
- Rationale and unresolved risks: `__REQUIRED__`
