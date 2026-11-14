<script lang="ts">
	import { onMount, onDestroy, tick } from 'svelte';
	import { goto } from '$app/navigation';
	import { get } from 'svelte/store';
	import { user } from '$lib/stores/auth';
	import { createPoll } from '$lib/stores/polls';
	import { createPollCreation } from '$lib/poll-creation';
	import { createSessionWork } from '$lib/session-scope';
	import { addDays, currentZone, today } from '$lib/date-time';
	import {
		advance, canAdvance, created, deadlineNote, firstOptionDate, goBack, goTo, initialStep, quickPickDate, quickPicks,
		reviewRows, stepLabel, type FlowStep
	} from '$lib/poll-flow';
	import TimeOptionsStep from '$lib/components/TimeOptionsStep.svelte';
	import PollShare from '$lib/components/PollShare.svelte';

	const work = createSessionWork();
	const creation = createPollCreation({ create: createPoll });
	onMount(() => user.subscribe(value => creation.setOwner(value?.id ?? null)));
	onDestroy(() => { creation.invalidate(); work.dispose(); });
	$effect(() => { creation.setOwner($user?.id ?? null); });

	// Redirect if not authenticated
	$effect(() => {
		if ($user === null) {
			goto('/auth');
		}
	});

	const zone = currentZone();
	const firstDate = today(zone);

	// A retained, unresolved submission reopens on the last step so it can be retried.
	const retained = () => { const state = get(creation); return state.uncertain || state.recoveryRequired; };
	let step = $state<FlowStep>(initialStep(retained()));
	let positioned = $state<string | null>(null);
	// The account's draft arrives after mount; place the flow once per account, and never after creation.
	$effect(() => {
		const owner = $creation.ownerId;
		if (owner === positioned) return;
		positioned = owner;
		if (owner && step !== 'share') step = initialStep($creation.uncertain || $creation.recoveryRequired);
	});

	let draft = $derived($creation.draft);
	let loading = $derived($creation.saving);
	let locked = $derived(loading || $creation.uncertain || $creation.recoveryRequired);
	let error = $state('');
	let heading = $state<HTMLElement | null>(null);

	let deadlineOn = $state(get(creation).draft.dueDate !== '');
	$effect(() => { if (draft.dueDate) deadlineOn = true; });

	const titles: Record<FlowStep, [string, string]> = {
		details: ['Poll details', 'What are you trying to schedule?'],
		timeOptions: ['Time options', 'Add the times people can vote on.'],
		deadline: ['Response deadline', 'Choose when voting closes. You can skip this.'],
		eventPass: ['Event Pass', 'Review your poll, then create it.'],
		share: ['Poll created', '']
	};

	async function move(next: FlowStep) {
		if (next === step) return;
		step = next;
		error = '';
		// Hand the new screen to assistive technology.
		await tick();
		heading?.focus();
	}

	function setDeadline(on: boolean) {
		deadlineOn = on;
		creation.edit({ dueDate: on ? addDays(firstDate, 1) : '' });
	}

	async function create() {
		const isCurrent = work.capture();
		error = '';
		const result = await creation.submit();
		if (isCurrent() && result) await move(created());
	}

	function submit(event: SubmitEvent) {
		event.preventDefault();
		if (step === 'eventPass') create();
		else move(advance(step, draft));
	}

	let first = $derived(firstOptionDate(draft));
	let rows = $derived(reviewRows(draft));
	let result = $derived($creation.result);
	let shownError = $derived(error || $creation.error);
</script>

<svelte:head><title>New poll · Meeting Scheduler</title></svelte:head>

