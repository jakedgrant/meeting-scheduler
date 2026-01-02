# Pre-Claude Code Setup Checklist

Complete these steps before starting Claude Code implementation.

## 1. Account Setup

### Supabase
- [x] Create account at https://supabase.com
- [x] Create new project named "meeting-scheduler"
- [x] Save credentials:
  ```
  Project URL: https://jaymsvyddyvvozzrgfpg.supabase.co
  Anon Key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY5NjE1NjMsImV4cCI6MjA4MjUzNzU2M30.2_N53weaaa0L-hZ11NXNatbhGyPWOyW57PERQDmvmTM
  Service Role Key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Njk2MTU2MywiZXhwIjoyMDgyNTM3NTYzfQ.de0i0Hr7x78tNTMopfYD6Aj_2vgEKqv3qxI0J6zrxkI
  Database Password: jpw_ugf0mab@wqu.ZBR
  ```

### RevenueCat
- [x] Create account at https://www.revenuecat.com
- [x] Create new project
- [x] Save credentials:
  ```
  Project ID: proj29e92231
  iOS Public API Key: appl_IjDPPTTLISbUsrRUeNXXBGrlLMt
  Android Public API Key: ________________________
  Secret API Key: sk_MXznxVyevJmacNSNaPQuqTlDbvVNC
  ```

### Stripe (for RevenueCat Web Billing)
- [x] Create account at https://stripe.com (if you don't have one)
- [x] Connect Stripe to RevenueCat:
  - Go to RevenueCat Dashboard → Your Project → Apps & providers
  - Click "Connect to Stripe"
  - Follow OAuth flow
- [x] Save Web Billing API Key:
  ```
  Web Public API Key: rcb_sgssHsUfpdiVlFtWZoFDxQtAovZY
  ```

### GitHub
- [x] Create new repository: `meeting-scheduler`
- [x] Clone locally (or leave empty for Claude Code to initialize)
  ```
  Repository URL: https://github.com/jakedgrant/meeting-scheduler.git
  ```

---

## 2. Local Development Tools

Run these commands to verify your setup:

```bash
# Check Xcode (macOS)
xcode-select --version
# Should show: xcode-select version 2XXX or higher

# Check Swift
swift --version
# Should show: Swift version 5.9 or higher

# Check Node.js
node --version
# Should show: v20.x.x or higher

# Install pnpm if not installed
npm install -g pnpm
pnpm --version
# Should show: 8.x.x or higher

# Install Supabase CLI
brew install supabase/tap/supabase
supabase --version
# Should show: 1.x.x or higher

# Install Skip tools
brew install skiptools/skip/skip
skip --version
# Should show version info
```

---

## 3. Configure Supabase Auth Providers

### Google OAuth
1. Go to https://console.cloud.google.com/apis/credentials
2. Create OAuth 2.0 Client ID (Web application)
3. Add authorized redirect URI:
   ```
   https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback
   ```
4. Copy Client ID and Client Secret
5. In Supabase Dashboard → Authentication → Providers → Google:
   - Enable Google
   - Paste Client ID and Secret
   - Save

### Apple Sign-In
1. Go to https://developer.apple.com/account/resources/identifiers
2. Create App ID with "Sign in with Apple" capability
3. Create Services ID for web authentication
4. Configure domains and return URL:
   ```
   Domain: YOUR_PROJECT_REF.supabase.co
   Return URL: https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback
   ```
5. In Supabase Dashboard → Authentication → Providers → Apple:
   - Enable Apple
   - Add Service ID, Team ID, Key ID, and Private Key
   - Save

---

## 4. Create Environment File

Create a `.env.local` file with your credentials:

```bash
# Supabase
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

# RevenueCat
REVENUECAT_PROJECT_ID=xxxxxxxx
REVENUECAT_PUBLIC_API_KEY_IOS=appl_xxxxxxxx
REVENUECAT_PUBLIC_API_KEY_ANDROID=goog_xxxxxxxx
REVENUECAT_PUBLIC_API_KEY_WEB=rcb_xxxxxxxx
REVENUECAT_SECRET_API_KEY=sk_xxxxxxxx
REVENUECAT_WEBHOOK_AUTH=Bearer your-secure-random-string

# App Config
APP_BUNDLE_ID=com.yourcompany.meetingscheduler
```

Generate a secure webhook auth string:
```bash
openssl rand -hex 32
```

---

## 5. Ready for Claude Code!

Once all boxes are checked above, you're ready to start Claude Code.

### Starting Claude Code

**Option A: VS Code with Claude Extension**
1. Open VS Code
2. Open Command Palette (Cmd+Shift+P)
3. Run "Claude: Open Chat"
4. Start with the prompt below

**Option B: Claude Code CLI**
```bash
claude-code
```

### Initial Prompt for Claude Code

Copy and paste this to start:

```
I'm building a multiplatform meeting scheduler app. I have a project brief document that contains all specifications.

Please read the project brief at /home/claude/meeting-scheduler-project-brief.md (or I can paste it).

Let's start Phase 1:
1. Create the repository structure
2. Initialize Supabase project locally
3. Create the database migration from the schema in the brief

My environment:
- macOS with Xcode 15+
- Swift 5.9+
- Node.js 20+
- Supabase CLI installed
- Skip tools installed

My Supabase project URL is: [YOUR_URL]
```

---

## Troubleshooting

### "Skip not found"
```bash
brew tap skiptools/skip
brew install skip
```

### "Supabase CLI not found"
```bash
brew install supabase/tap/supabase
```

### "Swift version too old"
Update Xcode from the Mac App Store, then:
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### "Node.js version too old"
```bash
# Using nvm (recommended)
nvm install 20
nvm use 20

# Or using brew
brew install node@20
```
