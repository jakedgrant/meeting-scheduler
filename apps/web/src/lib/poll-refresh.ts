export const POLL_REFRESH_INTERVAL_MS = 30_000
const WAKE_DELAY_MS = 250

interface RefreshEnvironment {
  window: Pick<Window, 'addEventListener' | 'removeEventListener' | 'setTimeout' | 'clearTimeout'>
  document: Pick<Document, 'addEventListener' | 'removeEventListener' | 'visibilityState'>
  navigator: Pick<Navigator, 'onLine'>
}

/** One visible, online poll at a time; event bursts share one complete read. */
export function startPollRefresh(refresh: () => Promise<void>, environment?: RefreshEnvironment) {
  if (!environment) {
    if (typeof window === 'undefined') return { stop() {}, refresh() {} }
    environment = { window, document, navigator }
  }
  const { window: target, document: page, navigator: network } = environment
  let timer: number | undefined
  let stopped = false
  let running = false
  let pending = false
  let waking = false
  const visible = () => page.visibilityState === 'visible' && network.onLine

  function schedule(delay: number) {
    target.clearTimeout(timer)
    timer = target.setTimeout(() => { void run() }, delay)
  }
  async function run() {
    timer = undefined
    waking = false
    if (stopped || !visible()) return
    running = true
    try { await refresh() }
    finally {
      running = false
      if (!stopped && visible()) schedule(pending ? WAKE_DELAY_MS : POLL_REFRESH_INTERVAL_MS)
      pending = false
    }
  }
  function wake() {
    if (stopped || !visible()) return
    if (running) { pending = true; return }
    if (waking) return
    waking = true
    schedule(WAKE_DELAY_MS)
  }
  function visibilityChanged() {
    if (visible()) wake()
    else { target.clearTimeout(timer); timer = undefined; waking = false }
  }
  target.addEventListener('focus', wake)
  target.addEventListener('online', wake)
  page.addEventListener('visibilitychange', visibilityChanged)
  if (visible()) schedule(POLL_REFRESH_INTERVAL_MS)
  return {
    refresh: wake,
    stop() {
      stopped = true
      target.clearTimeout(timer)
      target.removeEventListener('focus', wake)
      target.removeEventListener('online', wake)
      page.removeEventListener('visibilitychange', visibilityChanged)
    }
  }
}
