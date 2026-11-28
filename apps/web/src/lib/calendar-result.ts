// The ?calendar= marker calendar-oauth-callback appends to the page the browser
// returns to after consent; see supabase/functions/_shared/calendar/service.ts.
// Clients still read the connection status to trust a "connected" marker.

export type CalendarResult = 'connected' | 'cancelled' | 'failed' | 'declined'

export function parseCalendarResult(value: string | null): CalendarResult | null {
  return value === 'connected' || value === 'cancelled' || value === 'failed' || value === 'declined' ? value : null
}

export const CALENDAR_DECLINED_MESSAGE = "Calendar access wasn't granted. Connect again and allow it to check conflicts."
