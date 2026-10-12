# Plan 009: Include the original Octopus MIT notice in releases

## Status

- Priority: P1; category: release compliance; effort: S; change risk: LOW.
- Planned at: commit `525e357`, 2026-10-13, with staged release preparation changes.
- Depends on: none; perform the final rebuild after plan 008 too.
- Status: APPLIED IN SOURCE; packaging now includes the original notice and the verifier
  checks its presence. ZIP verification and publication require separate approval.

## Why

Root `LICENSE` retains the original Octopus copyright and MIT permission notice.
Its lines 12-13 require that notice to accompany copies or substantial portions.
The prepared ZIP's only license file is `Contents/Resources/ThirdPartyNotices.txt`;
the complete root license is absent. Including this notice does not publish Octopus's source.
Reference: [MIT license text](https://opensource.org/license/mit).

## Current state and scope

- `LICENSE`: preserve original attribution. Mayank separately approved removing his added
  copyright-line addition and later chose a separate "Modified by Mayank Baral" credit
  in the packaged notices. That public attribution is explicitly approved.
- `scripts/beta-release.py`: `prepare(output, version, build)` initializes `notices = []`
  and adds only Sparkle and KeyboardShortcuts licenses before signing the app.
- `scripts/beta-release.py`: `verify(output)` currently has no original-license check.
- `plans/README.md` and this plan: record application and verification status.

The release script, approved attribution edit in LICENSE, and plan/index are editable for this fix. Do not change app logic,
licenses, authors, bundle IDs, version numbers, ZIP ownership metadata, or the public README.
Use existing `Path.read_text()`, `ZipFile.read(...)`, and `fail(...)` patterns.

## Steps and verification

1. Initialize notices with a clearly labelled original Octopus entry containing `ROOT / 'LICENSE'`
   verbatim, followed by the separately approved "Modified by Mayank Baral" credit. Keep the two dependency notices. Insert it before main-app codesigning so resource
   signatures include the new notice. Verify by inspecting the source diff.
2. In `verify(output)`, read the packaged ThirdPartyNotices file and require the complete
   root license (ignoring only outside whitespace) to be present. Fail before uploading if absent.
   Verify by inspecting the shared `prepare`/`publish` call paths.
3. After both plans and separate build approval:
   ```sh
   python3 scripts/beta-release.py prepare --output .build/beta-release/2.1.0-4-repaired
   ```
   Expected: `Sparkle update signature verified` and `Prepared ... Nothing has been uploaded`.
4. Inspect the new ZIP without reading any secret files:
   ```sh
   python3 - <<'PY'
   from pathlib import Path
   import zipfile
   path = Path('.build/beta-release/2.1.0-4-repaired/Octopus-2.1.0-4.zip')
   with zipfile.ZipFile(path) as archive:
       notices = archive.read('octopus.app/Contents/Resources/ThirdPartyNotices.txt').decode()
       assert Path('LICENSE').read_text().strip() in notices
       assert 'Sparkle' in notices and 'KeyboardShortcuts' in notices
   print('All required license notices present')
   PY
   ```
   Expected: exact success line and exit 0. Extract with macOS `ditto -x -k`, not Python
   extraction, when checking framework symlinks and code signatures.

## Done criteria and stop conditions

- [ ] Source packaging includes original Octopus, Sparkle, and KeyboardShortcuts notices.
- [ ] Publisher rejects the old ZIP lacking the original notice.
- [ ] Actual rebuilt ZIP contains the complete root LICENSE and passes both signing checks.
- [ ] Existing signed ZIP stays unchanged until the repaired package is reviewed.

Stop if the root license changes unexpectedly, the packaged notice is incomplete, or a fix
requires modifying app source or attribution. No unit test duplicating the script is necessary;
verify the real ZIP. Update the index without claiming unperformed checks passed.

## Maintenance

Include notices before signing every app; adding them afterward invalidates signatures.
If another dependency is introduced, add its required notices too. Keep original attribution
even when distributing a closed-source modified app. Never upload source or private keys.
