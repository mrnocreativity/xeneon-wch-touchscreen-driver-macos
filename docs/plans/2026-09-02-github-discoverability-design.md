# GitHub Discoverability Design

## Goal

Make the public Xeneon WCH Touchscreen Driver for macOS easier to discover,
evaluate, install, and recommend through GitHub without detaching it from the
upstream fork network while PR #3 remains open.

The repository already has a search-oriented name, description, compatibility
table, and 15 topics. The audit confirmed that its primary search limitation is
GitHub's default exclusion of forks. This change improves every safe supporting
surface now and deliberately defers leaving the fork network.

## Chosen scope

### Repository presentation

- Reuse the existing noCreativity blog photograph of the real desk setup. The
  blog thumbnail and article image are byte-identical 1844x853 PNG files.
- Create one optimized 1280x640 repository asset from that photograph for the
  README and GitHub social preview. Do not generate or invent a replacement.
- Add a concise **Problems this fixes** section near the top of the README with
  the concrete symptoms users search for.
- Add a genuine invitation to star the repository and submit a compatibility
  report after successful use.
- Link the repository homepage metadata to the matching noCreativity article.

### Topics and profile

Keep all existing topics and use the remaining five topic slots for:

- `macos-driver`
- `swift`
- `corsair-xeneon-edge`
- `prechen-hd-123`
- `stretched-bar-display`

Pin the repository to the owner's GitHub profile so profile visitors can find
it directly.

### Community reports

Add structured GitHub issue forms for:

- hardware compatibility reports;
- installation, mapping, or gesture bugs.

The compatibility form requests retail naming, model/store identifiers,
VID:PID, display resolution, Mac and macOS information, connection method, and
gesture results. It explicitly prohibits controller serial numbers and USB
location IDs. The bug form requests reproducible behavior, expected behavior,
affected gestures/displays, logs with private identifiers removed, and relevant
environment details.

Create focused `compatibility`, `hardware`, `installation`, and `bug` labels.
Keep blank issues enabled so the forms guide rather than block contributors.

### First GitHub release

Publish `v1.1.0` from the verified `main` commit. The existing changelog already
records `1.0.0`; the current unreleased work is therefore a compatible minor
release.

The release is source-only. Although local code-signing identities exist, no
notarization profile is configured. Publishing an unnotarized prebuilt binary
would create avoidable Gatekeeper friction and weaken trust. GitHub will provide
source ZIP and tarball downloads automatically, while users install through the
repository installer or `llm.txt`.

The changelog will describe the AI-assisted installation guide, objective
preflight, compatibility-reporting surfaces, and discoverability improvements
alongside the existing user-facing driver work.

## Deferred fork-network change

Do not use GitHub's **Leave fork network** action, delete/recreate the
repository, rename the upstream contribution branch, or change PR #3. The open
PR remains the reason to preserve the fork relationship for now.

After PR #3 reaches a terminal outcome, fork detachment can be reconsidered as
a separate explicitly approved migration. That later action is permanent and
has different metadata and PR consequences.

## Verification

Repository verification includes:

- image dimensions, size under GitHub's 1 MB social-preview limit, and visual
  inspection;
- issue-form YAML parsing and required-field inspection;
- README link and image-path checks;
- shell syntax checks;
- 82 Swift tests with warnings treated as errors;
- warning-clean release build;
- whitespace and complete outgoing-diff checks;
- GitHub metadata readback for topics, homepage, labels, profile pin, social
  preview, tag, and release;
- matching local and remote `main` commit identities;
- unchanged `codex/multi-display-touch-driver` branch and upstream PR #3.
