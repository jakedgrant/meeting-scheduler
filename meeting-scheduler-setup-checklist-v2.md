# Meeting Scheduler - Setup Checklist

## Prerequisites Before Starting with Claude Code

Complete these steps manually before starting implementation.

---

## 1. Supabase Setup ✅ Required

### Create Project
- [x] Go to [supabase.com](https://supabase.com) and create account
- [x] Create new project (choose region closest to your users)
- [x] Wait for project to provision (~2 minutes)

### Get Credentials
- [x] Copy **Project URL** (Settings → API → Project URL) https://jaymsvyddyvvozzrgfpg.supabase.co
- [x] Copy **Anon Key** (Settings → API → Project API keys → anon public) eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY5NjE1NjMsImV4cCI6MjA4MjUzNzU2M30.2_N53weaaa0L-hZ11NXNatbhGyPWOyW57PERQDmvmTM
- [x] Copy **Service Role Key** (Settings → API → Project API keys → service_role) - keep secret! - eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Njk2MTU2MywiZXhwIjoyMDgyNTM3NTYzfQ.de0i0Hr7x78tNTMopfYD6Aj_2vgEKqv3qxI0J6zrxkI

### Configure Auth Providers
- [x] Go to Authentication → Providers

**Google OAuth:**
- [x] Go to [Google Cloud Console](https://console.cloud.google.com)
- [x] Create OAuth 2.0 credentials
- [x] Add authorized redirect URI: `https://[YOUR_PROJECT_REF].supabase.co/auth/v1/callback`
- [x] Copy Client ID and Secret to Supabase

**Apple Sign-In:**
- [x] Go to [Apple Developer Portal](https://developer.apple.com)
- [x] Create App ID with Sign In with Apple capability
- [x] Create Services ID for web sign-in
- [x] Generate private key
- [x] Configure in Supabase with: Services ID, Team ID, Key ID, Private Key

### Install Supabase CLI
```bash
# macOS
brew install supabase/tap/supabase

# npm (alternative)
npm install -g supabase
```

---

## 2. RevenueCat Setup ✅ Required

### Create Project
- [x] Go to [revenuecat.com](https://www.revenuecat.com) and create account
- [x] Create new project
- [x] Note Project Id: proj29e92231

### Connect Stores

**App Store Connect (iOS):**
- [x] Create App Store Connect API Key (App Store Connect → Users and Access → Keys)
- [x] Add to RevenueCat: Settings → Apps → Add App → iOS
- [x] Note your **RevenueCat iOS API Key** appl_IjDPPTTLISbUsrRUeNXXBGrlLMt

**Google Play (Android):**
- [ ] Create Google Play Service Account with financial access
- [ ] Add to RevenueCat: Settings → Apps → Add App → Android
- [ ] Note your **RevenueCat Android API Key**

**Stripe (Web Billing):**
- [x] Go to RevenueCat → Settings → Apps → Add App → Stripe
- [x] Click "Connect Stripe" and authorize
- [x] Note your **RevenueCat Web API Key** rcb_sgssHsUfpdiVlFtWZoFDxQtAovZY

### Create Entitlements
- [ ] Go to RevenueCat → Project → Entitlements
- [ ] Create: `pro_access`
- [ ] Create: `team_access`

### Create Products

**In App Store Connect:**
- [ ] Create subscription group: "Meeting Scheduler"
- [ ] Add products:
  - `pro_monthly` - $4.99/month
  - `pro_yearly` - $49.99/year
  - `team_monthly` - $9.99/month
  - `team_yearly` - $99.99/year
- [ ] Add consumable: `event_pass` - $1.99

**In Google Play Console:**
- [ ] Create subscription products matching above
- [ ] Create one-time product for event pass

**In RevenueCat:**
- [ ] Create Products matching store product IDs
- [ ] Link products to entitlements
- [ ] Create Offering "default" with packages

### Configure Webhook
- [x] Go to RevenueCat → Project → Integrations → Webhooks
- [x] Add webhook URL: `https://jaymsvyddyvvozzrgfpg.supabase.co/functions/v1/revenuecat-webhook`
- [x] Set authorization header: `Bearer 95287eaadab89ffc19cba3b6830b8d18ff19d6298b79c02291d08bb45a62868e`
- [ ] Enable events: All subscription events + NON_RENEWING_PURCHASE

### GitHub
- [x] Create new repository: `meeting-scheduler`
- [x] Clone locally (or leave empty for Claude Code to initialize)
  ```
  Repository URL: https://github.com/jakedgrant/meeting-scheduler.git
  ```

---

## 3. Development Tools ✅ Required

### macOS
- [x] Xcode 26+ (for iOS development and Skip)
- [ ] Android Studio (for Android testing)

### Swift & Skip
```bash
# Verify Swift version (need 5.9+)
swift --version

# Install Skip
brew install skiptools/skip/skip

# Verify Skip installation
skip doctor
```

### Node.js & Package Manager
```bash
# Install Node.js 20+ (recommend using nvm)
nvm install 20
nvm use 20

# Install pnpm (recommended) or use npm
npm install -g pnpm
```

### Verify All Tools
```bash
# Run these to verify setup
swift --version          # Should be 5.9+
skip doctor              # Should show all green
node --version           # Should be 20+
pnpm --version           # Should be 8+
supabase --version       # Should be latest
```

---

## 4. Accounts Summary

| Service | Purpose | URL |
|---------|---------|-----|
| Supabase | Database, Auth, Edge Functions, Realtime | [supabase.com](https://supabase.com) |
| RevenueCat | Subscription billing | [revenuecat.com](https://revenuecat.com) |
| Apple Developer | iOS app distribution | [developer.apple.com](https://developer.apple.com) |
| Google Play Console | Android app distribution | [play.google.com/console](https://play.google.com/console) |
| Stripe | Web payments (via RevenueCat) | [stripe.com](https://stripe.com) |
| Cloudflare | Web hosting (Pages) | [cloudflare.com](https://cloudflare.com) |
| GitHub | Source control | [github.com](https://github.com) |

---

## 5. Credentials Checklist

Before starting with Claude Code, have these ready:

```bash
# Supabase
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...  # Keep secret!

# RevenueCat
REVENUECAT_IOS_KEY=appl_xxxxx
REVENUECAT_ANDROID_KEY=goog_xxxxx
REVENUECAT_WEB_KEY=rcb_xxxxx
REVENUECAT_WEBHOOK_SECRET=your-random-secret

# OAuth (configured in Supabase dashboard)
# - Google Client ID & Secret
# - Apple Services ID, Team ID, Key ID, Private Key
```

---

## 6. Estimated Costs

### MVP / Development Phase
| Service | Cost |
|---------|------|
| Supabase | $0 (free tier: 500MB, 50K MAU) |
| RevenueCat | $0 (free to $2.5K MTR) |
| Cloudflare Pages | $0 (free tier) |
| Apple Developer | $99/year |
| Google Play | $25 one-time |
| **Total** | ~$125 one-time + $99/year |

### Production (1K daily users)
| Service | Cost |
|---------|------|
| Supabase | $25/month (Pro tier) |
| RevenueCat | $0-1% of revenue |
| Cloudflare | $0 |
| **Total** | ~$25-50/month |

---

## Ready to Start?

Once you've completed the checklist above, you're ready to start with Claude Code!

### Startup Prompt for Claude Code:

```
I'm building a multiplatform meeting scheduler app. Here's my setup:

**Architecture:** Supabase-only (no separate backend)
- Supabase for auth, database, edge functions, realtime
- RevenueCat for billing (iOS, Android, Web)
- SvelteKit for web
- Skip.tools for iOS + Android (shared Swift code)

**Completed:**
- Supabase project created
- RevenueCat project created with Stripe connected
- Auth providers configured (Google, Apple)
- Entitlements created: pro_access, team_access

**My credentials:**
- Supabase URL: [YOUR_URL]
- Supabase Anon Key: [YOUR_KEY]
- RevenueCat Web Key: [YOUR_KEY]

Let's start Phase 1:
1. Create the repository structure
2. Create the database migration file
3. Deploy the RevenueCat webhook Edge Function
4. Initialize the SvelteKit web project

I have the full project brief. Want me to paste it?
```

---

## Quick Reference: What Changed from v1

| Removed | Why |
|---------|-----|
| Railway / Fly.io | Not needed - Supabase handles everything |
| Vapor backend | Replaced by Supabase Edge Functions |
| OpenAPI spec | Not needed - using Supabase SDK directly |
| Generated API clients | Not needed - SDKs provide type safety |

| Simplified |
|------------|
| Architecture: 1 service (Supabase) instead of 2 |
| Deployment: Just Supabase + Cloudflare Pages |
| Cost: ~$0/month to start instead of $10-30 |
