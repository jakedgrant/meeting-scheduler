# Darwin (iOS) Project Directory

This directory will contain iOS-specific configuration and project files for the Skip Fuse app.

## What Goes Here

After running the Skip build process on macOS, this directory will contain:

- **Xcode Project Files**: `.xcodeproj` or `.xcworkspace` files
- **Assets**: `Assets.xcassets` for app icons, images, etc.
- **Entitlements**: `Entitlements.plist` for app capabilities
- **Configuration**: `.xcconfig` files for build settings
- **iOS-specific Sources**: Any platform-specific Swift code

## Initial Setup

The Darwin project structure will be automatically generated when you:

1. Install Skip CLI on macOS: `brew install skiptools/skip/skip`
2. Navigate to the mobile directory: `cd apps/mobile`
3. Run: `swift build` or `skip build`

This will initialize the full Skip Fuse project structure including the Xcode project.

## Building for iOS

Once set up, you can build and run the iOS app from Xcode by opening the project file in this directory.
