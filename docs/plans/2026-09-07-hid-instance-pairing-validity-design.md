# HID Instance Pairing Validity Design

## Problem

The two attached touch controllers report the same USB serial number, and the
two touch displays report the same vendor, model, and zero serial number. A
same-boot pairing currently identifies a controller by USB location and serial.
If the driver misses a disconnect while it is stopped, macOS can re-enumerate a
different physical controller at the same location. The saved pairing still
looks valid even though touch is routed to the other display.

The observed failure mapped controller `0x01100000`, which emitted a touch on
the physical right panel, to display 4 at the left desktop edge. Both saved
records passed the existing descriptor checks because the duplicated public
identities cannot distinguish the panels.

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

For this machine, preserve the manually corrected live association while
upgrading the saved records to version 3 with the currently observed registry
entry IDs. Then restart the installed driver and verify two active pairings and
the absence of a calibration overlay.
