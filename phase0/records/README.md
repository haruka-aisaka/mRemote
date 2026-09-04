# Phase 0 records

The first physical-device run needs only a Core Adoption test record. Do not fill in the detailed
JSON baseline or create a compatibility matrix before that run. Those records become useful only
after choosing to support more than the personal iPad, keyboard, and Windows configuration.

That run happened on 2026-09-05 and the decision is `GO`. Completed records match `*.local.*` and
are deliberately not committed, because they name the operator and the Windows host; the decision
itself and its redacted summary live in `phase0/README.md`, which is committed. The unfilled
`*.local.*` copies of the detailed JSON baseline and the compatibility matrix are placeholders
only -- fill them from the templates if another device or keyboard ever needs to be supported.

Before a run:

```bash
cp phase0/records/phase0-test-record.template.md \
  phase0/records/phase0-test-<run-id>.local.md
```

Complete the short Markdown record and validate it with:

```bash
phase0/records/validate-phase0-markdown.sh \
  phase0/records/phase0-test-<run-id>.local.md
```

The Core record has seven tests: device build, NLA/TLS trust, one displayed desktop frame, Eisu,
Kana, IME suppression, and teardown. `GO` requires all seven to pass and means only that this
FreeRDP bridge is suitable for the recorded personal baseline. It is not a product, compatibility,
or release decision.

## Deferred validation

When a feature is implemented or another environment is supported, create the detailed JSON
baseline and optional matrix from their templates. They record pointer hardware, iPadOS settings,
Windows layout, and additional device combinations; they are deliberately not prerequisites for the
first Core decision.

Validate a completed JSON baseline with:

```bash
phase0/records/validate-input-baseline.sh \
  phase0/records/input-baseline-<short-id>.local.json
```

The JSON and matrix validators remain available for compatibility work. A `COMPLETE` matrix still
requires all linked records to pass, but it does not redefine the personal Core decision.

Run regression checks after changing record tooling:

```bash
phase0/records/tests/test-validator.sh
phase0/records/tests/test-phase0-markdown-validator.sh
```
