import { get, writable } from 'svelte/store'
import type { AvailabilityStatus } from './supabase'

export interface AvailabilityEntry {
	time_option_id: string
	status: AvailabilityStatus
	note: string | null
}

export interface AvailabilitySnapshot {
	participant_id: string
	poll_id: string
	version: number
	comment: string | null
	responses: (AvailabilityEntry & { id: string; updated_at: string })[]
	saved_at?: string
	replayed?: boolean
}

export interface AvailabilitySave {
	pollId: string
	participantId: string
	requestId: string
	expectedVersion: number
	responses: AvailabilityEntry[]
	comment: string | null
}

interface EditorState {
	snapshot: AvailabilitySnapshot | null
	responses: Record<string, AvailabilityEntry>
	comment: string
	dirty: boolean
	saving: boolean
	error: string | null
	conflict: boolean
	saved: boolean
}

function draftFrom(snapshot: AvailabilitySnapshot) {
	return {
		responses: Object.fromEntries(snapshot.responses.map(response => [response.time_option_id, {
			time_option_id: response.time_option_id, status: response.status, note: response.note
		}])),
		comment: snapshot.comment ?? ''
	}
}

function saveError(error: unknown): { message: string; conflict: boolean } {
	const failure = error as { code?: string; message?: string }
	if (failure?.code === 'PT409') return {
		message: 'Your responses changed on another device. Your draft is kept. Reload the saved version before choosing to save your draft again.',
		conflict: true
	}
	if (failure?.code === '42501' && failure.message === 'Guest access denied') return {
		message: 'Your guest access is no longer valid. Your draft is kept; join again to continue.', conflict: false
	}
	if (failure?.code === '42501' && failure.message?.startsWith('Poll is not accepting')) return {
		message: 'This poll is no longer accepting responses. Your draft is kept.', conflict: false
	}
	if (failure?.code === 'PGRST202') return {
		message: 'Response saving is temporarily unavailable. Your draft is kept. Please retry after the service is updated.', conflict: false
	}
	return { message: 'We could not confirm your save. Your draft is kept. Retry to confirm it safely.', conflict: false }
}

// Account/poll/participant ownership survives screen recreation and account switches.
// A saved operation retains its exact request UUID and expected version for replay.
const recovery = new Map<string, string>()
const recoveryKey = (owner: string, snapshot: AvailabilitySnapshot) =>
  `meeting-scheduler:availability:${owner}:${snapshot.poll_id}:${snapshot.participant_id}`

