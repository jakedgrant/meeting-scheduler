# Meeting Scheduler

A multiplatform meeting scheduling service (similar to Doodle/When2meet) that allows groups of people to find common meeting times.

## Platforms

- **Web**: SvelteKit with TypeScript
- **iOS**: Swift with SwiftUI (via Skip.tools)
- **Android**: Kotlin (transpiled from Swift via Skip.tools)

## Architecture

**Supabase-only backend** - No separate backend server required.

- **Supabase**: Auth, PostgreSQL database, Edge Functions, Realtime
- **RevenueCat**: Billing for iOS, Android, and Web (via Stripe)

## Project Structure

```
meeting-scheduler/
├── apps/
│   ├── web/                 # SvelteKit web app
│   └── mobile/              # Skip iOS + Android
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
| Team | $9.99 | $99.99 | Everything + team workspace, analytics |

## RevenueCat Integration

Subscription events are processed via the `/functions/revenuecat-webhook` Edge Function, which syncs subscription status to the `subscriptions` table in Supabase.

### Entitlements

- `pro_access`: Pro tier features
- `team_access`: Team tier features (includes Pro)

## Development

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
