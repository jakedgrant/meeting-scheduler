# Android release signing

This document describes how Android release builds are signed and how to verify the result. It addresses finding F26 in the [architecture review](architecture-review-2026-10-21.md#f26-android-release-builds-can-silently-use-debug-signing).

## Behaviour

| Build | Signing inputs | Result |
| --- | --- | --- |
| Debug (`assembleDebug`, `installDebug`) | None needed | Signed with the standard Android debug key, as before. Application ID `com.meetingscheduler.android.debug`. |
| Release (`assembleRelease`, `bundleRelease`) | All four present, keystore file exists | Signed with the release key. |
| Release | Any input missing or blank, or the keystore path doesn't exist | The build fails before packaging and lists every missing input. No release artifact is produced, and the build never falls back to the debug key. |
| Release with `-PallowUnsignedRelease=true` | Incomplete | Explicit opt-in. Produces `app-release-unsigned.apk` (or an unsigned `.aab`) and logs a warning. Use it only when a separate, controlled step signs the artifact. |

Configuring, compiling, linting, and unit-testing the release variant (for example `compileReleaseKotlin` or `testReleaseUnitTest`) do not need signing material. Android Studio sync still works without it. The check runs from the `validateReleaseSigning` task, which these tasks depend on: `assembleRelease`, `bundleRelease`, `packageRelease`, `packageReleaseBundle`, `signReleaseBundle`, and `packageReleaseUniversalApk`.

Before this change, the release build type used the debug signing config whenever the `KEYSTORE_FILE` environment variable was unset. It checked only that one variable.

## Inputs

Each input is read from a Gradle property first, then from an environment variable with the same name.

| Name | Meaning |
| --- | --- |
| `KEYSTORE_FILE` | Path to the keystore (`.jks` or PKCS12). Use an absolute path. A relative path resolves against `apps/android/app/`. |
| `KEYSTORE_PASSWORD` | Keystore password |
| `KEY_ALIAS` | Alias of the signing key in the keystore |
| `KEY_PASSWORD` | Password for that key (for PKCS12 keystores, usually the same as the keystore password) |

Gradle properties can come from `-PNAME=value` or from the user-level `~/.gradle/gradle.properties`. **Do not put credentials in `apps/android/gradle.properties`.** That file is tracked by Git even though `.gitignore` lists it, so anything written there gets committed. Keystores (`*.jks`, `*.keystore`) are ignored and must never be committed.

The check confirms the inputs exist and the keystore file exists. A wrong password or alias fails later in AGP's packaging task with AGP's own keystore error.

## CI configuration

Store these as CI secrets (the names are suggestions; only the four environment variables above are read by Gradle):

| Secret | Contents |
| --- | --- |
| `ANDROID_RELEASE_KEYSTORE_BASE64` | `base64 -i upload-key.jks` output |
| `ANDROID_RELEASE_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_RELEASE_KEY_ALIAS` | Key alias |
| `ANDROID_RELEASE_KEY_PASSWORD` | Key password |
| `ANDROID_RELEASE_CERT_SHA256` | Expected SHA-256 certificate fingerprint (not secret, but kept with the others) |

Example GitHub Actions step:

```yaml
- name: Build signed release bundle
  working-directory: apps/android
  env:
    KEYSTORE_PASSWORD: ${{ secrets.ANDROID_RELEASE_KEYSTORE_PASSWORD }}
    KEY_ALIAS: ${{ secrets.ANDROID_RELEASE_KEY_ALIAS }}
    KEY_PASSWORD: ${{ secrets.ANDROID_RELEASE_KEY_PASSWORD }}
  run: |
    echo "${{ secrets.ANDROID_RELEASE_KEYSTORE_BASE64 }}" | base64 --decode > "$RUNNER_TEMP/release.jks"
    export KEYSTORE_FILE="$RUNNER_TEMP/release.jks"
    ./gradlew --no-daemon :app:bundleRelease
```

A release build also needs `app/google-services.json` for the release application ID. That file is ignored by Git, so CI must supply it from a secret as well. Crashlytics uploads the R8 mapping file for minified release builds, which needs network access and a real Firebase app ID.

With Play App Signing, the key configured here is the **upload key**, and Google re-signs with the app signing key. Register the app signing key's SHA-1 (from Play Console) with the Google Sign-In Android OAuth client, or Google Sign-In fails in Play-distributed builds.

## Verifying the certificate on an artifact

Find the expected fingerprint from the keystore:

```bash
keytool -list -v -keystore "$KEYSTORE_FILE" -alias "$KEY_ALIAS" | grep -E "SHA256:|Owner:"
```

APK (`apksigner` ships in Android SDK build-tools):

```bash
apksigner verify --verbose --print-certs app/build/outputs/apk/release/app-release.apk
# Expect "Verified using v2 scheme (APK Signature Scheme v2): true", and a
# "Signer #1 certificate SHA-256 digest" equal to the expected fingerprint.
# The certificate DN must not be "CN=Android Debug, O=Android, C=US".
```

App bundle:

```bash
keytool -printcert -jarfile app/build/outputs/bundle/release/app-release.aab
# Expect the release Owner and the expected SHA256 fingerprint.
```

In CI, compare the digest with `ANDROID_RELEASE_CERT_SHA256` and fail the job if they differ.

## Verification steps for this change

Run these from `apps/android` with JDK 17 or 21 and Android SDK platform 36 / build-tools 36.0.0. They need no emulator or device.

```bash
unset KEYSTORE_FILE KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD

# 1. Debug still builds and is debug-signed
./gradlew --no-daemon :app:assembleDebug
apksigner verify --print-certs app/build/outputs/apk/debug/app-debug.apk   # CN=Android Debug

# 2. Release without signing fails clearly, listing all four inputs
./gradlew --no-daemon :app:assembleRelease          # expect: "Release signing is not configured ..."
KEY_ALIAS=x ./gradlew --no-daemon :app:bundleRelease  # lists the three still missing

# 3. Release with a throwaway keystore is signed with that key
keytool -genkeypair -keystore /tmp/f26-test.jks -storetype PKCS12 -alias f26test \
  -keyalg RSA -keysize 2048 -validity 1 -storepass f26-test-pass -keypass f26-test-pass \
  -dname "CN=F26 Throwaway"
KEYSTORE_FILE=/tmp/f26-test.jks KEYSTORE_PASSWORD=f26-test-pass KEY_ALIAS=f26test \
  KEY_PASSWORD=f26-test-pass ./gradlew --no-daemon :app:assembleRelease
apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk   # CN=F26 Throwaway
rm /tmp/f26-test.jks

# 4. Explicit unsigned opt-in
./gradlew --no-daemon :app:assembleRelease -PallowUnsignedRelease=true   # warning; app-release-unsigned.apk
```

### Recorded result, October 22, 2026

The workstation had no Gradle-compatible JDK. Only Temurin 25 and 26 are installed, and Gradle 8.11.1 (the project wrapper) and 9.0-milestone-1 both failed at startup with "25.0.1". It also had no Android SDK platform 36 or build-tools, so no `apksigner`. The steps above were therefore **not run**. Verification was static:

- Reviewed the Kotlin DSL against the Gradle 8.11 and AGP 8.9 APIs: `tasks.named(Spec)` (Gradle 8.6+), the nullable `BuildType.signingConfig`, and `buildFeatures.buildConfig`.
- Confirmed that only the release build type referenced a signing config and that nothing else selects the debug key for release.
- Compiled the iOS `Shared` package in both configurations with `xcodebuild -scheme Shared -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. Both succeeded. The Debug compile passes `-DDEBUG` to the module and the Release compile doesn't, so the `#if DEBUG` log-level gate selects `.warn` in Release.

Run steps 1–4 above (or the equivalent CI job) before merging.

## Native billing log levels (F26/F27)

- Android `PurchaseService`: `Purchases.logLevel` is `DEBUG` only when `BuildConfig.DEBUG`, and `WARN` otherwise. `buildFeatures.buildConfig = true` was enabled so that `BuildConfig` is generated.
- iOS `PurchaseService` (in the `apps/mobile` package): `#if DEBUG` selects `.debug`, otherwise `.warn`.

Still open under F27: both services print the RevenueCat `originalAppUserId` on login, and raw error messages on failure, through `println`/`print` in every build type.
