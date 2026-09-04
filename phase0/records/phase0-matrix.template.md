# Phase 0 matrix completion record

Use one copy for each candidate FreeRDP version, channel/codec set, and minimum-OS decision. This
record is the completeness index for the immutable input baselines and Phase 0 test records; it is
not test evidence by itself.

## Candidate metadata

| Field | Value |
|---|---|
| Matrix ID | `__REQUIRED__` |
| Git commit | `__REQUIRED__` |
| FreeRDP commit | `__REQUIRED__` |
| Candidate channel/codec set | `__REQUIRED__` |
| Minimum OS under test | `__REQUIRED__` |
| Agreed matrix scope / review reference | `__REQUIRED__` |
| Reviewer | `__REQUIRED_OR_REDACTED__` |

## Agreed combinations

Add a row before testing for every agreed device, OS build, keyboard and transport, pointer and
transport, relevant iPadOS-settings profile, and Windows target/build/layout combination. A baseline
or test record may be referenced by more than one row only when its recorded environment actually
matches every field in those rows.

Use `PASS`, `FAIL`, `BLOCKED`, or `NOT RUN`. Mark a combination `PASS` only when its linked immutable
record or explicitly listed set of records gives `PASS` for every Results row in
`phase0-test-record.template.md`. `P0-MEM-02` may pass with a measured supported-limit decision and
the evidence named in that row; three successful concurrent sessions are not mandatory.

| Combination ID | Device / OS build | Keyboard / transport | Pointer / transport | iPadOS settings profile | Windows target / build / layout | Input baseline record | Phase 0 test record(s) | Result | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `__REQUIRED__` | `__REQUIRED__` | `__REQUIRED__` | `__REQUIRED__` | `__REQUIRED__` | `__REQUIRED__` | `__REQUIRED__.json` | `__REQUIRED__.md` | `NOT RUN` | |

## Completeness review

- Agreed combination count: `__REQUIRED__`
- Rows present: `__REQUIRED__`
- `PASS`: `__REQUIRED__`
- `FAIL`: `__REQUIRED__`
- `BLOCKED`: `__REQUIRED__`
- `NOT RUN`: `__REQUIRED__`
- Missing agreed combinations: `__REQUIRED__`
- Status: `INCOMPLETE` (`COMPLETE` or `INCOMPLETE`)
- Review notes: `__REQUIRED__`

Set `COMPLETE` only when the agreed count equals the number of rows, every row is `PASS`, no agreed
combination is missing, and every referenced Results row has reviewable evidence. Until then the
Phase 0 Gate decision cannot be `GO`; it remains `UNDECIDED` unless the candidate is explicitly
rejected as `NO-GO`.
