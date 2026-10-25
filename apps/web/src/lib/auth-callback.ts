import type { Session } from '@supabase/supabase-js'
import { createSessionWork, captureSession } from './session-scope'

/** Root composition owns SDK initialization; the callback page only navigates. */
export function createAuthCallback(dependencies: {
  getSession(): Promise<{ data: { session: Session | null }; error: { message: string } | null }>
  navigate(path: string): unknown
}) {
  const work = createSessionWork()
  return {
    async run() {
      const isCurrent = work.capture()
      const scope = captureSession()
      try {
        const { data, error } = await dependencies.getSession()
        if (!isCurrent()) return
        if (error) {
          dependencies.navigate('/auth?error=' + encodeURIComponent(error.message))
        } else if (!data.session?.user || (data.session.expires_at !== undefined && data.session.expires_at * 1000 <= Date.now())) {
          dependencies.navigate('/auth?error=No%20session')
        } else if (data.session.user.id === scope.accountId) {
          dependencies.navigate('/polls')
        }
      } catch {
        if (isCurrent()) dependencies.navigate('/auth?error=Sign-in%20could%20not%20be%20verified')
      }
    },
    dispose: work.dispose
  }
}
