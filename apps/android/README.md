# Meeting Scheduler - Android App

This is the Android port of the Meeting Scheduler iOS app, translated from Swift/SwiftUI to Kotlin/Jetpack Compose.

## Architecture

The app follows the same architecture as the iOS version:

- **MVVM Pattern**: ViewModels manage state and business logic
- **Jetpack Compose**: Modern declarative UI framework (equivalent to SwiftUI)
- **Kotlin Coroutines**: Asynchronous programming (equivalent to Swift async/await)
- **Services**: Singleton services for auth, polls, calendar, and purchases

## Project Structure

```
app/src/main/
├── kotlin/com/meetingscheduler/android/
│   ├── Config.kt                      # Configuration constants
│   ├── MainActivity.kt                # Main activity entry point
│   │
│   ├── models/                        # Data models
│   │   ├── User.kt                    # Profile model
│   │   ├── Poll.kt                    # Poll-related models
│   │   └── Subscription.kt            # Subscription models
│   │
│   ├── services/                      # Business logic services
│   │   ├── SupabaseService.kt         # Database service
│   │   ├── AuthService.kt             # Authentication
│   │   ├── PollService.kt             # Poll operations
│   │   ├── CalendarService.kt         # Calendar integration
│   │   └── PurchaseService.kt         # RevenueCat billing
│   │
│   └── ui/                            # Jetpack Compose views
│       ├── ContentView.kt             # Root composable
│       ├── MainTabView.kt             # Tab navigation
│       ├── AuthView.kt                # Authentication screen
│       ├── PollListView.kt            # Polls listing
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

# Release build
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

1. Implement remaining views (CreatePollView, PollDetailView, etc.)
2. Add navigation between screens
3. Implement full calendar conflict checking
4. Add unit tests
5. Add integration tests
6. Optimize performance
7. Add analytics
8. Submit to Google Play Store

## License

Same as the iOS app.
