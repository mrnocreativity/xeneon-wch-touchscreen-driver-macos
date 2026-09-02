# Prechen Multi-Display Touch Design

## Goal

Turn the existing single-display WCH `27c0:0859` driver into a standalone macOS touch utility that supports multiple identical Prechen displays.

## Product behavior

- Each physical touchscreen is paired once with a physical display.
- Pairing uses a native full-screen overlay: the app asks the user to touch the indicated display and records which USB controller produced the raw report.
- Pairings persist across login, restart, sleep, display rearrangement, scaling changes, and ordinary unplug/replug cycles.
- Missing or ambiguous hardware is suspended instead of being routed to the wrong display.
- Replaced displays or controllers trigger pairing again when stable identities no longer match.
- One-finger tap clicks, immediate movement scrolls, and hold-then-move performs a mouse drag.

## Identity and persistence

Touch devices are identified by their IOHID location ID and controller profile. Displays are identified by CoreGraphics display UUID with EDID vendor/model/serial and last-known bounds retained as diagnostics and conservative recovery hints.

The persisted mapping is:

`touch controller location ID -> display UUID`

The application never guesses when two compatible candidates are indistinguishable. It enters pairing mode instead.

## Architecture

### HID device monitor

The monitor creates one device session for each matching WCH mouse interface (report ID `0x07`, seven-byte reports). Each session owns its parser and carries its location ID into every normalized touch event. Non-touch digitizer and vendor interfaces are ignored.

Production opens the matching interface exclusively so macOS does not also move the cursor on the main display.

### Session router

The router resolves the event's controller location ID to a persisted display UUID, resolves that UUID to the current CoreGraphics display ID and bounds, and sends the event to an independent gesture controller for that pairing.

Each controller therefore has isolated parser, gesture, timeout, and display state. Removing one device cannot cancel another device's gesture.

### Display registry

The registry enumerates active CoreGraphics displays, derives stable UUIDs, listens for display-reconfiguration callbacks, and refreshes bounds without changing approved pairings. It exposes candidate displays for pairing and reports missing mappings.

### Pairing coordinator

When an unpaired controller or unresolved display exists, normal event injection for that controller is suspended. The coordinator presents a native AppKit overlay on one candidate display at a time. The first unpaired controller that produces a down event is bound to that display. The mapping is written atomically, confirmed visually, and the coordinator advances.

Pairing can be cancelled safely. Existing valid mappings remain active while only unresolved controllers are paired.

### Gesture classifier

The single-touch controller begins in a pending state:

- Lift without meaningful movement: inject a click at the touched point.
- Movement beyond a small threshold before the hold deadline: emit pixel scroll events with began/changed/ended phases.
- Hold without movement until the deadline: enter drag mode and inject mouse down/drag/up.

The cursor is borrowed only when required and restored after click or drag. Scroll targets the touched location without posting a mouse-down event. Initial tuning is configurable and covered by deterministic unit tests.

## Recovery and failure handling

- LaunchAgent starts the driver at login.
- HID attach/removal and display reconfiguration rebuild live sessions without discarding stored mappings.
- A missing display suspends its controller.
- A changed USB location or display UUID creates an unresolved pairing and prompts instead of falling back to the main display.
- Stuck contact timeouts end scroll or post mouse-up as appropriate.
- Permissions and pairing state are recorded in the existing file and unified logs.

## Verification

- Unit tests cover device identity, per-device parser isolation, persistence, UUID resolution, ambiguous recovery, coordinate mapping, click, scroll, hold-drag, cancellation, and timeouts.
- Local build and the full Swift test suite must pass.
- Physical acceptance uses both Prechen displays simultaneously: taps and scrolls must remain on their paired displays, unplug/replug must recover, rearranging displays must update bounds, and restarting the LaunchAgent must restore both mappings.

## Constraints

- The WCH firmware provides only one contact on macOS, so true multi-finger gestures are unavailable.
- The solution uses documented native macOS frameworks for HID input, display discovery, pairing UI, and event synthesis.
