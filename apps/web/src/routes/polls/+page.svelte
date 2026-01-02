<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { user, profile, signOut } from '$lib/stores/auth';
	import { polls, createdPolls, joinedPolls, pollsLoading, loadMyPolls, loadPollByCode } from '$lib/stores/polls';
	import { subscription, loadSubscription, getMaxActivePolls } from '$lib/stores/subscription';

	let joinCode = $state('');
	let joinError = $state('');
	let joinLoading = $state(false);

	$effect(() => {
		if ($user === null) {
			goto('/auth');
		}
	});

	onMount(() => {
		loadMyPolls();
		// Load subscription separately without blocking poll display
		loadSubscription().catch((err) => {
			console.error('Failed to load subscription:', err);
		});
	});

	async function handleSignOut() {
		await signOut();
		goto('/');
	}

	async function handleJoinByCode() {
		const code = joinCode.trim().toUpperCase();

		if (!code) {
			joinError = 'Please enter a code';
			return;
		}

		if (code.length !== 6) {
			joinError = 'Code must be 6 characters';
			return;
		}

		joinError = '';
		joinLoading = true;

		try {
			const poll = await loadPollByCode(code);

			if (!poll) {
				joinError = 'Poll not found. Please check the code.';
				return;
			}

			if (poll.status === 'closed' || poll.status === 'archived') {
				joinError = 'This poll is closed and cannot accept new participants.';
				return;
			}

			// Navigate to the poll
			goto(`/polls/${poll.id}`);
		} catch (err) {
			console.error('Failed to join poll:', err);
			joinError = 'Failed to join poll. Please try again.';
		} finally {
			joinLoading = false;
		}
	}

	function canCreatePoll(): boolean {
		const maxPolls = getMaxActivePolls($subscription);
		const activePolls = $polls.filter((p) => p.status === 'draft' || p.status === 'active').length;
		return activePolls < maxPolls;
	}

	function formatDate(dateString: string): string {
		return new Date(dateString).toLocaleDateString();
	}

	function getStatusBadgeClass(status: string): string {
		switch (status) {
			case 'active':
				return 'badge-active';
			case 'closed':
				return 'badge-closed';
			case 'archived':
				return 'badge-archived';
			default:
				return 'badge-draft';
		}
	}
</script>

