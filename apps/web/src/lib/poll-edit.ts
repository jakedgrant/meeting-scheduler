import type { Poll } from './supabase'
import { calendarDate, formatInstant, zonedInstant } from './date-time'

export interface PollEditDraft {
	title: string
	description: string
	location: string
	hasDeadline: boolean
	deadline: string
}

function wallMinute(instant: string, zone: string): string {
	const time = new Intl.DateTimeFormat('en-GB', {
		timeZone: zone, hourCycle: 'h23', hour: '2-digit', minute: '2-digit'
	}).format(new Date(instant))
	return `${calendarDate(instant, zone)}T${time}`
}

export function createPollEditDraft(poll: Poll): PollEditDraft {
	return {
		title: poll.title, description: poll.description ?? '', location: poll.location ?? '',
		hasDeadline: poll.closes_at !== null,
		deadline: poll.closes_at ? wallMinute(poll.closes_at, poll.timezone) : ''
	}
}

export function hasPollEdits(poll: Poll, draft: PollEditDraft): boolean {
	const original = createPollEditDraft(poll)
	return draft.title !== original.title || draft.description !== original.description
		|| draft.location !== original.location || draft.hasDeadline !== original.hasDeadline
		|| (draft.hasDeadline && draft.deadline !== original.deadline)
}

/** Builds only edited detail columns, preserving untouched deadline precision. */
export function pollEditChanges(poll: Poll, draft: PollEditDraft, now = Date.now()) {
	const title = draft.title.trim()
	if (!title || [...title].length > 200) throw new Error('Enter a title of 1 to 200 characters.')
	if ([...draft.description].length > 10_000) throw new Error('Description must be 10,000 characters or less.')
	if ([...draft.location].length > 1_000) throw new Error('Location must be 1,000 characters or less.')
	const changes: Partial<Pick<Poll, 'title' | 'description' | 'location' | 'closes_at'>> = {}
	if (draft.title !== poll.title) changes.title = title
	if (draft.description !== (poll.description ?? '')) changes.description = draft.description || null
	if (draft.location !== (poll.location ?? '')) changes.location = draft.location || null
	const original = createPollEditDraft(poll)
	if (draft.hasDeadline !== original.hasDeadline || (draft.hasDeadline && draft.deadline !== original.deadline)) {
		if (!draft.hasDeadline) changes.closes_at = null
		else {
			const [date, time] = draft.deadline.split('T')
			if (!date || !time) throw new Error('Choose a response deadline.')
			const instant = zonedInstant(date, time, poll.timezone)
			if (instant.getTime() <= now) throw new Error('Choose a response deadline in the future.')
			changes.closes_at = formatInstant(instant)
		}
	}
	return changes
}
