import { json } from '@sveltejs/kit'
import type { RequestHandler } from './$types'
import { appleAppSiteAssociation } from '$lib/apple-app-site-association'

// Served by the server rather than from `static/`: the file has no extension, and Apple
// requires `application/json` with a 200 response, which a static host may not send.
export const GET: RequestHandler = () =>
	json(appleAppSiteAssociation, { headers: { 'cache-control': 'public, max-age=3600' } })
