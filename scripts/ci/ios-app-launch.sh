#!/usr/bin/env bash
set -euo pipefail

# Builds the MeetingScheduler app wrapper for a simulator, installs it on a fresh simulator and
# launches it with no signed-in session. The launch must stay alive for IOS_LAUNCH_SECONDS, and
# the system must write no crash report for it. No account, secret or test backend is involved:
# a signed-out launch makes no authenticated request, so the run does not depend on hosted data.
#
# On a disposable GitHub Actions runner the script creates and deletes its own simulator. For a
# local run, set IOS_LAUNCH_SIMULATOR_ID to a simulator you own; the script then boots it if
# needed, uninstalls the app before and after, and leaves the simulator in its original state.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="${IOS_CI_OUTPUT:?IOS_CI_OUTPUT must name the job output directory}"
settle_seconds="${IOS_LAUNCH_SECONDS:-15}"
bundle_id=com.jacobgrant.MeetingScheduler
local_simulator="${IOS_LAUNCH_SIMULATOR_ID:-}"
if [[ -z "$local_simulator" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
  printf '%s\n' 'Run this script on a GitHub Actions runner, or set IOS_LAUNCH_SIMULATOR_ID.' >&2
  exit 1
fi
mkdir -p "$output"

simulator_id="$local_simulator"
booted_here=false
cleanup() {
  [[ -n "$simulator_id" ]] || return 0
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
  if [[ -n "$local_simulator" ]]; then
    xcrun simctl uninstall "$simulator_id" "$bundle_id" 2>/dev/null || true
    if [[ "$booted_here" == true ]]; then xcrun simctl shutdown "$simulator_id" || true; fi
  else
    xcrun simctl shutdown "$simulator_id" || true
    xcrun simctl delete "$simulator_id" || true
  fi
}
trap cleanup EXIT

xcodebuild -version | tee "$output/xcode-version.txt"

if [[ -z "$local_simulator" ]]; then
  # Select an installed iOS 26 runtime explicitly rather than whichever simulator the image booted.
  xcrun simctl list runtimes --json > "$output/runtimes.json"
  runtime_id="$(python3 - "$output/runtimes.json" <<'PY'
import json, pathlib, sys
runtimes = json.loads(pathlib.Path(sys.argv[1]).read_text())['runtimes']
eligible = [r for r in runtimes if r.get('isAvailable')
    and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
    and r['version'].split('.')[0] == '26']
if not eligible:
    raise SystemExit('No available iOS 26 simulator runtime in the selected Xcode')
print(max(eligible, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)"
  simulator_id="$(xcrun simctl create "Scheduler Launch CI ${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime_id")"
fi

if ! xcrun simctl list devices booted | grep -q "$simulator_id"; then
  booted_here=true
  xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b
[[ -z "$local_simulator" ]] || xcrun simctl uninstall "$simulator_id" "$bundle_id" 2>/dev/null || true

derived="$output/LaunchDerivedData"
xcodebuild -project "$repo_root/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$output/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination "platform=iOS Simulator,id=$simulator_id" CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$output/launch-build.log"

app="$derived/Build/Products/Debug-iphonesimulator/MeetingScheduler.app"
test -d "$app"
xcrun simctl install "$simulator_id" "$app"

reports="$HOME/Library/Logs/DiagnosticReports"
marker="$output/launch-start"
touch "$marker"
launch_output="$(xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id")"
printf '%s\n' "$launch_output" | tee "$output/launch.txt"
pid="${launch_output##*: }"
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "::error::simctl did not report a process id"; exit 1; }

# The process must still be the same running process after the settle period.
sleep "$settle_seconds"
xcrun simctl io "$simulator_id" screenshot "$output/launched.png"
if ! kill -0 "$pid" 2>/dev/null; then
  echo "::error::MeetingScheduler (pid $pid) exited within ${settle_seconds}s of launch"
  exit 1
fi
if xcrun simctl spawn "$simulator_id" launchctl list | awk -v id="UIKitApplication:$bundle_id" 'index($0, id)' \
    | tee "$output/launchctl.txt" | grep -q .; then :; else
  echo "::error::the app is not registered with the simulator after launch"
  exit 1
fi
if [[ -d "$reports" ]] && find "$reports" -name 'MeetingScheduler*' -newer "$marker" | grep -q .; then
  echo "::error::a crash report was written for MeetingScheduler"
  find "$reports" -name 'MeetingScheduler*' -newer "$marker" -print
  exit 1
fi
echo "MeetingScheduler stayed running as pid $pid for ${settle_seconds}s with no crash report."