<div class="dashboard">
	<header>
		<div class="logo">Meeting Scheduler</div>
		<div class="user-menu">
			<span>{$profile?.display_name || $user?.email}</span>
			<button onclick={handleSignOut}>Sign Out</button>
		</div>
	</header>

	<main>
		<div class="page-header">
			<h1>My Polls</h1>
			{#if canCreatePoll()}
				<a href="/polls/new" class="btn primary">Create Poll</a>
			{:else}
				<button class="btn secondary" disabled title="Upgrade to create more polls">
					Upgrade to Pro
				</button>
			{/if}
		</div>

		<div class="join-by-code">
			<h2>Join a Poll</h2>
			<p>Enter a 6-character code to join an existing poll</p>
			<form onsubmit={(e) => { e.preventDefault(); handleJoinByCode(); }}>
				<div class="join-input-group">
					<input
						type="text"
						bind:value={joinCode}
						placeholder="ABC123"
						maxlength="6"
						class="join-input"
						disabled={joinLoading}
					/>
					<button type="submit" class="btn primary" disabled={joinLoading}>
						{joinLoading ? 'Joining...' : 'Join Poll'}
					</button>
				</div>
				{#if joinError}
					<p class="error-message">{joinError}</p>
				{/if}
			</form>
		</div>

		{#if $pollsLoading}
			<div class="loading">Loading polls...</div>
		{:else if $createdPolls.length === 0 && $joinedPolls.length === 0}
			<div class="empty-state">
				<h2>No polls yet</h2>
				<p>Create your first poll to start scheduling meetings.</p>
				<a href="/polls/new" class="btn primary">Create Your First Poll</a>
			</div>
		{:else}
			{#if $createdPolls.length > 0}
				<h2 class="section-header">My Polls</h2>
				<div class="polls-grid">
					{#each $createdPolls as poll}
						<a href="/polls/{poll.id}" class="poll-card">
							<div class="poll-header">
								<h3>{poll.title}</h3>
								<span class="badge {getStatusBadgeClass(poll.status)}">{poll.status}</span>
							</div>
							{#if poll.description}
								<p class="poll-description">{poll.description}</p>
							{/if}
							<div class="poll-meta">
								<span>Created {formatDate(poll.created_at)}</span>
							</div>
						</a>
					{/each}
				</div>
			{/if}

			{#if $joinedPolls.length > 0}
				<h2 class="section-header">Polls I Joined</h2>
				<div class="polls-grid">
					{#each $joinedPolls as poll}
						<a href="/polls/{poll.id}" class="poll-card">
							<div class="poll-header">
								<h3>{poll.title}</h3>
								<span class="badge {getStatusBadgeClass(poll.status)}">{poll.status}</span>
							</div>
							{#if poll.description}
								<p class="poll-description">{poll.description}</p>
							{/if}
							<div class="poll-meta">
								<span>Created {formatDate(poll.created_at)}</span>
							</div>
						</a>
					{/each}
				</div>
			{/if}
		{/if}
	</main>
</div>

<style>
	.dashboard {
		min-height: 100vh;
		background: #f5f5f5;
	}

	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 1rem 2rem;
		background: white;
		border-bottom: 1px solid #eee;
	}

	.logo {
		font-weight: 600;
		font-size: 1.25rem;
	}

	.user-menu {
		display: flex;
		align-items: center;
		gap: 1rem;
	}

	.user-menu button {
		padding: 0.5rem 1rem;
		background: transparent;
		border: 1px solid #ddd;
		border-radius: 6px;
		cursor: pointer;
	}

	.user-menu button:hover {
		background: #f5f5f5;
	}

	main {
		max-width: 1000px;
		margin: 0 auto;
		padding: 2rem;
	}

	.page-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 2rem;
	}

	.page-header h1 {
		margin: 0;
	}

	.section-header {
		margin: 2rem 0 1rem;
		font-size: 1.25rem;
		font-weight: 600;
	}

	.join-by-code {
		background: white;
		padding: 1.5rem;
		border-radius: 12px;
		margin-bottom: 2rem;
	}

	.join-by-code h2 {
		margin: 0 0 0.5rem;
		font-size: 1.25rem;
	}

	.join-by-code p {
		margin: 0 0 1rem;
		color: #666;
		font-size: 0.875rem;
	}

	.join-input-group {
		display: flex;
		gap: 0.75rem;
		align-items: flex-start;
	}

	.join-input {
		flex: 1;
		padding: 0.75rem;
		border: 1px solid #ddd;
		border-radius: 6px;
		font-size: 1rem;
		text-transform: uppercase;
		font-family: monospace;
		letter-spacing: 0.1em;
		max-width: 200px;
	}

	.join-input:focus {
		outline: none;
		border-color: #007bff;
	}

	.join-input:disabled {
		background: #f5f5f5;
		cursor: not-allowed;
	}

	.error-message {
		margin: 0.75rem 0 0;
		color: #dc3545;
		font-size: 0.875rem;
	}

	.btn {
		display: inline-block;
		padding: 0.75rem 1.5rem;
		border-radius: 6px;
		text-decoration: none;
		font-weight: 500;
		border: none;
		cursor: pointer;
		transition: all 0.2s ease;
	}

	.btn.primary {
		background: #007bff;
		color: white;
	}

	.btn.primary:hover {
		background: #0056b3;
	}

	.btn.secondary {
		background: #6c757d;
		color: white;
	}

	.btn:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.loading {
		text-align: center;
		padding: 4rem;
		color: #666;
	}

	.empty-state {
		text-align: center;
		padding: 4rem;
		background: white;
		border-radius: 12px;
	}

	.empty-state h2 {
		margin: 0 0 0.5rem;
	}

	.empty-state p {
		margin: 0 0 1.5rem;
		color: #666;
	}

	.polls-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
		gap: 1rem;
	}

	.poll-card {
		display: block;
		background: white;
		border-radius: 8px;
		padding: 1.25rem;
		text-decoration: none;
		color: inherit;
		transition: box-shadow 0.2s;
	}

	.poll-card:hover {
		box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
	}

	.poll-header {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		gap: 0.5rem;
		margin-bottom: 0.5rem;
	}

	.poll-header h3 {
		margin: 0;
		font-size: 1.125rem;
	}

	.badge {
		padding: 0.25rem 0.5rem;
		border-radius: 4px;
		font-size: 0.75rem;
		font-weight: 500;
		text-transform: uppercase;
	}

	.badge-draft {
		background: #f0f0f0;
		color: #666;
	}

	.badge-active {
		background: #d4edda;
		color: #155724;
	}

	.badge-closed {
		background: #fff3cd;
		color: #856404;
	}

	.badge-archived {
		background: #e2e3e5;
		color: #383d41;
	}

	.poll-description {
		margin: 0 0 0.75rem;
		color: #666;
		font-size: 0.875rem;
		display: -webkit-box;
		-webkit-line-clamp: 2;
		-webkit-box-orient: vertical;
		overflow: hidden;
	}

	.poll-meta {
		font-size: 0.75rem;
		color: #999;
	}
</style>
