# AI-Assisted Installation Guide Design

## Goal

Make the repository safely installable by Codex, Claude Code, Cursor, and other
local coding agents with filesystem and terminal access. A root-level
`llm.txt` will be the authoritative operational runbook for those agents, while
the README will offer a copyable request and retain the complete manual install
path.

The guide must describe the repository as it actually works. It cannot imply
that an AI agent can grant macOS privacy permissions, perform a physical touch,
or bypass operating-system security boundaries.

## Chosen format

`llm.txt` will be a plain-text, Markdown-compatible runbook rather than only a
short prompt or a machine-specific command transcript. This keeps it readable
by people, portable across coding agents, and precise enough for an agent to
execute and verify.

The runbook will contain:

- supported environment and hardware signals;
- authority and safety boundaries;
- read-only preflight checks;
- the exact installation flow;
- user-controlled privacy and physical pairing handoffs;
- post-installation verification;
- focused troubleshooting and uninstall instructions;
- a concise final report contract.

## Authority boundary

Opening the repository and asking an agent to install it authorizes the agent
to run read-only preflight checks and `./Scripts/install.sh` for the current
user. The runbook will prohibit `sudo`, secret disclosure, unrelated config
changes, destructive repair, and repository publication unless those actions
are separately requested.

The agent must stop and ask the user to perform:

- Input Monitoring approval;
- Accessibility approval;
- each physical **Touch this display** pairing touch.

The agent may resume verification after the user confirms those steps. It must
report any acceptance gap instead of claiming success from a successful build
or LaunchAgent registration alone.

## Installation flow

1. Confirm macOS 13 or newer, the repository root, the Swift toolchain, a clean
   understanding of existing installation state, and—when connected—the target
   WCH controller identity.
2. Preserve existing configuration and pairings. Do not remove or rewrite them
   as a routine installation step.
3. Use a user-supplied stable `CODESIGN_IDENTITY` when one is already available;
   otherwise install with the linker's ad-hoc signature and explain that macOS
   may request privacy approval again after a rebuild.
4. Run `./Scripts/install.sh` without `sudo`.
5. Hand privacy approval and physical pairing to the user.
6. Verify the LaunchAgent, installed signature, driver logs, controller
   discovery, and resulting active pairings without printing hardware serials
   or location IDs.
7. Report which checks passed and any remaining manual or physical validation.

## Stable internal identifier

Both guides will explain why generated files still use
`com.ajvwhite.MacXeneonEdgeTouchDriver`. It is the original project's stable
installation identifier and is retained so upgrades continue to use the same
LaunchAgent, executable location, configuration, logs, saved pairings, and
macOS privacy identity. It is not an unexpected dependency, network service,
or separate installed product.

Renaming the identifier to a fork-specific value such as `com.nocreativity`
would create a second installation identity, risk duplicate agents, and cause
macOS to treat rebuilt software as a different privacy subject.

## README integration

The README will add an **Install with an AI coding agent** section immediately
before the manual installation section. It will:

- link directly to `llm.txt`;
- name representative local coding agents without requiring any one vendor;
- clarify that the agent needs local filesystem and terminal access;
- provide a copyable prompt that tells the agent to follow `llm.txt`;
- state that the user must complete macOS privacy approval and physical pairing;
- preserve the existing manual installation instructions directly below.

The stable-identifier explanation will appear beside the generated LaunchAgent
path, where users are most likely to notice the original reverse-domain name.

## Verification

Documentation verification will include:

- checking every command and path against the current shell scripts;
- checking all relative links;
- searching for accidental machine-specific identities, serials, and location
  IDs;
- shell syntax checks for the referenced scripts;
- `git diff --check`;
- inspecting the complete outgoing diff before publishing `fork/main`.

This documentation-only change does not update or publish upstream PR #3.
