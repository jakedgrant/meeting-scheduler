import { get, writable } from 'svelte/store'
import { CLOSED_POLL_MESSAGE, joinFailureMessage, lookUpPollInvitation, type InvitationTarget, type JoinDependencies } from './join-by-code'

type InvitationState = {
	status: 'looking' | 'ready' | 'joining' | 'failed'
	target: InvitationTarget | null
	message: string
}

/** Looking up a code never joins. Only confirm dispatches the join command. */
export function createPollInvitation(deps: JoinDependencies & { open(id: string): void }) {
	const state = writable<InvitationState>({ status: 'looking', target: null, message: '' })
	let run = 0
	let disposed = false
	return {
		subscribe: state.subscribe,
		async prepare(code: string) {
			if (disposed) return
			const current = ++run
			state.set({ status: 'looking', target: null, message: '' })
			const found = await lookUpPollInvitation(code, deps)
			if (current !== run) return
			state.set(found.ok
				? { status: 'ready', target: found.poll, message: '' }
				: { status: 'failed', target: null, message: found.message })
		},
		async confirm(input: { accountId: string | null; name?: string }) {
			const { status, target } = get(state)
			if (disposed || status !== 'ready' || !target) return
			if (!target.requiresJoin || (input.accountId !== null && input.accountId === target.creatorId)) {
				if (input.accountId !== null) {
					state.set({ status: 'joining', target, message: '' })
					deps.open(target.id)
				} else state.update(value => ({ ...value, message: CLOSED_POLL_MESSAGE }))
				return
			}
			const name = input.accountId !== null ? undefined : input.name?.trim()
			if (input.accountId === null && !name) {
				state.update(value => ({ ...value, message: 'Please enter your name' }))
				return
			}
			const current = run
			state.set({ status: 'joining', target, message: '' })
			try {
				await deps.joinPoll(target.id, name)
				if (current === run) deps.open(target.id)
			} catch (error) {
				if (current === run) state.set({ status: 'ready', target, message: joinFailureMessage(error, input.accountId === null) })
			}
		},
		dispose() { disposed = true; run++ }
	}
}
