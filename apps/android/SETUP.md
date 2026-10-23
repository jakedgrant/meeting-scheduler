# Android App Setup Guide

Quick setup guide for the Meeting Scheduler Android app.

## Prerequisites

- Android Studio Arctic Fox or later
- JDK 17
- Android SDK API 26+ (Android 8.0+)
- Git

## Quick Start

### 1. Clone and Open Project

```bash
cd /path/to/meeting-scheduler/apps/android
```

Open in Android Studio: `File > Open > Select android folder`

### 2. Configure Firebase

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Create a new project or use existing
3. Add Android app with package name: `com.meetingscheduler.android`
4. Download `google-services.json`
5. Place it in: `apps/android/app/google-services.json`

**Get SHA-1 fingerprint:**
```bash
cd ~/.android
keytool -list -v -keystore debug.keystore -alias androiddebugkey -storepass android -keypass android
```

6. Add SHA-1 to Firebase Console under Project Settings

### 3. Configure Google Sign-In

1. In Firebase Console, go to Authentication > Sign-in method
2. Enable Google
3. Go to [Google Cloud Console](https://console.cloud.google.com)
4. Navigate to APIs & Services > Credentials
5. Create OAuth 2.0 Web Client ID
6. Copy the Web Client ID
7. Update `apps/android/app/src/main/kotlin/com/meetingscheduler/android/ui/AuthView.kt`:
   ```kotlin
   .requestIdToken("YOUR_WEB_CLIENT_ID_HERE")
   ```

### 4. Release Signing (Release Builds Only)

Debug builds need no signing setup. Release builds (`assembleRelease`, `bundleRelease`) fail unless `KEYSTORE_FILE`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD` are set as environment variables or in your user-level `~/.gradle/gradle.properties`. They never fall back to the debug key. Don't put credentials in `apps/android/gradle.properties`: that file is tracked by Git. See [docs/android-release-signing.md](../../docs/android-release-signing.md).

### 5. Sync and Build

1. In Android Studio: `File > Sync Project with Gradle Files`
2. Wait for sync to complete
3. Build: `Build > Make Project`
4. Run on emulator or device

## Running the App

### On Emulator

1. Open AVD Manager: `Tools > Device Manager`
2. Create/Start an emulator (API 26+)
3. Click Run button or `Shift + F10`

### On Physical Device

1. Enable Developer Options on device
2. Enable USB Debugging
3. Connect via USB
4. Click Run and select your device

## Build Variants

- **Debug**: Development build with debug logging
  ```bash
  ./gradlew assembleDebug
  ```

- **Release**: Production build with ProGuard enabled
  ```bash
  ./gradlew assembleRelease
  ```

## Testing

### Run Unit Tests
```bash
./gradlew test
```

### Run Instrumented Tests
```bash
./gradlew connectedAndroidTest
```

## Troubleshooting

### Gradle Sync Failed
- Check internet connection
- Invalidate caches: `File > Invalidate Caches / Restart`
- Delete `.gradle` folder and sync again

### Google Sign-In Not Working
- Verify SHA-1 fingerprint matches in Firebase Console
- Ensure Web Client ID is correct in AuthView.kt
- Check `google-services.json` is in correct location

### Build Errors
- Clean project: `Build > Clean Project`
- Rebuild: `Build > Rebuild Project`
- Check JDK version is 17

## Next Steps

See [PRODUCTION_CHECKLIST.md](PRODUCTION_CHECKLIST.md) for complete production deployment guide.

## Useful Commands

```bash
# List connected devices
adb devices

# View logs
adb logcat | grep "MeetingScheduler"

# Clear app data
adb shell pm clear com.meetingscheduler.android

# Uninstall app
adb uninstall com.meetingscheduler.android

# Install APK
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Project Structure

```
apps/android/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── kotlin/com/meetingscheduler/android/
│   │   │   │   ├── models/       # Data models
│   │   │   │   ├── services/     # Business logic
│   │   │   │   ├── ui/           # Compose screens
│   │   │   │   └── MainActivity.kt
│   │   │   ├── AndroidManifest.xml
│   │   │   └── res/              # Resources
│   │   ├── test/                 # Unit tests
│   │   └── androidTest/          # Instrumented tests
│   ├── build.gradle.kts
│   └── proguard-rules.pro
├── build.gradle.kts
└── settings.gradle.kts
```

## Support

For issues and questions:
- Check [PRODUCTION_CHECKLIST.md](PRODUCTION_CHECKLIST.md)
- Review Android documentation
- Check Firebase documentation
