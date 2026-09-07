# HID Instance Pairing Validity Design

**Superseded:** the [pairing authority rework](2026-09-07-pairing-authority-rework-design.md)
replaces this document's restart-persistence policy. A stable HID registry entry
cannot prove video-endpoint continuity. Ambiguous mappings now require
uninterrupted process observation and two-target physical calibration.
The design below is historical context, not current recovery guidance.

## Problem

The two attached touch controllers report the same USB serial number, and the
two touch displays report the same vendor, model, and zero serial number. A
same-boot pairing currently identifies a controller by USB location and serial.
If the driver misses a disconnect while it is stopped, macOS can re-enumerate a
different physical controller at the same location. The saved pairing still
looks valid even though touch is routed to the other display.

The observed failure routed a touch on the physical right panel to the left
display. Both saved records passed descriptor checks because their public
identities were duplicated. Later log review showed the wrong associations
were created during earlier calibration; this was not proof of a subsequent
USB re-enumeration. The identity risk above remains real but was not established
as the cause of that incident.

## Options

1. Preserve the current mapping until a removal callback arrives. This keeps
   restarts seamless but cannot detect a disconnect that occurs while the
   driver is not monitoring devices.
2. Discard ambiguous mappings on every process launch. This is safe but forces
   calibration after routine driver updates and service restarts.
3. Bind same-boot mappings to the current IORegistry HID service instance. This
   preserves mappings across process restarts while the hardware is unchanged
   and rejects them after USB re-enumeration. This is the selected approach.

## Design

`HIDDeviceMonitor` reads the 64-bit registry entry ID from each matched
`IOHIDDevice` service and includes it in `TouchDeviceIdentity`. The registry ID
is runtime-incarnation evidence, not public hardware identity, so it must not
be used by `hardwareKey` or trusted across boots.

Boot-session pairing resolution requires location, serial, and registry entry
ID to agree whenever the current controller exposes a registry ID. Descriptor
reconciliation removes a saved boot-session pairing when the same USB location
now has a different registry instance. Removal callbacks continue to
invalidate their mapping immediately.

Pairing persistence advances to version 3. Version 2 hardware-scoped records
remain valid because they were established from unique public device and
display identities. Version 2 boot-session records are discarded because they
do not contain the registry-instance evidence required to distinguish these
duplicate controllers. Newly calibrated records contain the registry entry ID.

Logs include the registry entry ID when a controller is matched so installed
state can be audited without a debugger.

## Verification

Unit tests cover persistence across a driver restart with an unchanged registry
instance, rejection and pruning after a registry-instance change at the same
USB location, migration of version 2 boot-session records, and retention of
safe version 2 hardware records. Existing pairing, topology, gesture, build,
script, signing, and installed LaunchAgent checks remain required.

The former manual record-migration procedure is withdrawn. Install the current
driver and use its canonical physical calibration/re-pair flow; do not seed or
rewrite saved mappings manually.
