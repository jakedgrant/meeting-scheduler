import { get, writable } from 'svelte/store'
import type { Poll, PollTimeOption } from './supabase'
import { allDayInterval, currentZone, DateTimeError, deadlineFor, isCalendarDate, timedInterval } from './date-time'

export interface CreationPayload {
	title: string
	description: string | null
	location: string | null
	timezone: string
	closes_at: string | null
	time_options: { start_time: string; end_time: string; is_all_day: boolean }[]
	use_event_pass: boolean
}

export interface CreationResult {
	poll: Poll
	time_options: PollTimeOption[]
	redeemed_pass_id: string | null
	entitlement: 'free' | 'pro_access' | 'team_access' | 'event_pass'
	replayed: boolean
}

export interface CreationOperation {
	operation_id: string
	payload: CreationPayload
}

export interface CreationDraft {
	title: string
	description: string
	location: string
	dueDate: string
	isAllDay: boolean
	useEventPass: boolean
	timezone: string
	timeOptions: { id: string; date: string; startTime: string; endTime: string }[]
}

interface DraftStorage {
	getItem(key: string): string | null
	setItem(key: string, value: string): void
	removeItem(key: string): void
}

const storageKey = (owner: string) => `meeting-scheduler:create-poll:${owner}`
// Browsers may deny storage. Keep failed drafts across same-tab navigation even
// then; a full reload still requires functioning browser storage.
const memoryDrafts = new Map<string, string>()

export function creationStorage(): DraftStorage | null {
	try { return typeof sessionStorage === 'undefined' ? null : sessionStorage } catch { return null }
}

export function emptyCreationDraft(): CreationDraft {
	return {
		title: '', description: '', location: '', dueDate: '', isAllDay: false, useEventPass: false,
		timezone: currentZone(),
		timeOptions: [{ id: crypto.randomUUID(), date: '', startTime: '09:00', endTime: '10:00' }]
	}
}

export function creationPayload(draft: CreationDraft, zone: string = currentZone()): CreationPayload {
	if (!draft.title.trim()) throw new Error('Please enter a poll title.')
	if (!draft.timeOptions.length || draft.timeOptions.some(option => !option.date || !option.startTime || !option.endTime)) {
		throw new Error('Choose a date and times for every option, or remove the unfinished option.')
	}
	// New payloads interpret picker values in this browser's current zone and
	// record that zone. Pending payloads are reused verbatim, including across a zone change.
	const time_options = draft.timeOptions.map(option => {
		try {
			return { ...(draft.isAllDay ? allDayInterval(option.date, zone) : timedInterval(option.date, option.startTime, option.endTime, zone)), is_all_day: draft.isAllDay }
		} catch (error) {
			if (error instanceof DateTimeError && error.code === 'nonexistent_local_time') {
				throw new Error(`${option.date} ${option.startTime}–${option.endTime} includes a time skipped by a clock change in ${zone}. Choose another time.`)
			}
			throw new Error('End time must be after start time for every option.')
		}
	})
	let closes_at: string | null = null
	if (draft.dueDate) {
		if (!isCalendarDate(draft.dueDate)) throw new Error('Choose a valid response due date.')
		closes_at = deadlineFor(draft.dueDate, zone)
	}
	return {
		title: draft.title.trim(), description: draft.description.trim() || null, location: draft.location.trim() || null,
		timezone: zone, closes_at, time_options, use_event_pass: draft.useEventPass
	}
}

function failure(error: unknown): { message: string; uncertain: boolean } {
	const code = (error as { code?: string })?.code
	const message = {
		'42501': 'Sign in again before creating your poll. Your draft is kept.',
		'22023': 'Some poll details were rejected. Check the title, deadline and time options. Your draft is kept.',
		P0001: 'Your active poll limit has been reached. Close an existing poll, or use an eligible event pass. Your draft is kept.',
		P0002: 'No verified event pass is available. Refresh your purchases or turn off Use an event pass. Your draft is kept.',
		'22000': 'This creation was already submitted with different details. Restore its original draft to retry safely.',
		'54000': 'A share code could not be assigned. Retry creating your poll. Your draft is kept.',
		PGRST202: 'Poll creation is temporarily unavailable. Your draft is kept. Retry after the service is updated.'
	}[code ?? '']
	// A transport failure may follow a committed transaction. Keep the exact
	// operation and freeze edits until a retry resolves whether it committed.
	return message ? { message, uncertain: code === '22000' } : {
		message: 'We could not confirm creation. Your draft is kept. Retry to recover the original poll safely.', uncertain: true
	}
}

interface CreationState {
	ownerId: string | null
	draft: CreationDraft
	saving: boolean
	uncertain: boolean
	recoveryRequired: boolean
	error: string | null
	result: CreationResult | null
}