/** Shared by the poll page and its in-process integration tests. */
export function createAvailabilityEditor(commands: {
	save: (save: AvailabilitySave) => Promise<AvailabilitySnapshot>
	load: (pollId: string, participantId: string) => Promise<AvailabilitySnapshot>
}) {
	const state = writable<EditorState>({
		snapshot: null, responses: {}, comment: '', dirty: false,
		saving: false, error: null, conflict: false, saved: false
	})
	let pending: AvailabilitySave | null = null
	let generation = 0
	let owner: string | null = null
	function remember() {
		const value = get(state)
		if (!owner || !value.snapshot || (!value.dirty && !pending)) return
		const key = recoveryKey(owner, value.snapshot)
		const raw = JSON.stringify({ state: { ...value, saving: false }, pending })
		recovery.set(key, raw)
		try { if (typeof sessionStorage !== 'undefined') sessionStorage.setItem(key, raw) } catch { /* In-memory recovery still works. */ }
	}
	function clearRecovery(snapshot: AvailabilitySnapshot) {
		if (!owner) return
		const key = recoveryKey(owner, snapshot)
		recovery.delete(key)
		try { if (typeof sessionStorage !== 'undefined') sessionStorage.removeItem(key) } catch { /* Save is authoritative. */ }
	}
	function setOwner(next: string | null) {
		if (owner === next) return
		remember()
		generation++
		owner = next
		pending = null
		state.set({ snapshot: null, responses: {}, comment: '', dirty: false, saving: false, error: null, conflict: false, saved: false })
	}
	const sameIdentity = (a: AvailabilitySnapshot | null, b: AvailabilitySnapshot) =>
		a?.poll_id === b.poll_id && a.participant_id === b.participant_id

	function initialize(snapshot: AvailabilitySnapshot | null) {
		const current = get(state)
		if (snapshot && sameIdentity(current.snapshot, snapshot) && (current.dirty || current.saving)) return
		if (snapshot === current.snapshot) return
		remember()
		generation++
		pending = null
		if (owner && snapshot) {
			const key = recoveryKey(owner, snapshot)
			try {
				const raw = recovery.get(key) ?? (typeof sessionStorage === 'undefined' ? null : sessionStorage.getItem(key))
				if (raw) {
					const saved = JSON.parse(raw)
					if (sameIdentity(saved.state?.snapshot, snapshot) && typeof saved.state.comment === 'string'
						&& saved.state.responses && typeof saved.state.responses === 'object'
						&& (!saved.pending || (saved.pending.pollId === snapshot.poll_id && saved.pending.participantId === snapshot.participant_id
							&& typeof saved.pending.requestId === 'string' && Number.isSafeInteger(saved.pending.expectedVersion)))) {
						pending = saved.pending
						state.set({ ...saved.state, saving: false, saved: false })
						return
					}
				}
			} catch { /* An unreadable response draft cannot affect server authority. */ }
		}
		state.set({
			snapshot, ...(snapshot ? draftFrom(snapshot) : { responses: {}, comment: '' }),
			dirty: false, saving: false, error: null, conflict: false, saved: false
		})
	}

	function edit(update: Partial<Pick<EditorState, 'responses' | 'comment'>>) {
		const current = get(state)
		if (current.saving) return
		const next = { ...current, ...update }
		const sameResponses = Object.keys(current.responses).length === Object.keys(next.responses).length
			&& Object.entries(current.responses).every(([id, entry]) =>
				next.responses[id]?.status === entry.status && next.responses[id]?.note === entry.note)
		if (sameResponses && current.comment === next.comment) return
		// DOM input/change events and clicks on an already-selected response do
		// not create a different logical save. Preserve its idempotency key.
		if (!sameResponses || current.comment.trim() !== next.comment.trim()) pending = null
		state.update(value => ({ ...value, ...update, dirty: true, error: null, saved: false }))
		remember()
	}

	async function save() {
		const current = get(state)
		if (!current.snapshot || current.saving || current.conflict) return
		if (current.comment.length > 500) {
			state.update(value => ({ ...value, error: 'Comment must be 500 characters or fewer.' }))
			return
		}
		pending ??= {
			pollId: current.snapshot.poll_id, participantId: current.snapshot.participant_id,
			requestId: crypto.randomUUID(), expectedVersion: current.snapshot.version,
			responses: Object.values(current.responses).sort((a, b) => a.time_option_id.localeCompare(b.time_option_id)),
			comment: current.comment.trim() || null
		}
		remember()
		const operation = pending
		const started = generation
		state.update(value => ({ ...value, saving: true, error: null, saved: false }))
		try {
			const snapshot = await commands.save(operation)
			if (started !== generation) return
			clearRecovery(snapshot)
			pending = null
			state.set({ snapshot, ...draftFrom(snapshot), dirty: false, saving: false, error: null, conflict: false, saved: true })
		} catch (error) {
			if (started !== generation) return
			const failure = saveError(error)
			state.update(value => ({ ...value, saving: false, error: failure.message, conflict: failure.conflict }))
			remember()
		}
	}

	// Explicitly preserve the draft, adopt the latest version, then let the user
	// decide to overwrite it. A conflict must never silently become last-write-wins.
	async function reloadAfterConflict() {
		const current = get(state)
		if (!current.snapshot || current.saving) return
		const started = generation
		state.update(value => ({ ...value, saving: true }))
		try {
			const snapshot = await commands.load(current.snapshot.poll_id, current.snapshot.participant_id)
			if (started !== generation) return
			pending = null
			state.update(value => ({
				...value, snapshot, saving: false, conflict: false,
				error: 'The latest saved version is loaded. Your draft is kept. Save your draft to replace the saved responses.'
			}))
			remember()
		} catch (error) {
			if (started !== generation) return
			state.update(value => ({ ...value, saving: false, error: 'Could not reload the saved version. Your draft is kept. Please retry.' }))
		}
	}

	return {
		subscribe: state.subscribe, initialize, setOwner, save, reloadAfterConflict,
		invalidate() { remember(); generation++; state.update(value => ({ ...value, saving: false })) },
		setResponse: (timeOptionId: string, status: AvailabilityStatus) => edit({
			responses: { ...get(state).responses, [timeOptionId]: {
				time_option_id: timeOptionId, status, note: get(state).responses[timeOptionId]?.note ?? null
			} }
		}),
		setComment: (comment: string) => edit({ comment })
	}
}
