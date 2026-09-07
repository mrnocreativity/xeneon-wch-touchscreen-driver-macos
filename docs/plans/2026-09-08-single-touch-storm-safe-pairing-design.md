# Single-touch, storm-safe pairing

Approved scope: restore one deliberate touch-and-release per display while
retaining verified overlay placement, topology stability, observation-scoped
authority, and transactional persistence. Do not revert the authority rework.

## Interaction and authority

Show one central circle on each display in sequence. Only a fresh physical down
followed by a coherent release on that target can commit the association. An
untouched prompt has no deadline; a pressed contact retains its bounded release
deadline. Calibration never synthesizes mouse input. Use a new calibration
revision so older records cannot bypass the corrected input-admission policy.

## Structural input boundary

Touch routing must not call display reconciliation or start calibration. Those
operations belong to topology, command, presentation retry, and recovery events.
All calibration input enters one admission path which rejects storming
controllers, expired observations, stale placement, and validator-generated
downs that do not correspond to a fresh physical down after prompt readiness.

If an unresolved controller enters a storm, stop the current attempt once and
wait for the existing quiet-recovery timer. Repeated storm samples must neither
advance topology-stability observations nor cancel/reopen the overlay. Resume
only when every unresolved controller has left storm mode. Storms on an already
paired controller must not interrupt calibration of another controller.

Preserve storm detection and its timer across display-only routing suspension;
clear it when the actual controller session is removed or the existing quiet
recovery rule succeeds. Preserve the existing paired-controller gesture policy;
this change does not claim to eliminate upstream controller/power faults.

## Implementation and verification

1. Simplify the challenge, overlay contract, and persisted calibration revision.
2. Separate input dispatch from reconciliation; centralize calibration admission
   and unresolved-controller storm waiting/recovery.
3. Add regressions for no pairing during storm acquisition or reacquisition,
   no prompt churn or topology observation advancement from touch traffic,
   preserved storms across geometry changes, fresh-down provenance, unaffected
   paired controllers, and one-contact completion without synthetic input.
4. Run warning-clean tests/builds and update current usage documentation.
5. Install through the signed canonical installer and verify a fresh LaunchAgent
   process, responsive status, and stable waiting at the first physical target.
   The user is away: do not generate touches or manually modify saved mappings.
   Physical completion and reconnect acceptance remain explicitly unverified.

## Verification receipt

- 119 tests pass with warnings treated as errors, including storm reacquisition,
  fresh-down provenance, independent controller cleanup, and the idle-prompt
  regression. The release build is also warning-clean; script syntax, LaunchAgent
  plist lint, and whitespace checks pass.
- The canonical installer built, signed, and restarted the driver. Strict
  signature verification passed, the installed executable's build UUID matched
  the release artifact, and the fresh process exposed responsive status.
- Unattended first-target acceptance was not established: both controllers
  reported target contacts after startup and again after canonical `re-pair`.
  No agent-generated input was used. These reports do not establish deliberate
  human touches or physically correct routing, and their cause is unconfirmed.
- Because the user was unavailable for physical verification, canonical
  `re-pair` followed by `cancel-pairing` revoked those associations and left the
  driver running with pairing paused and both controllers suspended. Resume with
  `re-pair` when physical verification is possible. No runtime files were edited
  manually. Physical reconnect and unexpected-contact investigation remain open.
