# Meeting Scheduler - Android App

This is the Android port of the Meeting Scheduler iOS app, translated from Swift/SwiftUI to Kotlin/Jetpack Compose.

## Architecture

- **Composition root**: `AppContainer`, created by `MeetingSchedulerApplication`, builds the Supabase client, the auth, poll, calendar and purchase services, the clock and the factory for each account's creation-draft store once per process. Services that need a context or a long-lived scope get the Application context or the application coroutine scope, never an Activity (see docs/android-lifetimes.md). `MainActivity` passes them down to the screens.
- **Screen models**: `PollDetailModel` and `PollCreationModel` in `ui` hold the detail and creation workflows. They reach the services through the interfaces in `services/PollScreenDependencies.kt` and take the clock (and, for creation, the draft store) as constructor arguments, so their unit tests pass fakes. The screens get those values from `PollScreenEnvironment`. Each screen builds a new model when the signed-in account or its session changes. The other screens still call the services directly.
- **Jetpack Compose**: Modern declarative UI framework (equivalent to SwiftUI)
- **Kotlin Coroutines**: Asynchronous programming (equivalent to Swift async/await)

## Project Structure

```
app/src/main/
├── kotlin/com/meetingscheduler/android/
│   ├── Config.kt                      # Configuration constants
│   ├── MainActivity.kt                # Main activity entry point
│   ├── AppContainer.kt                # Builds the Supabase client and services once per process
│   │
│   ├── models/                        # Data models
│   │   ├── User.kt                    # Profile model
│   │   ├── Poll.kt                    # Poll-related models
│   │   ├── PollCreation.kt            # Creation commands and plan limits (checked against packages/shared-config/entitlements.json)
│   │   └── Subscription.kt            # Subscription models
│   │
│   ├── services/                      # Business logic services
│   │   ├── AuthService.kt             # Authentication
│   │   ├── PollService.kt             # Poll operations
│   │   ├── PollScreenDependencies.kt  # What the screen models need from the services
│   │   ├── CalendarService.kt         # Calendar integration
│   │   └── PurchaseService.kt         # RevenueCat billing
│   │
│   └── ui/                            # Jetpack Compose views
│       ├── ContentView.kt             # Root composable
│       ├── MainTabView.kt             # Tab navigation
│       ├── AuthView.kt                # Authentication screen
│       ├── PollListView.kt            # Polls listing
│       ├── PollDetailView.kt          # Poll detail, with PollDetailModel.kt
│       ├── CreatePollView.kt          # Poll creation, with PollCreationModel.kt
│       ├── PollScreenEnvironment.kt   # Clock and draft store from AppContainer
│       ├── SettingsView.kt            # Settings & profile
│       └── theme/                     # Material Design theme
│
├── AndroidManifest.xml                # App manifest & permissions
└── res/                               # Resources
    └── values/
        ├── strings.xml                # String resources
        └── themes.xml                 # App theme
```

## Dependencies

### Core Android
- **Kotlin 1.9.20**
- **Jetpack Compose** (UI framework)
- **Material 3** (Design system)
- **Navigation Compose** (Navigation)
- **DataStore** (Preferences storage)

### Backend & Data
- **Supabase Kotlin 2.0.0** (Backend as a Service)
  - Auth (Authentication)
  - Postgrest (Database)
  - Functions (Edge Functions)
  - Realtime (Real-time updates)
- **Kotlinx Serialization** (JSON serialization)
- **Kotlinx DateTime** (Date/time handling)

### Third-party Integrations
- **RevenueCat 7.0.0** (In-app purchases & subscriptions)
- **Google Play Services Auth** (Google Sign-In)
- **Google Calendar API** (Calendar integration)

## Key Translation Decisions

### Swift to Kotlin
- `struct` → `data class`
- `enum` → `enum class` with `@Serializable`
- `@Observable` → `mutableStateOf` with Compose
- `async/await` → Kotlin coroutines with `suspend`
- `UUID` → `String` (Supabase uses string UUIDs)
- `Date` → `kotlinx.datetime.Instant`

### SwiftUI to Jetpack Compose
- `View` → `@Composable` functions
- `@State` → `remember { mutableStateOf() }`
- `NavigationStack` → `NavController`
- `TabView` → `NavigationBar` with state
- `.sheet()` → `AlertDialog` or bottom sheets
- `List` → `LazyColumn`
- `TextField` → `OutlinedTextField`

### Platform Differences

#### Authentication
- **iOS**: Apple Sign-In native support
- **Android**: Apple Sign-In not available, Google Sign-In implemented

#### Calendar
- **iOS**: EventKit framework
- **Android**: CalendarContract provider + Google Calendar API

#### Permissions
- **iOS**: Info.plist entries
- **Android**: Runtime permissions in AndroidManifest.xml + request at runtime

## Configuration

### Supabase
Update `Config.kt` with your Supabase credentials:
```kotlin
const val SUPABASE_URL = "https://your-project.supabase.co"
const val SUPABASE_ANON_KEY = "your-anon-key"
```

### RevenueCat
Update `Config.kt` with your RevenueCat API key:
```kotlin
const val REVENUE_CAT_API_KEY = "your-api-key"
```

### Google Sign-In
1. Add your OAuth 2.0 Web Client ID in `AuthView.kt`
2. Configure OAuth consent screen in Google Cloud Console
3. Add SHA-1 fingerprint for your app

## Building

### Requirements
- Android Studio Hedgehog or later
- JDK 17
- Android SDK 34
- Minimum SDK 26 (Android 8.0)

### Build Commands
```bash
# Debug build
./gradlew assembleDebug

# Release build (needs signing inputs; see docs/android-release-signing.md)
./gradlew assembleRelease

# Install on device
./gradlew installDebug
```

## Features Implemented

✅ User authentication (Google, Magic Link)
✅ Poll creation and management
✅ Poll joining with share codes
✅ Real-time poll updates
✅ Calendar integration (Android Calendar + Google Calendar)
✅ Conflict detection
✅ In-app purchases (RevenueCat)
✅ Profile management
✅ Settings & preferences

## Known Limitations

- Apple Sign-In not available on Android
- Some UI animations differ from iOS version
- Calendar API differences between platforms
- Material Design instead of iOS design language

## Next Steps

1. Run the instrumented tests on a device in CI
2. Optimize performance
3. Add analytics
4. Submit to Google Play Store

## License

Same as the iOS app.
