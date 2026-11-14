# Beta release — agent steps

How an agent ships a new Octopus beta. Background, signing and privacy details live in
`scripts/BETA-RELEASE.md`; this file is the checklist. Only run it when the user asks for a release —
publishing is public and cannot be silently undone.

## 1. Check the starting state

```sh
git status -s && git log --oneline -10
gh release list -R mayank-devac/octopus-dist --limit 3
grep -m2 "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" octopus.xcodeproj/project.pbxproj
```

- The last published tag is `v<version>-build.<build>`. Commits after it are what this release contains.
- If there are uncommitted source changes, ask whether they belong in the release. The build uses the
  working tree, not the last commit.

## 2. Choose the next version

- Build number: always last build + 1, even when the visible version stays the same.
- Version: bump the patch (`2.1.6` → `2.1.7`) unless the user names another.
- Update both app-target entries in `octopus.xcodeproj/project.pbxproj` (Debug and Release):
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Leave the test targets (`1.0` / `1`) alone.
- Commit the bump only if the user asks.

## 3. Test only what changed

Run just the test files covering the changed code, and read the tail only:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test -only-testing:octopusTests/<Suite> 2>&1 \
  | grep -E "failed|error:|TEST (SUCC|FAIL)" | tail -6
```

A filter that matches nothing still "passes" — confirm the suite actually ran. Stop if anything fails.

## 4. Write release notes

Save them in the scratchpad (never in the repo). Keep the existing format:

```markdown
## What's new in Octopus <version> (build <build>)

- <emoji> <user-facing change in plain words>. (<short commit hash>)

Beta release for testing and feedback; some behaviour may still be unstable or incomplete.
```

Describe what users notice, not internal refactors.

## 5. Build and publish

```sh
python3 scripts/beta-release.py release --version <v> --build <b> --notes-file <notes.md> \
  > <scratchpad>/release.log 2>&1; echo exit=$?; tail -5 <scratchpad>/release.log
```

- Takes several minutes (universal Release archive). Run it in the background and redirect the log;
  the xcodebuild output is huge.
- Success ends with `Published https://github.com/mayank-devac/octopus-dist/releases/tag/v<v>-build.<b>`.
- If the user says stop/wait, stop it at once. Before publishing it is harmless; afterwards check
  the GitHub release and feed before doing anything else.

## 6. Verify the feed

```sh
curl -sL https://raw.githubusercontent.com/mayank-devac/octopus-dist/main/appcast.xml \
  | grep -m2 -o 'shortVersionString>[0-9.]*\|url="[^"]*"'
```

The first entry must show the new version and its ZIP URL.

## Failure rules

- `Output already exists`: a previous attempt left `.build/beta-release/<v>-<b>/`. Look inside first;
  remove it only if it is an unpublished, incomplete attempt — otherwise use a fresh `--output`.
- `Release tag already exists`: never overwrite or delete a published release. Bump the build instead.
- Partial publish (release created but feed not pushed, or the reverse): stop and report to the user.
- Keychain key mismatch (`SUPublicEDKey`): stop. Never regenerate or export the Sparkle key.
- `Signing certificate 'Octopus Release' is not in the Keychain`: stop and ask the user to restore
  it from backup. Never create a new one silently — a new certificate resets everyone's Accessibility grant.

## Report back

Release URL, version/build, tests run, and what is not verified: a real Sparkle update from the
previous version and Accessibility permission surviving the update.
