---
name: xeneon-release
description: Prepare, build, notarize, and publish semantic-versioned GitHub releases of the Xeneon WCH Touchscreen Driver for macOS. Use for release planning, version bumps, or publishing a new portable installer on the fork.
---

# Xeneon Driver Releases

Run from the root of the Xeneon driver checkout and read its local repository instructions. Publish only to `mrnocreativity/xeneon-wch-touchscreen-driver-macos` from the fork's `main`. Keep the upstream repository and curated PR branch outside this workflow.

## Choose the version

1. Check the worktree, branch and remotes, then compare the live fork `main`, GitHub Releases, and remote tags. Use `gh release list -R mrnocreativity/xeneon-wch-touchscreen-driver-macos` and `git ls-remote --tags fork`. Use the last stable fork release tag as the baseline and inspect the actual changes since it. Verify that the proposed tag is unused.
2. Apply [SemVer](https://semver.org/). Bump major for incompatible changes to the supported install, configuration or command interfaces. Bump minor for backward-compatible functionality or deprecations. Bump patch for backward-compatible fixes. Use the highest applicable category and reset lower components.
3. Set `CFBundleShortVersionString` in `Resources/PortableInstaller/Info.plist` to the release version without the `v` prefix. Increment the integer `CFBundleVersion`. Move shipped changes from **Unreleased** into the new section of `CHANGELOG.md`. Write GitHub notes from the changelog and actual verification. Credit Alexander White when describing the original portable installer port. [Original PR #21](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/21)

## Load local release settings

Keep `.env.release.local` in the primary checkout with permissions `0600`. Verify `git check-ignore -- .env.release.local` succeeds and `git ls-files -- .env.release.local` returns no path. This trusted, shell-compatible file contains two references to the local Keychain:

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
NOTARIZATION_PROFILE='Your local notarytool profile name'
```

Keep passwords and API private keys in Keychain or secure storage outside the checkout. If the profile is missing, follow the Apple setup in `docs/PORTABLE-INSTALLER.md` or use an [App Store Connect team API key](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/). Import a downloaded key locally with `xcrun notarytool store-credentials PROFILE --key KEY_PATH --key-id KEY_ID --issuer ISSUER_ID`. Use the same Developer ID team as existing installs so macOS privacy approvals can survive upgrades.

## Build and verify

- Check GitHub write access and confirm the configured Developer ID Application identity is valid with `security find-identity -v -p codesigning`.
- Run `swift test` and `git diff --check`. For installer changes, run each suite separately with Python 3: `Scripts/test-install.py`, `Scripts/test-uninstall.py`, and `Scripts/test-portable-installer.py`. Record which hardware and install paths were actually tested.
- Commit the version and changelog locally. Build from that exact commit in a clean checkout. From the primary checkout, set `release_checkout` to the clean checkout's absolute path and `release_output` to a fresh absolute output directory. Source the ignored file in a subshell so its values stay scoped to the release:

  ```sh
  (
    set -e
    . ./.env.release.local
    : "${CODESIGN_IDENTITY:?Missing Developer ID Application identity}"
    : "${NOTARIZATION_PROFILE:?Missing notarization profile}"
    export CODESIGN_IDENTITY NOTARIZATION_PROFILE
    xcrun notarytool history --keychain-profile "$NOTARIZATION_PROFILE" >/dev/null
    cd "$release_checkout"
    ./Scripts/build-portable-installer.sh --arch universal --output "$release_output"
  )
  ```

  The builder notarizes the payload and installer in two stages and staples the installer. For troubleshooting, read `docs/PORTABLE-INSTALLER.md`.
- In the output directory, verify the ZIP against its `.zip.sha256` file using `shasum -a 256 -c`. Extract the ZIP and verify the app and helpers with `codesign --verify --deep --strict`, validate the app's ticket with `xcrun stapler validate`, and check both architecture slices with `lipo -archs`. Confirm the app version matches the intended tag. Use the installer itself for authorized local smoke tests. Keep signed-only builds local until notarization succeeds.

## Publish and verify

1. With authorization for the fork release, recheck the release commit and remote tips, then push the release commit to fork `main` and push the single annotated `vMAJOR.MINOR.PATCH` tag. Verify the remote tag resolves to the commit that built the ZIP. Published tags and release assets stay immutable. Use a new version for corrections.
2. Create a draft with `gh release create "$tag" --repo "$repo" --verify-tag --draft --title "$title" --notes-file "$notes" "$zip" "$checksum"`. If the tag or release already exists, inspect it and resume only if it matches the intended commit and artifact. Confirm that the draft contains the intended notes and both assets. Download the draft assets to a fresh directory and verify the checksum against the local build.
3. Publish with `gh release edit "$tag" --repo "$repo" --draft=false --latest` for a stable release. Verify the public release URL, tag, and downloadable ZIP and checksum. Report the released version, link, and verification limits.
