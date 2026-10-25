import { captureSession } from './session-scope'

/** A page lifetime, including identity/route changes that reuse the component. */
export function createPollPageSession() {
	let generation = 0
	let active = false
	return {
		activate() { active = true; generation++ },
		invalidate() { active = false; generation++ },
		capture() {
			const started = generation
			const scope = captureSession()
			return () => active && started === generation && scope.isCurrent()
		},
		async joinAndReload(join: () => Promise<unknown>, reload: () => Promise<unknown>) {
			const started = generation
			const scope = captureSession()
			const isCurrent = () => active && started === generation && scope.isCurrent()
			try {
				await join()
			} catch (error) {
				if (isCurrent()) throw error
				return
			}
			if (isCurrent()) await reload()
		}
	}
}
