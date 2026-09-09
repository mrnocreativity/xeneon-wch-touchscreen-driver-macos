# Pairing authority and recovery

The [single-touch storm-safe follow-up](2026-09-08-single-touch-storm-safe-pairing-design.md)
supersedes the two-target interaction below and closes the storm admission and
touch-driven reconciliation paths. This document retains the original design
and its dated verification history.

Approved scope: replace implicit mapper-based permission with explicit pairing
states. Keep existing HID parsing and ordinary gesture behavior.

## Authority

Only an active association may route touch. Waiting, needs-pairing, calibrating,
and suspended states carry diagnostic reasons. Reconfiguration suspends routing
and cancels pending gestures before reconciliation. A generation counter rejects
delayed recovery work from older configurations. Geometry changes preserve a
calibrated association only during uninterrupted observation; endpoint changes
invalidate ambiguous associations as a group. Unique hardware associations must
remain unique among current endpoints and stored records.

Ambiguous associations are process-local authority. The persistence schema stores
a calibration protocol revision and observation-session identifier; restart,
sleep/wake, observer failure, or a responsiveness gap requires fresh calibration.
HID registry identifiers remain useful reconnect evidence, but cannot establish
the video endpoint's identity. Existing records have no evidence of the new
calibration protocol and must pass physical calibration on upgrade.

## Calibration

Wait for complete stable topology and verified AppKit/CoreGraphics placement.
Require two complete touch/release contacts at distinct visible normalized panel
targets from the same controller. Contacts must begin after each target is ready.
Wrong-target contacts, competing controllers, noise, timeout, or topology change
restart the attempt. No calibration contact creates synthetic mouse input.
Waiting for the user is not a contact timeout: keep each untouched target stable
indefinitely. Only an in-progress contact has a two-second release deadline.
Status must distinguish raw reports, parsed lifecycle events, validated contacts,
and calibration decisions so a silent prompt has a diagnosable cause.
Revalidate the visible overlay and topology before committing. Publish an active
association only after atomic persistence succeeds.

## Recovery and observation

The heartbeat-expiry invalidation policy below is historical and superseded by
[load-safe observation](2026-09-09-load-safe-observation-design.md): scheduling
delays block routing but do not establish lost endpoint identity.

Expose `status`, `re-pair`, and `cancel-pairing` commands through a user-owned local
IPC endpoint serviced by the running driver. Status reports per-controller state,
reason, display bounds, and observation generation. Re-pair revokes authority and
uses the same coordinator as automatic recovery. Cancellation leaves unresolved
input disabled and hides the overlay. No external tool edits the pairing file.

Use display/HID callbacks, sleep/wake notifications, periodic enumeration, and
event-loop heartbeat acknowledgements. A stale heartbeat blocks touch and requires
recovery after responsiveness returns. Polling cannot detect a completely invisible
hardware exchange between identical observations; conservative invalidation at
observation gaps is required and this limitation must remain documented.

## Implementation sequence

1. Add authority/calibration models and transactional, validated schema migration.
2. Integrate coordinator states, suspension, generation checks, and observations.
3. Add target-aware calibration overlays and the local command channel.
4. Add sequence tests covering restart/wake, topology changes, stale callbacks,
   noise/competing touches, persistence failure, commands, and migration.
5. Update usage documentation, build, sign, and install. Trigger canonical recovery
   and hand physical target touches to the user. Publish only to fork main under
   the existing authorization; never update the curated upstream PR branch.

## Implementation verification

- 109 Swift tests pass with warnings treated as errors. Coverage includes
  two-target contact validation, stale observation generations, heartbeat
  expiry, queued hold cancellation, restart migration, group revocation,
  persistence failure, removed-device reports, overlay/topology changes, and
  command endpoint ownership and round trips.
- The release build is warning-clean; shell syntax, plist, and whitespace checks
  pass. The canonical installer deployed a signed binary whose strict signature
  verification passes, and the LaunchAgent is running.
- Live `status`, `cancel-pairing`, and `re-pair` commands were acknowledged.
  Cancellation removed the visible driver window and suspended unresolved input;
  re-pair returned to calibration with a fresh generation. WindowServer bounds
  placed the initial prompt on a touch display, not the main monitor.
- Physical completion on both panels and a subsequent cable/sleep/wake acceptance
  sequence remain user-dependent and are not claimed by these automated checks.

Follow-up: physical use exposed an idle 15-second restart loop and insufficient
input diagnostics. The idle deadline is removed; contact-release protection
remains. 111 warning-clean tests pass, including a real-time regression beyond
the former deadline and status counters exercised through HID-report ingestion.
The signed follow-up was installed and the live prompt remained stable. At that
check the new process had received zero relevant HID reports; the cause of the
reported missing touches and physical acceptance remain unresolved, not inferred
from successful UI or command checks.
