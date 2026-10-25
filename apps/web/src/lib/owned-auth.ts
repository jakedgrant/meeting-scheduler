import { AuthClient, createClient, navigatorLock, processLock, type Session, type SupportedStorage, type LockFunc } from '@supabase/supabase-js'

export function memoryAuthStorage(): SupportedStorage {
  const values = new Map<string, string>()
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value) }, removeItem: key => { values.delete(key) } }
}

export function browserAuthStorage(): SupportedStorage {
  try {
    const storage = globalThis.localStorage
    const probe = `meeting-scheduler:auth-storage:${crypto.randomUUID()}`
    storage.setItem(probe, probe)
    storage.removeItem(probe)
    return storage
  } catch { return memoryAuthStorage() }
}

/** Ownership only, never an authorization claim. A refresh retains session_id;
 * a fresh login to the same account has a different lineage. Fail closed when
 * a nonstandard token lacks lineage and its exact credentials have changed. */
export function sessionOwner(session: Session | null): string | null {
  if (!session) return null
  try {
    const raw = session.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const claims = JSON.parse(atob(raw))
    if (typeof claims.session_id === 'string' && claims.sub === session.user.id) return `${session.user.id}:${claims.session_id}`
  } catch { /* SDK test/custom tokens may not contain a session_id. */ }
  return `${session.user.id}:${session.access_token}:${session.refresh_token}`
}

