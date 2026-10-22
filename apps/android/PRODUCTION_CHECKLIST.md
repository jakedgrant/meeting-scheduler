# Android App Production Checklist
## For iOS Engineers New to Android Development

This guide will help you take the Meeting Scheduler Android app from development to production. Each section includes iOS comparisons to help you understand Android concepts.

---

## 📋 Table of Contents

1. [Development Environment Setup](#1-development-environment-setup)
2. [Configure Google Sign-In](#2-configure-google-sign-in)
3. [Test Calendar Features](#3-test-calendar-features)
4. [Configure RevenueCat](#4-configure-revenuecat)
5. [Testing & Quality Assurance](#5-testing--quality-assurance)
6. [Optimization & Performance](#6-optimization--performance)
7. [Play Store Release](#7-play-store-release)

---

## 1. Development Environment Setup

### Install Android Studio
**iOS Equivalent:** Xcode

- [x] Download Android Studio from https://developer.android.com/studio
- [x] Install Android Studio (similar to installing Xcode)
- [x] During setup, ensure these components are installed:
  - [x] Android SDK (like iOS SDK)
  - [x] Android SDK Platform-Tools
  - [x] Android Emulator (like iOS Simulator)
  - [x] Android Virtual Device (AVD)

### Open the Project

- [x] Open Android Studio
- [x] Select "Open an Existing Project"
- [x] Navigate to `/home/user/meeting-scheduler/apps/android`
- [x] Wait for Gradle sync to complete (similar to Swift Package Manager resolution)

### Configure Android SDK

**iOS Equivalent:** Setting deployment targets in Xcode

- [x] Open `File > Project Structure` (or `Cmd + ;` on Mac)
- [x] Under "Project", set:
  - [x] Compile SDK: 34 (Android 14)
  - [x] Build Tools Version: Latest
- [x] Under "Modules > app", verify:
  - [ ] Minimum SDK: 26 (Android 8.0)
  - [ ] Target SDK: 34
  - [ ] Source Compatibility: Java 17
  - [ ] Target Compatibility: Java 17

### Set Up Android Emulator

**iOS Equivalent:** iOS Simulator

- [x] Open AVD Manager: `Tools > Device Manager`
- [x] Click "Create Virtual Device"
- [x] Select a phone (recommend Pixel 6 or Pixel 7)
- [x] Choose system image:
  - [x] Select "Tiramisu" (API 33) or "UpsideDownCake" (API 34)
  - [x] Download if needed
- [x] Click "Finish"
- [x] Test by clicking the play button next to your AVD

### Connect Physical Device (Recommended)

**iOS Equivalent:** Running on physical iPhone

**Enable Developer Options on Android Device:**
- [ ] Go to Settings > About Phone
- [ ] Tap "Build Number" 7 times (you'll see "You are now a developer!")
- [ ] Go back to Settings > System > Developer Options
- [ ] Enable "USB Debugging"
- [ ] Connect device via USB
- [ ] When prompted on device, tap "Allow" for USB debugging

**Verify Connection:**
- [ ] In terminal, run: `adb devices`
- [ ] You should see your device listed
- [ ] In Android Studio, your device appears in the device dropdown

---

## 2. Configure Google Sign-In

### Create Firebase Project

**iOS Equivalent:** Setting up Firebase for iOS

- [x] Go to https://console.firebase.google.com
- [x] Click "Add Project"
- [x] Enter project name: "Meeting Scheduler"
- [x] Disable Google Analytics (optional for now)
- [x] Click "Create Project"

### Add Android App to Firebase

- [x] In Firebase Console, click "Add App" and select Android
- [x] Enter Android package name:
  ```
  com.meetingscheduler.android
  ```
  **Note:** Find this in `app/build.gradle.kts` under `namespace`

- [x] Enter app nickname: "Meeting Scheduler Android"
- [ ] Leave SHA-1 empty for now (we'll add it later)
- [ ] Click "Register App"

### Download Configuration File

- [x] Download `google-services.json`
- [x] Place it in: `apps/android/app/google-services.json`
- [x] Verify it's in the correct location (same directory as `build.gradle.kts`)

### Get Debug SHA-1 Certificate

**iOS Equivalent:** Development certificate fingerprint

**On macOS/Linux:**
```bash
cd ~/.android
keytool -list -v -keystore debug.keystore -alias androiddebugkey -storepass android -keypass android
```

**On Windows:**
```bash
cd %USERPROFILE%\.android
keytool -list -v -keystore debug.keystore -alias androiddebugkey -storepass android -keypass android
```

- [x] Copy the SHA-1 fingerprint (looks like `A1:B2:C3:...`)
- [x] In Firebase Console, go to Project Settings
- [x] Under "Your apps" > Android app, click "Add fingerprint"
- [x] Paste the SHA-1 fingerprint
- [x] Click "Save"

### Configure OAuth Consent Screen

- [ ] Go to Google Cloud Console: https://console.cloud.google.com
- [ ] Select your Firebase project from the dropdown
- [ ] Go to "APIs & Services" > "OAuth consent screen"
- [ ] Select "External" user type
- [ ] Fill in:
  - [ ] App name: "Meeting Scheduler"
  - [ ] User support email: your email
  - [ ] Developer contact: your email
- [ ] Click "Save and Continue"
- [ ] Skip Scopes (click "Save and Continue")
- [ ] Skip Test Users (click "Save and Continue")
- [ ] Click "Back to Dashboard"

### Create OAuth 2.0 Client IDs

- [x] Go to "APIs & Services" > "Credentials"
- [x] Click "Create Credentials" > "OAuth client ID"

**Create Android Client:**
- [x] Application type: "Android"
- [x] Name: "Meeting Scheduler Android"
- [x] Package name: `com.meetingscheduler.android`
- [x] SHA-1: Paste your debug SHA-1 from earlier
- [x] Click "Create"
- [ ] **Save the Client ID** (you won't use it directly, but keep it)

**Create Web Client (IMPORTANT):**
- [ ] Click "Create Credentials" > "OAuth client ID" again
- [ ] Application type: "Web application"
- [ ] Name: "Meeting Scheduler Web Client"
- [ ] No need to add URIs
- [ ] Click "Create"
- [ ] **Copy the Web Client ID** - this is what you need!

### Update AuthView.kt with Web Client ID

- [x] Open `apps/android/app/src/main/kotlin/com/meetingscheduler/android/ui/AuthView.kt`
- [x] Find line 66:
  ```kotlin
  .requestIdToken("YOUR_WEB_CLIENT_ID") // TODO: Add your Google Web Client ID
  ```
- [x] Replace `"YOUR_WEB_CLIENT_ID"` with your actual Web Client ID:
  ```kotlin
  .requestIdToken("123456789-abcdefg.apps.googleusercontent.com")
  ```
- [x] Save the file

### Enable Google Sign-In API

- [x] In Google Cloud Console, go to "APIs & Services" > "Library"
- [ ] Search for "Google Sign-In"
- [ ] Click "Google Sign-In API"
- [ ] Click "Enable"

### Add Google Services Plugin to Gradle

- [ ] Open `apps/android/app/build.gradle.kts`
- [ ] At the top, add:
  ```kotlin
  plugins {
      // ... existing plugins
      id("com.google.gms.google-services") version "4.4.0"
  }
  ```
- [ ] Open `apps/android/build.gradle.kts` (project level)
- [ ] In `buildscript` > `dependencies`, add:
  ```kotlin
  classpath("com.google.gms:google-services:4.4.0")
  ```
- [ ] Sync Gradle

### Test Google Sign-In

- [ ] Run the app on emulator or device
- [ ] Tap "Continue with Google"
- [ ] You should see Google account picker
- [ ] Select an account
- [ ] Verify you're signed in (should see polls screen)

**Troubleshooting:**
- If sign-in fails with "Error 10", check:
  - [ ] Web Client ID is correct in `AuthView.kt`
  - [ ] SHA-1 fingerprint matches your debug keystore
  - [ ] Google Sign-In API is enabled
  - [ ] `google-services.json` is in the right location

---

## 3. Test Calendar Features

### Test Android Calendar Integration

**iOS Equivalent:** EventKit testing

#### Grant Calendar Permission

- [ ] Run the app
- [ ] Go to Settings tab
- [ ] Under "Calendar Integration", toggle "Android Calendar"
- [ ] System should prompt for permission
- [ ] Tap "Allow"
- [ ] Verify toggle stays on

#### Add Test Calendar Events

**Using Device Calendar App:**
- [ ] Open device's Calendar app (Google Calendar)
- [ ] Create several events for testing:
  - [ ] Event 1: Tomorrow 9:00 AM - 10:00 AM (busy)
  - [ ] Event 2: Tomorrow 2:00 PM - 3:00 PM (busy)
  - [ ] Event 3: Tomorrow (all-day)

**Verify in Meeting Scheduler:**
- [ ] In Meeting Scheduler, create a new poll
- [ ] Add time options that overlap with your calendar events
- [ ] Submit the poll
- [ ] Verify conflicting times show "Busy" badge
- [ ] Verify conflicts are auto-marked as "Unavailable"

#### Test Without Calendar Permission

- [ ] Go to device Settings > Apps > Meeting Scheduler > Permissions
- [ ] Disable Calendar permission
- [ ] Return to app, go to Settings
- [ ] Try to enable Android Calendar toggle
- [ ] Verify permission prompt appears again

### Test Google Calendar Integration

**iOS Equivalent:** Google Calendar integration via OAuth

#### Prerequisites

- [ ] Ensure you have a Google account with calendar events
- [ ] Events should be on Google Calendar (not local device calendar)

#### Configure backend calendar authorization

- [ ] Complete the [calendar credentials rollout](../../docs/calendar-credentials.md), including the private storage migration, dedicated Google Web OAuth client, Edge secrets, functions, and maintenance worker.
- [ ] Confirm the Google Calendar API is enabled and the backend requests `https://www.googleapis.com/auth/calendar.events.freebusy`.
- [ ] Calendar permission is granted through Settings in the external browser. Keep the app's Supabase sign-in flow separate; provider credentials belong only to the backend.

#### Test Google Calendar

- [ ] Go to Settings > Calendar Integration
- [ ] Toggle "Google Calendar" on
- [ ] Accept calendar permission in the browser and return to the app
- [ ] Verify the connected Google account appears in Settings
- [ ] Create a poll with times that conflict with your Google Calendar
- [ ] Verify conflicts are detected
- [ ] Disconnect, verify app access stops, and confirm queued Google revocation completes
- [ ] Reconnect and verify sign-out clears the displayed calendar state

**Troubleshooting:**
- If Google Calendar toggle doesn't work:
  - [ ] Check that Google Calendar API is enabled
  - [ ] Verify the dedicated client's redirect URI and Edge Function secrets match the rollout guide
  - [ ] Check the safe connection error shown in Settings and the backend request/error codes
  - [ ] Confirm revocation maintenance is running before attempting to reconnect

---

## 4. Configure RevenueCat

**iOS Equivalent:** RevenueCat iOS SDK setup

### Create RevenueCat Account

- [ ] Go to https://www.revenuecat.com
- [ ] Sign up or log in
- [ ] Create a new project: "Meeting Scheduler"

### Configure Android in RevenueCat

- [ ] In RevenueCat dashboard, go to your project
- [ ] Click "Apps" in sidebar
- [ ] Click "Add App"
- [ ] Select "Android"
- [ ] Enter:
  - [ ] App Name: "Meeting Scheduler Android"
  - [ ] Package Name: `com.meetingscheduler.android`
- [ ] Click "Save"

### Get Google Play Service Credentials

**This is different from iOS - Android uses JSON key file instead of p8 key**

- [ ] Go to Google Play Console: https://play.google.com/console
- [ ] If you haven't published the app yet, create a draft:
  - [ ] Click "Create app"
  - [ ] Fill in app details
  - [ ] Create a draft (you don't need to publish)
- [ ] Go to "Setup" > "API access"
- [ ] Click "Link to Google Cloud Project" (select your Firebase project)
- [ ] Under "Service Accounts", click "Create service account"
- [ ] Follow link to Google Cloud Console
- [ ] Create service account:
  - [ ] Name: "RevenueCat"
  - [ ] Click "Create and Continue"
  - [ ] Skip permissions, click "Continue"
  - [ ] Click "Done"
- [ ] Click on the service account you just created
- [ ] Go to "Keys" tab
- [ ] Click "Add Key" > "Create new key"
- [ ] Select "JSON"
- [ ] Click "Create" - this downloads the JSON file

### Upload Credentials to RevenueCat

- [ ] In RevenueCat, go to your Android app settings
- [ ] Under "Service Credentials", click "Upload JSON"
- [ ] Upload the JSON file you just downloaded
- [ ] Click "Save"

### Verify API Key

- [ ] In RevenueCat, go to "API keys"
- [ ] Copy the "Public API key" (should start with `goog_`)
- [ ] Open `apps/android/app/src/main/kotlin/com/meetingscheduler/android/Config.kt`
- [ ] Verify the `REVENUE_CAT_API_KEY` matches your public key
- [ ] If not, update it:
  ```kotlin
  const val REVENUE_CAT_API_KEY = "goog_your_actual_key_here"
  ```

### Create Products in Google Play Console

**iOS Equivalent:** Creating in-app purchases in App Store Connect

- [ ] In Google Play Console, go to "Monetize" > "Products" > "In-app products"
- [ ] Click "Create product"

**Create Pro Monthly:**
- [ ] Product ID: `pro_monthly`
- [ ] Name: "Pro Monthly"
- [ ] Description: "Unlimited polls and premium features - monthly"
- [ ] Status: Active
- [ ] Price: Set your price (e.g., $9.99)
- [ ] Click "Save"

**Create Pro Annual:**
- [ ] Product ID: `pro_annual`
- [ ] Name: "Pro Annual"
- [ ] Description: "Unlimited polls and premium features - annual"
- [ ] Status: Active
- [ ] Price: Set your price (e.g., $99.99)
- [ ] Click "Save"

### Create Subscriptions (If Using Subscriptions Instead)

**Note:** RevenueCat works better with subscriptions. If using subscriptions:

- [ ] Go to "Monetize" > "Products" > "Subscriptions"
- [ ] Click "Create subscription"
- [ ] Set up billing period, pricing, free trials, etc.
- [ ] Product IDs should match what you set in RevenueCat

### Configure Offerings in RevenueCat

- [ ] In RevenueCat, go to "Offerings"
- [ ] Click "Create Offering"
- [ ] Name: "Default"
- [ ] Identifier: `default`
- [ ] Add packages:
  - [ ] Package 1: `pro_monthly` - Type: Monthly
  - [ ] Package 2: `pro_annual` - Type: Annual
- [ ] Set as default offering
- [ ] Click "Save"

### Create Entitlements

- [ ] In RevenueCat, go to "Entitlements"
- [ ] Click "Create Entitlement"
- [ ] Entitlement ID: `pro_access`
- [ ] Display name: "Pro Access"
- [ ] Attach products:
  - [ ] `pro_monthly`
  - [ ] `pro_annual`
- [ ] Click "Save"

### Test Purchases (Requires App Upload)

**Note:** Unlike iOS, you can't test purchases in debug mode without uploading to Google Play Console

**Set Up Internal Testing:**
- [ ] In Google Play Console, go to "Testing" > "Internal testing"
- [ ] Click "Create new release"
- [ ] Upload a signed APK/AAB (we'll create this in the next section)
- [ ] Add testers:
  - [ ] Create email list with your test accounts
  - [ ] Add list to testers
- [ ] Release to internal testing

**Test the Purchase Flow:**
- [ ] Install the app from Play Store (internal testing track)
- [ ] Go to Settings > Upgrade to Pro
- [ ] Select a package
- [ ] Tap "Subscribe Now"
- [ ] Complete test purchase (Google provides test cards)
- [ ] Verify purchase shows "Active" in Settings

**Test Restore Purchases:**
- [ ] After purchasing, uninstall the app
- [ ] Reinstall from internal testing
- [ ] Sign in
- [ ] Go to Settings
- [ ] Tap "Restore Purchases"
- [ ] Verify subscription shows as active

---

## 5. Testing & Quality Assurance

### Create a Test Plan

**iOS Equivalent:** Similar to Xcode Test Plans

- [ ] Create test document listing all features
- [ ] Include test cases for:
  - [ ] Authentication flows
  - [ ] Poll creation and management
  - [ ] Availability responses
  - [ ] Calendar integration
  - [ ] Subscription flows
  - [ ] Error handling

### Manual Testing Checklist

#### Authentication
- [ ] Google Sign-In works
- [ ] Magic Link email authentication works
- [ ] Session persists after app restart
- [ ] Sign out works
- [ ] Profile editing works

#### Poll Management
- [ ] Create poll with multiple time options
- [ ] Create poll with date range
- [ ] Create poll with all-day events
- [ ] Join poll with share code
- [ ] Invalid share code shows error
- [ ] View poll details
- [ ] Submit availability responses
- [ ] Responses save correctly
- [ ] Close poll (as creator)
- [ ] Select final meeting time
- [ ] Share poll via share sheet

#### Calendar Integration
- [ ] Calendar permission request works
- [ ] Android Calendar conflicts detected
- [ ] Google Calendar conflicts detected
- [ ] Conflicts auto-marked unavailable
- [ ] Toggle switches work
- [ ] Permission denial handled gracefully

#### Subscriptions
- [ ] Paywall displays correctly
- [ ] Packages load from RevenueCat
- [ ] Purchase flow works
- [ ] Subscription status displays correctly
- [ ] Restore purchases works
- [ ] Free tier limitations work

#### UI/UX
- [ ] All screens render correctly
- [ ] Navigation works smoothly
- [ ] Back button behavior is correct
- [ ] Loading states show appropriately
- [ ] Error messages are clear
- [ ] Empty states display correctly

### Test on Multiple Devices

**Minimum Test Coverage:**
- [ ] Device with Android 8.0 (API 26)
- [ ] Device with Android 12 (API 31)
- [ ] Device with Android 14 (API 34)
- [ ] Different screen sizes (phone, tablet)
- [ ] Different manufacturers (Samsung, Google Pixel, etc.)

**Using Android Studio Device Manager:**
- [ ] Create AVDs for each Android version
- [ ] Test all critical flows on each

### Automated Testing (Recommended but Optional)

**iOS Equivalent:** XCTest

**Create Unit Tests:**
- [ ] Create test file: `app/src/test/kotlin/com/meetingscheduler/android/ExampleUnitTest.kt`
- [ ] Test service logic (AuthService, PollService, etc.)
- [ ] Run tests: `./gradlew test`

**Create UI Tests:**
- [ ] Create test file: `app/src/androidTest/kotlin/com/meetingscheduler/android/ExampleInstrumentedTest.kt`
- [ ] Use Espresso for UI testing
- [ ] Run tests: `./gradlew connectedAndroidTest`

### Performance Testing

- [ ] Open Android Profiler: `View > Tool Windows > Profiler`
- [ ] Record session while using the app
- [ ] Check:
  - [ ] Memory usage stays reasonable (< 200MB)
  - [ ] No memory leaks
  - [ ] CPU usage is acceptable
  - [ ] Network calls are efficient

---

## 6. Optimization & Performance

### Enable R8/ProGuard

**iOS Equivalent:** Bitcode optimization

- [ ] Open `app/build.gradle.kts`
- [ ] In `buildTypes` > `release`, ensure:
  ```kotlin
  buildTypes {
      release {
          isMinifyEnabled = true
          isShrinkResources = true
          proguardFiles(
              getDefaultProguardFile("proguard-android-optimize.txt"),
              "proguard-rules.pro"
          )
      }
  }
  ```
- [ ] Build release APK: `./gradlew assembleRelease`
- [ ] Test to ensure nothing is broken

### Reduce APK Size

- [ ] Remove unused resources:
  ```kotlin
  android {
      buildTypes {
          release {
              isShrinkResources = true
          }
      }
  }
  ```
- [ ] Use Android App Bundle (AAB) instead of APK
- [ ] Check APK analyzer: `Build > Analyze APK`
- [ ] Target size: < 15MB

### Optimize Images

- [ ] Convert PNGs to WebP: Right-click image > Convert to WebP
- [ ] Use vector drawables instead of PNGs where possible
- [ ] Compress images

### Network Optimization

- [ ] Verify Supabase calls use connection pooling
- [ ] Add request caching where appropriate
- [ ] Test on slow network (use Network Profiler)

### Battery Optimization

**iOS Equivalent:** Energy Impact in Instruments

- [ ] Test battery drain: `View > Tool Windows > Energy Profiler`
- [ ] Ensure no wakelocks are held unnecessarily
- [ ] Optimize background tasks

### Add Crash Reporting

**iOS Equivalent:** Crashlytics

**Option 1: Firebase Crashlytics**
- [ ] In Firebase Console, enable Crashlytics
- [ ] Add to `app/build.gradle.kts`:
  ```kotlin
  dependencies {
      implementation("com.google.firebase:firebase-crashlytics-ktx")
  }
  ```
- [ ] Initialize in `MainActivity`:
  ```kotlin
  FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
  ```

**Option 2: Sentry**
- [ ] Sign up at https://sentry.io
- [ ] Follow Android integration guide

### Add Analytics

**iOS Equivalent:** Firebase Analytics

- [ ] In Firebase Console, Analytics is automatically enabled
- [ ] Add to `app/build.gradle.kts`:
  ```kotlin
  dependencies {
      implementation("com.google.firebase:firebase-analytics-ktx")
  }
  ```
- [ ] Log events in key user actions

---

## 7. Play Store Release

### Create App Signing Key

**iOS Equivalent:** Distribution certificate

**Generate Upload Key:**
```bash
cd ~/
keytool -genkey -v -keystore meeting-scheduler-upload-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias meeting-scheduler
```

- [ ] Enter password (save this securely!)
- [ ] Enter your details (name, organization, etc.)
- [ ] Save the `.jks` file in a secure location (NOT in your repository!)

### Configure Signing in Android Studio

- [ ] Open `app/build.gradle.kts`
- [ ] Add signing config:
  ```kotlin
  android {
      signingConfigs {
          create("release") {
              storeFile = file("/path/to/meeting-scheduler-upload-key.jks")
              storePassword = "your_store_password"
              keyAlias = "meeting-scheduler"
              keyPassword = "your_key_password"
          }
      }

      buildTypes {
          release {
              signingConfig = signingConfigs.getByName("release")
              // ... other release config
          }
      }
  }
  ```

**Security Note:** Don't commit passwords! Use environment variables or gradle.properties

### Build Release APK/AAB

**Build Android App Bundle (Recommended):**
```bash
./gradlew bundleRelease
```
- [ ] Output: `app/build/outputs/bundle/release/app-release.aab`

**Build APK (Alternative):**
```bash
./gradlew assembleRelease
```
- [ ] Output: `app/build/outputs/apk/release/app-release.apk`

### Create Google Play Console Listing

- [ ] Go to Google Play Console
- [ ] Complete app information:
  - [ ] App name: "Meeting Scheduler"
  - [ ] Short description: 150 chars describing the app
  - [ ] Full description: Detailed description
  - [ ] App icon: 512x512 PNG
  - [ ] Feature graphic: 1024x500 PNG
  - [ ] Screenshots: At least 2 per device type
    - [ ] Use emulator or device to capture
    - [ ] Show key features (poll creation, calendar integration, etc.)

### Set Up Store Listing Content

**Screenshots Needed:**
- [ ] Create poll screen
- [ ] Poll detail with responses
- [ ] Calendar integration
- [ ] Settings screen
- [ ] Minimum 2, maximum 8 per device type

**Promotional Content:**
- [ ] App icon (512x512)
- [ ] Feature graphic (1024x500)
- [ ] Promotional video (optional, but recommended)

### Configure Content Rating

- [ ] In Play Console, go to "Content rating"
- [ ] Complete questionnaire
- [ ] The app should be rated for all ages
- [ ] No violence, mature content, etc.

### Set Privacy Policy

- [ ] Create privacy policy (required for apps that collect data)
- [ ] Host it on a web server
- [ ] Add URL to Play Console

### Configure App Pricing

- [ ] Go to "Pricing & distribution"
- [ ] Select "Free" (app is free, purchases are in-app)
- [ ] Select countries to distribute
- [ ] Accept content guidelines

### Upload Release Bundle

**Internal Testing First:**
- [ ] Go to "Testing" > "Internal testing"
- [ ] Click "Create new release"
- [ ] Upload the AAB file
- [ ] Add release notes
- [ ] Review and rollout

**Test Internal Release:**
- [ ] Add testers (use email addresses)
- [ ] Testers receive email with opt-in link
- [ ] Install and test from Play Store
- [ ] Fix any issues found

**Promote to Production:**
- [ ] After internal testing passes
- [ ] Go to "Production" release
- [ ] Click "Create new release"
- [ ] Or promote from internal testing
- [ ] Review and submit for review

### App Review Timeline

**iOS Equivalent:** App Store review process

- [ ] Wait for Google review (typically 1-3 days)
- [ ] Respond to any review feedback
- [ ] Once approved, app goes live

### Post-Launch Monitoring

- [ ] Monitor crash reports in Firebase Crashlytics
- [ ] Check Play Console statistics
- [ ] Monitor user reviews and respond
- [ ] Track analytics to understand user behavior
- [ ] Plan updates based on feedback

---

## 📝 Additional Resources

### Android Documentation
- Official Android Developer Guide: https://developer.android.com
- Jetpack Compose Tutorial: https://developer.android.com/jetpack/compose/tutorial
- Material Design 3: https://m3.material.io

### Key Differences for iOS Engineers
| iOS | Android |
|-----|---------|
| Xcode | Android Studio |
| Swift | Kotlin |
| SwiftUI | Jetpack Compose |
| CocoaPods/SPM | Gradle |
| Xcode Simulator | Android Emulator |
| TestFlight | Internal Testing Track |
| App Store Connect | Google Play Console |
| .ipa file | .apk or .aab file |
| Certificates & Provisioning | Signing Keys (.jks) |
| Info.plist | AndroidManifest.xml |
| Bundle ID | Package Name |

### Helpful Commands

```bash
# Build debug APK
./gradlew assembleDebug

# Build release APK
./gradlew assembleRelease

# Build release AAB
./gradlew bundleRelease

# Run tests
./gradlew test

# List connected devices
adb devices

# Install APK to device
adb install app/build/outputs/apk/debug/app-debug.apk

# View logs
adb logcat

# View logs for your app only
adb logcat | grep "com.meetingscheduler.android"

# Clear app data
adb shell pm clear com.meetingscheduler.android
```

---

## ✅ Final Checklist Before Release

- [ ] All features tested and working
- [ ] Google Sign-In configured and tested
- [ ] Calendar permissions working
- [ ] RevenueCat subscriptions tested
- [ ] Crash reporting enabled
- [ ] Analytics enabled
- [ ] ProGuard rules tested with release build
- [ ] APK/AAB size optimized
- [ ] Screenshots and store listing complete
- [ ] Privacy policy published
- [ ] Content rating completed
- [ ] Internal testing completed successfully
- [ ] All third-party API keys secured (not in code)
- [ ] Production signing key backed up securely
- [ ] Release notes written
- [ ] Support email configured

---

## 🆘 Troubleshooting Common Issues

### Build Fails
- Check Gradle sync: `File > Sync Project with Gradle Files`
- Clear build cache: `Build > Clean Project`, then `Build > Rebuild Project`
- Invalidate caches: `File > Invalidate Caches / Restart`

### Google Sign-In Fails
- Verify SHA-1 fingerprint in Firebase
- Check Web Client ID in `AuthView.kt`
- Ensure `google-services.json` is present

### Calendar Permission Not Working
- Check `AndroidManifest.xml` has permission declared
- Test on Android 6.0+ (runtime permissions required)

### RevenueCat Not Loading Products
- Verify app is in Google Play Console (even as draft)
- Check service account JSON is uploaded correctly
- Ensure products are active in Play Console

### App Crashes on Release Build
- Check ProGuard rules in `proguard-rules.pro`
- Look at crash reports in Firebase Crashlytics
- Test with `debuggable true` temporarily to get better logs

---

## 🎉 Success Criteria

Your app is ready for production when:

- ✅ All features work as expected
- ✅ No crashes during testing
- ✅ Performance is acceptable
- ✅ Security best practices followed
- ✅ Store listing is complete and professional
- ✅ Internal testing completed successfully
- ✅ All integration points (Google, RevenueCat, Supabase) working

**Congratulations on launching your first Android app!** 🚀

---

*Last Updated: January 2026*
*Android App Version: 1.0.0*
*Minimum Android Version: 8.0 (API 26)*
*Target Android Version: 14 (API 34)*
