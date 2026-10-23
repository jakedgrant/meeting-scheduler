import { get, writable } from 'svelte/store'
import type { Poll, PollTimeOption } from './supabase'

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
		timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
		timeOptions: [{ id: crypto.randomUUID(), date: '', startTime: '09:00', endTime: '10:00' }]
	}
}

export function creationPayload(draft: CreationDraft): CreationPayload {
	if (!draft.title.trim()) throw new Error('Please enter a poll title.')
	if (!draft.timeOptions.length || draft.timeOptions.some(option => !option.date || !option.startTime || !option.endTime)) {
		throw new Error('Choose a date and times for every option, or remove the unfinished option.')
	}
	const time_options = draft.timeOptions.map(option => {
		const start = new Date(`${option.date}T${draft.isAllDay ? '00:00' : option.startTime}`)
		const end = new Date(`${option.date}T${draft.isAllDay ? '23:59' : option.endTime}`)
		if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || end <= start) {
			throw new Error('End time must be after start time for every option.')
		}
		return { start_time: start.toISOString(), end_time: end.toISOString(), is_all_day: draft.isAllDay }
	})
	return {
		title: draft.title.trim(), description: draft.description.trim() || null, location: draft.location.trim() || null,
		timezone: draft.timezone, closes_at: draft.dueDate ? new Date(draft.dueDate).toISOString() : null,
		time_options, use_event_pass: draft.useEventPass
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
	error: string | null
	result: CreationResult | null
}

/** Owns retry identity and draft state across failures, navigation and account changes. */
export function createPollCreation(commands: {
	create(operation: CreationOperation): Promise<CreationResult>
}, storage: DraftStorage | null = creationStorage()) {
	const state = writable<CreationState>({ ownerId: null, draft: emptyCreationDraft(), saving: false, uncertain: false, error: null, result: null })
	let operation: CreationOperation | null = null
	let generation = 0

	function persist() {
		const current = get(state)
		if (!current.ownerId) return
		const saved = JSON.stringify({ draft: current.draft, operation, uncertain: current.saving || current.uncertain })
		memoryDrafts.set(current.ownerId, saved)
		try { storage?.setItem(storageKey(current.ownerId), saved) } catch { /* In-memory retry remains available. */ }
	}

	function setOwner(ownerId: string | null) {
		if (ownerId === get(state).ownerId) return
		generation++
		operation = null
		let draft = emptyCreationDraft()
		let uncertain = false
		try {
			let raw = ownerId && memoryDrafts.get(ownerId)
			if (!raw && ownerId) {
				try { raw = storage?.getItem(storageKey(ownerId)) ?? undefined } catch { /* Continue with a new in-memory draft. */ }
			}
			if (raw) {
				const saved = JSON.parse(raw)
				if (typeof saved.draft?.title === 'string' && Array.isArray(saved.draft?.timeOptions)) {
					// Validate the whole shape before putting a saved draft on screen.
				const candidate = { ...draft, ...saved.draft }
				if (['description', 'location', 'dueDate', 'timezone'].every(key => typeof candidate[key] === 'string')
					&& ['isAllDay', 'useEventPass'].every(key => typeof candidate[key] === 'boolean')
					&& candidate.timeOptions.every((item: Record<string, unknown>) => ['id', 'date', 'startTime', 'endTime'].every(key => typeof item?.[key] === 'string'))) draft = candidate
				}
				if (saved.operation?.operation_id && /^[0-9a-f-]{36}$/i.test(saved.operation.operation_id)
					&& typeof saved.operation.payload?.title === 'string' && Array.isArray(saved.operation.payload?.time_options)) {
					operation = saved.operation
					// Persisting happens before sending; a reload must conservatively
					// treat every pending operation as possibly committed.
					uncertain = saved.uncertain !== false
				}
			}
		} catch { /* An incomplete draft can still be restored without a submission. */ }
		state.set({ ownerId, draft, saving: false, uncertain, error: uncertain ? 'A previous creation is awaiting confirmation. Retry to recover it safely.' : null, result: null })
	}

	function edit(update: Partial<CreationDraft>) {
		const current = get(state)
		if (!current.ownerId || current.saving || current.uncertain) return
		const draft = { ...current.draft, ...update }
		if (operation) {
			try { if (JSON.stringify(creationPayload(draft)) !== JSON.stringify(operation.payload)) operation = null } catch { operation = null }
		}
		state.update(value => ({ ...value, draft, error: null, result: null }))
		persist()
	}

	async function submit(): Promise<CreationResult | null> {
		const current = get(state)
		if (!current.ownerId || current.saving) return null
		if (current.result) return current.result
		try { operation ??= { operation_id: crypto.randomUUID(), payload: creationPayload(current.draft) } }
		catch (error) {
			state.update(value => ({ ...value, error: error instanceof Error ? error.message : 'Check your poll details.' }))
			return null
		}
		const started = generation
		state.update(value => ({ ...value, saving: true, error: null }))
		persist()
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
