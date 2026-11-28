<script lang="ts">
	import { onDestroy, onMount, tick } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
	import { user, ensureProfile, updateProfile, completeOnboarding } from '$lib/stores/auth';
	import { calendarEnabled, calendarLoading, initCalendar, enableCalendarIntegration } from '$lib/stores/calendar';
	import { captureSession, createSessionWork } from '$lib/session-scope';
	import {
		CALENDAR_MESSAGES, DISPLAY_NAME_MAX, calendarState, normalizeName, parseStep, previewOf, rememberNext,
		resolveWelcomeEntry, retry, type OnboardingStep
	} from '$lib/onboarding';
	import { HOME, welcomeHref } from '$lib/next-destination';
	import type { CalendarResult } from '$lib/calendar-result';

	const work = createSessionWork();
	onDestroy(() => work.dispose());

	let ready = $state(false);
	let next = $state(HOME);
	let name = $state('');
	let savedName: string | null = null;
	let avatarUrl = $state<string | null>(null);
	let avatarFailed = $state(false);
	let nameSaveFailed = $state(false);
	let pendingSave: Promise<void> = Promise.resolve();
	let calendarResult = $state<CalendarResult | null>(null);
	let startFailed = $state(false);
	// Covers the gaps the calendar store doesn't: verifying a return, and waiting on the name save before redirecting.
	let pending = $state(false);
	let finishing = $state(false);
	let heading = $state<HTMLHeadingElement>();
	let announcedPreview = $state('');

	const step = $derived(parseStep($page.url.searchParams.get('step')));
	const preview = $derived(previewOf(name));
	const calendar = $derived(calendarState({
		connected: $calendarEnabled,
		connecting: $calendarLoading || pending,
		result: calendarResult,
		startFailed
	}));

	onMount(() => {
		const isCurrent = work.capture();
		void (async () => {
			if (!$user) { await goto('/auth', { replaceState: true }); return; }
			const entry = await resolveWelcomeEntry({
				url: $page.url, storage: sessionStorage, loadProfile: ensureProfile, metadata: $user.user_metadata
			});
			if (!isCurrent()) return;
			if (entry.kind === 'leave') { await goto(entry.to, { replaceState: true }); return; }
			({ next, name, savedName, avatarUrl } = entry);
			if (entry.result) {
				calendarResult = entry.result;
				// Drop the marker so a refresh doesn't repeat the message.
				await goto(welcomeHref('calendar', next), { replaceState: true, keepFocus: true, noScroll: true });
				if (entry.result === 'connected') {
					pending = true;
					await initCalendar();
					if (isCurrent()) pending = false;
				}
			}
			if (isCurrent()) ready = true;
		})();
	});

	// A signed-out tab has nothing to onboard.
	$effect(() => {
		if (ready && !$user) void goto('/auth', { replaceState: true });
	});

	// Move focus to the new step's heading, but let the name field keep its autofocus on first load.
	let shownStep: OnboardingStep | null = null;
	$effect(() => {
		if (!ready) return;
		const current = step;
		const previous = shownStep;
		shownStep = current;
		if (previous === null && current === 'name') return;
		void tick().then(() => heading?.focus());
	});

	// Set directly and restored on leave: a <svelte:head> title would stay on the next page,
	// including when a finished account only passes through here after sign-in.
	$effect(() => {
		if (!ready) return;
		const previous = document.title;
		document.title = step === 'name' ? 'Your name · Meetful' : 'Calendar · Meetful';
		return () => { document.title = previous; };
	});

	// Announce the preview after typing pauses, not on every keystroke.
	$effect(() => {
		const text = `Preview: ${preview.name}, answered yes`;
		const timer = setTimeout(() => { announcedPreview = text; }, 600);
		return () => clearTimeout(timer);
	});

	function goToStep(target: OnboardingStep) {
		void goto(welcomeHref(target, next), { keepFocus: true, noScroll: true });
	}

	function continueFromName(event: SubmitEvent) {
		event.preventDefault();
		const value = normalizeName(name);
		if (value !== savedName) saveName(value);
		goToStep('calendar');
	}

	// Optimistic: the step changes now and the save retries in the background.
	// A newer save supersedes an older one, so a superseded save starts no further retries.
	let saveGeneration = 0;
	function saveName(value: string | null) {
		const isCurrent = work.capture();
		const scope = captureSession();
		const generation = ++saveGeneration;
		const superseded = () => generation !== saveGeneration || !scope.isCurrent();
		nameSaveFailed = false;
		pendingSave = retry(() => updateProfile({ display_name: value }), { shouldStop: superseded })
			.then(
				() => { if (!superseded()) savedName = value; },
				() => { if (!superseded() && isCurrent()) nameSaveFailed = true; }
			);
	}

	async function connectCalendar() {
		if (pending) return;
		const isCurrent = work.capture();
		pending = true;
		startFailed = false;
		calendarResult = null;
		// The redirect leaves the page, so the name has to land first.
		await pendingSave;
		if (!isCurrent()) return;
		rememberNext(sessionStorage, next);
		try {
			await enableCalendarIntegration('welcome');
			// On success the page is leaving for Google, or the store already reports Connected.
		} catch {
			if (isCurrent()) { startFailed = true; pending = false; }
		}
	}

	// Finishing never blocks on the server: after a short wait it leaves anyway, and an
	// unrecorded completion only shows this flow again at the next sign-in. Completion runs
	// after any name save, because both write the profile and the later write would fail
	// the earlier one; if the wait runs out, the chain carries on in the background.
	const FINISH_WAIT_MS = 4000;
	async function finish() {
		if (finishing) return;
		finishing = true;
		const isCurrent = work.capture();
		const scope = captureSession();
		await Promise.race([
			pendingSave.then(() => retry(completeOnboarding, { delays: [1000], shouldStop: () => !scope.isCurrent() })).catch(() => {}),
			new Promise(resolve => setTimeout(resolve, FINISH_WAIT_MS))
		]);
		if (isCurrent()) await goto(next, { replaceState: true });
	}

	// Coming Back from Google's screen can restore this page from the back-forward cache
	// with the Connect button still waiting on a redirect that already happened.
	function restoreFromCache(event: PageTransitionEvent) {
		if (event.persisted) pending = false;
	}

	function finishOnEnter(event: KeyboardEvent) {
		// A held Enter from the name step would otherwise repeat into this step and finish it unseen.
		if (event.repeat || event.isComposing) return;
		if (event.key !== 'Enter' || step !== 'calendar' || !ready || event.defaultPrevented) return;
		const target = event.target as HTMLElement | null;
		if (target?.closest('a, button, input, textarea, select')) return;
		event.preventDefault();
		void finish();
	}
