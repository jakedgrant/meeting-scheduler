# Supabase Project Launch Checklist

This checklist covers all steps needed to deploy your Meeting Scheduler application to production.

## Prerequisites

- [ ] Supabase account created
- [ ] Domain name purchased and DNS access available
- [ ] Google Cloud Console account (for OAuth)
- [ ] Apple Developer account (for OAuth)
- [ ] RevenueCat account configured
- [ ] Hosting platform account (Vercel, Netlify, or Cloudflare Pages)

---

## 1. Create Production Supabase Project

### 1.1 Project Creation
- [ ] Go to [Supabase Dashboard](https://supabase.com/dashboard)
- [ ] Click "New Project"
- [ ] Choose organization
- [ ] Set project name: `meeting-scheduler-prod` (or your preferred name)
- [ ] Generate a strong database password and save it securely
- [ ] Select a region close to your users
- [ ] Choose pricing plan (Free tier or Pro)
- [ ] Wait for project provisioning to complete (~2 minutes)

### 1.2 Get Project Credentials
- [ ] Navigate to Project Settings > API
- [ ] Copy and save securely:
  - Project URL (e.g., `https://xxxxx.supabase.co`)
  - `anon` public key
  - `service_role` secret key (keep this private!)
- [ ] Navigate to Project Settings > Database
- [ ] Copy connection string for future reference

---

## 2. Database Setup

### 2.1 Link Local Project to Production
```bash
# In your project root
supabase link --project-ref <your-project-ref>
```
- [ ] Find project ref in Project Settings > General > Reference ID

### 2.2 Push Database Migrations
```bash
# Push all migrations to production
supabase db push
```
- [ ] Verify migrations applied successfully
- [ ] Check Supabase Dashboard > Database > Migrations to confirm all migrations are listed

### 2.3 Verify Database Schema
- [ ] Open Supabase Dashboard > Table Editor
- [ ] Confirm these tables exist:
  - `users`
  - `polls`
  - `time_options`
  - `responses`
  - `poll_share_codes` (or similar)
- [ ] Navigate to Database > Policies
- [ ] Verify Row Level Security (RLS) policies are active

### 2.4 Seed Data (Optional)
- [ ] If you have production seed data, run:
  ```bash
  supabase db reset --db-url <production-connection-string>
  ```
  **WARNING:** Only do this on a fresh database!

---

## 3. Configure Authentication

### 3.1 Update Site URL
- [ ] Go to Authentication > URL Configuration
- [ ] Set Site URL to your production domain: `https://yourdomain.com`
- [ ] Add Redirect URLs:
  - `https://yourdomain.com/auth/callback`
  - `https://www.yourdomain.com/auth/callback` (if using www)
  - `meetingscheduler://auth/callback` (for mobile app)

### 3.2 Configure Email Settings
- [ ] Go to Authentication > Email Templates
- [ ] Customize email templates (optional but recommended):
  - Confirm signup
  - Magic link
  - Password reset
- [ ] Update "From" email address in Authentication > Settings
- [ ] Consider using custom SMTP in Authentication > Settings > SMTP Settings

### 3.3 Setup Google OAuth

#### Create Google OAuth Credentials
- [ ] Go to [Google Cloud Console](https://console.cloud.google.com)
- [ ] Create new project or select existing
- [ ] Enable Google+ API
- [ ] Go to Credentials > Create Credentials > OAuth 2.0 Client ID
- [ ] Configure OAuth consent screen:
  - App name: "Meeting Scheduler"
  - User support email
  - Developer contact email
  - Add scopes: email, profile
- [ ] Create OAuth 2.0 Client ID:
  - Application type: Web application
  - Name: "Meeting Scheduler Web"
  - Authorized redirect URIs:
    - `https://<your-project-ref>.supabase.co/auth/v1/callback`
- [ ] Copy Client ID and Client Secret

#### Configure in Supabase
- [ ] Go to Authentication > Providers > Google
- [ ] Enable Google provider
- [ ] Paste Client ID
- [ ] Paste Client Secret
- [ ] Click Save

### 3.4 Setup Apple OAuth

#### Create Apple Service ID
- [ ] Go to [Apple Developer Console](https://developer.apple.com/account)
- [ ] Certificates, Identifiers & Profiles > Identifiers
- [ ] Create new App ID (if needed)
- [ ] Create new Services ID:
  - Description: "Meeting Scheduler Web"
  - Identifier: `com.yourdomain.meetingscheduler` (must be unique)
  - Enable "Sign in with Apple"
  - Configure:
    - Primary App ID: (select your app ID)
    - Web Domain: `yourdomain.com`
    - Return URLs: `https://<your-project-ref>.supabase.co/auth/v1/callback`

#### Generate Client Secret
- [ ] Use the script in your repo: `generate-apple-secret.js`
- [ ] Or generate manually following [Supabase Apple OAuth docs](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [ ] You'll need:
  - Services ID (Client ID)
  - Key ID
  - Team ID
  - Private key (.p8 file)

#### Configure in Supabase
- [ ] Go to Authentication > Providers > Apple
- [ ] Enable Apple provider
- [ ] Paste Client ID (Services ID)
- [ ] Paste Client Secret (generated JWT)
- [ ] Click Save

---

## 4. Deploy Edge Functions

### 4.1 Configure Function Secrets
```bash
# Set service role key for functions
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>

# Set RevenueCat webhook auth
supabase secrets set REVENUECAT_WEBHOOK_AUTH="Bearer <your-secret-token>"
```
- [ ] Generate a strong random token for `REVENUECAT_WEBHOOK_AUTH`
- [ ] Save this token for RevenueCat webhook configuration later

### 4.2 Deploy Functions
```bash
# Deploy all functions
supabase functions deploy

# Or deploy specific function
supabase functions deploy revenuecat-webhook
```
- [ ] Verify deployment success in terminal output
- [ ] Check Supabase Dashboard > Edge Functions
- [ ] Confirm `revenuecat-webhook` is listed and deployed

### 4.3 Test Edge Functions
- [ ] Get function URL from Dashboard > Edge Functions > revenuecat-webhook
- [ ] Test with curl (if applicable):
  ```bash
  curl -X POST https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook \
    -H "Authorization: Bearer <your-secret-token>" \
    -H "Content-Type: application/json" \
    -d '{"test": true}'
  ```

---

## 5. Configure RevenueCat

### 5.1 Setup Webhook
- [ ] Go to RevenueCat Dashboard > Project Settings > Integrations
- [ ] Add new Webhook
- [ ] Webhook URL: `https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook`
- [ ] Authorization Header: `Bearer <your-secret-token>` (from step 4.1)
- [ ] Select events to send (recommended):
  - `INITIAL_PURCHASE`
  - `RENEWAL`
  - `CANCELLATION`
  - `EXPIRATION`
  - `PRODUCT_CHANGE`
- [ ] Save webhook

### 5.2 Get RevenueCat API Keys
- [ ] Go to RevenueCat Dashboard > Project Settings > API Keys
- [ ] Copy "Public app-specific API key" for Web
- [ ] Save for environment variables

---

## 6. Deploy Web Application

### 6.1 Choose Hosting Platform
Recommended platforms for SvelteKit:
- **Vercel** (easiest, auto-detects SvelteKit)
- **Netlify** (good performance, easy setup)
- **Cloudflare Pages** (global CDN, generous free tier)

### 6.2 Configure Environment Variables

Create production environment variables on your hosting platform:

```bash
# Supabase
VITE_SUPABASE_URL=https://<your-project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<your-anon-key>

# RevenueCat
VITE_REVENUECAT_WEB_KEY=<your-revenuecat-web-key>

# App
VITE_APP_NAME="Meeting Scheduler"
VITE_APP_URL=https://yourdomain.com
```

- [ ] Add all environment variables to hosting platform
- [ ] Verify no local/development values are used

### 6.3 Deploy to Vercel (Option A)

#### Via GitHub (Recommended)
- [ ] Push code to GitHub repository
- [ ] Go to [Vercel Dashboard](https://vercel.com)
- [ ] Click "Add New" > "Project"
- [ ] Import your GitHub repository
- [ ] Configure:
  - Framework Preset: SvelteKit (auto-detected)
  - Root Directory: `apps/web`
  - Build Command: `npm run build` (auto-detected)
  - Output Directory: `.svelte-kit` (auto-detected)
  - Install Command: `npm install`
- [ ] Add environment variables (from step 6.2)
- [ ] Click Deploy
- [ ] Wait for deployment to complete

#### Via CLI
```bash
# Install Vercel CLI
npm i -g vercel

# Deploy from apps/web directory
cd apps/web
vercel --prod
```
- [ ] Follow CLI prompts
- [ ] Add environment variables when prompted or via dashboard

### 6.4 Deploy to Netlify (Option B)

#### Via GitHub (Recommended)
- [ ] Go to [Netlify Dashboard](https://app.netlify.com)
- [ ] Click "Add new site" > "Import an existing project"
- [ ] Connect to GitHub and select repository
- [ ] Configure:
  - Base directory: `apps/web`
  - Build command: `npm run build`
  - Publish directory: `apps/web/.svelte-kit/output`
- [ ] Add environment variables (from step 6.2)
- [ ] Click Deploy

#### Via CLI
```bash
# Install Netlify CLI
npm i -g netlify-cli

# Deploy from apps/web directory
cd apps/web
netlify deploy --prod
```

### 6.5 Deploy to Cloudflare Pages (Option C)
- [ ] Go to [Cloudflare Dashboard](https://dash.cloudflare.com)
- [ ] Pages > Create a project
- [ ] Connect to GitHub
- [ ] Configure:
  - Build command: `npm run build`
  - Build output directory: `.svelte-kit/cloudflare`
  - Root directory: `apps/web`
- [ ] Add environment variables
- [ ] Save and Deploy

---

## 7. Domain Configuration

### 7.1 Add Custom Domain
- [ ] In your hosting platform dashboard, add custom domain
- [ ] Follow platform-specific instructions:
  - **Vercel**: Settings > Domains > Add
  - **Netlify**: Domain settings > Add custom domain
  - **Cloudflare**: Automatic if using Cloudflare DNS

### 7.2 Configure DNS
- [ ] Add DNS records (platform will provide):
  - **A record** or **CNAME**: Point to hosting platform
  - Example for Vercel: `CNAME @ cname.vercel-dns.com`
- [ ] If using www subdomain, add second CNAME
- [ ] Wait for DNS propagation (can take 24-48 hours, usually faster)

### 7.3 Enable HTTPS
- [ ] Most platforms auto-provision SSL certificates
- [ ] Verify HTTPS is working: `https://yourdomain.com`
- [ ] Enable "Force HTTPS" in hosting platform settings

### 7.4 Update Supabase Configuration
- [ ] Return to Supabase Dashboard
- [ ] Update Authentication > URL Configuration:
  - Site URL: `https://yourdomain.com`
  - Add redirect URL: `https://yourdomain.com/auth/callback`
- [ ] Update OAuth redirect URLs in:
  - Google Cloud Console
  - Apple Developer Console

---

## 8. Mobile App Configuration

### 8.1 Update Mobile App Environment
- [ ] Update `apps/mobile/Sources/Shared/Services/Config.swift`
- [ ] Change Supabase URL to production
- [ ] Change Supabase anon key to production
- [ ] Update any other production-specific configs

### 8.2 App Store / Play Store Setup
- [ ] Configure app in Apple App Store Connect
- [ ] Configure app in Google Play Console
- [ ] Submit for review (separate detailed process)

---

## 9. Testing & Verification

### 9.1 Functionality Tests
- [ ] Visit production URL: `https://yourdomain.com`
- [ ] Test user registration/signup
- [ ] Test email login
- [ ] Test Google OAuth login
- [ ] Test Apple OAuth login
- [ ] Create a new poll
- [ ] Add time options to poll
- [ ] Share poll (verify share codes work)
- [ ] Respond to poll as different user
- [ ] Finalize a poll
- [ ] Test settings page
- [ ] Test RevenueCat paywall (if applicable)

### 9.2 Security Checks
- [ ] Verify HTTPS is enforced
- [ ] Test RLS policies:
  - Try accessing another user's private data
  - Verify unauthorized access is blocked
- [ ] Check that service role key is NOT exposed in frontend
- [ ] Verify webhook auth is working
- [ ] Check CORS settings in Supabase if needed

### 9.3 Performance Tests
- [ ] Test page load times
- [ ] Check Lighthouse score
- [ ] Verify images/assets are optimized
- [ ] Test on mobile devices
- [ ] Test on different browsers

### 9.4 Monitoring Setup
- [ ] Enable Supabase logs in Dashboard > Logs
- [ ] Set up error tracking (e.g., Sentry)
- [ ] Configure uptime monitoring (e.g., UptimeRobot, Better Uptime)
- [ ] Set up analytics (if desired)

---

## 10. Post-Launch

### 10.1 Database Backups
- [ ] Verify automated backups are enabled (Supabase Dashboard > Database > Backups)
- [ ] Pro plan includes Point-in-Time Recovery
- [ ] Consider additional backup strategy for critical data

### 10.2 Documentation
- [ ] Document deployment process for your team
- [ ] Create runbook for common issues
- [ ] Document environment variables
- [ ] Save all credentials in secure password manager

### 10.3 Rate Limiting & Security
- [ ] Consider enabling rate limiting in Supabase
- [ ] Set up database connection pooling if needed
- [ ] Review and adjust RLS policies as needed
- [ ] Enable 2FA on Supabase account

### 10.4 Scaling Considerations
- [ ] Monitor database performance in Supabase Dashboard
- [ ] Consider upgrading Supabase plan if needed
- [ ] Review Edge Function usage and limits
- [ ] Set up database indexes for performance

---

## 11. Rollback Plan

In case of issues:

### Emergency Rollback
- [ ] Hosting platform: Revert to previous deployment
  - Vercel: Deployments > Previous deployment > Promote to Production
  - Netlify: Deploys > Previous deploy > Publish
- [ ] If database migration issues: Use Supabase Dashboard > Database > Backups to restore

### Database Rollback
```bash
# Reset to specific migration (DANGEROUS - test first!)
supabase db reset --db-url <production-url> --version <migration-version>
```

---

## Quick Reference

### Important URLs
- Production App: `https://yourdomain.com`
- Supabase Dashboard: `https://supabase.com/dashboard/project/<project-ref>`
- Hosting Dashboard: `[Your hosting platform URL]`
- RevenueCat Dashboard: `https://app.revenuecat.com`

### Key Commands
```bash
# Link to production
supabase link --project-ref <ref>

# Push database changes
supabase db push

# Deploy edge functions
supabase functions deploy

# Set secrets
supabase secrets set KEY=value

# Build web app
cd apps/web && npm run build
```

### Support Resources
- [Supabase Documentation](https://supabase.com/docs)
- [SvelteKit Documentation](https://kit.svelte.dev/docs)
- [RevenueCat Documentation](https://www.revenuecat.com/docs)
- [Vercel Support](https://vercel.com/support) / [Netlify Support](https://www.netlify.com/support/)

---

## Notes

- **Always test in a staging environment first** if possible
- **Never commit secrets** to version control
- **Keep dependencies updated** for security patches
- **Monitor costs** on Supabase and hosting platforms
- **Test mobile deep links** after domain changes

Good luck with your launch! 🚀
