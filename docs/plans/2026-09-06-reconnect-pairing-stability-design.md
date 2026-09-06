# Reconnect Pairing Stability Design

## Goal

Never present calibration from a partial or moving reconnect topology. A pairing prompt may become visible only after every attached WCH controller has one compatible display candidate, that complete topology has remained unchanged across consecutive observations, and fresh CoreGraphics and AppKit state agree on the target display.

## Incident evidence

On September 6, the driver observed the two touch controllers before both video endpoints were visible. The log sequence was:

- zero compatible displays and one controller;
- one compatible display and two controllers;
- immediate presentation for display ID 3;
- the second compatible display appearing only on a later refresh.

The coordinator therefore treated a transient one-display snapshot as authoritative. The overlay controller also ordered its window to the front before its final screen/frame check, so a rejected placement could still flash on the wrong display.

## Considered approaches

### Increase the existing debounce

A longer fixed debounce reduces the chance of the race but cannot prove that enumeration is complete. USB and video endpoints can arrive many seconds apart, and this incident had no timely display callback after the second endpoint became visible.

### Move a visible prompt when topology changes

Following the target after presentation would correct its final position, but a user could already have touched while the prompt was on the wrong screen. Calibration must not authorize that interval.

### Complete-topology stability gate

The selected approach treats pairing as unsafe while compatible-display and controller counts disagree. It retries discovery while incomplete, then requires the same controller identities and display identities, descriptors, and bounds on consecutive observations before presentation. This provides evidence that the one-to-one topology is complete and stationary without guessing from timing alone.

## Coordinator behavior

Valid resolved mappings continue to route normally. Pairing of unresolved endpoints follows these rules:

1. Derive unresolved controllers and unused compatible displays from the fresh reconciliation snapshot.
2. If either side is empty, hide calibration and stop or wait as appropriate.
3. If the unresolved controller and unused display counts differ, hide calibration and schedule another bounded-frequency discovery refresh.
4. Build a stability signature from all attached controller runtime identities plus all compatible display IDs, public descriptors, and CoreGraphics bounds.
5. Require the production coordinator to observe that same signature twice. The first observation hides calibration and schedules the confirming refresh.
6. Only after confirmation may the existing one-at-a-time pairing flow present a prompt.
7. Reset stability evidence after HID removal, display reconfiguration, AppKit screen-parameter change, or any signature change.

The incomplete-topology retry remains active at low frequency because the incident proved that no useful display callback is guaranteed after the missing endpoint becomes queryable. Once the topology is complete or there is nothing left to pair, the retry is cancelled.

## Overlay placement

Immediately before creating the window, the overlay controller re-reads the target display's active membership, vendor, model, serial, and CoreGraphics bounds. Those values must still match the coordinator snapshot. It then resolves a fresh `NSScreen` by `NSScreenNumber`, validates the AppKit frame against the fresh CoreGraphics bounds, creates the window on that screen, and checks the still-hidden window's screen and frame. `orderFrontRegardless()` runs only after every check passes.

Any mismatch returns `false`; no window becomes visible and the coordinator retries from a new display snapshot.

## Verification

Automated coverage must prove:

- two controllers plus one compatible display never presents calibration;
- incomplete topology is re-enumerated and begins pairing only after the missing display appears;
- a complete topology must remain identical across consecutive production observations;
- a bounds or identity change resets stability instead of presenting stale placement;
- rejected post-creation placement cannot be ordered visibly;
- existing pairing, mapping, gesture, persistence, and topology tests remain green.

Local acceptance requires warning-clean tests and release build, whitespace validation, a signed LaunchAgent installation, current three-display descriptor/geometry agreement, and a running replacement process. Physical reconnect placement remains the final hardware acceptance check.

## Release boundary

The fix belongs on the fork's local `main`. It may be installed locally after verification. No fork push and no upstream PR change are authorized by this repair request.
