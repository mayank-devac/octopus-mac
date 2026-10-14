# Plan 008: Upgrade Sparkle before publishing the beta

## Status

- Priority: P1; category: security; effort: S; change risk: MED.
- Planned at: commit `525e357`, 2026-10-13, with staged release preparation changes.
- Depends on: none. Rebuild once after this plan and plan 009 are applied.
- Status: APPLIED IN SOURCE; Xcode resolved Sparkle 2.10.0 at the verified tag revision
  and kept KeyboardShortcuts 2.3.0. Final package verification and publication require separate approval.

## Why

The prepared Octopus 2.1.0/build 4 ZIP embeds Sparkle 2.8.1. Upstream advisory
[GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5)
affects versions through 2.9.5 and is fixed in 2.9.6. It concerns a local attack during
privileged update installation; this is not a claim of remote exploitation of Octopus.
Use the current verified stable release, 2.10.0, before the first public beta.

## Current state and scope

- `octopus.xcodeproj/project.pbxproj`: Sparkle uses `kind = upToNextMajorVersion; minimumVersion = 2.8.1;`.
- `octopus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: Sparkle is 2.8.1,
  revision `5581748cef2bae787496fe6d61139aebe0a451f6`. KeyboardShortcuts is 2.3.0 and must stay unchanged.
- `scripts/beta-release.py`: `verify(output)` checks ZIP metadata, hash, and EdDSA signature;
  add an embedded Sparkle version check so an old signed ZIP cannot be published accidentally.
- `scripts/BETA-RELEASE.md`: change the version-specific signing-feed limitation to 2.10.0.
- `plans/README.md` and this plan: record source application and pending artifact checks accurately.

Preserve Debug ID `com.mayank.octopus.local`, Release ID `store.getoctopus`, version 2.1.0,
build 4, the existing Keychain signing key, and the updater's public feed. No source upload,
new dependency, paid Apple account, app refactor, or application preferences change is in scope.
Use the release script's existing `fail(...)` error convention and subprocess argument lists.

## Steps and verification

1. Raise the Sparkle minimum to 2.10.0, retaining the existing requirement kind.
   Verify with `rg -n 'minimumVersion' octopus.xcodeproj/project.pbxproj`:
   Sparkle 2.10.0 and KeyboardShortcuts 2.3.0.
2. Resolve packages with:
   ```sh
   xcodebuild -resolvePackageDependencies -project octopus.xcodeproj -scheme octopus -clonedSourcePackagesDirPath .build/DerivedData/SourcePackages
   ```
   Expected: Sparkle 2.10.0, revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`;
   KeyboardShortcuts remains 2.3.0. This downloads dependencies; it does not build the app.
3. Read `Sparkle.framework/Versions/B/Resources/Info.plist` from the ZIP inside `verify(output)`.
   Require a numeric semantic version at least 2.10.0; report a useful error otherwise.
   Verify the source diff: the check executes for both `prepare` and `publish` before any upload.
4. Apply plan 009, then ask before rebuilding. Use a fresh output directory:
   ```sh
   python3 scripts/beta-release.py prepare --output .build/beta-release/2.1.0-4-repaired
   ```
   Expected: archive succeeds, Sparkle signature verifies, and the prepared ZIP embeds 2.10.0.
5. With approval, launch the extracted package and confirm startup, version 2.1.0/build 4,
   and Sparkle loading. Quit it and restore any original development copy afterward.
   A real two-version update remains separate from the startup check.

## Done criteria and stop conditions

- [ ] Requirement and resolved Sparkle version are 2.10.0; unrelated dependencies are unchanged.
- [ ] The publisher rejects the old ZIP based on its embedded Sparkle version.
- [ ] New ZIP verifies, contains Sparkle 2.10.0, and startup succeeds.
- [ ] Only scoped source/plan files changed; index records pending versus performed checks.

Stop if resolution changes KeyboardShortcuts, the verified tag revision differs, the upgrade
requires an updater API rewrite, or a build/check fails. Do not reset the Keychain key or
overwrite the existing ZIP/tag. No new implementation-mirroring unit tests are needed;
the regression check is against the actual embedded framework in the signed ZIP.

## Maintenance

Keep the package requirement, lockfile, and release minimum-version guard aligned on future
security upgrades. Preserve app identity and the signing key during updates. User approval
is required separately for building and publishing; do not commit or push the source tree.