interface AuthAttempt { id: string; owner: string | null; origin: string; expires: number; verifier: string | null; used: boolean; active?: () => boolean }
export function createOwnedAuth(options: {
  url: string; key: string; storage: SupportedStorage; lock?: LockFunc; autoRefresh?: boolean; fetch?: typeof fetch
}) {
  // Match SupabaseClient's existing default exactly, preserving development data.
  const storageKey = `sb-${new URL(options.url).hostname.split('.')[0]}-auth-token`
  const attemptKey = `${storageKey}:sign-in-attempt`
  const lock: LockFunc = options.lock ?? (typeof navigator !== 'undefined' && navigator.locks ? navigatorLock : processLock)
  const locked = <T>(operation: () => Promise<T>) => lock(`lock:${storageKey}`, -1, operation)
  const client = createClient(options.url, options.key, { auth: {
    storageKey, storage: options.storage, lock, persistSession: true,
    autoRefreshToken: options.autoRefresh ?? false, detectSessionInUrl: false, flowType: 'pkce'
  }, global: { fetch: options.fetch } })
  const listeners = new Set<(hint: Session | null, external: boolean) => void>()
  const publish = () => { void storedSession().then(value => { for (const listener of listeners) listener(value, false) }).catch(() => { for (const listener of listeners) listener(null, false) }) }
  async function storedSession() {
    const raw = await options.storage.getItem(storageKey)
    return raw ? JSON.parse(raw) as Session : null
  }
  async function readAttempt(): Promise<AuthAttempt | null> {
    const raw = await options.storage.getItem(attemptKey)
    return raw ? JSON.parse(raw) : null
  }
  async function owns(owner: string | null) { return sessionOwner(await storedSession()) === owner }
  let context: AuthAttempt | null = null
  let helper: InstanceType<typeof AuthClient> | undefined
  let helperTail: Promise<unknown> = Promise.resolve()
  async function getHelper() {
    if (!helper) {
      helper = new AuthClient({ url: `${options.url}/auth/v1`, headers: { apikey: options.key, Authorization: `Bearer ${options.key}` },
        // This SDK client has a virtual storage namespace. No helper session is
        // persisted and the empty key disables its BroadcastChannel. Publication
        // goes through our guarded adapter into the unchanged main SDK key.
        storageKey: '', persistSession: true, autoRefreshToken: false, detectSessionInUrl: false, flowType: 'pkce',
        fetch: options.fetch, lock: async (_name, _timeout, operation) => operation(),
        storage: {
          async getItem(key) {
            if (key !== '-code-verifier' || !context) return null
            if (!context || context.active?.() === false || !(await owns(context.owner))) throw new Error('Sign-in session changed')
            const saved = await readAttempt()
            if (!saved || saved.id !== context.id || saved.used || saved.expires <= Date.now()) throw new Error('Sign-in link expired or already used')
            context.used = true
            await options.storage.setItem(attemptKey, JSON.stringify(context))
            return context.verifier
          },
          async setItem(key, value) {
            if (!context || context.active?.() === false || !(await owns(context.owner))) throw new Error('Sign-in session changed')
            if (key === '-code-verifier') {
              context.verifier = value
              await options.storage.setItem(attemptKey, JSON.stringify(context))
            } else if (key === '') {
              const saved = await readAttempt()
              if (!saved || saved.id !== context.id || !saved.used) throw new Error('Sign-in attempt changed')
              await options.storage.setItem(storageKey, value)
            }
          },
          removeItem() { /* Verifier cleanup is attempt-owned; never erase another attempt. */ }
        }
      })
    }
    await helper.initialize()
    // Public SDK cleanup removes its visibility observer too. The helper has
    // no subscriptions, BroadcastChannel or active refresh timer afterward.
    await helper.stopAutoRefresh()
    return helper
  }
  function withHelper<T>(operation: (sdk: InstanceType<typeof AuthClient>) => Promise<T>): Promise<T> {
    const result = helperTail.then(async () => {
      const sdk = await getHelper()
      return locked(() => operation(sdk))
    })
    helperTail = result.catch(() => {})
    return result.finally(() => { context = null })
  }
  return {
    client, storageKey,
    syncRealtime: (session: Session | null) => client.realtime.setAuth(session?.access_token ?? options.key),
    subscribe(listener: (hint: Session | null, external: boolean) => void) {
      listeners.add(listener)
      const storageChanged = (event: StorageEvent) => {
        if (event.key !== storageKey && event.key !== null) return
        try { listener(event.newValue ? JSON.parse(event.newValue) : null, true) } catch { listener(null, true) }
      }
      if (typeof window !== 'undefined') window.addEventListener('storage', storageChanged)
      let stopped = false
      return () => {
        if (stopped) return
        stopped = true
        listeners.delete(listener)
        if (typeof window !== 'undefined') window.removeEventListener('storage', storageChanged)
      }
    },
    signOut(original: Session) {
      const owner = sessionOwner(original)
      const local = locked(async () => {
        const matches = await owns(owner)
        if (matches) await options.storage.removeItem(storageKey)
        const attempt = await readAttempt()
        if (attempt?.owner === owner) await options.storage.removeItem(attemptKey)
        return matches
      }).then(removed => { publish(); return removed })
      const remote = local.then(async () => {
        // Explicit JWT bypasses the mutable SDK session. 'local' revokes only
        // this lineage; it cannot revoke a fresh login to the same account.
        const { error } = await client.auth.admin.signOut(original.access_token, 'local')
        if (error && ![401, 403, 404].includes(error.status ?? 0)) throw error
      })
      return { local, remote }
    },
    start(request: { provider: 'google' | 'apple' } | { email: string }, original: Session | null, origin: string) {
      return withHelper(async sdk => {
        if (!(await owns(sessionOwner(original)))) throw new Error('Sign-in session changed')
        context = { id: crypto.randomUUID(), owner: sessionOwner(original), origin, expires: Date.now() + 10 * 60_000, verifier: null, used: false }
        await options.storage.setItem(attemptKey, JSON.stringify(context))
        const redirectTo = `${origin}/auth/callback?attempt=${context.id}`
        if ('provider' in request) {
          const result = await sdk.signInWithOAuth({ provider: request.provider, options: { redirectTo, skipBrowserRedirect: true } })
          if (result.error) throw result.error
          return result.data.url
        }
        const result = await sdk.signInWithOtp({ email: request.email, options: { emailRedirectTo: redirectTo } })
        if (result.error) throw result.error
        return null
      })
    },
    complete(url: URL, active: () => boolean = () => true) {
      return withHelper(async sdk => {
        if (!active()) throw new Error('Sign-in callback was disposed')
        const attempt = await readAttempt()
        if (url.pathname !== '/auth/callback' || !attempt || url.origin !== attempt.origin || url.searchParams.get('attempt') !== attempt.id
          || attempt.used || attempt.expires <= Date.now() || !attempt.verifier || !(await owns(attempt.owner))) throw new Error('Sign-in link expired, already used, or belongs to another session')
        if (url.searchParams.has('error') || !url.searchParams.get('code') || url.hash) {
          attempt.used = true
          await options.storage.setItem(attemptKey, JSON.stringify(attempt))
          throw new Error('Sign-in was cancelled or its link is invalid')
        }
        context = { ...attempt, active }
        const { data, error } = await sdk.exchangeCodeForSession(url.searchParams.get('code')!)
        if (error || !data.session) throw error ?? new Error('Sign-in could not be verified')
        return data.session
      }).then(session => { publish(); return session })
    }
  }
}
