<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { user } from '$lib/stores/auth';
	import { loadPollByCode, joinPoll } from '$lib/stores/polls';
	import { joinFailureMessage, lookUpJoinablePoll } from '$lib/join-by-code';

	// Opening a share link is the decision to join: look the code up, join, then open the poll.
	let status = $state<'looking' | 'ready' | 'joining' | 'failed'>('looking');
	let message = $state('');
	let target = $state<{ id: string; title: string } | null>(null);
	let guestName = $state('');

	// Each start supersedes the last, so a changed code or account never shows or acts on stale results.
	let run = 0;
	onDestroy(() => run++);

	function open(id: string) {
		// Replace the link so Back does not return to a page that joins again.
		void goto(`/polls/${id}`, { replaceState: true });
	}

	async function join(id: string, name: string | undefined, current: number) {
		status = 'joining';
		message = '';
		try {
			await joinPoll(id, name);
			if (current === run) open(id);
		} catch (error) {
			if (current !== run) return;
			status = name === undefined ? 'failed' : 'ready';
			message = joinFailureMessage(error, name !== undefined);
		}
	}

	async function start(code: string, signedIn: boolean) {
		const current = ++run;
		status = 'looking';
		message = '';
		target = null;
		const found = await lookUpJoinablePoll(code, { loadPollByCode });
		if (current !== run) return;
		if (!found.ok) {
			status = 'failed';
			message = found.message;
			return;
		}
		target = found.poll;
		if (signedIn) await join(found.poll.id, undefined, current);
		else status = 'ready';
	}

	$effect(() => {
		const code = $page.params.code ?? '';
		const signedIn = $user !== null;
		untrack(() => void start(code, signedIn));
	});

	async function handleGuestJoin(event: SubmitEvent) {
		event.preventDefault();
		const name = guestName.trim();
		if (!target) return;
		if (!name) {
			message = 'Please enter your name';
			return;
		}
		await join(target.id, name, run);
	}
</script>

<div class="join-container">
	<div class="join-card">
		{#if status === 'looking' || status === 'joining'}
			<p class="subtitle">{status === 'looking' ? 'Finding poll…' : 'Joining poll…'}</p>
		{:else if status === 'ready' && target}
			<h1>{target.title}</h1>
			<p class="subtitle">Enter your name to join this poll.</p>
			<form onsubmit={handleGuestJoin}>
				<input type="text" bind:value={guestName} placeholder="Enter your name" required />
				{#if message}<p class="error">{message}</p>{/if}
				<button class="btn primary" type="submit">Join</button>
			</form>
		{:else}
			<h1>Can't join this poll</h1>
			<p class="error">{message}</p>
			<p class="alt">
				<a href={$user ? '/polls' : '/'}>Back</a>
			</p>
		{/if}
	</div>
</div>

<style>
	.join-container {
		display: flex;
		justify-content: center;
		align-items: center;
		min-height: 100vh;
		padding: 1rem;
		background: #f5f5f5;
	}

	.join-card {
		background: white;
		border-radius: 12px;
		padding: 2rem;
		width: 100%;
		max-width: 400px;
		box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
	}

	h1 {
		margin: 0 0 0.5rem;
		text-align: center;
		font-size: 1.5rem;
	}

	.subtitle {
		margin: 0 0 1.5rem;
		text-align: center;
		color: #666;
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	input {
		padding: 0.625rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
	}

	.btn {
		padding: 0.625rem 1rem;
		border-radius: 6px;
		font-size: 1rem;
		font-weight: 500;
		cursor: pointer;
		border: none;
		background: #007bff;
		color: white;
	}

	.error {
		margin: 0;
		color: #c0392b;
		font-size: 0.875rem;
		text-align: center;
	}

	.alt {
		margin: 1rem 0 0;
		text-align: center;
		font-size: 0.875rem;
	}
</style>
