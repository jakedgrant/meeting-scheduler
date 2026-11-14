import type { CreationDraft } from './poll-creation'
import { addDays, formatCalendarDate } from './date-time'

/** The screens of the new-poll flow, in order. `share` follows a successful creation. */
export const flowSteps = ['details', 'timeOptions', 'deadline', 'eventPass', 'share'] as const
export type FlowStep = (typeof flowSteps)[number]

export const stepCount = flowSteps.length
export const lastEditableStep: FlowStep = 'eventPass'

type StepDraft = Pick<CreationDraft, 'title' | 'isAllDay' | 'timeOptions'>

/** "Step 2 of 5". */
export function stepLabel(step: FlowStep): string {
	return `Step ${flowSteps.indexOf(step) + 1} of ${stepCount}`
}

/**
 * Whether the current step has what it needs to move on. Creating the poll,
 * not advancing, leaves the Event Pass step, and the share step is final.
 */
export function canAdvance(step: FlowStep, draft: StepDraft): boolean {
	switch (step) {
		case 'details': return draft.title.trim().length > 0
		// All-day options are the picked days; every day needs a date.
		case 'timeOptions': return draft.timeOptions.length > 0
		case 'deadline': return true
		case 'eventPass':
		case 'share': return false
	}
}

/** The next step, or the same step while this one is incomplete. */
export function advance(step: FlowStep, draft: StepDraft): FlowStep {
	return canAdvance(step, draft) ? flowSteps[flowSteps.indexOf(step) + 1] : step
}

/** The previous step. Step 1 has none, and a created poll can't be edited by going back. */
export function goBack(step: FlowStep): FlowStep {
	if (step === 'share' || step === 'details') return step
	return flowSteps[flowSteps.indexOf(step) - 1]
}

/** Jumps back to an earlier step, as the review list does. It never moves forward. */
export function goTo(step: FlowStep, earlier: FlowStep): FlowStep {
	if (step === 'share') return step
	return flowSteps.indexOf(earlier) < flowSteps.indexOf(step) ? earlier : step
}

/** The step a flow opens on. A retained, unresolved submission is retried from the last step. */
export function initialStep(retainedSubmission: boolean): FlowStep {
	return retainedSubmission ? lastEditableStep : 'details'
}

/** The step after the server created the poll. */
export function created(): FlowStep {
	return 'share'
}

/** The earliest option date in the draft, for context on the deadline step. */
export function firstOptionDate(draft: Pick<CreationDraft, 'timeOptions'>): string | null {
	const dates = draft.timeOptions.map(option => option.date).filter(Boolean).sort()
	return dates[0] ?? null
}

export const quickPicks = [
	{ label: 'Tomorrow', days: 1 },
	{ label: 'In 2 days', days: 2 },
	{ label: 'In 1 week', days: 7 }
] as const

export function quickPickDate(today: string, days: number): string {
	return addDays(today, days)
}

/** A time zone's long name, such as "Central Standard Time"; falls back to its identifier. */
export function zoneName(zone: string, now: Date = new Date()): string {
	try {
		return new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'long' })
			.formatToParts(now).find(part => part.type === 'timeZoneName')?.value ?? zone
	} catch { return zone }
}

const shortDate: Intl.DateTimeFormatOptions = { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }

export function formatDay(date: string): string {
	return formatCalendarDate(date, shortDate)
}

/** The deadline step's explanation of when responses close. */
export function deadlineNote(dueDate: string, first: string | null, zone: string): string {
	const closes = `Responses close at the end of ${formatDay(dueDate)}, ${zoneName(zone)}.`
	return first ? `${closes} Your first option is ${formatDay(first)}.` : closes
}

export interface ReviewRow { step: FlowStep; label: string; value: string }

/** The summary the Event Pass step shows; each row jumps back to its own step. */
export function reviewRows(draft: CreationDraft): ReviewRow[] {
	const count = draft.timeOptions.length
	return [
		{ step: 'details', label: 'Title', value: draft.title.trim() || 'Not set' },
		{ step: 'timeOptions', label: 'Time options', value: `${count} ${count === 1 ? 'option' : 'options'}` },
		{ step: 'deadline', label: 'Deadline', value: draft.dueDate ? formatDay(draft.dueDate) : 'None' },
		{ step: 'details', label: 'Location', value: draft.location.trim() || 'None' }
	]
}

export interface CalendarCell { date: string; day: number }

/** A month as weeks of cells for a day picker: `null` pads the first week. `month` is `YYYY-MM`. */
export function monthCells(month: string): (CalendarCell | null)[] {
	const [year, monthNumber] = month.split('-').map(Number)
	const first = new Date(Date.UTC(year, monthNumber - 1, 1))
	const length = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate()
	const cells: (CalendarCell | null)[] = Array.from({ length: first.getUTCDay() }, () => null)
	for (let day = 1; day <= length; day++) cells.push({ date: `${month}-${String(day).padStart(2, '0')}`, day })
	return cells
}

/** `delta` months from `month` (`YYYY-MM`). */
export function shiftMonth(month: string, delta: number): string {
	const [year, monthNumber] = month.split('-').map(Number)
	const shifted = new Date(Date.UTC(year, monthNumber - 1 + delta, 1))
	return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(2, '0')}`
}

/** The link participants open: the site origin and the poll's id. */
export function pollLink(origin: string, pollId: string): string {
	return `${origin}/polls/${pollId}`
}
