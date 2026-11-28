import { allDayDate, calendarDate, formatCalendarDate } from './date-time'
import type { AvailabilityStatus } from './supabase'

const LOCALE = 'en-US'

/** "Tue, Dec 1", with the year only when the option is not in the current year. */
export function optionDateLabel(
	option: { start_time: string; is_all_day: boolean },
	pollZone: string,
	now: Date,
	viewerZone: string
): string {
	const date = option.is_all_day ? allDayDate(option, pollZone) : calendarDate(option.start_time, viewerZone)
	const otherYear = date.slice(0, 4) !== calendarDate(now, viewerZone).slice(0, 4)
	return formatCalendarDate(date, { weekday: 'short', month: 'short', day: 'numeric', ...(otherYear ? { year: 'numeric' } : {}) }, LOCALE)
}

function clock(instant: Date, zone: string) {
	const parts = new Intl.DateTimeFormat(LOCALE, { timeZone: zone, hour: 'numeric', minute: '2-digit', hour12: true })
		.formatToParts(instant)
	const part = (type: Intl.DateTimeFormatPartTypes) => parts.find(entry => entry.type === type)?.value ?? ''
	return { hour: part('hour'), minute: part('minute'), period: part('dayPeriod') }
}

/**
 * "6–8 PM": each end drops ":00", and both ends share AM/PM when they match. A range that ends on
 * a later day names it: "11 PM – 1 AM (Dec 2)". An end at the following midnight belongs to the
 * start's day.
 */
export function timeRangeLabel(start: string | Date, end: string | Date, zone: string): string {
	const from = new Date(start)
	const to = new Date(end)
	const time = (instant: Date, withPeriod: boolean) => {
		const { hour, minute, period } = clock(instant, zone)
		return `${hour}${minute === '00' ? '' : `:${minute}`}${withPeriod ? ` ${period}` : ''}`
	}
	const startDay = calendarDate(from, zone)
	const endDay = calendarDate(to, zone)
	if (startDay !== endDay) {
		const range = `${time(from, true)} – ${time(to, true)}`
		if (calendarDate(new Date(to.getTime() - 1000), zone) === startDay) return range
		return `${range} (${formatCalendarDate(endDay, { month: 'short', day: 'numeric' }, LOCALE)})`
	}
	const sharesPeriod = clock(from, zone).period === clock(to, zone).period
	return `${time(from, !sharesPeriod)}–${time(to, true)}`
}

/** The answer counts as tally segments: yes, maybe, then no, without empty ones. */
export function tallySegments(stats: Record<AvailabilityStatus, number>): { status: AvailabilityStatus; count: number }[] {
	return (['available', 'maybe', 'unavailable'] as const)
		.map(status => ({ status, count: stats[status] }))
		.filter(segment => segment.count > 0)
}

export const answerLabels: Record<AvailabilityStatus, string> = { available: 'Yes', maybe: 'Maybe', unavailable: 'No' }
