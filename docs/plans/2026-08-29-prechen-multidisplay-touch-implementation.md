# Prechen Multi-Display Touch Implementation Plan

1. Add display UUID snapshots, persisted pairing models, and atomic mapping storage.
2. Refactor HID monitoring to filter the WCH mouse interface and emit events tagged with controller location ID.
3. Add a per-controller session router with isolated parsers and gesture controllers.
4. Add AppKit pairing overlays and pairing coordination for unresolved controllers.
5. Replace unconditional mouse dragging with the tap, pixel-scroll, and hold-to-drag classifier.
6. Extend configuration and installation defaults without breaking existing single-display installs.
7. Add focused tests for identities, routing, persistence, pairing decisions, gesture classification, and recovery.
8. Build, run the full test suite, reinstall, and perform two-display physical acceptance.
