import { initAuth } from './stores/auth'
import { watchCalendarConnection } from './stores/calendar'
import { watchSubscription } from './stores/subscription'

/** Root layout owns all external listeners and can dispose during restoration. */
export function mountClientSession() {
  const stopAuth = initAuth()
  const stopCalendar = watchCalendarConnection()
  const stopSubscription = watchSubscription()
  let disposed = false
  return () => {
    if (disposed) return
    disposed = true
    stopCalendar()
    stopSubscription()
    stopAuth()
  }
}
