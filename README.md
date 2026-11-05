# Meeting Scheduler

A multiplatform meeting scheduling service (similar to Doodle/When2meet) that allows groups of people to find common meeting times.

## Platforms

- **Web**: SvelteKit with TypeScript
- **iOS**: Swift and SwiftUI, as a Swift package with an Xcode app wrapper
- **Android**: Kotlin and Jetpack Compose

The three clients are written separately and share no code. They share contracts instead.

## Architecture

**Supabase-only backend** - No separate backend server required.

- **Supabase**: Auth, PostgreSQL database, Edge Functions, Realtime
- **RevenueCat**: Billing for iOS, Android, and Web (via Stripe)

The database owns the product rules. Poll creation, joining, availability saves and finalization are SQL functions that check the caller, the poll's state and, where one applies, the plan limit, so a client can't grant itself more than its plan allows. The clients use the plan limits only to describe plans.

What the clients share:

- `packages/shared-config/entitlements.json` lists each tier's limits. The database tests check the creation command against it, the web reads its limits from it, and the iOS and Android tests check their copies against it.
- `packages/shared-config/date-time-fixtures.json` holds the date and time cases the database and each client's tests check; see [the date/time contract](docs/date-time-contract.md).
- `npm run generate:database-types` at the repository root generates `apps/web/src/lib/database.types.ts` from the migrations. The web checks each `json` function result in `rpc-results.ts` before using it.

Each client builds its services in one place and passes them to its screens:

- **iOS**: `AppServices` builds the Supabase transport, one SwiftData persistence provider, the clock and the auth, poll, calendar and purchase services.
- **Android**: `AppContainer` builds the Supabase client, the services, the clock and the factory for each account's creation-draft store once per process.
- **Web**: `apps/web/src/lib/supabase.ts` builds the one client; the stores in `apps/web/src/lib/stores` hold session-scoped state.

The poll detail and creation screens keep their workflows in models (`PollDetailModel` and `PollCreationModel` on iOS and Android, the stores and editors on the web), so tests run them with fakes. [The architecture review](docs/architecture-review-2026-10-21.md) and [its progress notes](docs/architecture-remediation-progress.md) record how this came about.

## Project Structure

```
meeting-scheduler/
├── apps/
│   ├── web/                 # SvelteKit web app
│   ├── android/             # Native Android app (Kotlin, Gradle)
│   └── mobile/              # iOS: Swift package (Sources/, Tests/)
│       └── MeetingScheduler/  # Xcode app wrapper (tracked; see docs/ios-checkout.md)
├── packages/
│   └── shared-config/       # Shared configuration
├── supabase/
│   ├── migrations/          # Database migrations
│   └── functions/           # Edge Functions
└── scripts/                 # Development scripts
```

## Getting Started

### Prerequisites

- Node.js 20+
- Supabase CLI
- Xcode 15+ (for iOS development)
- Android Studio (for Android development)

### Setup

1. **Clone and install dependencies:**
   ```bash
   cd apps/web
   npm install
   ```

2. **Configure environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your Supabase and RevenueCat credentials
   ```

3. **Set up Supabase:**
   ```bash
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   supabase functions deploy revenuecat-webhook
   ```

4. **Set Supabase secrets:**
   ```bash
   supabase secrets set REVENUECAT_WEBHOOK_AUTH="Bearer your-secret"
   ```

5. **Run the web app:**
   ```bash
   cd apps/web
   npm run dev
   ```

## Subscription Tiers

| Tier | Monthly | Yearly | Features |
|------|---------|--------|----------|
| Free | $0 | $0 | 1 active poll, 10 participants/poll |
| Pro | $4.99 | $49.99 | Unlimited polls, calendar sync, 50 participants |
| Team | $9.99 | $99.99 | Everything + team workspace, analytics, 100 participants |
| Event pass | — | — | One-time purchase for free accounts: one poll with 50 participants, outside the free poll limit |

## RevenueCat Integration

The `revenuecat-webhook` Edge Function verifies and queues each RevenueCat event. The scheduled `billing-worker` reads the customer's current purchases from RevenueCat and updates the `subscriptions` table and event passes in one transaction. See [billing webhooks](docs/billing-webhooks.md).

### Entitlements

- `pro_access`: Pro tier features
- `team_access`: Team tier features (includes Pro)

Event passes are one-time products, not entitlements. The billing worker records each pass bought under a product ID in `REVENUECAT_EVENT_PASS_PRODUCT_IDS` as a row in `public.event_passes` (see [billing webhooks](docs/billing-webhooks.md)). An account without a subscription can spend one pass when it creates a poll. That poll gets Pro's participant limit and doesn't count toward the free account's active poll.

## Development

### iOS

Open `apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj` in Xcode and run the `MeetingScheduler` scheme. The project uses the Swift package at `apps/mobile` as a local package. For a command-line build that needs no simulator device or signing, and for the clean-checkout check, see [docs/ios-checkout.md](docs/ios-checkout.md).

### Web

```bash
cd apps/web
npm run dev      # Start dev server
npm run build    # Build for production
npm run preview  # Preview production build
```

### Database

```bash
supabase db push           # Apply migrations
supabase db reset          # Reset and reseed database
supabase gen types --lang=typescript --project-id YOUR_PROJECT_ID > types/supabase.ts
```

### Edge Functions

```bash
supabase functions serve   # Local development
supabase functions deploy  # Deploy to production
```

## License

Private - All rights reserved
