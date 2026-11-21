import { env } from '$env/dynamic/private'
import type { Handle } from '@sveltejs/kit'
import { alphaGate } from '$lib/server/alpha-gate'

// ALPHA_PASSWORD turns on the private-alpha password page; unset it to open the site.
export const handle: Handle = async ({ event, resolve }) =>
	(await alphaGate(event.request, env.ALPHA_PASSWORD)) ?? resolve(event)
