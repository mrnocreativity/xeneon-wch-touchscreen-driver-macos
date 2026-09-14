# Selective storm filtering

Approved in conversation: retain usable, distinguishable finger input during a
controller storm without treating a few selected plausible samples as sufficient
evidence. Normal gestures, pairing authority and the other controller stay intact.

## Decisions

- Prefer bounded, competing stationary/trajectory candidates with explicit
  contradictory evidence over increasing the old longest-subsequence threshold.
  Whole-controller suppression and automatic USB resets are outside this change.
- Acquire only a recent, regularly supported dominant candidate. Spatial gates
  use stationary jitter or local motion prediction, never expand indefinitely
  after rejected reports. Ambiguity cancels rather than transfers a gesture.
- A candidate is not permission to click: validate releases after a short local
  confirmation interval, require fresh evidence when a hold timer fires, and
  cancel lost tracks without generating taps. Each double-click tap must pass.
- After raw silence, retain stricter recovery probation until clean completed
  contacts demonstrate recovery. Probation is not a reason to invalidate pairing.
- Retain bounded coordinate/decision diagnostics and write incident snapshots
  through existing bounded asynchronous logging, not per-report disk writes.

## Trade-offs and verification

Storm contacts may require more observation or be rejected when ambiguous.
Initial thresholds are conservative engineering defaults, not empirically tuned
against the September incidents: full coordinate recordings of those incidents
are unavailable. Tests must cover coherent stationary and curved motion with
outliers, competing clusters, plausible fragments in dense noise, false releases,
stale holds, safe cancellation, quiet-gap probation, independent controllers,
bounded capture and ordinary gesture regressions. Physical storm acceptance
remains a separate verification step.

## Implementation checklist

- [x] Inspect current code, design decisions and repository state.
- [x] Establish constraints from the conversation; no further clarification needed.
- [x] Compare threshold-only, full suppression and evidence-based tracking.
- [x] Present design and receive user approval.
- [x] Record approved design (writing-plans skill unavailable; checklist is fallback).
- [x] Implement bounded confidence tracker and recovery probation.
- [x] Integrate release validation and hold authorization with gesture synthesis.
- [x] Add bounded incident capture and status visibility.
- [x] Verify deterministic regressions, warning-clean tests/build and whitespace.
- [x] Install via canonical signed installer and inspect live status; no manual mappings.

Do not push main or the upstream PR as part of this implementation request.

## Implemented initial parameters

Acquisition considers at most 24 reports over 160 ms and requires six inliers
spanning at least 48 ms, at least 70% support, and no comparably supported
competing path. Continued tracking uses a maximum 48 ms support gap, bounded
local prediction error and four consecutive outliers as an additional revocation
limit. Releases require a supported endpoint and 24 ms without a pressed inlier
retracting the release; delivery after a 250 ms scheduling stall is cancelled.
The adaptive controller timer checks every 20 ms during an acquired contact and
once per second otherwise during a storm. Three clean completed contacts leave
post-silence probation, without withholding those contacts or re-pairing.

Diagnostics keep a 256-entry ring and a separate 256-entry entry capture with up
to 64 pre-trigger samples. Snapshots are limited to one per 30 seconds per
controller and a two-slot encoding/writing queue. They use a separate rotating
capture log (maximum 1 MiB plus one backup) rather than evicting operational
history. Parsed contact samples and decision timestamps are retained, not full
USB packet bytes; a late-window capture is not a complete incident replay.

Integration tests drive confidence ticks explicitly so fabricated report clocks
cannot race a real timer. Production enables automatic scheduling by default.

## Verification on September 14

- 154 debug tests passed before the final drag-expiry regression was added.
- All 155 release-mode tests passed with warnings treated as errors, including
  independently confirmed double-clicks and exactly-once drag release on expiry.
- Warning-clean release build, shell syntax checks and `git diff --check` passed.
- Canonical installer completed with the existing Developer ID signing identity;
  its built-in retry handled a transient LaunchAgent bootstrap error.
- Installed signature verified and its Mach-O UUID matched the release build.
  The restarted driver's AppKit and endpoint heartbeats were fresh, routing was
  available and no file-log messages were dropped. The bounded capture file was
  initialized successfully by the driver.
- No compatible controllers or displays were connected during live acceptance.
  Real touch usability, false-positive rate during a spontaneous storm and
  measured hardware latency remain unverified; no synthetic hardware touches,
  USB resets or manual pairing/configuration changes were performed.