<div class="create-poll">
	<header>
		<a href="/polls" class="close" aria-label={step === 'share' ? 'Close' : 'Cancel new poll'}>
			<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M5 5l14 14M19 5L5 19" /></svg>
		</a>
		{#if step !== 'share'}<p class="step-label">{stepLabel(step)}</p>{/if}
		<span class="spacer"></span>
	</header>

	{#if step === 'share' && result}
		<div class="done">
			<span class="badge" aria-hidden="true">
				<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
			</span>
			<h1 bind:this={heading} tabindex="-1">Poll created</h1>
			<p class="lead">{result.poll.title} is live. Share it any way you like.</p>
		</div>
		<PollShare pollId={result.poll.id} title={result.poll.title} shareCode={result.poll.share_code} />
		<div class="actions end">
			<a class="btn-link" href={`/polls/${result.poll.id}`}>Open poll</a>
		</div>
	{:else}
		<form onsubmit={submit}>
			<h1 bind:this={heading} tabindex="-1">{titles[step][0]}</h1>
			<p class="lead">{titles[step][1]}</p>

			{#if shownError}
				<div class="error" role="alert">{shownError}</div>
			{/if}

			{#if step === 'details'}
				<div class="card">
					<div class="field">
						<label for="title">Title</label>
						<input id="title" type="text" required value={draft.title} oninput={(event) => creation.edit({ title: event.currentTarget.value })} placeholder="Give your poll a name" disabled={locked} autocomplete="off" />
					</div>
					<div class="field">
						<label for="description">Description (optional)</label>
						<textarea id="description" value={draft.description} oninput={(event) => creation.edit({ description: event.currentTarget.value })} placeholder="Add some context" rows="4" disabled={locked}></textarea>
					</div>
					<div class="field">
						<label for="location">Location (optional)</label>
						<input id="location" type="text" value={draft.location} oninput={(event) => creation.edit({ location: event.currentTarget.value })} placeholder="Where is it?" disabled={locked} autocomplete="off" />
					</div>
				</div>
				<p class="note">Participants see these details when they open your poll.</p>
			{:else if step === 'timeOptions'}
				<TimeOptionsStep
					isAllDay={draft.isAllDay}
					timeOptions={draft.timeOptions}
					today={firstDate}
					{locked}
					onedit={(update) => creation.edit(update)}
					onerror={(message) => (error = message)}
				/>
			{:else if step === 'deadline'}
				<div class="card">
					<div class="row">
						<label for="deadline-on">Set response deadline</label>
						<button id="deadline-on" type="button" role="switch" aria-checked={deadlineOn} class="switch" class:on={deadlineOn} disabled={locked} onclick={() => setDeadline(!deadlineOn)}><span></span></button>
					</div>
					{#if deadlineOn}
						<div class="deadline-body">
							<div class="field">
								<label for="due-date">Close responses on</label>
								<input id="due-date" type="date" value={draft.dueDate} min={firstDate} oninput={(event) => creation.edit({ dueDate: event.currentTarget.value })} disabled={locked} />
							</div>
							<div class="field">
								<span class="label" id="quick-picks">Quick picks</span>
								<div class="chips" role="group" aria-labelledby="quick-picks">
									{#each quickPicks as pick}
										{@const date = quickPickDate(firstDate, pick.days)}
										<button type="button" class="chip" class:active={draft.dueDate === date} aria-pressed={draft.dueDate === date} disabled={locked} onclick={() => creation.edit({ dueDate: date })}>{pick.label}</button>
									{/each}
								</div>
							</div>
						</div>
					{/if}
				</div>
				{#if deadlineOn && draft.dueDate}
					<p class="note" aria-live="polite">{deadlineNote(draft.dueDate, first, zone)}</p>
				{/if}
			{:else if step === 'eventPass'}
				<div class="card">
					<div class="row">
						<label for="use-pass">Use an event pass for this poll</label>
						<button id="use-pass" type="button" role="switch" aria-checked={draft.useEventPass} class="switch" class:on={draft.useEventPass} disabled={locked} onclick={() => creation.edit({ useEventPass: !draft.useEventPass })}><span></span></button>
					</div>
				</div>
				<p class="note">Use your oldest available pass for this poll. If your subscription covers the poll, your pass is kept. Your plan and participant limit are checked when the poll is created.</p>

				<h2 class="section-label">Review</h2>
				<ul class="card review">
					{#each rows as row}
						<li>
							<button type="button" onclick={() => move(goTo(step, row.step))}>
								<span class="key">{row.label}</span>
								<span class="value">{row.value}<span class="chev" aria-hidden="true">&rsaquo;</span></span>
								<span class="sr">Edit {row.label.toLowerCase()}</span>
							</button>
						</li>
					{/each}
				</ul>
			{/if}

			<div class="actions" class:end={step === 'details'}>
				{#if step !== 'details'}
					<button type="button" class="circle ghost" aria-label="Back" onclick={() => move(goBack(step))} disabled={loading}>
						<svg width="14" height="22" viewBox="0 0 14 22" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 3L3 11l8 8" /></svg>
					</button>
				{/if}
				{#if step === 'eventPass'}
					<button type="submit" class="circle primary" aria-label={loading ? 'Creating poll' : $creation.error ? 'Retry create poll' : 'Create poll'} disabled={loading || !$creation.ownerId || $creation.recoveryRequired}>
						<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
					</button>
				{:else}
					<button type="submit" class="circle primary" aria-label="Continue" disabled={!canAdvance(step, draft)}>
						<svg width="14" height="22" viewBox="0 0 14 22" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 3l8 8-8 8" /></svg>
					</button>
				{/if}
			</div>
			{#if step === 'eventPass'}
				<p class="submit-hint" aria-live="polite">{loading ? 'Creating…' : $creation.error ? 'Retry creating this poll with the check button.' : ''}</p>
			{/if}
		</form>
	{/if}
</div>

<style>
	:global(body) { background: #f2f2f7; }
	.create-poll { max-width: 600px; margin: 0 auto; padding: 1rem 1rem 3rem; color: #111114; }
	header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem; }
	.close, .spacer { width: 44px; height: 44px; }
	.close { border-radius: 50%; background: #fff; display: flex; align-items: center; justify-content: center; color: #111114; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12); }
	.step-label { margin: 0; font-size: 0.9375rem; font-weight: 600; color: #5c5c61; }
	h1 { margin: 1rem 0 0; font-size: 1.875rem; line-height: 1.2; letter-spacing: -0.01em; }
	h1:focus { outline: none; }
	.lead { margin: 0.375rem 0 1rem; color: #5c5c61; font-size: 1rem; }
	.error { background: #fee; color: #a00; padding: 0.75rem; border-radius: 10px; margin-bottom: 1rem; }
	.card { background: #fff; border-radius: 16px; overflow: hidden; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1); margin-bottom: 0.75rem; list-style: none; padding: 0; }
	.field { padding: 0.875rem 1.25rem; display: flex; flex-direction: column; gap: 0.25rem; }
	.field + .field { border-top: 1px solid #e5e5ea; }
	.field label, .label { font-size: 0.8125rem; color: #5c5c61; }
	input[type='text'], textarea, input[type='date'] { font: inherit; font-size: 1.0625rem; border: 0; outline: 0; padding: 0; background: transparent; color: #111114; resize: vertical; }
	input[type='date'] { background: #efeff4; border-radius: 10px; padding: 0.5rem 0.75rem; min-height: 44px; box-sizing: border-box; align-self: flex-start; }
	input:focus-visible, textarea:focus-visible { outline: 3px solid #0b63ce; outline-offset: 4px; border-radius: 4px; }
	.note { margin: 0 1.25rem 0.75rem; font-size: 0.8125rem; line-height: 1.4; color: #5c5c61; }
	.row { display: flex; align-items: center; justify-content: space-between; gap: 1rem; min-height: 56px; padding: 0 1.25rem; }
	.row label { font-size: 1.0625rem; }
	.switch { flex: none; width: 51px; height: 31px; border-radius: 16px; border: 0; padding: 2px; background: #8e8e93; display: flex; align-items: center; cursor: pointer; }
	.switch span { width: 27px; height: 27px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3); transition: transform 0.15s; }
	.switch.on { background: #1f7a3d; }
	.switch.on span { transform: translateX(20px); }
	.switch:focus-visible, .chip:focus-visible, .review button:focus-visible, .circle:focus-visible, .close:focus-visible, .btn-link:focus-visible { outline: 3px solid #0b63ce; outline-offset: 2px; }
	.deadline-body { border-top: 1px solid #e5e5ea; padding: 0.25rem 0 0.75rem; }
	.chips { display: flex; flex-wrap: wrap; gap: 0.5rem; }
	.chip { border: 0; background: #efeff4; border-radius: 22px; padding: 0 1rem; min-height: 44px; font: inherit; font-size: 0.9375rem; color: #111114; cursor: pointer; }
	.chip.active { background: #0b63ce; color: #fff; font-weight: 600; }
	.section-label { margin: 1.25rem 1.25rem 0.5rem; font-size: 0.8125rem; font-weight: 400; color: #5c5c61; }
	.review li + li { border-top: 1px solid #e5e5ea; }
	.review button { width: 100%; min-height: 56px; padding: 0.75rem 1.25rem; display: flex; align-items: center; justify-content: space-between; gap: 1rem; border: 0; background: transparent; font: inherit; text-align: left; cursor: pointer; box-sizing: border-box; }
	.key { font-size: 0.9375rem; color: #5c5c61; flex: none; }
	.value { display: flex; align-items: center; gap: 0.5rem; font-size: 1.0625rem; min-width: 0; overflow-wrap: anywhere; text-align: right; }
	.chev { color: #5c5c61; font-size: 1.5rem; line-height: 1; }
	.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
	.actions { display: flex; align-items: center; justify-content: space-between; padding: 1rem 0.25rem 0; }
	.actions.end { justify-content: flex-end; }
	.circle { width: 60px; height: 60px; border-radius: 50%; border: 0; padding: 0; display: flex; align-items: center; justify-content: center; cursor: pointer; }
	.circle.primary { background: linear-gradient(180deg, #2a7de4, #0b63ce); color: #fff; box-shadow: 0 8px 24px rgba(11, 99, 206, 0.35); }
	.circle.ghost { background: #fff; color: #111114; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.14); }
	.circle:disabled { opacity: 0.4; cursor: default; box-shadow: none; }
	.submit-hint { min-height: 1.25rem; margin: 0.5rem 0 0; text-align: right; font-size: 0.875rem; color: #5c5c61; }
	.done { display: flex; flex-direction: column; align-items: center; text-align: center; margin-bottom: 0.5rem; }
	.badge { width: 64px; height: 64px; border-radius: 50%; background: #b85600; display: flex; align-items: center; justify-content: center; }
	.btn-link { display: inline-flex; align-items: center; min-height: 48px; padding: 0 1.5rem; border-radius: 24px; background: #0b63ce; color: #fff; text-decoration: none; font-weight: 600; }
</style>
