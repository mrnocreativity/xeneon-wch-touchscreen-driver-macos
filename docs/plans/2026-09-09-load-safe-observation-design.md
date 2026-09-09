# Load-safe observation and pairing continuity

Approved direction: separate responsiveness pauses from loss of endpoint identity,
retain fail-closed routing, and stop repeatedly discarding valid pairings under load.

## Decision and alternatives

A longer timeout only moves the failure threshold. Removing observation gating
would allow delayed gestures against stale geometry. Instead, preserve the gate
while separating registered endpoint-observation continuity from UI responsiveness.
Elapsed scheduling time alone is not evidence that registered callbacks were lost.

## Architecture and recovery

- Move HID callbacks and periodic inventory onto a dedicated run-loop thread,
  independent of AppKit, gesture processing, overlays, and disk logging. Its
  ordered inventory receipts follow match/removal events. Display callbacks still
  close the shared gate immediately before dispatching coordinator work.
- Send AppKit heartbeat probes independently of the gesture queue, with at most
  one pending probe. Track UI and endpoint freshness separately. Either stale
  receipt blocks routing immediately, but does not delete saved authority.
- On responsiveness recovery, cancel old gestures and in-progress calibration
  contacts, reject queued old input, and revalidate the latest endpoint inventory
  and observation revision before restoring routing. Keep an untouched prompt
  stable where topology and placement remain valid.
- Actual disconnect/membership changes, stopped observation, sleep/wake, and
  incomplete display transactions retain conservative identity invalidation.
  Merely seeing the same reusable display ID is never sufficient identity proof.
- Move production file logging to a bounded asynchronous queue. Expose freshness,
  recovery state, and read-only status without triggering pairing invalidation.
- Use an interactive LaunchAgent scheduling policy for this interactive input
  service. Apply installed changes only through the signed installer.

## Implementation plan and acceptance

1. Implement independently scheduled observation and pure liveness gating.
2. Implement non-destructive responsiveness recovery with stale-event rejection.
3. Isolate file logging and add diagnostics; update scheduling and documentation.
4. Test delayed UI/coordinator work, repeated delays without prompt churn, stale
   contacts, real endpoint changes during delays, stop/sleep boundaries, and
   bounded logging. Retain all existing storm and topology tests.
5. Run warning-clean tests/release build and installer checks; install, verify
   signature/process/status, then observe stability without synthetic touches.
   Physical routing and disconnect/reconnect acceptance remain user-dependent.

The brainstorming design was approved in the preceding discussion. The
writing-plans skill is not available in this session; the sequence above is the
implementation plan.

## Verification receipt

- 135 tests pass with warnings treated as errors; the release build is
  warning-clean. Regressions cover repeated UI/endpoint delays, stable untouched
  prompts, retained pairings, stale inventory revisions, actual disconnect and
  display-identity changes, held fingers, interrupted calibration, stale raw
  reports, coalesced observation work, independent run-loop lifecycle, and bounded
  file logging. Shell syntax, plist lint, and whitespace checks pass.
- The signed canonical installer restarted the service. Strict signature
  verification passed, the installed and release build UUIDs match, and launchd
  reports interactive scheduling. A live sample confirms the dedicated endpoint
  observation thread, separate from the AppKit main thread.
- During installation macOS reported endpoint membership/display changes, then
  both panels became available and the first physical target appeared. These
  transitions are distinct from heartbeat expiry. Status reports fresh AppKit
  and endpoint observations with no dropped file-log messages. Both controllers
  subsequently completed their physical-target flow and became active without
  any further observation-generation change.
- No saved mappings, configuration, or LaunchAgent files were changed manually,
  and no physical touches were simulated. Real heavy-load routing acceptance
  and physical touch/reconnect verification remain distinct from automated tests.
