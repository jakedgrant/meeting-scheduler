// Entering or following a share code is the decision to join. A share code
// previews a poll (get_poll_by_code) but does not open it: only members can read
// the details, so the caller joins first and opens the poll afterwards.
import type { PollParticipant } from './supabase'

export const SHARE_CODE_LENGTH = 6
export const CLOSED_POLL_MESSAGE = 'This poll is closed and cannot accept new participants.'
export const UNKNOWN_CODE_MESSAGE = 'Poll not found. Please check the code.'

// The code preview's columns are all nullable in the generated types.
export interface PollPreview { id: string | null; title: string | null; status: string | null }

export interface JoinDependencies {
	loadPollByCode(code: string): Promise<PollPreview | null>
	joinPoll(pollId: string, name?: string): Promise<PollParticipant>
}

export type Lookup = { ok: true; poll: { id: string; title: string } } | { ok: false; message: string }

export type JoinOutcome = { ok: true; pollId: string } | { ok: false; message: string }

/** The path a shared link opens. Non-members cannot open `/polls/<id>`, so links carry the code. */
export const joinPath = (shareCode: string) => `/join/${encodeURIComponent(shareCode)}`

/** What the person sees when the server refuses to add them to a poll. */
export function joinFailureMessage(error: unknown, asGuest = false): string {
	const { code, message } = (error ?? {}) as { code?: string; message?: string }
	// For a signed-in caller 42501 means the poll is closed or past its deadline. A guest
	// join raises it for other reasons too, so only the closed-poll message counts there.
	if (code === '42501' && (!asGuest || (message ?? '').startsWith('Poll is not accepting'))) return CLOSED_POLL_MESSAGE
	return error instanceof Error && error.message ? error.message : 'Failed to join poll. Please try again.'
}

/** Resolves a code to an active poll, or says why it cannot be joined. */
export async function lookUpJoinablePoll(code: string, deps: Pick<JoinDependencies, 'loadPollByCode'>): Promise<Lookup> {
	const poll = await deps.loadPollByCode(code)
	if (!poll?.id) return { ok: false, message: UNKNOWN_CODE_MESSAGE }
	if (poll.status !== 'active') return { ok: false, message: CLOSED_POLL_MESSAGE }
	return { ok: true, poll: { id: poll.id, title: poll.title ?? '' } }
}

/** Looks the code up, joins an active poll, and returns the id to open. Joins nothing otherwise. */
export async function joinByCode(code: string, deps: JoinDependencies, name?: string): Promise<JoinOutcome> {
	const found = await lookUpJoinablePoll(code, deps)
	if (!found.ok) return found
	try {
		await deps.joinPoll(found.poll.id, name)
	} catch (error) {
		return { ok: false, message: joinFailureMessage(error, name !== undefined) }
	}
	return { ok: true, pollId: found.poll.id }
}
