import { get, writable } from 'svelte/store'

export interface SessionIdentity { accountId: string | null; generation: number }
export const sessionIdentity = writable<SessionIdentity>({ accountId: null, generation: 0 })
let cancellation = new AbortController()

/** Only auth composition advances this scope. Token refresh is not a boundary. */
export function transitionSession(accountId: string | null) {
  if (get(sessionIdentity).accountId === accountId) return
  cancellation.abort()
  cancellation = new AbortController()
  sessionIdentity.update(value => ({ accountId, generation: value.generation + 1 }))
}

export function captureSession() {
  const identity = get(sessionIdentity)
  const signal = cancellation.signal
  return {
    ...identity, signal,
    isCurrent: () => !signal.aborted && get(sessionIdentity).generation === identity.generation
  }
}

/** A mounted owner plus the session generation protects local UI completions. */
export function createSessionWork() {
  let active = true
  let generation = 0
  let controller = new AbortController()
  return {
    capture() {
      const session = captureSession()
      const started = generation
      return () => active && generation === started && session.isCurrent()
    },
    signal: () => AbortSignal.any([controller.signal, captureSession().signal]),
    invalidate() { controller.abort(); controller = new AbortController(); generation++ },
    dispose() { controller.abort(); active = false; generation++ }
  }
}
