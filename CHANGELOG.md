# Changelog

## Unreleased

- Separates responsiveness pauses from pairing invalidation: independent HID observation and AppKit probes retain verified associations through scheduling delays while blocking stale input. Adds bounded asynchronous file logging, read-only status diagnostics, and interactive LaunchAgent scheduling. Real endpoint changes and sleep/wake still require fresh ambiguous pairing.
- Restores one central touch-and-release per display. Centralizes storm-safe calibration admission, keeps touch reports out of topology reconciliation, and waits for unresolved controllers to recover without repeatedly reopening prompts.
- Preserves storm evidence across display-only changes and isolates each controller's gesture-cleanup timer. Earlier calibration revisions require fresh pairing through the corrected flow.
- Keeps idle calibration targets stable instead of restarting every 15 seconds; only an in-progress contact has a release deadline. Adds input-stage counters and calibration decisions to diagnose silent prompts.
- Adds explicit pairing authority states, observation generations, immediate routing suspension, and cancellation of stale gesture/recovery work.
- Requires a fresh physical target contact and verified overlay/topology state before atomically committing calibration; old pairing schemas require recalibration.
- Limits ambiguous mappings to uninterrupted process observation, with conservative recovery after restart, sleep/wake, membership changes, or responsiveness gaps.
- Adds driver-owned `status`, `re-pair`, and `cancel-pairing` commands through a user-private local socket, plus periodic endpoint inventory and AppKit heartbeat checks.
- Waits for a complete, stable one-to-one controller/display topology before showing reconnect calibration and keeps discovering missing video endpoints when macOS omits a useful display callback.
- Revalidates fresh CoreGraphics identity and bounds against the explicit main and target `NSScreen` records before a pairing window can become visible.
- Runs the accessory application through AppKit's event loop and wakes it during graceful shutdown so WindowServer responsiveness cannot decay while HID input continues separately.
- Uses the current HID IORegistry instance as reconnect evidence; that identifier alone does not establish continuity of the corresponding video endpoint.

## 1.1.0 - 2026-09-02

- Renames the public project to Xeneon WCH Touchscreen Driver for macOS while preserving the installed executable, LaunchAgent, configuration, logs, and pairing paths for upgrade compatibility.
- Documents dated compatibility for the CORSAIR XENEON EDGE and the physically verified Prechen HD-123 / Amazon ASIN `B0CTMNPBX3`, and invites community reports for other `wch.cn TouchScreen` USB `27C0:0859` retail names.
- Uses documented IOHID, CoreGraphics, AppKit, and Foundation APIs for dynamic multi-display pairing and display-change observation.
- Reuses exact runtime assignments only within the current boot and restores across boots only when both public hardware identities are unique.
- Requests calibration after reboot for identical panels with duplicate controller serials or zero display serials instead of guessing from display position.
- Debounces HID and display changes, follows live display bounds, and retries calibration presentation while AppKit finishes login-time display enumeration.
- Migrates version-one runtime UUID pairings safely to an atomic version-two pairing file.
- Lets local installers supply a stable signing identity so macOS privacy approval can survive executable upgrades.
- Recognizes a fast second tap even when it arrives during the first click's delayed cleanup and emits the macOS click-count sequence `1`, then `2`.
- Restores the previously focused application and exact window with documented activation and Accessibility APIs, without a synthetic title-bar click.
- Rejects same-boot controller or display IDs when their current public descriptors no longer match the saved pairing.
- Invalidates ambiguous runtime pairings on hardware membership changes while preserving mappings across bounds-only rearrangement.
- Verifies AppKit screen identity and geometry before showing calibration, retrying instead of placing the overlay on another display.
- Uses the documented kernel boot time for same-boot persistence so sleep does not invalidate pairings, and prunes expired runtime records on load.
- Rejects physically implausible per-controller touch storms before they can move the cursor or produce clicks, scrolling, or dragging, without disabling other attached touchscreens.
- Switches only a confirmed storming controller into bounded confidence tracking so coherent intentional taps and movement can be recovered from interleaved outliers.
- Logs storm entry, periodic aggregate activity, and automatic recovery after one second of raw-report silence using a storm-only one-second GCD interval.
- Holds unconfirmed normal contacts outside gesture synthesis, preventing the hold-to-drag timer from turning an initial storm report into a click.
- Extends `HIDDump` with wall-clock timestamps and dynamic controller location IDs for evidence-based multi-controller diagnostics.
- Adds an AI installation runbook for Codex, Claude Code, Cursor, and other local coding agents, including privacy, pairing, verification, troubleshooting, and uninstall handoffs.
- Adds an objective pre-install usefulness check based only on macOS, Swift, code verification, and live `27C0:0859` controller presence—not crowdsourced compatibility guesses.
- Adds a real two-touchscreen desk image, problem-oriented README summary, structured compatibility and bug reports, and GitHub metadata for easier discovery.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
