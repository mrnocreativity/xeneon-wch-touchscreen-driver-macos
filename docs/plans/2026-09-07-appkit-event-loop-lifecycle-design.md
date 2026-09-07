# AppKit Event Loop Lifecycle Design

## Goal

Keep the long-running touch driver responsive to WindowServer while preserving its existing HID, pairing, gesture, signal, and LaunchAgent behavior.

## Incident evidence

After the installed process had run for roughly 34 hours, both connected touch controllers still delivered reports and the gesture queue still recognized taps. The LaunchAgent had not crashed or restarted, both display mappings remained resolved, and a process sample found no worker deadlock. However, WindowServer repeatedly logged that the driver process failed to act on dequeued pings before timing out.

The application creates `NSApplication`, uses AppKit screens and windows, and registers AppKit notifications, but then blocks the main thread in `CFRunLoopRun()`. That services Core Foundation sources without running `NSApplication`'s event-dispatch loop. HID callbacks on the separate gesture queue can therefore remain active while AppKit/SkyLight considers the process unresponsive.

## Immediate recovery

Restart the existing LaunchAgent with `launchctl kickstart -k`. This replaces the stale process without deleting configuration or pairings. It is a recovery step, not the structural repair.

## Considered approaches

### Restart only

A manual restart restores a fresh process but leaves the lifecycle defect unchanged.

### Add a watchdog

A watchdog could restart the process when responsiveness degrades. It would mask the broken event-loop ownership, interrupt active gestures, and add another failure path.

### Let AppKit own the main event loop

The selected approach replaces the bare Core Foundation loop with `NSApplication.run()`. Shutdown calls `NSApplication.stop(_:)` on the main thread and posts an application-defined wake event so a stop requested outside normal event dispatch cannot leave the loop sleeping.

## Lifecycle behavior

Startup continues to:

1. create the shared `NSApplication` and use accessory activation policy;
2. verify synthetic-event permission;
3. register display and AppKit screen observers;
4. install signal handlers;
5. start the HID monitor and schedule initial reconciliation;
6. enter the AppKit-owned event loop.

The HID monitor and gesture classifier remain on their existing serial queue. Pairing state, coordinate mapping, touch validation, and event synthesis do not change.

Shutdown continues to stop HID input, cancel timers and work items, end active gestures, hide pairing UI, unregister callbacks, and remove signal sources. It then stops and wakes the AppKit event loop. `SIGINT` and `SIGTERM` therefore retain graceful cleanup rather than relying on process termination.

## Verification

- Run the complete Swift test suite with warnings as errors.
- Build release with warnings as errors and run script/plist/whitespace checks.
- Install with the existing Developer ID identity while preserving the configuration and pairing hashes.
- Verify graceful replacement: the old process logs `Stopped`, the new process starts, finds both HID controllers, and resolves both mappings.
- Confirm the new process is in `NSApplication.run()` and WindowServer produces no missed-ping entries during the immediate soak.
- Keep physical taps on both panels as the visible acceptance check.

## Release boundary

Commit the lifecycle repair to local `main` and install it on this Mac. Do not push the fork or change the upstream PR without separate authorization.