</script>

{#snippet googleMark(className: string)}
	<!-- Google's full-color "G", as its sign-in branding guidelines require. -->
	<svg class={className} viewBox="0 0 48 48" aria-hidden="true">
		<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
		<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
		<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
		<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
	</svg>
{/snippet}

{#snippet checkMark()}
	<svg class="check" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
{/snippet}

<svelte:window onkeydown={finishOnEnter} onpageshow={restoreFromCache} />

<div class="welcome">
	<header class="brand">
		<svg class="brand-mark" viewBox="0 0 40 40" aria-hidden="true">
			<rect x="2" y="4" width="32" height="30" rx="8" fill="var(--brand)" />
			<circle cx="30" cy="30" r="8.5" fill="var(--brand)" stroke="var(--card)" stroke-width="3" />
			<path d="M26.5 30.2l2.4 2.4 4.6-4.8" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
		</svg>
		<span class="brand-name">Meetful</span>
	</header>

	{#if !ready}
		<p class="loading" role="status">Loading…</p>
	{:else}
		<main class="card">
			<div class="card-header">
				<span class="step-count">Step {step === 'name' ? 1 : 2} of 2</span>
				{#if step === 'name'}
					<button type="button" class="skip" onclick={() => goToStep('calendar')}>Skip for now</button>
				{:else}
					<button type="button" class="skip" onclick={finish} disabled={finishing}>Skip for now</button>
				{/if}
			</div>
			<div
				class="progress"
				role="progressbar"
				aria-label="Onboarding progress"
				aria-valuemin="0"
				aria-valuemax="2"
				aria-valuenow={step === 'name' ? 1 : 2}
				aria-valuetext="Step {step === 'name' ? 1 : 2} of 2"
			>
				<span class="bar done"></span>
				<span class="bar" class:done={step === 'calendar'}></span>
			</div>

			{#key step}
				{#if step === 'name'}
					<form class="step" onsubmit={continueFromName}>
						<div class="body">
							<h1 bind:this={heading} tabindex="-1">What should people call you?</h1>
							<p class="subtitle">Your name shows next to your answers in polls. Leave it blank to appear as Anonymous.</p>

							<label class="field-label" for="display-name">Display name</label>
							<!-- svelte-ignore a11y_autofocus -->
							<input
								id="display-name"
								class="text-input"
								type="text"
								bind:value={name}
								autocomplete="name"
								maxlength={DISPLAY_NAME_MAX}
								placeholder="Your name"
								autofocus
							/>

							<p class="caption">How others will see you</p>
							<div class="preview">
								{#if avatarUrl && !avatarFailed && preview.initial}
									<img class="avatar" src={avatarUrl} alt="" onerror={() => { avatarFailed = true; }} />
								{:else}
									<span class="avatar" class:anonymous={!preview.initial} aria-hidden="true">{preview.initial ?? '?'}</span>
								{/if}
								<span class="preview-name">{preview.name}</span>
								<span class="yes-chip">
									{@render checkMark()}
									<span class="visually-hidden">Yes</span>
								</span>
							</div>
							<p class="visually-hidden" aria-live="polite">{announcedPreview}</p>
						</div>

						<div class="footer">
							<button type="submit" class="primary">Continue</button>
						</div>
					</form>
				{:else}
					<form class="step" onsubmit={(event) => { event.preventDefault(); void finish(); }}>
						<div class="body">
							<h1 bind:this={heading} tabindex="-1">Spot conflicts before you answer</h1>
							<p class="subtitle">Connect Google Calendar and we'll flag poll times when you're already busy.</p>

							{#if nameSaveFailed}
								<p class="inline-error" role="alert">Your name couldn't be saved. You can set it in Settings.</p>
							{/if}

							<section class="provider" aria-labelledby="google-calendar-title">
								{@render googleMark('google-mark large')}
								<div class="provider-text">
									<h2 id="google-calendar-title">Google Calendar</h2>
									<p class="provider-description">Read-only. We only see busy or free, never event details.</p>

									{#if calendar === 'connected'}
										<span class="connected-pill">
											{@render checkMark()}
											Connected
										</span>
									{:else}
										<button type="button" class="google-button" onclick={connectCalendar} disabled={calendar === 'connecting'}>
											{#if calendar === 'connecting'}
												<span class="spinner" aria-hidden="true"></span>
												<span>Connecting…</span>
											{:else}
												{@render googleMark('google-mark')}
												<span>Connect with Google</span>
											{/if}
										</button>
										{#if calendar === 'failed' || calendar === 'declined'}
											<p class="calendar-error">{CALENDAR_MESSAGES[calendar]}</p>
										{/if}
									{/if}
									<p class="visually-hidden" aria-live="polite">{CALENDAR_MESSAGES[calendar]}</p>
								</div>
							</section>

							<p class="note">Using the iPhone app? It can also check Apple Calendar on your device.</p>
							<p class="note lock-note">
								<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10.5" width="14" height="10" rx="2.5" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" fill="none" /></svg>
								You can change this anytime in Settings.
							</p>
						</div>

						<div class="footer">
							<button type="button" class="secondary" onclick={() => goToStep('name')}>Back</button>
							<button type="submit" class="primary" disabled={finishing}>Finish</button>
						</div>
					</form>
				{/if}
			{/key}
		</main>
	{/if}
</div>

<style>
	.welcome {
		--brand: #f7931e;
		--brand-strong: #c2650a;
		--brand-tint: #fde9d2;
		--page: #f5f5f7;
		--card: #ffffff;
		--text: #111111;
		--text-secondary: #6b6b70;
		--separator: #e3e3e8;
		--track: #e6e6eb;
		--surface: #f3f3f6;
		--success: #1f8a3b;
		--success-tint: #e3f6e7;
		--danger: #c62828;
		--primary-fill: #111111;
		--primary-text: #ffffff;
		--serif: ui-serif, 'New York', 'Iowan Old Style', Charter, 'Source Serif Pro', Georgia, serif;

		min-height: 100vh;
		min-height: 100dvh;
		box-sizing: border-box;
		padding: 40px 16px 48px;
		background: var(--page);
		color: var(--text);
		display: flex;
		flex-direction: column;
		align-items: center;
	}

	@media (prefers-color-scheme: dark) {
		.welcome {
			--brand-strong: #ffb366;
			--brand-tint: #4a2f12;
			--page: #0b0b0c;
			--card: #1a1a1c;
			--text: #f5f5f7;
			--text-secondary: #a1a1a8;
			--separator: #2f2f33;
			--track: #3a3a3f;
			--surface: #242427;
			--success: #5fd37d;
			--success-tint: #17351f;
			--danger: #ff6b6b;
			--primary-fill: #f5f5f7;
			--primary-text: #111111;
		}
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 32px;
	}

	.brand-mark { width: 40px; height: 40px; }

	.brand-name {
		font-family: var(--serif);
		font-size: 30px;
		font-weight: 700;
		letter-spacing: -0.01em;
	}

	.loading { color: var(--text-secondary); }

	.card {
		width: 100%;
		max-width: 520px;
		box-sizing: border-box;
		padding: 40px;
		background: var(--card);
		border: 1px solid var(--separator);
		border-radius: 20px;
		display: flex;
		flex-direction: column;
		min-height: 620px;
	}

	.card-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 12px;
	}

	.step-count { font-size: 13px; color: var(--text-secondary); }

	.skip {
		background: none;
		border: none;
		padding: 2px 0;
		font: inherit;
		font-size: 14px;
		color: var(--text-secondary);
		cursor: pointer;
	}

	.skip:hover:not(:disabled) { text-decoration: underline; }

	.progress { display: flex; gap: 8px; margin-bottom: 36px; }

	.bar {
		flex: 1;
		height: 4px;
		border-radius: 2px;
		background: var(--track);
	}

	.bar.done { background: var(--brand); }

	.step {
		flex: 1;
		display: flex;
		flex-direction: column;
		animation: step-in 180ms ease-out;
	}

	@keyframes step-in {
		from { opacity: 0; transform: translateY(4px); }
		to { opacity: 1; transform: none; }
	}

	@media (prefers-reduced-motion: reduce) {
		.step { animation: none; }
		.spinner { animation-duration: 2s; }
	}

	h1 {
		font-family: var(--serif);
		font-size: 30px;
		font-weight: 400;
		line-height: 1.2;
		margin: 0 0 12px;
		outline: none;
	}

	.subtitle {
		font-size: 15px;
		line-height: 1.5;
		color: var(--text-secondary);
		margin: 0 0 28px;
	}

	.field-label {
		display: block;
		font-size: 13px;
		font-weight: 500;
		margin-bottom: 8px;
	}

	.text-input {
		width: 100%;
		box-sizing: border-box;
		height: 48px;
		padding: 0 14px;
		border: 1px solid var(--separator);
		border-radius: 12px;
		background: var(--card);
		color: var(--text);
		font: inherit;
		font-size: 16px;
	}

	.text-input:focus {
		outline: none;
		border: 1.5px solid var(--brand);
		padding: 0 13.5px;
	}

	.caption {
		font-size: 13px;
		color: var(--text-secondary);
		margin: 28px 0 8px;
	}

	.preview {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 64px;
		padding: 0 14px;
		box-sizing: border-box;
		border-radius: 14px;
		background: var(--surface);
	}

	.avatar {
		flex: none;
		width: 36px;
		height: 36px;
		border-radius: 50%;
		object-fit: cover;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		background: var(--brand-tint);
		color: var(--brand-strong);
		font-weight: 600;
		font-size: 15px;
	}

	.avatar.anonymous { background: var(--track); color: var(--text-secondary); }

	.preview-name {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: 16px;
	}

	.yes-chip {
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 30px;
		border-radius: 8px;
		background: var(--success-tint);
	}

	.check {
		width: 18px;
		height: 18px;
		fill: none;
		stroke: var(--success);
		stroke-width: 2.5;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	.inline-error, .calendar-error { color: var(--danger); font-size: 13px; }
	.inline-error { margin: -16px 0 20px; }
	.calendar-error { margin: 8px 0 0; }

	.provider {
		display: flex;
		gap: 16px;
		padding: 20px;
		border: 1px solid var(--separator);
		border-radius: 14px;
	}

	.provider-text { min-width: 0; }

	.provider h2 { font-size: 16px; font-weight: 600; margin: 2px 0 4px; }

	.provider-description {
		font-size: 13px;
		line-height: 1.45;
		color: var(--text-secondary);
		margin: 0 0 14px;
	}

	.google-mark { width: 18px; height: 18px; flex: none; }
	.google-mark.large { width: 28px; height: 28px; margin-top: 2px; }

	/* Google sign-in branding: white fill, #747775 outline, #1F1F1F label, full-color mark. */
	.google-button {
		display: inline-flex;
		align-items: center;
		gap: 10px;
		height: 40px;
		padding: 0 16px 0 12px;
		border: 1px solid #747775;
		border-radius: 20px;
		background: #ffffff;
		color: #1f1f1f;
		font-family: Roboto, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
		font-size: 14px;
		font-weight: 500;
		cursor: pointer;
	}

	.google-button:hover:not(:disabled) { background: #f8f9fa; }
	.google-button:disabled { cursor: default; opacity: 0.7; }

	@media (prefers-color-scheme: dark) {
		.google-button { background: #131314; border-color: #8e918f; color: #e3e3e3; }
		.google-button:hover:not(:disabled) { background: #1f1f20; }
	}

	.spinner {
		width: 16px;
		height: 16px;
		border-radius: 50%;
		border: 2px solid currentColor;
		border-right-color: transparent;
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin { to { transform: rotate(360deg); } }

	.connected-pill {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		height: 40px;
		padding: 0 18px 0 14px;
		border-radius: 20px;
		background: var(--success-tint);
		color: var(--success);
		font-size: 15px;
		font-weight: 500;
	}

	.note {
		font-size: 13px;
		line-height: 1.45;
		color: var(--text-secondary);
		margin: 20px 0 0;
	}

	.lock-note { display: flex; align-items: center; gap: 8px; margin-top: 12px; }

	.lock-note svg {
		width: 16px;
		height: 16px;
		flex: none;
		fill: var(--text-secondary);
		stroke: var(--text-secondary);
		stroke-width: 2;
	}

	.footer {
		margin-top: auto;
		padding-top: 32px;
		display: flex;
		gap: 12px;
	}

	.primary, .secondary {
		height: 48px;
		border-radius: 24px;
		font: inherit;
		font-size: 15px;
		cursor: pointer;
	}

	.primary {
		flex: 1;
		border: none;
		background: var(--primary-fill);
		color: var(--primary-text);
		font-weight: 600;
	}

	.primary:disabled { opacity: 0.6; cursor: default; }

	.secondary {
		flex: none;
		width: 120px;
		border: 1px solid var(--separator);
		background: transparent;
		color: var(--text);
	}

	/* The name field shows focus with its orange border instead. */
	.welcome button:focus-visible {
		outline: 2px solid var(--brand);
		outline-offset: 2px;
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		margin: -1px;
		padding: 0;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
		border: 0;
	}

	@media (max-width: 599px) {
		.welcome { padding: 24px 0 0; background: var(--card); }
		.brand { margin-bottom: 16px; }

		.card {
			flex: 1;
			max-width: none;
			min-height: 0;
			padding: 8px 24px 0;
			border: none;
			border-radius: 0;
		}

		.footer {
			position: sticky;
			bottom: 0;
			margin: auto -24px 0;
			padding: 16px 24px max(16px, env(safe-area-inset-bottom));
			background: var(--card);
		}
	}
</style>
