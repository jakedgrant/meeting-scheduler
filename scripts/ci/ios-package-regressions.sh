#!/usr/bin/env bash
set -euo pipefail

# This script owns a fresh simulator on an ephemeral GitHub-hosted runner.
# Do not use it against a developer's shared simulator service.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  printf '%s\n' 'Run this script only on a disposable GitHub Actions runner.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="${IOS_CI_OUTPUT:?IOS_CI_OUTPUT must name the isolated job output directory}"
mkdir -p "$output"
simulator_id=''
cleanup() {
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" || true
    xcrun simctl delete "$simulator_id" || true
  fi
}
trap cleanup EXIT

xcodebuild -version | tee "$output/xcode-version.txt"
xcrun swift --version | tee "$output/swift-version.txt"
python3 - "$output/swift-version.txt" <<'PY'
import pathlib, re, sys
match = re.search(r'Swift version (\d+)\.(\d+)', pathlib.Path(sys.argv[1]).read_text())
if not match or tuple(map(int, match.groups())) < (6, 2):
    raise SystemExit('Swift 6.2 or newer is required by Package.swift')
PY

cd "$repo_root"
package_dir="$repo_root/apps/mobile"
workspace="$package_dir/.swiftpm/xcode/package.xcworkspace"
mkdir -p "$workspace/xcshareddata/swiftpm"
cat > "$workspace/contents.xcworkspacedata" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>
XML
# The committed root lockfile remains authoritative for Xcode's generated
# package workspace as well. No wrapper project or dependency update is needed.
cp "$package_dir/Package.resolved" "$workspace/xcshareddata/swiftpm/Package.resolved"
verify_lockfile() {
  git diff --exit-code -- apps/mobile/Package.resolved
  python3 - "$package_dir/Package.resolved" "$workspace/xcshareddata/swiftpm/Package.resolved" <<'PY'
import json, pathlib, sys
def revisions(path):
    return {pin['identity']: pin['state']['revision']
        for pin in json.loads(pathlib.Path(path).read_text())['pins']}
if revisions(sys.argv[1]) != revisions(sys.argv[2]):
    raise SystemExit('Generated workspace changed the committed package revisions')
PY
}

common=(
  -workspace "$workspace"
  -scheme MeetingScheduler-Package
  -configuration Debug
  -derivedDataPath "$output/DerivedData"
  -clonedSourcePackagesDirPath "$output/SourcePackages"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGNING_ALLOWED=NO
)
xcodebuild "${common[@]}" -resolvePackageDependencies 2>&1 | tee "$output/resolve-packages.log"
verify_lockfile

# Select an installed iOS 26 runtime explicitly. Do not rely on an ambiguous
# device name or whichever simulator happens to be booted in the runner image.
xcrun simctl list runtimes --json > "$output/runtimes.json"
xcrun simctl list devicetypes --json > "$output/device-types.json"
python3 - "$output" <<'PY'
import json, pathlib, sys
output = pathlib.Path(sys.argv[1])
runtimes = json.loads((output / 'runtimes.json').read_text())['runtimes']
eligible = [r for r in runtimes if r.get('isAvailable')
    and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
    and r['version'].split('.')[0] == '26']
if not eligible:
    raise SystemExit('No available iOS 26 simulator runtime in the selected Xcode')
runtime = max(eligible, key=lambda r: tuple(map(int, r['version'].split('.'))))
device_types = json.loads((output / 'device-types.json').read_text())['devicetypes']
device = next((d for d in device_types
    if d['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'), None)
if not device:
    raise SystemExit('The documented iPhone 17 Pro device type is unavailable')
(output / 'runtime-id.txt').write_text(runtime['identifier'])
(output / 'device-type-id.txt').write_text(device['identifier'])
print(f"Dedicated CI device: {device['name']} / iOS {runtime['version']}")
PY
simulator_id="$(xcrun simctl create "Scheduler CI ${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" \
  "$(cat "$output/device-type-id.txt")" "$(cat "$output/runtime-id.txt")")"
printf '%s\n' "$simulator_id" > "$output/simulator-id.txt"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b

xcodebuild "${common[@]}" \
  -destination 'generic/platform=iOS Simulator' \
  -parallel-testing-enabled NO build-for-testing 2>&1 | tee "$output/build-for-testing.log"

# One regression target contains the production SwiftData provider, account
# lifecycle and availability command/editor suites as each feature lands.
xcodebuild "${common[@]}" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO \
  -only-testing:MeetingSchedulerTests \
  -resultBundlePath "$output/Regressions.xcresult" \
  test-without-building 2>&1 | tee "$output/test.log"

verify_lockfile

# Compile the tracked application wrapper as well as the package. Shared auth,
# calendar and billing changes must remain wired into the shipping entry point.
xcodebuild -project "$repo_root/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath "$output/WrapperDerivedData" \
  -clonedSourcePackagesDirPath "$output/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$output/wrapper-build.log"
verify_lockfile
