# iOS checkout and build layout

This document records how the iOS app is laid out in the repository and how to confirm that a clean checkout builds. It closes finding F25 in the [architecture review](architecture-review-2026-10-21.md#f25-the-ios-app-wrapper-is-not-reproducible-from-a-clean-checkout).

## Layout

```
apps/mobile/
├── Package.swift            # Swift package: Shared + MeetingSchedulerApp libraries, tests
├── Package.resolved         # Pins for `swift build` / `swift test` on the package
├── Sources/
│   ├── Shared/              # Services, models, config
│   └── MeetingSchedulerApp/ # SwiftUI screens
├── Tests/                   # Package tests
└── MeetingScheduler/        # Xcode app wrapper (tracked files, not a submodule)
    ├── MeetingScheduler.xcodeproj/
    │   ├── project.pbxproj
    │   ├── project.xcworkspace/contents.xcworkspacedata
    │   ├── project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    │   └── xcshareddata/xcschemes/MeetingScheduler.xcscheme
    ├── MeetingScheduler/    # @main entry point, Info.plist, entitlements, assets, app icon
    ├── MeetingSchedulerTests/
    └── MeetingSchedulerUITests/
```

The wrapper is thin. `MeetingSchedulerApp.swift` imports the `MeetingSchedulerApp` and `Shared` products from the package at `apps/mobile`. The project references the package with an `XCLocalSwiftPackageReference` whose `relativePath` is `../../mobile`, resolved from the `.xcodeproj`'s parent directory (`apps/mobile/MeetingScheduler`), so it points at `apps/mobile`. The project's targets use file-system-synchronized groups, so new files dropped into `MeetingScheduler/` join the app target without editing `project.pbxproj`.

## Decision: tracked monorepo files, not a submodule

Until this change, the parent repository recorded `apps/mobile/MeetingScheduler` as a gitlink (mode `160000`) at `079a8b1a127b6eda39e8272c224c441b05cbd202`, with no `.gitmodules` entry. The evidence, gathered October 22, 2026:

- `git cat-file -t 079a8b1a…` fails in the main repository's object store.
- The GitHub API reports "No commit found for SHA" for `jakedgrant/meeting-scheduler`, and `git ls-remote` lists no ref at that commit.
- The local wrapper directory has no `.git`, and no other repository under `~/Developer` holds the object as a loose file. The account has no separate wrapper repository.
- The gitlink dates from the repository's first commit. Xcode most likely created a nested repository when the project was generated, and that nested `.git` was removed later.

A submodule would need a second repository that does not exist, and the pinned commit is unrecoverable. The wrapper is also small (about 480 KB, 14 files), changes together with the package, and has no separate release cycle. It is now tracked directly in this repository.

## Ignore rules

`.gitignore` still ignores `*.xcodeproj` and `*.xcworkspace` globally, with two negations that re-include this one project and its embedded workspace:

```
!/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj/
!/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj/project.xcworkspace/
```

User-specific state stays ignored by the existing rules: `xcuserdata/` (breakpoints, per-user scheme management, `UserInterfaceState.xcuserstate`), `*.xcuserstate`, `DerivedData/`, `build/`, `.build/`, and `.DS_Store`. To confirm, run `git check-ignore -v` on a path such as `apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj/xcuserdata/<user>.xcuserdatad/x.plist`. Any other Xcode project added elsewhere stays ignored until it gets its own negation.

## Configuration and secrets

The wrapper holds no API keys, `.xcconfig` files, or provisioning profiles. The project uses automatic signing with `DEVELOPMENT_TEAM = PWBLH7P4Y4`. A team ID is public (it appears in every signed binary), and contributors on another team override it locally or on the command line. The entitlements file declares Sign in with Apple only.

The Supabase URL, Supabase anon key, and RevenueCat Apple public SDK key live in `apps/mobile/Sources/Shared/Services/Config.swift`, which was already tracked. All three are publishable client keys designed to ship inside the app binary, so a clean checkout needs no extra configuration. Moving them to per-environment build settings belongs to F23/F12 environment work, not to this change.

## Package resolution

Two `Package.resolved` files exist. `apps/mobile/Package.resolved` is used by `swift build` / `swift test` on the package. The project's `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is used by `xcodebuild` and Xcode. On October 22, 2026 both pinned the same eight packages at the same revisions (purchases-ios 5.97.0, supabase-swift 2.39.0, and their transitive dependencies). When a dependency changes, update both files. The build commands below pass `-onlyUsePackageVersionsFromResolvedFile`, so drift between the project's resolved file and `Package.swift` fails the build instead of resolving silently.

A first build fetches all eight packages from GitHub. On a machine with a warm SwiftPM cache (`~/Library/Caches/org.swift.swiftpm`), Xcode prints `Fetching from … (cached)` and checks out from that cache. CI on a cold runner needs network access to github.com, or a cache of the cloned packages.

## Clean-checkout verification

The following commands need no simulator device, signing identity, or local server:

```bash
D=$(mktemp -d /tmp/ios-clean-XXXX)
git clone --no-local --branch <branch> <repository> "$D/repo"
cd "$D/repo"
git submodule status          # prints nothing; there are no submodules
git ls-files --stage apps/mobile/MeetingScheduler | grep 160000   # no output

xcodebuild \
  -project apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj \
  -scheme MeetingScheduler -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$D/DerivedData" \
  -clonedSourcePackagesDirPath "$D/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build

# Compiles the unit and UI test bundles without running them
xcodebuild … same flags … build-for-testing

# Release configuration for a device, unsigned
xcodebuild … -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$D/DerivedData-release" … CODE_SIGNING_ALLOWED=NO build
```

### Recorded result, October 22, 2026

Toolchain: Xcode 27.1 (27A9269), Apple Swift 6.4, macOS 27. The disposable clone came from branch `claude/f25-ios-checkout` and contained 14 tracked wrapper files and no gitlink.

| Command | Result |
| --- | --- |
| Debug `build`, `generic/platform=iOS Simulator` | `** BUILD SUCCEEDED **` (40 s). All 8 packages checked out at their pinned versions from the warm cache. One tool warning: AppIntents metadata extraction skipped, because the app has no AppIntents dependency. |
| Debug `build-for-testing`, same destination | `** TEST BUILD SUCCEEDED **` |
| Release `build`, `generic/platform=iOS` | `** BUILD SUCCEEDED **` (56 s), with the same single AppIntents warning. |

The test bundles were compiled but not run, because running them needs a simulator reservation. The UI test targets are still Xcode templates (see F24).

## Follow-ups

- **F24 CI:** add a macOS job that runs the Debug simulator build and `build-for-testing` above on pull requests that touch `apps/mobile/**`, using the same flags. Cache `SourcePackages` keyed on the project's `Package.resolved`. Running tests requires a simulator runtime on the runner. This change adds no CI job.
- **Stale local copy:** after this change merges, the untracked wrapper directory in an existing checkout conflicts with the incoming tracked files. Move it aside before pulling (for example, `mv apps/mobile/MeetingScheduler ~/MeetingScheduler.local-backup`), pull, compare against the backup (`diff -r -x xcuserdata -x .DS_Store`), and then delete the backup. Per-user `xcuserdata` can be copied back if wanted, since it stays ignored.
- Other changes inside `apps/mobile/MeetingScheduler` should wait for this change to merge (integration rule for F25).
