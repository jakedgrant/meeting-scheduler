// Guest capability storage and error classification for signed-out poll
// participation. The capability is a bearer secret: keep it in this module's
// storage only, and never log it, render it, or send it anywhere except the
// guest RPCs.

export interface GuestCapability {
	participantId: string
	token: string
}

/** Minimal Storage subset, so tests can supply an in-memory implementation. */
export interface CapabilityStorage {
	getItem(key: string): string | null
	setItem(key: string, value: string): void
	removeItem(key: string): void
}

/** The fields of a PostgREST/Supabase error this module inspects. */
export interface RpcError {
	code?: string | null
	message?: string | null
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TOKEN = /^[0-9a-f]{64}$/

export const GUEST_ACCESS_LOST_MESSAGE =
	'Your guest access to this poll is no longer valid on this device. Join again to take part.'

export function guestStorageKey(pollId: string): string {
	return `meeting-scheduler:guest:${pollId}`
}

export function isValidCapability(value: unknown): value is GuestCapability {
	if (!value || typeof value !== 'object') return false
	const candidate = value as Record<string, unknown>
	return (
		typeof candidate.participantId === 'string' &&
		UUID.test(candidate.participantId) &&
		typeof candidate.token === 'string' &&
		TOKEN.test(candidate.token)
	)
}

/** Returns the stored capability for a poll; malformed entries are removed. */
export function readGuestCapability(
	storage: CapabilityStorage | null,
	pollId: string
): GuestCapability | null {
	if (!storage) return null
	const key = guestStorageKey(pollId)
	try {
		const raw = storage.getItem(key)
		if (!raw) return null
		const parsed: unknown = JSON.parse(raw)
		if (isValidCapability(parsed)) {
			return { participantId: parsed.participantId, token: parsed.token }
		}
	} catch {
		// Unparseable or inaccessible storage: treat as absent.
	}
	clearGuestCapability(storage, pollId)
	return null
}

/** Stores the capability; returns false if storage is unavailable or full. */
export function saveGuestCapability(
	storage: CapabilityStorage | null,
	pollId: string,
	capability: GuestCapability
): boolean {
	if (!storage || !isValidCapability(capability)) return false
	try {
		storage.setItem(
			guestStorageKey(pollId),
			JSON.stringify({ participantId: capability.participantId, token: capability.token })
		)
		return true
	} catch {
		return false
	}
}

export function clearGuestCapability(storage: CapabilityStorage | null, pollId: string): void {
	try {
		storage?.removeItem(guestStorageKey(pollId))
	} catch {
		// Nothing else to do; the capability simply stays unusable.
	}
}

/** PostgREST reports an RPC absent from its schema cache (migration not yet deployed). */
export function isMissingRpc(error: RpcError | null | undefined): boolean {
	return error?.code === 'PGRST202'
}

/** The capability is malformed, unknown, rotated, or its row was claimed or deleted. */
export function isGuestAccessDenied(error: RpcError | null | undefined): boolean {
	return error?.code === '42501' && error.message === 'Guest access denied'
}

/** The poll is closed, expired, or no longer accepting guest changes. */
export function isPollClosedError(error: RpcError | null | undefined): boolean {
	return error?.code === '42501' && (error.message ?? '').startsWith('Poll is not accepting')
}

export function browserStorage(): CapabilityStorage | null {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage
	} catch {
		return null
	}
}
