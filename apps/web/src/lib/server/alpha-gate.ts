// Shared-password gate for the private alpha. Every page request needs a cookie
// that proves the visitor entered the password once; without it the server
// answers with a password form instead of the app. With no password configured
// the gate is off, so local development and the public launch need no code change.

export const ALPHA_COOKIE = 'meetful_alpha'
export const ALPHA_UNLOCK_PATH = '/alpha-unlock'
const COOKIE_MAX_AGE = 60 * 60 * 24 * 90

/**
 * Paths that must load without the password: crawler rules, the browser's icon request,
 * the about and privacy pages, which app stores and Google's OAuth review must reach, and
 * the file Apple's CDN fetches to let poll links open the iOS app.
 * Built assets under /_app are served before this hook runs, so the open pages' styles load too.
 */
const OPEN_PATHS = new Set([
	'/robots.txt',
	'/favicon.ico',
	'/favicon.png',
	'/about',
	'/privacy',
	'/.well-known/apple-app-site-association'
])

/**
 * Returns the response to send instead of the app, or `null` to serve the app.
 * The cookie holds a hash of the password, so changing the password signs everyone out.
 */
export async function alphaGate(request: Request, password: string | undefined): Promise<Response | null> {
	if (!password) return null
	const url = new URL(request.url)
	if (OPEN_PATHS.has(url.pathname)) return null

	const expected = await accessToken(password)
	if (url.pathname === ALPHA_UNLOCK_PATH) return unlock(request, url, password, expected)
	if (sameText(readCookie(request, ALPHA_COOKIE) ?? '', expected)) return null
	return formPage(url.pathname + url.search, false)
}

async function unlock(request: Request, url: URL, password: string, token: string): Promise<Response> {
	if (request.method !== 'POST') return redirect('/')
	const form = await request.formData().catch(() => null)
	const next = safeNext(form?.get('next'))
	const attempt = form?.get('password')
	if (typeof attempt !== 'string' || !sameText(attempt, password)) return formPage(next, true)

	const secure = url.protocol === 'https:' ? '; Secure' : ''
	return new Response(null, {
		status: 303,
		headers: {
			location: next,
			'set-cookie': `${ALPHA_COOKIE}=${token}; Path=/; Max-Age=${COOKIE_MAX_AGE}; HttpOnly; SameSite=Lax${secure}`,
			'cache-control': 'no-store'
		}
	})
}

/** Only same-site paths, so the form can't be used to redirect somewhere else. */
function safeNext(value: FormDataEntryValue | null | undefined): string {
	return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') && !value.includes('\\') ? value : '/'
}

async function accessToken(password: string): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`meetful-alpha:${password}`))
	return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
}

/** Compares without stopping at the first differing character. */
function sameText(a: string, b: string): boolean {
	const left = new TextEncoder().encode(a)
	const right = new TextEncoder().encode(b)
	let difference = left.length ^ right.length
	for (let index = 0; index < Math.max(left.length, right.length); index++) difference |= (left[index] ?? 0) ^ (right[index] ?? 0)
	return difference === 0
}

function readCookie(request: Request, name: string): string | undefined {
	for (const part of (request.headers.get('cookie') ?? '').split(';')) {
		const [key, ...value] = part.trim().split('=')
		if (key === name) return value.join('=')
	}
	return undefined
}

function redirect(location: string): Response {
	return new Response(null, { status: 303, headers: { location, 'cache-control': 'no-store' } })
}

const escapeHTML = (text: string) =>
	text.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!)

function formPage(next: string, wrongPassword: boolean): Response {
	const error = wrongPassword ? '<p class="error" role="alert">That password isn’t right.</p>' : ''
	const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Meetful</title>
<style>
:root { color-scheme: light dark; --bg: #f6f6f8; --card: #fff; --text: #1c1c1e; --muted: #6e6e73; --accent: #4f46e5; --border: #d1d1d6; --error: #c4314b; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --accent: #818cf8; --border: #3a3a3c; --error: #ff6b81; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px; background: var(--bg); color: var(--text); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { width: 100%; max-width: 360px; background: var(--card); border-radius: 16px; padding: 28px 24px; box-shadow: 0 1px 3px rgb(0 0 0 / 0.08); }
h1 { margin: 0 0 4px; font-size: 1.5rem; }
p { margin: 0 0 20px; color: var(--muted); }
label { display: block; font-weight: 600; margin-bottom: 6px; }
input { width: 100%; font: inherit; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--border); background: transparent; color: inherit; }
button { width: 100%; margin-top: 16px; font: inherit; font-weight: 600; padding: 11px; border: 0; border-radius: 10px; background: var(--accent); color: #fff; cursor: pointer; }
.error { color: var(--error); margin: 12px 0 0; }
</style>
</head>
<body>
<main>
<h1>Meetful</h1>
<p>Meetful is in a private alpha. Enter the password you were given.</p>
<form method="post" action="${ALPHA_UNLOCK_PATH}">
<input type="hidden" name="next" value="${escapeHTML(next)}">
<label for="password">Password</label>
<input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
${error}
<button type="submit">Continue</button>
</form>
</main>
</body>
</html>`
	return new Response(html, {
		status: 401,
		headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex' }
	})
}
