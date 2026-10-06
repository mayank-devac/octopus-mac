#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$SCRIPT_DIR/.build/DerivedData}"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/octopus.app"

echo "Building octopus ($CONFIGURATION)..."
/usr/bin/xcodebuild \
    -project "$SCRIPT_DIR/octopus.xcodeproj" \
    -scheme octopus \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build succeeded, but octopus.app was not found at: $APP_PATH" >&2
    exit 1
fi

echo "Restarting octopus..."
# Match the resolved bundle path, never every process named octopus.
# A refused or timed-out quit exits the script before another instance launches.
/usr/bin/osascript -l JavaScript - "$APP_PATH" <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');

function run(argv) {
    const targetPath = ObjC.unwrap($.NSURL.fileURLWithPath(argv[0]).URLByResolvingSymlinksInPath.path);
    const runningApps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const targets = [];

    for (let index = 0; index < runningApps.count; index++) {
        const app = runningApps.objectAtIndex(index);
        const bundleURL = app.bundleURL;
        if (!bundleURL.isNil() &&
            ObjC.unwrap(bundleURL.URLByResolvingSymlinksInPath.path) === targetPath) {
            targets.push(app);
        }
    }

    for (const app of targets) {
        if (!app.isTerminated && !app.terminate) {
            throw new Error('octopus could not be asked to quit. Close it manually and retry.');
        }
    }

    const deadline = Date.now() + 10000;
    while (targets.some(app => !app.isTerminated)) {
        if (Date.now() >= deadline) {
            throw new Error('octopus is still running. Close it manually and retry; no forced kill was attempted.');
        }
        // AppKit refreshes termination state when the main run loop runs.
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
    }

    return targets.length ? 'Previous instance quit normally.' : 'No running instance at the target app path.';
}
JXA

/usr/bin/open -n "$APP_PATH"
echo "Launched: $APP_PATH"
