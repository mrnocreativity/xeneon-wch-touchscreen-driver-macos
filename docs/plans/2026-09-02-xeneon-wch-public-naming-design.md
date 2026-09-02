# Xeneon WCH Public Naming Design

## Goal

Give the fork a clear, searchable public identity that reflects its actual
hardware compatibility and multi-display macOS behavior. People should be able
to find it using the names printed on known products, the terms used in retail
listings, the USB controller identity visible during troubleshooting, and both
current and legacy names for Apple's desktop operating system.

## Public identity

The public software name is **Xeneon WCH Touchscreen Driver for macOS**.

The GitHub repository slug is:

```text
xeneon-wch-touchscreen-driver-macos
```

The repository description is:

> Independent open-source macOS / OS X multi-display touchscreen driver for CORSAIR XENEON EDGE and compatible wch.cn TouchScreen 27C0:0859 panels, including Prechen HD-123 12.3-inch 1920x720 portable monitors sold for AIDA64 CPU/GPU/RAM monitoring (Amazon ASIN B0CTMNPBX3).

The name uses Xeneon for the best-known retail reference and WCH for the shared
controller identity. The README does not call the product "Xeneon & Co.";
instead, it explains that the driver can support Xeneon and similarly
constructed screens because they expose the same controller protocol.

The software is independent and is not affiliated with Corsair, Prechen, or
WCH. `OS X` is included as a discovery term used by people searching for a Mac
touchscreen solution, not as a claim that versions older than the package's
declared macOS 13 minimum are supported.

## Hardware terminology

The confirmed USB identity is:

- manufacturer/product string: `wch.cn TouchScreen`;
- USB vendor ID: `0x27C0`;
- USB product ID: `0x0859`.

Public documentation calls this the WCH touchscreen controller or controller
identity. It must not invent a more specific chip model unless future hardware
evidence establishes one.

## README structure

The README opens with the new public name and a concise explanation of the
problem solved: correct per-display direct-touch mapping on macOS, including
multiple identical panels, tap, scroll, hold-drag, double-click, focus
restoration, reconnect handling, and containment of incoherent controller
reports.

A dated **Known compatibility** section separates evidence levels:

- the Prechen HD-123 / Amazon ASIN B0CTMNPBX3 is physically verified in this
  fork with two identical 12.3-inch 1920x720 panels;
- the CORSAIR XENEON EDGE 14.5-inch 2560x720 display is the original reference
  device and supported controller/display target;
- other panels exposing `wch.cn TouchScreen` USB `27C0:0859` are compatibility
  candidates, not confirmed products until a user reports successful use.

The compatibility heading includes its last-updated date. Compatibility facts
must be updated from reports rather than presented as timeless assumptions.

## Community compatibility reports

The README explicitly asks users to report other brand names, model numbers,
retail listing titles, and store identifiers for displays that work. This both
helps other owners and adds the exact language people encounter while buying or
troubleshooting the same rebadged hardware.

A useful report includes:

- brand and exact marketed product/listing name;
- model number, store URL, and ASIN or equivalent identifier;
- USB manufacturer/product strings and VID:PID;
- native display resolution;
- Mac model and macOS version;
- HDMI, USB-C, hub, or dock connection path;
- results for pairing, tapping, scrolling, dragging, and double-clicking.

Confirmed reports can be added to the dated compatibility table with their
evidence level and report date. A shared controller ID alone remains a candidate
signal because display descriptors, report formats, and firmware behavior can
still differ.

## GitHub discovery metadata

The initial repository topics are:

- `macos`
- `osx`
- `mac`
- `corsair`
- `xeneon-edge`
- `touchscreen`
- `touchscreen-driver`
- `external-touchscreen`
- `wch`
- `27c0-0859`
- `prechen`
- `hd-123`
- `portable-monitor`
- `multi-monitor`
- `aida64`
- `usb-hid`

## Compatibility-preserving rename boundary

This change renames the public repository and README identity. It does not yet
rename the Swift package targets, installed executable, LaunchAgent label,
Application Support directory, log directory, or configuration and pairing
paths. Keeping the existing internal `MacXeneonEdgeTouchDriver` identity avoids
breaking installed LaunchAgents, privacy permissions, configuration, and saved
pairings merely for public branding.

An internal runtime rename would require a separate migration design and is not
part of this change.

## Branch and publication boundary

Local `main` becomes the canonical branch for the renamed fork and tracks the
fork's `main`. The existing completed driver history is merged into it without
rewriting published commits.

Upstream PR #3 continues to use
`codex/multi-display-touch-driver` as a curated publication branch. The fork's
complete `main` is not merged wholesale into that branch. Future commits that
belong upstream are reviewed and cherry-picked onto the PR branch only after
explicit approval, keeping fork-specific material out of the upstream change.