/** Owns retry identity and draft state across failures, navigation and account changes. */
export function createPollCreation(commands: {
	create(operation: CreationOperation): Promise<CreationResult>
}, storage: DraftStorage | null = creationStorage()) {
	const state = writable<CreationState>({ ownerId: null, draft: emptyCreationDraft(), saving: false, uncertain: false, recoveryRequired: false, error: null, result: null })
	let operation: CreationOperation | null = null
	let generation = 0

	function persist() {
		const current = get(state)
		if (!current.ownerId) return false
		const saved = JSON.stringify({ draft: current.draft, operation, uncertain: current.saving || current.uncertain })
		memoryDrafts.set(current.ownerId, saved)
		try {
			storage?.setItem(storageKey(current.ownerId), saved)
			return storage?.getItem(storageKey(current.ownerId)) === saved
		} catch { return false }
	}

	function setOwner(ownerId: string | null) {
		if (ownerId === get(state).ownerId) return
		generation++
		operation = null
		let draft = emptyCreationDraft()
		let uncertain = false
		let recoveryRequired = false
		try {
			let raw = ownerId && memoryDrafts.get(ownerId)
			if (!raw && ownerId) {
				try { raw = storage?.getItem(storageKey(ownerId)) ?? undefined } catch { /* Continue with a new in-memory draft. */ }
			}
			if (raw) {
				const saved = JSON.parse(raw)
				let validDraft = false
				if (typeof saved.draft?.title === 'string' && Array.isArray(saved.draft?.timeOptions)) {
					// Validate the whole shape before putting a saved draft on screen.
				const candidate = { ...draft, ...saved.draft }
				if (['description', 'location', 'dueDate', 'timezone'].every(key => typeof candidate[key] === 'string')
					&& ['isAllDay', 'useEventPass'].every(key => typeof candidate[key] === 'boolean')
					&& candidate.timeOptions.every((item: Record<string, unknown>) => ['id', 'date', 'startTime', 'endTime'].every(key => typeof item?.[key] === 'string'))) { draft = candidate; validDraft = true }
				}
				recoveryRequired = !validDraft
				if (saved.operation?.operation_id && /^[0-9a-f-]{36}$/i.test(saved.operation.operation_id)
					&& typeof saved.operation.payload?.title === 'string' && typeof saved.operation.payload?.timezone === 'string'
					&& typeof saved.operation.payload?.use_event_pass === 'boolean'
					&& ['description', 'location', 'closes_at'].every(key => saved.operation.payload[key] === null || typeof saved.operation.payload[key] === 'string')
					&& Array.isArray(saved.operation.payload?.time_options) && saved.operation.payload.time_options.length > 0
					&& saved.operation.payload.time_options.every((option: Record<string, unknown>) => typeof option?.start_time === 'string' && typeof option?.end_time === 'string' && typeof option?.is_all_day === 'boolean')) {
					operation = saved.operation
					// Persisting happens before sending; a reload must conservatively
					// treat every pending operation as possibly committed.
					uncertain = saved.uncertain !== false
				} else if (saved.operation !== null) recoveryRequired = true
			}
		} catch { recoveryRequired = true }
		state.set({ ownerId, draft, saving: false, uncertain, recoveryRequired,
			error: recoveryRequired ? 'The saved creation cannot be read safely. Check My Polls for its result and contact support to recover this draft before creating again.'
				: uncertain ? 'A previous creation is awaiting confirmation. Retry to recover it safely.' : null, result: null })
	}

	function edit(update: Partial<CreationDraft>) {
		const current = get(state)
		if (!current.ownerId || current.saving || current.uncertain || current.recoveryRequired) return
		const draft = { ...current.draft, ...update }
		if (operation) {
			try { if (JSON.stringify(creationPayload(draft)) !== JSON.stringify(operation.payload)) operation = null } catch { operation = null }
		}
		state.update(value => ({ ...value, draft, error: null, result: null }))
		persist()
	}

	async function submit(): Promise<CreationResult | null> {
		const current = get(state)
		if (!current.ownerId || current.saving || current.recoveryRequired) return null
		if (current.result) return current.result
		try { operation ??= { operation_id: crypto.randomUUID(), payload: creationPayload(current.draft) } }
		catch (error) {
			state.update(value => ({ ...value, error: error instanceof Error ? error.message : 'Check your poll details.' }))
			return null
		}
		const started = generation
		state.update(value => ({ ...value, saving: true, error: null }))
		if (!persist()) {
			state.update(value => ({ ...value, saving: false, error: 'Enable browser storage before creating this poll. Your draft is kept, and no creation request was sent. Then retry.' }))
			persist()
			return null
		}
		try {
			const result = await commands.create(operation)
			if (started !== generation) return null
			operation = null
			memoryDrafts.delete(current.ownerId)
			try { storage?.removeItem(storageKey(current.ownerId)) } catch { /* Creation is authoritative. */ }
			state.update(value => ({ ...value, saving: false, uncertain: false, result }))
			return result
		} catch (error) {
			if (started !== generation) return null
			const failed = failure(error)
			state.update(value => ({ ...value, saving: false, error: failed.message, uncertain: failed.uncertain }))
			persist()
			return null
		}
	}

	function invalidate() { generation++ }
	return { subscribe: state.subscribe, setOwner, edit, submit, invalidate }
}
