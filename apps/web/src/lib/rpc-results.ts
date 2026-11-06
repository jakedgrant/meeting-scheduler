// Runtime checks for database functions that return json. The generated types
// describe those results only as Json, so the stores check each one here before
// publishing it. A row check names every generated column with its exact type:
// when a migration adds or removes a column or changes its generated type,
// svelte-check fails here until the check matches. Keys the payload adds beyond the type are ignored.
import type { Enums } from './database.types'
import type { AvailabilitySnapshot } from './availability-editor'
import type { CreationResult } from './poll-creation'
import type { AvailabilityResponse, Poll, PollParticipant, PollTimeOption } from './supabase'

/**
 * A type guard whose type is invariant, so a check written for `string` cannot
 * stand in for a `string | null` column, or the reverse.
 */
export interface Check<T> {
	(value: unknown): value is T
	readonly invariant?: (value: T) => T
}

const check = <T>(test: (value: unknown) => boolean) => test as Check<T>

const string = check<string>(value => typeof value === 'string')
const boolean = check<boolean>(value => typeof value === 'boolean')
const integer = check<number>(Number.isSafeInteger)
// The ISO 8601 form Postgres writes for timestamptz in JSON, e.g. 2026-11-04T10:15:30.123456+00:00,
// including years past 9999, which create_poll accepts, and the trailing " BC" Postgres writes for
// years before 1. Fixtures may end in Z.
// A pattern, not Date.parse: engines differ on fractions beyond milliseconds.
const ISO_INSTANT = /^\d{4,}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}(:\d{2}){0,2})( BC)?$/
const instant = check<string>(value => typeof value === 'string' && ISO_INSTANT.test(value))

const nullable = <T>(inner: Check<T>) => check<T | null>(value => value === null || inner(value))
const optional = <T>(inner: Check<T>) => check<T | undefined>(value => value === undefined || inner(value))
const arrayOf = <T>(item: Check<T>) => check<T[]>(value => Array.isArray(value) && value.every(item))

/** Every member of a string union, each listed once, so a new member fails to compile. */
const oneOf = <T extends string>(members: Record<T, true>) =>
	check<T>(value => typeof value === 'string' && Object.hasOwn(members, value))

/** An object with every key of `T`, optional keys included; those take an `optional` check. */
const object = <T>(fields: { [K in keyof Required<T>]: Check<T[K]> }) => {
	const entries = Object.entries(fields) as [string, Check<unknown>][]
	return check<T>(value => typeof value === 'object' && value !== null && !Array.isArray(value)
		&& entries.every(([key, field]) => field((value as Record<string, unknown>)[key])))
}

const pollStatus = oneOf<Enums<'poll_status'>>({ draft: true, active: true, closed: true, archived: true })
const availabilityStatus = oneOf<Enums<'availability_status'>>({ available: true, maybe: true, unavailable: true })

export const isPoll = object<Poll>({
	closes_at: nullable(instant),
	created_at: instant,
	creator_id: string,
	description: nullable(string),
	id: string,
	is_premium: boolean,
	location: nullable(string),
	max_participants: integer,
	selected_end_time: nullable(instant),
	selected_start_time: nullable(instant),
	share_code: string,
	status: pollStatus,
	timezone: string,
	title: string,
	updated_at: instant
})

export const isPollTimeOption = object<PollTimeOption>({
	created_at: instant,
	end_time: instant,
	id: string,
	is_all_day: boolean,
	poll_id: string,
	start_time: instant
})

// Detail reads embed the profile name; join results are the bare row.
export const isPollParticipant = object<PollParticipant>({
	access_token: string,
	anonymous_email: nullable(string),
	anonymous_name: nullable(string),
	comment: nullable(string),
	created_at: instant,
	id: string,
	poll_id: string,
	updated_at: instant,
	user_id: nullable(string),
	profiles: optional(nullable(object<{ display_name: string | null }>({ display_name: nullable(string) })))
})

export const isAvailabilityResponse = object<AvailabilityResponse>({
	created_at: instant,
	id: string,
	note: nullable(string),
	participant_id: string,
	status: availabilityStatus,
	time_option_id: string,
	updated_at: instant
})

/** One poll in list_poll_summaries, with the counts the list shows. */
export interface SummaryRow {
	poll: Poll
	role: 'owner' | 'member'
	participant_count: number
	time_option_count: number
	earliest_start: string | null
	latest_start: string | null
}

export const isSummaryRow = object<SummaryRow>({
	poll: isPoll,
	role: oneOf<SummaryRow['role']>({ owner: true, member: true }),
	participant_count: integer,
	time_option_count: integer,
	earliest_start: nullable(instant),
	latest_start: nullable(instant)
})

/** get_poll_detail. The counts let the caller confirm both lists are whole. */
export interface PollDetail {
	poll: Poll
	time_options: PollTimeOption[]
	participants: PollParticipant[]
	time_option_count: number
	participant_count: number
}

const pollDetailFields = {
	poll: isPoll,
	time_options: arrayOf(isPollTimeOption),
	participants: arrayOf(isPollParticipant),
	time_option_count: integer,
	participant_count: integer
}
export const isPollDetail = object<PollDetail>(pollDetailFields)

/** get_poll_detail_as_guest: get_poll_detail read through a guest capability. */
export interface PollDetailAsGuest extends PollDetail {
	participant_id: string
}

export const isPollDetailAsGuest = object<PollDetailAsGuest>({
	...pollDetailFields,
	participant_id: string
})

export const isCreationResult = object<CreationResult>({
	poll: isPoll,
	time_options: arrayOf(isPollTimeOption),
	redeemed_pass_id: nullable(string),
	entitlement: string,
	replayed: boolean
})

/** join_poll. `created` is false when the caller was already a member. */
export interface JoinResult {
	participant: PollParticipant
	created: boolean
}

const joinFields = { participant: isPollParticipant, created: boolean }
export const isJoinResult = object<JoinResult>(joinFields)

/** join_poll_as_guest. The token is the capability the caller sent. */
export interface GuestJoinResult extends JoinResult {
	guest_token: string
}

export const isGuestJoinResult = object<GuestJoinResult>({ ...joinFields, guest_token: string })

// get_availability returns the snapshot alone; save_availability adds saved_at and replayed.
export const isAvailabilitySnapshot = object<AvailabilitySnapshot>({
	participant_id: string,
	poll_id: string,
	version: integer,
	comment: nullable(string),
	responses: arrayOf(object<AvailabilitySnapshot['responses'][number]>({
		id: string,
		time_option_id: string,
		status: availabilityStatus,
		note: nullable(string),
		updated_at: instant
	})),
	saved_at: optional(instant),
	replayed: optional(boolean)
})
