#!/usr/bin/env bash
set -euo pipefail

# CI only. Writes a placeholder google-services.json so the Android app builds without a
# Firebase project; the placeholder is not a real configuration and contacts nothing.
target="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../apps/android/app" && pwd)/google-services.json"
test ! -e "$target"
cat > "$target" <<'JSON'
{
  "project_info": {
    "project_number": "000000000000",
    "project_id": "ci-placeholder-not-a-real-project",
    "storage_bucket": "ci-placeholder-not-a-real-project.appspot.com"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:000000000000:android:0000000000000000",
        "android_client_info": { "package_name": "com.meetingscheduler.android" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "CI-PLACEHOLDER-NOT-A-REAL-KEY" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:000000000000:android:0000000000000001",
        "android_client_info": { "package_name": "com.meetingscheduler.android.debug" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "CI-PLACEHOLDER-NOT-A-REAL-KEY" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    }
  ],
  "configuration_version": "1"
}
JSON
