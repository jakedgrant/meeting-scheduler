#!/usr/bin/env bash
set -euo pipefail

# ServiceSet makes the compiler check every service it holds, but the compiler can't stop a new
# value being added to the environment beside it. This check fails on any way of doing that.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
service_key='^apps/mobile/Sources/Shared/Services/ServiceEnvironment\.swift:[0-9]+:private struct ServiceSetKey: EnvironmentKey \{$'

stray="$(cd "$repo_root" \
  && { grep -rnE --include='*.swift' '\bEnvironmentKey\b|@Entry\b|@Environment\([A-Za-z_.]+\.self\)' \
    apps/mobile/Sources apps/mobile/MeetingScheduler || true; } \
  | { grep -vE "$service_key" || true; })"

if [[ -n "$stray" ]]; then
  printf '%s\n' "$stray" >&2
  printf '%s\n' 'Add services to ServiceSet in ServiceEnvironment.swift rather than a separate environment value.' >&2
  printf '%s\n' 'If this value is not a service, allow it in scripts/ci/check-ios-environment-keys.sh.' >&2
  exit 1
fi
