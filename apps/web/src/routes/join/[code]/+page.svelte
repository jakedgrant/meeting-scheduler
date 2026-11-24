<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { user } from '$lib/stores/auth';
	import { sessionIdentity } from '$lib/session-scope';
	import { loadPollByCode, joinPoll } from '$lib/stores/polls';
	import { createPollInvitation } from '$lib/poll-invitation';

	let guestName = $state('');
	const invitation = createPollInvitation({
		loadPollByCode, joinPoll,
		open: id => { void goto(`/polls/${id}`, { replaceState: true }); }
	});
	onDestroy(() => invitation.dispose());
	const needsMembership = $derived($invitation.target?.requiresJoin && $invitation.target.creatorId !== $user?.id);

	$effect(() => {
		const code = $page.params.code ?? '';
		// Replacing a session also invalidates a pending confirmation or join result.
		void $sessionIdentity;
		untrack(() => { guestName = ''; void invitation.prepare(code); });
	});

	async function handleConfirm(event: SubmitEvent) {
		event.preventDefault();
		await invitation.confirm({ accountId: $user?.id ?? null, name: guestName });
	}
</script>

<div class="join-container">
	<div class="join-card">
		{#if $invitation.status === 'looking' || $invitation.status === 'joining'}
			<p class="subtitle">{$invitation.status === 'looking' ? 'Finding poll…' : 'Joining poll…'}</p>
		{:else if $invitation.status === 'ready' && $invitation.target}
			<h1>{$invitation.target.title}</h1>
			<p class="subtitle">{needsMembership ? 'Do you want to join this poll?' : 'Open this poll’s results?'}</p>
			<form onsubmit={handleConfirm}>
				{#if !$user}
					<label for="guest-name">Your name</label>
					<input id="guest-name" type="text" bind:value={guestName} placeholder="Enter your name" required />
				{/if}
				{#if $invitation.message}<p class="error" role="alert">{$invitation.message}</p>{/if}
				<button class="btn primary" type="submit">{needsMembership ? 'Join Poll' : 'Open Poll'}</button>
			</form>
			<p class="alt"><a href={$user ? '/polls' : '/'}>Cancel</a></p>
		{:else}
			<h1>Can't join this poll</h1>
			<p class="error" role="alert">{$invitation.message}</p>
			<p class="alt"><a href={$user ? '/polls' : '/'}>Back</a></p>
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
