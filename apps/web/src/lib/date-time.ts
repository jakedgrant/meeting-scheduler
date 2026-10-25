/**
 * Calendar dates, zoned wall times and instants (F21). See docs/date-time-contract.md.
 *
 * A calendar date is a `YYYY-MM-DD` string with no zone. Date arithmetic never
 * goes through the host's local time, so ranges are the same in every browser
 * zone. Wall times are resolved in an explicit IANA zone.
 */

export type DateTimeErrorCode = 'invalid_date' | 'invalid_time' | 'nonexistent_local_time' | 'end_not_after_start'

export class DateTimeError extends Error {
	constructor(readonly code: DateTimeErrorCode, message: string) {
		super(message)
		this.name = 'DateTimeError'
	}
}

const DAY = 86_400_000
const datePattern = /^(\d{4})-(\d{2})-(\d{2})$/
const timePattern = /^([01]\d|2[0-3]):([0-5]\d)$/

function dateParts(value: string): [number, number, number] {
	const match = datePattern.exec(value)
	if (match) {
		const [y, m, d] = [Number(match[1]), Number(match[2]), Number(match[3])]
		const utc = new Date(Date.UTC(y, m - 1, d))
		if (utc.getUTCFullYear() === y && utc.getUTCMonth() === m - 1 && utc.getUTCDate() === d) return [y, m, d]
	}
	throw new DateTimeError('invalid_date', `Invalid calendar date: ${value}`)
}

function timeParts(value: string): [number, number] {
	const match = timePattern.exec(value)
	if (!match) throw new DateTimeError('invalid_time', `Invalid time: ${value}`)
	return [Number(match[1]), Number(match[2])]
}

function formatDate(utcClock: number): string {
	return new Date(utcClock).toISOString().slice(0, 10)
}

export function isCalendarDate(value: string): boolean {
	try { dateParts(value); return true } catch { return false }
}

export function addDays(date: string, days: number): string {
	const [y, m, d] = dateParts(date)
	return formatDate(Date.UTC(y, m - 1, d + days))
}

/** Every calendar date from start through end, inclusive. Empty when end precedes start. */
export function dateRange(start: string, end: string): string[] {
	const [sy, sm, sd] = dateParts(start)
	const [ey, em, ed] = dateParts(end)
	const first = Date.UTC(sy, sm - 1, sd)
	const last = Date.UTC(ey, em - 1, ed)
	const dates: string[] = []
	for (let day = first; day <= last; day += DAY) dates.push(formatDate(day))
	return dates
}

const formatters = new Map<string, Intl.DateTimeFormat>()
function wallFormatter(zone: string) {
	let formatter = formatters.get(zone)
	if (!formatter) {
		formatter = new Intl.DateTimeFormat('en-US', {
			timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
			hour: '2-digit', minute: '2-digit', second: '2-digit'
		})
		formatters.set(zone, formatter)
	}
	return formatter
}

/** The wall clock in zone at an instant, expressed as milliseconds of a UTC-labelled clock. */
function wallClock(instant: number, zone: string): number {
	const parts = Object.fromEntries(wallFormatter(zone).formatToParts(new Date(instant)).map(p => [p.type, p.value]))
	return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day),
		Number(parts.hour), Number(parts.minute), Number(parts.second))
}

/** Instants whose wall clock in zone equals the naive value: none in a gap, two in a repeated hour. */
function candidates(naive: number, zone: string): { matches: number[]; all: number[] } {
	const offsets = new Set([naive - DAY, naive, naive + DAY].map(probe => wallClock(probe, zone) - probe))
	const all = [...offsets].map(offset => naive - offset).sort((a, b) => a - b)
	return { matches: all.filter(instant => wallClock(instant, zone) === naive), all }
}

/** Resolve a wall time. A skipped time is rejected; a repeated time uses its first occurrence. */
export function zonedInstant(date: string, time: string, zone: string): Date {
	const [y, m, d] = dateParts(date)
	const [hour, minute] = timeParts(time)
	const { matches } = candidates(Date.UTC(y, m - 1, d, hour, minute), zone)
	if (!matches.length) {
		throw new DateTimeError('nonexistent_local_time', `${date} ${time} does not exist in ${zone} because of a clock change.`)
	}
	return new Date(matches[0])
}

/** First instant of a calendar date in zone. If midnight is skipped, the first time after the gap. */
export function startOfDay(date: string, zone: string): Date {
	const [y, m, d] = dateParts(date)
	const { matches, all } = candidates(Date.UTC(y, m - 1, d), zone)
	return new Date(matches.length ? matches[0] : all[all.length - 1])
}

/** The calendar date in zone at an instant. */
export function calendarDate(instant: Date | string, zone: string): string {
	return formatDate(wallClock(new Date(instant).getTime(), zone))
}

export function today(zone: string, now: Date = new Date()): string {
	return calendarDate(now, zone)
}

/** Canonical instant: UTC, whole seconds, explicit `Z`. */
export function formatInstant(instant: Date): string {
	return instant.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

export function timedInterval(date: string, start: string, end: string, zone: string) {
	if (timeParts(end)[0] * 60 + timeParts(end)[1] <= timeParts(start)[0] * 60 + timeParts(start)[1]) {
		throw new DateTimeError('end_not_after_start', 'End time must be after start time.')
	}
	return { start_time: formatInstant(zonedInstant(date, start, zone)), end_time: formatInstant(zonedInstant(date, end, zone)) }
}

/** One calendar date: its start through the next date's start (exclusive). */
export function allDayInterval(date: string, zone: string) {
	return { start_time: formatInstant(startOfDay(date, zone)), end_time: formatInstant(startOfDay(addDays(date, 1), zone)) }
}

/** A response due date accepts responses through the end of that date in zone. */
export function deadlineFor(dueDate: string, zone: string): string {
	return formatInstant(startOfDay(addDays(dueDate, 1), zone))
}

/** The calendar date an all-day option represents, read in the poll's zone (legacy 23:59 ends included). */
export function allDayDate(option: { start_time: string }, zone: string): string {
	return calendarDate(option.start_time, zone)
}

/** Format a calendar date for display without letting the viewer's zone move it. */
export function formatCalendarDate(date: string, options: Intl.DateTimeFormatOptions, locale = 'en-US'): string {
	const [y, m, d] = dateParts(date)
	return new Date(Date.UTC(y, m - 1, d, 12)).toLocaleDateString(locale, { ...options, timeZone: 'UTC' })
}

export function currentZone(): string {
	return Intl.DateTimeFormat().resolvedOptions().timeZone
}
