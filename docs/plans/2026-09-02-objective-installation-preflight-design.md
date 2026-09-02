# Objective Installation Preflight Design

## Goal

Ensure an AI coding agent informs the user before installation when local,
objective evidence shows that the driver cannot currently run or cannot
currently be useful. Preserve the user's authority to continue despite that
warning.

The decision must not rely on product names, the community compatibility table,
crowdsourced success or failure reports, or an AI model's intuition about
similar hardware.

## Evidence boundary

The preflight uses only facts that the agent can verify on the user's Mac and in
the current checkout:

- the host is macOS;
- the installed macOS major version is 13 or newer, matching `Package.swift`;
- the Swift toolchain is available;
- the repository and install scripts are present and syntactically valid;
- the Swift tests pass with warnings treated as errors;
- the release build succeeds with warnings treated as errors;
- a USB controller with the exact driver-matched VID:PID `27C0:0859` is
  currently attached.

The hardware check reports only whether the required controller is present. It
does not inspect a retail name, compare the device with the README compatibility
table, or infer that an unknown display is incompatible.

## Outcomes

### Ready to install

All software checks pass and the required controller is present. The agent may
continue with the existing installation flow.

### Installable, but hardware is not currently available

All software checks pass, but `27C0:0859` is not detected. The agent tells the
user that installation can proceed but touchscreen behavior cannot work or be
physically verified until the matching controller is connected. Absence is not
described as incompatibility because the user may intend to connect it later.

The agent asks whether to continue. If the user says yes, it proceeds and
records hardware validation as incomplete.

### Software blocker

The host, macOS version, Swift toolchain, repository, script, tests, or release
build fails its factual check. The agent identifies the exact failed check and
its consequence, then asks whether the user wants to continue or correct the
problem first.

If the user continues, the agent runs whatever remaining steps are technically
possible. It does not hide an expected failure or claim that an impossible
command succeeded.

## Interaction contract

Warnings appear after the read-only preflight and before
`./Scripts/install.sh`. Each warning includes:

1. the objective evidence;
2. the practical consequence;
3. the recommended next action;
4. an explicit choice to continue anyway.

An agent must not turn uncertainty into a warning. A display absent from the
community table, an unfamiliar brand, or a model's opinion is not evidence that
the driver will fail.

## Verification

The documented commands must be checked against the current package, scripts,
and hard-coded HID matcher. Verification covers:

- `Package.swift` declaring macOS 13;
- production matching `27C0:0859`;
- the USB inventory check returning success while a matching controller is
  attached and a nonzero result otherwise;
- warning-clean Swift tests and release build;
- shell syntax and whitespace checks;
- a complete outgoing diff with no local hardware identities or topology.

This runbook-only change is published on the fork's `main` branch and does not
change upstream PR #3.
