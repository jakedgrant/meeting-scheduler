/** Supabase may retain an expired session while offline refresh retries. Hide it
 * at expiry without deleting that account's recovery records or revoking B. */
export function createSessionExpiry(clock = {
  now: () => Date.now(),
  schedule: (callback: () => void, delay: number) => setTimeout(callback, delay),
  cancel: (timer: ReturnType<typeof setTimeout>) => clearTimeout(timer)
}) {
  let revision = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  function clear() { revision++; if (timer) clock.cancel(timer); timer = undefined }
  return {
    isExpired(expiresAt?: number) { return expiresAt !== undefined && (!Number.isFinite(expiresAt) || expiresAt * 1000 <= clock.now()) },
    watch(expiresAt: number | undefined, expire: () => void) {
      clear()
      if (expiresAt === undefined) return
      const started = revision
      function check() {
        if (revision !== started) return
        const delay = expiresAt! * 1000 - clock.now()
        if (!Number.isFinite(delay) || delay <= 0) { timer = undefined; expire(); return }
        timer = clock.schedule(check, Math.min(delay, 2_147_483_647))
      }
      check()
    },
    dispose: clear
  }
}
