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
- [ ] Implement bounded confidence tracker and recovery probation.
- [ ] Integrate release validation and hold authorization with gesture synthesis.
- [ ] Add bounded incident capture and status visibility.
- [ ] Verify deterministic regressions, warning-clean tests/build and whitespace.
- [ ] Install via canonical signed installer and inspect live status; no manual mappings.

Do not push main or the upstream PR as part of this implementation request.
