# Skip Fuse Setup for MeetingScheduler Android

This document describes how to build the Android version of the MeetingScheduler mobile app using **Skip Fuse**, which compiles Swift code natively for Android without transpilation.

## What is Skip Fuse?

Skip Fuse is a native Swift-to-Android solution that:
- ✅ **Compiles Swift natively** for Android using the official Swift SDK for Android
- ✅ **Auto-generates JNI bridging** code to communicate with Kotlin/Java
- ✅ **Shares Swift code** between iOS and Android platforms
- ✅ **Avoids transpilation** - your Swift code compiles directly to native ARM binaries
- ✅ **Free for indie developers** as of November 2025

## Prerequisites

### Required Software (macOS only)

Skip Fuse **requires macOS** - it cannot be used on Linux or Windows. You need:

1. **macOS 13+** (ARM or Intel)
2. **Xcode** (latest version)
3. **Homebrew** - Install from https://brew.sh
4. **Android Studio** - Latest version (Koala 2024.1.1+)
5. **Skip CLI** - Installed via Homebrew (see below)

### Installation Steps

1. **Install Skip CLI and prerequisites:**
   ```bash
   brew install skiptools/skip/skip
   ```
   This automatically installs:
   - Skip CLI tool
   - Kotlin compiler
   - Gradle build system
   - Android build tools

2. **Verify installation:**
   ```bash
   skip --version
   ```

## Project Structure

The mobile app is now configured with the following structure:

```
apps/mobile/
├── Package.swift          # Swift Package Manager configuration (Skip Fuse enabled)
├── Skip.env              # Skip Fuse app configuration
├── Sources/              # Shared Swift source code
│   ├── MeetingSchedulerApp/  # SwiftUI views and app code
│   └── Shared/           # Models, services, and business logic
├── Android/              # Android-specific configuration
│   └── settings.gradle.kts   # Gradle settings for Android build
├── Darwin/               # iOS-specific configuration (generated)
└── Tests/                # Unit tests

```

## Building the App

### First Time Setup

1. **Navigate to the mobile directory:**
   ```bash
   cd apps/mobile
   ```

2. **Build the project:**
   ```bash
   swift build
   ```

   This will:
   - Resolve Swift package dependencies
   - Initialize the Skip Fuse plugin
   - Generate the Android project structure
   - Create the Darwin (iOS) Xcode project
   - Compile Swift code for both platforms

3. **Open in Xcode (recommended):**
   ```bash
   skip open
   ```
   OR manually open the generated Xcode project in `Darwin/`

### Running on iOS Simulator

From Xcode:
1. Select an iOS simulator target
2. Click Run (⌘R)

From command line:
```bash
xcodebuild -scheme MeetingSchedulerApp -destination 'platform=iOS Simulator,name=iPhone 15' run
```

### Running on Android Emulator

#### Option 1: From Xcode (Easiest)

The Xcode project includes a build phase script that automatically deploys to Android:

1. Start an Android emulator in Android Studio
2. In Xcode, select the MeetingSchedulerApp target
3. Build and run (⌘R)
4. The app will deploy to **both** iOS simulator and Android emulator simultaneously!

#### Option 2: From Android Studio

1. Open the `Android/` directory in Android Studio
2. Let Gradle sync the project
3. Select an Android emulator
4. Click Run

#### Option 3: From Command Line

```bash
cd Android
./gradlew installDebug
adb shell am start -n com.meetingscheduler.app/.MainActivity
```

### Testing

Run all tests (Swift + Kotlin):
```bash
skip test
```

Run Swift tests only:
```bash
swift test
```

Run from Xcode:
```bash
⌘U (or Product > Test)
```

## Package.swift Configuration

The project is configured with Skip Fuse packages:

- **skip-fuse** - Core Skip Fuse bridging framework
- **skip-fuse-ui** - SwiftUI to Android bridge (NOT skip-ui)
- **skip-foundation** - Foundation framework for Android
- **skip-model** - Model/data layer support

## Key Differences: Skip Fuse vs Skip Lite

| Feature | Skip Fuse (This Project) | Skip Lite |
|---------|-------------------------|-----------|
| Swift Compilation | ✅ Native ARM binaries | ❌ Transpiled to Kotlin |
| Swift SDK for Android | ✅ Yes | ❌ No |
| Package Required | `skip-fuse-ui` | `skip-ui` |
| Dependency Support | ✅ Any Swift package | ⚠️ Must be "Skip-aware" |
| Performance | ⭐⭐⭐⭐⭐ Native | ⭐⭐⭐⭐ Good |
| Setup Flag | `--native-app` | (default) |

## Troubleshooting

### Skip CLI not found
```bash
# Ensure Homebrew bin is in PATH
export PATH="/opt/homebrew/bin:$PATH"  # For Apple Silicon
# OR
export PATH="/usr/local/bin:$PATH"     # For Intel Macs

brew install skiptools/skip/skip
```

### Android emulator not detected
```bash
# Check Android SDK path
echo $ANDROID_HOME

# Should point to Android SDK (usually ~/Library/Android/sdk)
# If not set:
export ANDROID_HOME=~/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools
```

### Build fails with dependency errors
```bash
# Clean and rebuild
swift package clean
swift build
```

### Xcode DerivedData issues
```bash
# Clean Xcode caches
rm -rf ~/Library/Developer/Xcode/DerivedData
```

## Deployment

### iOS App Store

1. Open the Darwin Xcode project
2. Configure signing and capabilities
3. Archive the app (Product > Archive)
4. Use Xcode Organizer to upload to App Store Connect

OR use Fastlane:
```bash
cd Darwin
fastlane release
```

### Google Play Store

1. Configure app signing in `Android/app/build.gradle.kts`
2. Build release APK/AAB:
   ```bash
   cd Android
   ./gradlew bundleRelease  # For AAB (recommended)
   # OR
   ./gradlew assembleRelease  # For APK
   ```
3. Upload to Google Play Console

OR use Fastlane:
```bash
cd Android
fastlane release
```

## Resources

- **Skip Documentation**: https://skip.tools/docs/
- **Skip Fuse Package**: https://github.com/skiptools/skip-fuse
- **Skip Fuse UI**: https://github.com/skiptools/skip-fuse-ui
- **Example Apps**: https://github.com/skiptools/skipapp-showcase-fuse
- **Swift SDK for Android**: https://www.swift.org/install/

## Support

For issues or questions:
- **Skip GitHub Issues**: https://github.com/skiptools/skip/issues
- **Skip Discussions**: https://github.com/orgs/skiptools/discussions

---

**Note**: This setup was initialized on Linux. The Android and Darwin project structures will be fully generated when you first run `swift build` on macOS with Skip CLI installed.
